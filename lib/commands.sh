# shellcheck shell=bash
# Operator commands added in 2.0: init-env, config, secret, zabbix-check, item-map, apply.
# They exist so that nobody has to hand-edit configuration files or type secrets on a command line.

SECRET_NAMES="zabbix-password clickhouse-password admin-password"

# ------------------------------------------------------------------------------------------------------------- init-env
# grafana-platform init-env [<file>] [KEY=VALUE ...]   create the environment file from the template and set values in one line.
# Without <file> it is env/production.env of this release, which every command then finds without --env-file.
cmd_init_env() {
  require_root
  if [ "${#OPT_ARGS[@]}" -eq 0 ] || [[ "${OPT_ARGS[0]}" == *=* ]]; then OPT_ARGS=("$RELEASE_DIR/env/production.env" "${OPT_ARGS[@]+"${OPT_ARGS[@]}"}"); fi
  local f=${OPT_ARGS[0]}
  if [ -e "$f" ] && [ "$OPT_YES" != 1 ]; then die "$f already exists: change values with '$(CLI) config set KEY=VALUE' (or add --yes to start over from the template)"; fi
  ( umask 027; cp "$RELEASE_DIR/env/production.env.example" "$f.new" ) || die "cannot write $f"
  if [ "${#OPT_ARGS[@]}" -gt 1 ]; then env_parser set "$f.new" "${OPT_ARGS[@]:1}" || { rm -f "$f.new" "$f.new.previous"; die "nothing was written"; }; fi
  rm -f "$f.new.previous"
  chmod 0640 "$f.new"; mv -f "$f.new" "$f"
  pass "created $f from env/production.env.example ($(( ${#OPT_ARGS[@]} - 1 )) value(s) set on the command line)"
  local o=""; [ "$f" -ef "$RELEASE_DIR/env/production.env" ] || o=" --env-file $f"
  info "review: $(CLI) config show$o      check: $(CLI) preflight$o"
}

# ------------------------------------------------------------------------------------------------------------- config
# grafana-platform config show|check|set KEY=VALUE ... [--env-file F]
cmd_config() {
  local sub=${OPT_ARGS[0]:-show} f k
  case "$sub" in
    set)
      require_root
      [ "${#OPT_ARGS[@]}" -gt 1 ] || die "usage: $(CLI) config set KEY=VALUE [KEY=VALUE ...] [--env-file F]"
      f=$(resolve_env_file)
      env_parser set "$f" "${OPT_ARGS[@]:1}" || die "$f was not changed"
      pass "updated $f: $(printf '%s ' "${OPT_ARGS[@]:1}" | sed -E 's/=[^ ]*/=…/g')(previous version: $f.previous)"
      if [ -f "$ENV_INSTALLED" ] && [ ! "$f" -ef "$ENV_INSTALLED" ]; then info "note: the installed configuration is $ENV_INSTALLED; it takes this change on the next: $(CLI) install --env-file $f"
      elif [ -f "$RELEASE_JSON" ]; then info "apply it: $(CLI) install   (re-converges configuration and content; changes nothing that already matches)"; fi ;;
    show|check)
      load_env
      if [ "$sub" = check ]; then pass "$ENV_FILE_USED is valid"; for k in "${ENV_WARNINGS[@]+"${ENV_WARNINGS[@]}"}"; do warn "$k"; done; return 0; fi
      printf '# %s (values after defaults; secrets are files and are never shown)\n' "$ENV_FILE_USED"
      while read -r k _; do printf '%-28s= %s\n' "$k" "${!k}"; done < <(env_parser keys)
      printf '%-28s= %s (%s)\n' "(package source)" "$PKG_SRC" "$PKG_SRC_WHY" ;;
    keys) env_parser keys ;;
    *) die "usage: $(CLI) config show|check|set|keys" ;;
  esac
}

# ------------------------------------------------------------------------------------------------------------- secret
# grafana-platform secret set <name>     prompts twice without echo (or reads one line from a pipe)
# grafana-platform secret status
cmd_secret() {
  require_root
  if ENV_FILE_TRY=$(resolve_env_file 2>/dev/null); then load_env; else SECRETS_DIR=$ETC/secrets; CLICKHOUSE_ENABLED=yes; fi
  local sub=${OPT_ARGS[0]:-status} name=${OPT_ARGS[1]:-} v v2 n
  case "$sub" in
    set)
      case " $SECRET_NAMES " in *" $name "*) ;; *) die "usage: $(CLI) secret set zabbix-password|clickhouse-password|admin-password" ;; esac
      if [ -t 0 ]; then
        IFS= read -r -s -p "Value for $name (not echoed): " v; echo
        IFS= read -r -s -p "Repeat: " v2; echo
        [ "$v" = "$v2" ] || die "the two entries differ; nothing was stored"
      else IFS= read -r v || true; fi
      v=${v%$'\r'}
      [ -n "$v" ] || die "empty value; nothing was stored"
      install -d -m 0750 "$SECRETS_DIR"; getent group grafana >/dev/null 2>&1 && chgrp grafana "$SECRETS_DIR"
      local tmp; tmp=$(umask 077; mktemp "$SECRETS_DIR/.$name.XXXXXX")
      printf '%s' "$v" > "$tmp"; chown root:root "$tmp"; chmod 0600 "$tmp"; mv -f "$tmp" "$SECRETS_DIR/$name"
      v=""; v2=""
      pass "secret $name stored in $SECRETS_DIR/$name (mode 600, root only); the value was not displayed or logged"
      if [ "$name" = admin-password ]; then
        if [ -f "$RELEASE_JSON" ]; then warn "Grafana reads admin-password only when its database is first created: change the live admin password in the Grafana UI (Profile -> Change password)"
        else info "install will use it as the initial Grafana admin password (user ${GRAFANA_ADMIN_USER:-admin})"; fi
      elif [ -f "$RELEASE_JSON" ]; then info "Grafana keeps its own encrypted copy: push the new value with: $(CLI) rotate-secrets"; fi ;;
    status)
      for n in $SECRET_NAMES secret-key; do
        if [ -s "$SECRETS_DIR/$n" ]; then printf '  %-20s present  mode %s  owner %s\n' "$n" "$(mode_of "$SECRETS_DIR/$n")" "$(owner_of "$SECRETS_DIR/$n")"
        else
          case "$n" in
            zabbix-password) printf '  %-20s MISSING  -> %s secret set %s\n' "$n" "$(CLI)" "$n" ;;
            clickhouse-password) if clickhouse_enabled; then printf '  %-20s MISSING  -> %s secret set %s\n' "$n" "$(CLI)" "$n"; else printf '  %-20s not needed (CLICKHOUSE_ENABLED=no)\n' "$n"; fi ;;
            *) printf '  %-20s generated by install\n' "$n" ;;
          esac
        fi
      done ;;
    *) die "usage: $(CLI) secret set <name> | secret status" ;;
  esac
}

# ------------------------------------------------------------------------------------------------------------- Zabbix helpers
zabbix_tool() { # runs tools/zabbix-item-map.mjs with the datasource credentials (password through the environment, never argv)
  zabbix_enabled || die "Zabbix is not connected (ZABBIX_ENABLED=no): connect it with: sudo ./install.sh --zabbix"
  node_runtime
  local pw; pw=$(secret zabbix-password)
  [ -n "$pw" ] || die "secret zabbix-password is missing: $(CLI) secret set zabbix-password"
  local extra=(); [ -n "${ZABBIX_CA_FILE:-}" ] && extra+=("NODE_EXTRA_CA_CERTS=$ZABBIX_CA_FILE")
  [ "$ZABBIX_TLS_SKIP_VERIFY" = true ] && [ "$ALLOW_INSECURE_DATASOURCES" = yes ] && extra+=("NODE_TLS_REJECT_UNAUTHORIZED=0")
  env "${extra[@]+"${extra[@]}"}" ZABBIX_URL="$ZABBIX_URL" ZABBIX_USER="$ZABBIX_USER" ZABBIX_PASSWORD="$pw" \
    "$(node_bin)" "$RELEASE_DIR/tools/zabbix-item-map.mjs" "$@"
}

# grafana-platform zabbix-check     log in with ZABBIX_USER + secret, count visible hosts, log out (read-only)
cmd_zabbix_check() {
  require_root; load_env
  step "Zabbix API login test ($ZABBIX_URL as $ZABBIX_USER)"
  local rc=0; zabbix_tool --check || rc=$?
  [ "$rc" = 0 ] && pass "Zabbix login works; the datasource will be able to authenticate" || { fail "Zabbix login test failed (see above)"; fix "wrong password: $(CLI) secret set zabbix-password ; wrong user: $(CLI) config set ZABBIX_USER=<user>"; return 1; }
}

# grafana-platform item-map [--host LABNAME=PRODNAME ...] [--set LABID=ITEMID ...] [--search WORD]
cmd_item_map() {
  require_root; load_env
  local out=$ZABBIX_ITEM_MAP_FILE rc=0
  install -d -m 0755 "$(dirname "$out")"
  step "Building the Zabbix item map for the NOC dashboards (read-only against $ZABBIX_URL)"
  zabbix_tool --out "$out" --merge "${OPT_ARGS[@]+"${OPT_ARGS[@]}"}" || rc=$?
  [ -f "$out" ] && { chmod 0640 "$out"; getent group grafana >/dev/null 2>&1 && chgrp grafana "$out"; }
  case "$rc" in
    0) pass "item map complete: $out"; info "deploy the NOC dashboards: $(CLI) config set ALLOW_NOC_WITHOUT_ITEM_MAP=no ; $(CLI) apply   (before install: just run install)" ;;
    3) warn "item map written but INCOMPLETE: $out (the unmapped ids are listed above; nothing was guessed)"
       info "different host names in production:  $(CLI) item-map --host SITE-A=<production host name> ..."
       info "find an item by hand:                  $(CLI) item-map --search <host name>"
       info "set an id you verified in Zabbix:      $(CLI) item-map --set <lab id>=<production item id>"
       info "or keep the NOC dashboards deferred:   $(CLI) config set ALLOW_NOC_WITHOUT_ITEM_MAP=yes" ;;
    *) fail "item map tool failed (exit $rc)"; return 1 ;;
  esac
}

# ------------------------------------------------------------------------------------------------------------- apply
# grafana-platform apply      re-apply datasources, dashboards and playlist only (after enabling ClickHouse, building the item map, ...)
cmd_apply() {
  require_root; load_env
  [ -f "$RELEASE_JSON" ] || die "Grafana is not installed by grafana-platform yet: run $(CLI) install"
  log_to_file apply
  step "Content"; apply_content
  step "Verification"; PASS_N=0; WARN_N=0; FAIL_N=0; verify_all
  summary "APPLY"
}

# ------------------------------------------------------------------------------------------------------------- uninstall
# grafana-platform uninstall [--yes] [--purge]
#   Returns the host to "no Grafana": safety backup first (when possible), then service, package, version lock, firewall rules, units, release
#   and command link are removed. KEPT by default: /etc/grafana-platform (configuration, secrets, item map), /var/lib/grafana (database),
#   /etc/grafana and every backup — so a later 'install' (of this or another release) can pick up where it was.
#   --purge additionally deletes /etc/grafana-platform, /etc/grafana, /var/lib/grafana and the private CA anchors this tool added. Backups are never deleted.
cmd_uninstall() {
  require_root; load_env; log_to_file uninstall
  local purge=0 x; for x in "${OPT_ARGS[@]+"${OPT_ARGS[@]}"}"; do [ "$x" = --purge ] && purge=1; done
  if [ ! -f "$RELEASE_JSON" ] && ! rpm -q grafana >/dev/null 2>&1; then pass "nothing to uninstall (no Grafana package, no managed installation)"; return 0; fi
  if [ ! -f "$RELEASE_JSON" ] && [ ! -f "$ETC/.install-started" ]; then die "Grafana is installed but not by grafana-platform: refusing to remove it"; fi
  if [ "$OPT_YES" != 1 ]; then read -r -p "Remove Grafana from this host$([ $purge = 1 ] && echo ' AND delete its data, configuration and secrets')? A backup is taken first. [y/N] " x; [ "$x" = y ] || die "aborted"; fi
  step "Safety backup"
  if [ -f "$GRAFANA_VAR/grafana.db" ] && command -v sqlite3 >/dev/null 2>&1; then
    if ( make_backup pre-uninstall && echo "$BACKUP_LAST" > "$ETC/.last-uninstall-backup" ); then pass "backup: $(cat "$ETC/.last-uninstall-backup")"; else warn "safety backup failed; continuing only because you confirmed"; fi
  else warn "no safety backup (no database or no sqlite3)"; fi
  step "Removing"
  systemctl disable --now grafana-platform-backup.timer >/dev/null 2>&1 || true
  systemctl stop grafana-server >/dev/null 2>&1 || true; systemctl disable grafana-server >/dev/null 2>&1 || true
  dnf -q versionlock delete grafana >/dev/null 2>&1 || true
  if rpm -q grafana >/dev/null 2>&1; then dnf -y -q remove grafana </dev/null >/dev/null && pass "package grafana removed" || fail "dnf could not remove grafana"; fi
  local zone r; zone=${GRAFANA_FIREWALL_ZONE:-$(firewall-cmd --get-default-zone 2>/dev/null || echo public)}
  while IFS= read -r r; do [[ "$r" == *"port=\"$GRAFANA_HTTP_PORT\""* ]] && firewall-cmd -q --permanent --zone="$zone" --remove-rich-rule="$r"; done < <(firewall-cmd --permanent --zone="$zone" --list-rich-rules 2>/dev/null || true)
  firewall-cmd -q --reload 2>/dev/null || true; pass "firewalld rules for $GRAFANA_HTTP_PORT/tcp removed (zone $zone)"
  rm -f /etc/yum.repos.d/grafana-platform.repo /etc/systemd/system/grafana-platform-backup.service /etc/systemd/system/grafana-platform-backup.timer
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -f /usr/local/sbin/grafana-platform; [ -L /usr/sbin/grafana-platform ] && rm -f /usr/sbin/grafana-platform; [ "$(readlink -f /usr/local/bin/node 2>/dev/null)" = "$OPT/node/bin/node" ] && rm -f /usr/local/bin/node
  rm -rf "${OPT:?}"; rm -f "$RELEASE_JSON" "$ETC/.install-started"
  pass "release, command link, units and repository definition removed"
  if [ "$purge" = 1 ]; then
    rm -rf "${GRAFANA_VAR:?}" "${GRAFANA_ETC:?}" "${ETC:?}"
    rm -f /etc/pki/ca-trust/source/anchors/grafana-platform-*.pem; update-ca-trust extract >/dev/null 2>&1 || true
    pass "purged: $GRAFANA_VAR, $GRAFANA_ETC, $ETC (configuration and secrets) and the CA anchors added by this tool"
  else info "kept: $ETC (platform.env, secrets, item map), $GRAFANA_VAR (database), $GRAFANA_ETC. Reinstall: <release>/bin/grafana-platform install"; fi
  info "backups kept in $BACKUP_DIR"
  summary "UNINSTALL"
}
