# shellcheck shell=bash
# verify / status / backup / restore / upgrade / rollback

count_tool_lines() { # read tool output on stdin, print it and count [PASS]/[WARN]/[FAIL] lines
  local l
  while IFS= read -r l; do
    case "$l" in
      "[PASS]"*) PASS_N=$((PASS_N+1)); printf '%s[PASS]%s%s\n' "$c_ok" "$c_off" "${l#\[PASS\]}" ;;
      "[WARN]"*) WARN_N=$((WARN_N+1)); printf '%s[WARN]%s%s\n' "$c_warn" "$c_off" "${l#\[WARN\]}" ;;
      "[FAIL]"*) FAIL_N=$((FAIL_N+1)); printf '%s[FAIL]%s%s\n' "$c_bad" "$c_off" "${l#\[FAIL\]}" ;;
    esac
  done
}

verify_all() {
  step "Platform and security baseline"
  # shellcheck disable=SC1090
  . "$OS_RELEASE_FILE"
  [ "$ID" = rhel ] && [[ "$VERSION_ID" == 9.* ]] && pass "OS: Red Hat Enterprise Linux $VERSION_ID" || { [ "${PLATFORM_ALLOW_EL_CLONE:-no}" = yes ] && warn "OS: $ID $VERSION_ID (EL clone allowed for acceptance testing)" || fail "OS: $ID $VERSION_ID is not RHEL 9.x"; }
  [ "$(getenforce 2>/dev/null)" = Enforcing ] && pass "SELinux Enforcing" || warn "SELinux is $(getenforce 2>/dev/null || echo unknown) (Grafana runs unconfined on RHEL either way; Enforcing is still recommended)"
  systemctl is-active --quiet firewalld && pass "firewalld active" || fail "firewalld inactive"
  local avc; avc=$(ausearch -m avc,user_avc -ts boot -c grafana-server 2>/dev/null | grep -c 'type=AVC' || true)
  [ "${avc:-0}" = 0 ] && pass "no SELinux denials for grafana-server since boot" || fail "$avc SELinux denial(s) for grafana-server since boot (ausearch -m avc -c grafana-server)"
  info "SELinux domain of the grafana process: $(ps -o label= -C grafana 2>/dev/null | head -1) (RHEL ships no Grafana policy; see docs/SECURITY-PRODUCTION.md)"

  step "Package"
  local cur want; cur=$(installed_version); want=$(want_version)
  [ "$cur" = "$want" ] && pass "grafana-$cur installed (pinned $want)" || fail "grafana is '$cur', this release pins $want"
  rpm -q --qf '%{RSAHEADER:pgpsig}' grafana 2>/dev/null | grep -qi "${GRAFANA_RPM_GPG_FPR: -16}" && pass "RPM signature: Grafana Labs key ${GRAFANA_RPM_GPG_FPR: -16}" || fail "RPM is not signed by the pinned Grafana key"
  local bad="" rl rp
  while IFS= read -r rl; do   # config files (c) and directories (the platform tightens /etc/grafana) are expected to differ
    rp=${rl##* }; case "$rl" in *" c /"*) continue ;; esac
    [ -d "$rp" ] || bad+="$rl; "
  done < <(rpm -V grafana 2>/dev/null || true)
  [ -z "$bad" ] && pass "packaged files unmodified (rpm -V)" || warn "packaged files differ from the RPM: ${bad:0:200}"
  dnf -q versionlock list 2>/dev/null | grep -q '^grafana-' && pass "version lock present" || warn "no dnf versionlock on grafana"

  step "Service and network"
  systemctl is-active --quiet grafana-server && pass "grafana-server active" || fail "grafana-server not active"
  systemctl is-enabled --quiet grafana-server && pass "grafana-server enabled at boot" || fail "grafana-server not enabled"
  local pu; pu=$(ps -o user= -C grafana 2>/dev/null | sort -u | tr '\n' ' ')
  [ "${pu// /}" = grafana ] && pass "runs as the unprivileged user 'grafana'" || fail "grafana process owner(s): '${pu}'"
  ss -ltnH "sport = :$GRAFANA_HTTP_PORT" | grep -q . && pass "listening on $GRAFANA_HTTP_PORT/tcp" || fail "nothing listens on $GRAFANA_HTTP_PORT/tcp"
  local zone; zone=${GRAFANA_FIREWALL_ZONE:-$(firewall-cmd --get-default-zone)}
  if firewall-cmd --zone="$zone" --list-rich-rules | grep -q "port=\"$GRAFANA_HTTP_PORT\""; then pass "firewalld admits $GRAFANA_HTTP_PORT/tcp only by source rule"; else fail "no firewalld source rule for $GRAFANA_HTTP_PORT/tcp"; fi
  if firewall-cmd --zone="$zone" --list-ports | tr ' ' '\n' | grep -qx "$GRAFANA_HTTP_PORT/tcp"; then fail "$GRAFANA_HTTP_PORT/tcp is open to every source in zone $zone"; else pass "port is not opened unrestricted"; fi
  local extra; extra=$( { ss -ltnpH | grep -E 'grafana' | awk '{print $4}' | grep -v ":$GRAFANA_HTTP_PORT\$" | tr '\n' ' '; } || true)
  [ -z "$extra" ] && pass "grafana listens on no other TCP port" || warn "grafana also listens on: $extra"
  if wait_health 30; then pass "/api/health ok over $GRAFANA_PROTOCOL"; else fail "/api/health failed"; fi
  if [ "$GRAFANA_PROTOCOL" = https ]; then
    curl_local -o /dev/null "$(base_url)/api/health" 2>/dev/null && pass "TLS certificate verifies against the system trust store for $GRAFANA_DOMAIN" || fail "TLS verification of $GRAFANA_DOMAIN failed"
    if curl_local --tls-max 1.1 -o /dev/null "$(base_url)/api/health" 2>/dev/null; then fail "server accepts TLS <= 1.1"; else pass "TLS 1.0/1.1 refused"; fi
    openssl x509 -in "$GRAFANA_ETC/tls/grafana.crt" -noout -checkend $((30*86400)) >/dev/null 2>&1 && pass "certificate valid for more than 30 days" || warn "certificate expires within 30 days"
  else warn "HTTP only: credentials and cookies are unencrypted"; fi
  [ "$(curl_local "$(base_url)/api/health" | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])' 2>/dev/null)" = "${GRAFANA_VERSION_OVERRIDE:-$GRAFANA_VERSION}" ] && pass "Grafana reports version ${GRAFANA_VERSION_OVERRIDE:-$GRAFANA_VERSION}" || fail "Grafana reports a different version"

  step "Files, secrets and permissions"
  chk_mode() { local m; m=$(mode_of "$1"); case " $2 " in *" $m "*) pass "$1 mode $m owner $(owner_of "$1")" ;; *) fail "$1 has mode $m (expected $2)" ;; esac; }
  chk_mode "$GRAFANA_ETC/grafana.ini" "640 600 440"
  chk_mode "$SECRETS_DIR/admin-password" "640 600 440"; chk_mode "$SECRETS_DIR/secret-key" "640 600 440"
  zabbix_enabled && chk_mode "$SECRETS_DIR/zabbix-password" "600 400"; clickhouse_enabled && chk_mode "$SECRETS_DIR/clickhouse-password" "600 400"
  [ "$GRAFANA_PROTOCOL" = https ] && chk_mode "$GRAFANA_ETC/tls/grafana.key" "640 600 440"
  [ -f "$GRAFANA_VAR/grafana.db" ] && [ "$(owner_of "$GRAFANA_VAR/grafana.db")" = grafana:grafana ] && pass "database owned by grafana, mode $(mode_of "$GRAFANA_VAR/grafana.db")" || fail "database missing or wrong owner"
  grep -rIlE 'password *= *[^$ ]' "$GRAFANA_ETC/grafana.ini" >/dev/null 2>&1 && fail "grafana.ini contains a literal password" || pass "grafana.ini holds no literal password"
  grep -q 'secret_key *= *\$__file' "$GRAFANA_ETC/grafana.ini" && pass "unique secret_key from file (not the packaged default)" || fail "secret_key is not taken from a file"
  local ctx; ctx=$(ls -Zd "$GRAFANA_VAR/grafana.db" 2>/dev/null | awk '{print $1}')
  [ -n "$ctx" ] && pass "SELinux label of the database: $ctx"

  step "Plugins"
  local id ver sha cur
  while read -r id ver sha _; do
    [ -z "$id" ] && continue; cur=$(plugin_version "$id")
    [ "$cur" = "$ver" ] && pass "plugin $id $ver" || fail "plugin $id is '$cur', pinned $ver"
  done < <(sed 's/#.*//' "$RELEASE_DIR/plugins/plugins.txt" | awk 'NF')

  step "Content (dashboards, folders, datasources, playlist)"
  count_tool_lines < <(run_content_tool verify --item-map "$ZABBIX_ITEM_MAP_FILE" 2>&1 || true)

  step "Operations"
  local last; last=$(ls -1t "$BACKUP_DIR"/grafana-platform-*.tar.gz* 2>/dev/null | head -1 || true)
  if [ -n "$last" ]; then [ $(( $(date +%s) - $(stat -c %Y "$last") )) -lt $((3*86400)) ] && pass "latest backup $(basename "$last")" || warn "latest backup is older than 3 days ($(basename "$last"))"; else warn "no backup exists yet in $BACKUP_DIR"; fi
  local errs; errs=$(journalctl -u grafana-server -p err --since "-30min" --no-pager -q 2>/dev/null | grep -vc '^$' || true)
  [ "${errs:-0}" -le 3 ] && pass "journal: $errs error line(s) in the last 30 min" || warn "journal: $errs error lines in the last 30 min (journalctl -u grafana-server -p err)"
}

cmd_verify() { require_root; load_env; verify_all; summary "VERIFY"; }

cmd_status() {
  require_root; load_env
  printf 'grafana-platform %s   Grafana %s   environment %s\n' "$(cat "$RELEASE_DIR/VERSION")" "$(installed_version)" "$PLATFORM_ENV"
  printf 'service : %s (enabled: %s)\n' "$(systemctl is-active grafana-server)" "$(systemctl is-enabled grafana-server 2>/dev/null)"
  printf 'endpoint: %s   health: %s\n' "$(base_url)" "$(curl_local "$(base_url)/api/health" 2>/dev/null | tr -d '\n ' || echo unreachable)"
  [ "$GRAFANA_PROTOCOL" = https ] && printf 'cert    : %s\n' "$(openssl x509 -in "$GRAFANA_ETC/tls/grafana.crt" -noout -enddate 2>/dev/null)"
  printf 'backups : %s (newest: %s)\n' "$BACKUP_DIR" "$(ls -1t "$BACKUP_DIR"/grafana-platform-*.tar.gz* 2>/dev/null | head -1 | xargs -r basename)"
  printf 'content : '; run_content_tool verify --item-map "$ZABBIX_ITEM_MAP_FILE" 2>&1 | tail -1
  python3 -c 'import json;d=json.load(open("'"$RELEASE_JSON"'"));print("release : installed",d.get("installed_at"),"updated",d.get("updated_at"),"last_upgrade",d.get("last_upgrade"))' 2>/dev/null || true
}

# ---------------------------------------------------------------------------------------------------------------- backup
BACKUP_LAST=""
make_backup() { # $1 label
  local label=${1:-manual} ts work stage
  ts=$(date +%Y%m%d-%H%M%S); work=$(mktemp -d); stage="$work/b"
  mkdir -p "$stage/etc-grafana" "$stage/etc-platform" "$stage/content" "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  command -v sqlite3 >/dev/null || die "sqlite3 is required for a consistent database copy"
  sqlite3 "$GRAFANA_VAR/grafana.db" ".backup '$stage/grafana.db'"
  [ "$(sqlite3 "$stage/grafana.db" 'PRAGMA integrity_check;')" = ok ] || die "database copy failed its integrity check"
  local with_secrets=0; { [ "$OPT_INCLUDE_SECRETS" = 1 ] || [ -n "${BACKUP_GPG_PASSPHRASE_FILE:-}" ]; } && with_secrets=1
  (cd "$GRAFANA_ETC" && tar --exclude=grafana.ini.rpm-default $([ "$with_secrets" = 1 ] || echo "--exclude=tls/*.key") -cf - .) | tar -xf - -C "$stage/etc-grafana"
  cp -a /etc/sysconfig/grafana-server "$stage/etc-grafana/sysconfig-grafana-server" 2>/dev/null || true
  cp -a "$ENV_INSTALLED" "$RELEASE_JSON" "$stage/etc-platform/" 2>/dev/null || true
  [ -f "$ZABBIX_ITEM_MAP_FILE" ] && cp -a "$ZABBIX_ITEM_MAP_FILE" "$stage/etc-platform/zabbix-item-map.json"
  mkdir -p "$stage/etc-platform/ca"; local cav   # public CA certificates named in the environment file: needed to rebuild trust on a new host
  for cav in ZABBIX_CA_FILE CLICKHOUSE_CA_FILE GRAFANA_TLS_CA_FILE; do [ -n "${!cav:-}" ] && [ -r "${!cav}" ] && cp "${!cav}" "$stage/etc-platform/ca/$cav.pem"; done
  if [ "$with_secrets" = 1 ]; then mkdir -p "$stage/secrets"; cp -a "$SECRETS_DIR/." "$stage/secrets/"; fi
  run_content_tool backup --out "$stage/content" >/dev/null 2>&1 || warn "content export (API) failed; the database copy is still complete"
  local sk; sk=$(sha256sum "$SECRETS_DIR/secret-key" | cut -d' ' -f1)
  { echo "created=$(date -u +%FT%TZ)"; echo "label=$label"; echo "host=$(hostname)"; echo "platform_version=$(cat "$RELEASE_DIR/VERSION")"
    echo "grafana_package=$(installed_version)"; echo "secrets_included=$with_secrets"; echo "secret_key_sha256=$sk"
    echo "--- sha256"; (cd "$stage" && find . -type f ! -name manifest.txt -print0 | sort -z | xargs -0 sha256sum); } > "$stage/manifest.txt"
  local out="$BACKUP_DIR/grafana-platform-$ts-$label.tar.gz"
  ( umask 077; tar -C "$stage" -czf "$out" . )
  if [ -n "${BACKUP_GPG_PASSPHRASE_FILE:-}" ]; then
    ( umask 077; gpg --batch --yes --pinentry-mode loopback --passphrase-file "$BACKUP_GPG_PASSPHRASE_FILE" --cipher-algo AES256 -o "$out.gpg" -c "$out" ) 2>/dev/null </dev/null && rm -f "$out" && out="$out.gpg" || die "encryption of the backup failed"
    pkill -x gpg-agent 2>/dev/null || true
  fi
  chmod 600 "$out"; rm -rf "$work"; BACKUP_LAST=$out
  # retention: the newest BACKUP_KEEP regular archives and the newest 5 safety (pre-*) archives are kept
  local old f
  for old in "-(manual|scheduled)\.tar\.gz(\.gpg)?$:$BACKUP_KEEP" "-pre-[a-z]+\.tar\.gz(\.gpg)?$:5"; do
    for f in $( { ls -1t "$BACKUP_DIR"/grafana-platform-*.tar.gz* 2>/dev/null | grep -E -e "${old%:*}" | tail -n +$(( ${old##*:} + 1 )); } || true); do rm -f "$f"; done
  done
}

cmd_backup() {
  require_root; load_env; log_to_file backup
  [ -f "$RELEASE_JSON" ] || die "not a managed installation"
  make_backup "$([ -n "${INVOCATION_ID:-}" ] && echo scheduled || echo manual)"
  pass "backup written: $BACKUP_LAST ($(stat -c %s "$BACKUP_LAST") bytes)"
  if [ -n "${BACKUP_GPG_PASSPHRASE_FILE:-}" ]; then pass "encrypted (AES256) and includes the secrets needed for recovery"
  elif [ "$OPT_INCLUDE_SECRETS" = 1 ]; then warn "archive is NOT encrypted but contains secrets: protect it like a credential"
  else warn "secrets are NOT in this archive. Recovery on a new host needs your own copy of $SECRETS_DIR (especially secret-key) — see docs/BACKUP-RESTORE.md"; fi
  summary "BACKUP"
}

# ---------------------------------------------------------------------------------------------------------------- restore
prepare_archive() { # $1 archive -> sets RESTORE_DIR
  local a=$1 plain
  [ -f "$a" ] || die "archive not found: $a"
  RESTORE_DIR=$(mktemp -d)
  plain=$a
  if [[ "$a" == *.gpg ]]; then
    [ -n "${BACKUP_GPG_PASSPHRASE_FILE:-}" ] || die "archive is encrypted: set BACKUP_GPG_PASSPHRASE_FILE"
    plain="$RESTORE_DIR/archive.tar.gz"
    gpg --batch --yes --pinentry-mode loopback --passphrase-file "$BACKUP_GPG_PASSPHRASE_FILE" -o "$plain" -d "$a" 2>/dev/null </dev/null || die "decryption failed (wrong passphrase or damaged archive)"
    pkill -x gpg-agent 2>/dev/null || true
  fi
  mkdir -p "$RESTORE_DIR/x"; tar -xzf "$plain" -C "$RESTORE_DIR/x" || die "archive cannot be extracted"
  [ "$plain" != "$a" ] && rm -f "$plain"
  (cd "$RESTORE_DIR/x" && sed -n '/^--- sha256$/,$p' manifest.txt | tail -n +2 | sha256sum -c --quiet) || die "archive fails its SHA-256 manifest: refusing to restore"
  if [ "${SKIP_DB_CHECK:-0}" != 1 ]; then [ "$(sqlite3 "$RESTORE_DIR/x/grafana.db" 'PRAGMA integrity_check;')" = ok ] || die "archived database fails its integrity check"; fi
}

manifest_get() { sed -n "s/^$1=//p" "$RESTORE_DIR/x/manifest.txt" | head -1; }

restore_bootstrap() { # new, empty host: put platform.env, secrets, item map, CA and TLS material from a backup (made with --include-secrets) back in place
  SKIP_DB_CHECK=1 prepare_archive "$1"
  [ "$(manifest_get secrets_included)" = 1 ] || die "this archive was made without --include-secrets: there are no secrets to bootstrap from; create $ETC/platform.env and $SECRETS_DIR yourself (docs/BACKUP-RESTORE.md)"
  local x="$RESTORE_DIR/x" v cur
  install -d -m 0755 "$ETC"; install -d -m 0700 "$ETC/secrets"
  cp -a "$x/secrets/." "$ETC/secrets/"; chmod 600 "$ETC"/secrets/*
  [ -f "$x/etc-platform/zabbix-item-map.json" ] && install -m 0640 "$x/etc-platform/zabbix-item-map.json" "$ETC/zabbix-item-map.json"
  install -d -m 0700 "$ETC/restored"
  [ -f "$x/etc-grafana/tls/grafana.crt" ] && cp "$x/etc-grafana/tls/grafana.crt" "$ETC/restored/grafana.crt"
  [ -f "$x/etc-grafana/tls/grafana.key" ] && cp "$x/etc-grafana/tls/grafana.key" "$ETC/restored/grafana.key" && chmod 600 "$ETC/restored/grafana.key"
  for v in ZABBIX_CA_FILE CLICKHOUSE_CA_FILE GRAFANA_TLS_CA_FILE; do [ -f "$x/etc-platform/ca/$v.pem" ] && cp "$x/etc-platform/ca/$v.pem" "$ETC/restored/$v.pem"; done
  install -m 0640 "$x/etc-platform/platform.env" "$ENV_INSTALLED"
  sed -i "s#^ZABBIX_ITEM_MAP_FILE=.*#ZABBIX_ITEM_MAP_FILE=$ETC/zabbix-item-map.json#" "$ENV_INSTALLED"
  # files named in the old environment file that do not exist on this host are replaced by the restored copies
  for v in GRAFANA_TLS_CERT_FILE:grafana.crt GRAFANA_TLS_KEY_FILE:grafana.key ZABBIX_CA_FILE:ZABBIX_CA_FILE.pem CLICKHOUSE_CA_FILE:CLICKHOUSE_CA_FILE.pem GRAFANA_TLS_CA_FILE:GRAFANA_TLS_CA_FILE.pem; do
    cur=$(sed -n "s/^${v%%:*}=//p" "$ENV_INSTALLED" | head -1)
    if [ -n "$cur" ] && [ ! -r "$cur" ] && [ -f "$ETC/restored/${v##*:}" ]; then sed -i "s#^${v%%:*}=.*#${v%%:*}=$ETC/restored/${v##*:}#" "$ENV_INSTALLED"; info "${v%%:*} now points at $ETC/restored/${v##*:}"; fi
  done
  rm -rf "$RESTORE_DIR"
  pass "platform.env, secrets, item map, CA and TLS material restored from $(basename "$1")"
  info "next: grafana-platform install, then: grafana-platform restore $1 --yes"
}

cmd_restore() {
  require_root; log_to_file restore
  local a="" boot=0 x
  for x in "${OPT_ARGS[@]}"; do case "$x" in --bootstrap) boot=1 ;; *) [ -z "$a" ] && a=$x ;; esac; done
  [ -n "$a" ] || die "usage: grafana-platform restore <archive> [--yes] [--bootstrap]"
  if [ "$boot" = 1 ]; then restore_bootstrap "$a"; return 0; fi
  load_env
  [ -f "$RELEASE_JSON" ] || die "no managed installation: run 'install' first, then restore. On a bare host with no environment file: restore <archive> --bootstrap first"
  prepare_archive "$a"
  local bpkg; bpkg=$(manifest_get grafana_package); local cur; cur=$(installed_version)
  info "archive: created $(manifest_get created), Grafana $bpkg, platform $(manifest_get platform_version), secrets_included=$(manifest_get secrets_included)"
  if [ -n "$cur" ] && [ "$(printf '%s\n%s\n' "$bpkg" "$cur" | sort -V | head -1)" != "$bpkg" ]; then die "the archive is from a NEWER Grafana ($bpkg) than the installed one ($cur): upgrade the package first"; fi
  [ "$cur" != "$bpkg" ] && warn "archive is from Grafana $bpkg, installed is $cur: Grafana will migrate the database on start"
  # the datasource passwords inside the database are encrypted with secret_key
  local want_sk have_sk; want_sk=$(manifest_get secret_key_sha256); have_sk=$(sha256sum "$SECRETS_DIR/secret-key" 2>/dev/null | cut -d' ' -f1 || true)
  if [ "$(manifest_get secrets_included)" = 1 ]; then pass "archive carries the secrets (including secret_key)"
  elif [ "$want_sk" = "$have_sk" ]; then pass "the current secret_key matches the archive"
  else die "this archive does not contain the secrets and $SECRETS_DIR/secret-key is NOT the key the database was encrypted with: put the original secret-key file in place first"; fi
  if [ "$OPT_YES" != 1 ]; then read -r -p "Grafana will be stopped and its database/configuration replaced. A safety backup is taken first. Continue? [y/N] " ans; [ "$ans" = y ] || die "aborted"; fi
  make_backup pre-restore; pass "safety backup of the current state: $BACKUP_LAST"
  systemctl stop grafana-server
  if [ "$(manifest_get secrets_included)" = 1 ]; then install -d -m 0750 -o root -g grafana "$SECRETS_DIR"; cp -a "$RESTORE_DIR/x/secrets/." "$SECRETS_DIR/"; fi
  install -m 0640 -o grafana -g grafana "$RESTORE_DIR/x/grafana.db" "$GRAFANA_VAR/grafana.db"
  rm -f "$GRAFANA_VAR/grafana.db-wal" "$GRAFANA_VAR/grafana.db-shm"; rm -rf "${GRAFANA_VAR:?}/unified-search"   # derived search index: rebuilt on start; a stale one would still serve restored-away dashboards
  (cd "$RESTORE_DIR/x/etc-grafana" && tar --exclude=sysconfig-grafana-server -cf - .) | tar -xf - -C "$GRAFANA_ETC"
  [ -f "$RESTORE_DIR/x/etc-grafana/sysconfig-grafana-server" ] && install -m 0640 -o root -g grafana "$RESTORE_DIR/x/etc-grafana/sysconfig-grafana-server" /etc/sysconfig/grafana-server
  [ -f "$RESTORE_DIR/x/etc-platform/zabbix-item-map.json" ] && [ ! -f "$ZABBIX_ITEM_MAP_FILE" ] && install -m 0640 -o root -g grafana "$RESTORE_DIR/x/etc-platform/zabbix-item-map.json" "$ZABBIX_ITEM_MAP_FILE"
  chown -R root:grafana "$GRAFANA_ETC"; chmod 0640 "$GRAFANA_ETC/grafana.ini"; [ -d "$GRAFANA_ETC/tls" ] && chmod 0750 "$GRAFANA_ETC/tls"
  [ -f "$SECRETS_DIR/zabbix-password" ] && chown root:root "$SECRETS_DIR/zabbix-password" "$SECRETS_DIR/clickhouse-password" 2>/dev/null || true
  restorecon -RF "$GRAFANA_ETC" "$GRAFANA_VAR" >/dev/null 2>&1 || true
  if [ "$GRAFANA_PROTOCOL" = https ] && [ ! -f "$GRAFANA_ETC/tls/grafana.key" ]; then install_tls; fi
  install_plugins
  systemctl start grafana-server
  wait_health 120 || { journalctl -u grafana-server -n 25 --no-pager >&2; die "Grafana is not healthy after the restore; the safety backup is $BACKUP_LAST"; }
  pass "database and configuration restored; Grafana healthy"
  rm -rf "$RESTORE_DIR"
  step "Verification after restore"; verify_all
  summary "RESTORE"
}

# ---------------------------------------------------------------------------------------------------------------- upgrade / rollback
set_last_upgrade() { python3 - "$RELEASE_JSON" "$1" "$2" "$3" <<'PY'
import json, sys, time
p, frm, to, bk = sys.argv[1:5]
d = json.load(open(p)); d["last_upgrade"] = {"from": frm, "to": to, "backup": bk, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "completed": False}
json.dump(d, open(p, "w"), indent=2)
PY
}
mark_upgrade_done() { python3 - "$RELEASE_JSON" "$1" <<'PY'
import json, sys
p, done = sys.argv[1:3]
d = json.load(open(p))
if d.get("last_upgrade"): d["last_upgrade"]["completed"] = (done == "1")
json.dump(d, open(p, "w"), indent=2)
PY
}

upgrade_inner() { # runs in a subshell inside an 'if': errexit is inactive there, so every step is checked explicitly
  dnf -q versionlock delete grafana >/dev/null 2>&1 || true
  import_rpm_key || return 1; install_grafana || return 1; lock_version || return 1
  install_plugins || return 1; render_grafana_ini || return 1; CONFIG_CHANGED=1; start_service || return 1
  deploy_release || return 1; apply_content || return 1
}

cmd_upgrade() {
  require_root; load_env; log_to_file upgrade
  [ -f "$RELEASE_JSON" ] || die "not a managed installation (no $RELEASE_JSON): use install"
  PLATFORM_STATE=MANAGED
  local cur want; cur=$(installed_version); want=$(want_version)
  info "installed: grafana-$cur   this release pins: grafana-$want"
  if [ "$cur" = "$want" ]; then
    info "package already current; re-converging configuration, plugins and content only"
    step "Preflight"; run_preflight install; [ "$FAIL_N" -eq 0 ] || { summary PREFLIGHT; die "preflight failed: nothing was changed"; }
    PASS_N=0; WARN_N=0; FAIL_N=0; CONFIG_CHANGED=0; PLUGINS_CHANGED=0
    install_plugins; render_grafana_ini; start_service; deploy_release; apply_content; write_release_json; verify_all; summary "UPGRADE (converge)"; return
  fi
  [ "$(printf '%s\n%s\n' "$cur" "$want" | sort -V | head -1)" = "$cur" ] || die "target grafana-$want is OLDER than the installed grafana-$cur: use 'rollback' to go back"
  step "Preflight"; run_preflight install
  [ "$FAIL_N" -eq 0 ] || { summary PREFLIGHT; die "preflight failed: nothing was changed"; }
  if [ "$OPT_YES" != 1 ]; then read -r -p "Upgrade grafana-$cur -> grafana-$want (a backup is taken first). Continue? [y/N] " ans; [ "$ans" = y ] || die "aborted"; fi
  PASS_N=0; WARN_N=0; FAIL_N=0; CONFIG_CHANGED=0; PLUGINS_CHANGED=0
  step "Backup before upgrade"; make_backup pre-upgrade; pass "pre-upgrade backup: $BACKUP_LAST"
  local bk=$BACKUP_LAST
  if [ "$PKG_SRC" = repo ]; then mkdir -p "$BACKUP_DIR/rpm"; (dnf -q download --destdir "$BACKUP_DIR/rpm" "grafana-$cur" </dev/null >/dev/null 2>&1 && pass "previous RPM cached for rollback") || warn "could not cache the previous RPM (rollback will download it from the repository)"; fi
  set_last_upgrade "$cur" "$want" "$bk"
  step "Upgrade"
  if ( upgrade_inner "$want" ); then
    mark_upgrade_done 1; write_release_json
    step "Verification"; PASS_N=0; WARN_N=0; FAIL_N=0; verify_all
    if [ "$FAIL_N" -gt 0 ] && [ "${UPGRADE_AUTO_ROLLBACK:-yes}" = yes ]; then fail "verification failed after the upgrade: rolling back automatically"; rollback_inner "$bk" "$cur"; summary "UPGRADE (rolled back)"; return 1; fi
    summary "UPGRADE"
  else
    fail "upgrade step failed"
    if [ "${UPGRADE_AUTO_ROLLBACK:-yes}" = yes ]; then rollback_inner "$bk" "$cur"; summary "UPGRADE (rolled back)"; return 1; fi
    die "upgrade failed; roll back with: grafana-platform rollback --yes"
  fi
}

rollback_inner() { # $1 archive $2 version-release to return to
  local arch=$1 ver=$2
  step "Rollback to grafana-$ver"
  systemctl stop grafana-server || true
  dnf -q versionlock delete grafana >/dev/null 2>&1 || true
  local rpmf; rpmf=$(ls -1 "$BACKUP_DIR"/rpm/grafana-"$ver".x86_64.rpm 2>/dev/null | head -1 || true)
  if [ -n "$rpmf" ]; then rpm -K "$rpmf" 2>&1 | grep -qi 'OK' && dnf -y -q downgrade "$rpmf" </dev/null >/dev/null || die "could not downgrade from the cached RPM"
  elif [ "$PKG_SRC" = bundle ] && [ -f "$BUNDLE_DIR/rpm/grafana-$ver.x86_64.rpm" ]; then dnf -y -q downgrade "$BUNDLE_DIR/rpm/grafana-$ver.x86_64.rpm" </dev/null >/dev/null
  else dnf -y -q downgrade "grafana-$ver" </dev/null >/dev/null || die "could not downgrade to grafana-$ver (no cached RPM, repository unavailable?)"; fi
  [ "$(installed_version)" = "$ver" ] && pass "package returned to grafana-$ver" || die "package is $(installed_version) after the downgrade attempt"
  dnf -q versionlock add "grafana-$ver" >/dev/null 2>&1 || true
  systemctl stop grafana-server || true   # the RPM scriptlets of the downgrade may have started it again: the database must not be replaced under a running Grafana
  OPT_YES=1; OPT_ARGS=("$arch"); RESTORE_FROM_ROLLBACK=1
  restore_state_only "$arch"
  start_service
  pass "state restored from $(basename "$arch") and Grafana healthy on grafana-$ver"
  mark_upgrade_done 0
  verify_all_after_rollback "$ver"
}

verify_all_after_rollback() { step "Verification after rollback"; export GRAFANA_VERSION_OVERRIDE=${1%-*}; verify_all; }

restore_state_only() { # database + configuration from an archive (service already stopped)
  prepare_archive "$1"
  install -m 0640 -o grafana -g grafana "$RESTORE_DIR/x/grafana.db" "$GRAFANA_VAR/grafana.db"; rm -f "$GRAFANA_VAR/grafana.db-wal" "$GRAFANA_VAR/grafana.db-shm"; rm -rf "${GRAFANA_VAR:?}/unified-search"
  if [ -d "$RESTORE_DIR/x/secrets" ]; then cp -a "$RESTORE_DIR/x/secrets/." "$SECRETS_DIR/"; fi
  (cd "$RESTORE_DIR/x/etc-grafana" && tar --exclude=sysconfig-grafana-server -cf - .) | tar -xf - -C "$GRAFANA_ETC"
  chown -R root:grafana "$GRAFANA_ETC"; chmod 0640 "$GRAFANA_ETC/grafana.ini"
  restorecon -RF "$GRAFANA_ETC" "$GRAFANA_VAR" >/dev/null 2>&1 || true
  rm -rf "$RESTORE_DIR"
}

cmd_rollback() {
  require_root; load_env; log_to_file rollback
  local arch=${OPT_ARGS[0]:-} from=""
  read -r from_ver arch_rec < <(python3 -c 'import json;d=json.load(open("'"$RELEASE_JSON"'"));u=d.get("last_upgrade") or {};print(u.get("from",""),u.get("backup",""))' 2>/dev/null || echo " ")
  [ -n "$arch" ] || arch=$arch_rec
  [ -n "$arch" ] && [ -f "$arch" ] || die "no archive: give one, or run it after an upgrade (release.json records the pre-upgrade backup)"
  from=$from_ver; [ -n "$from" ] || from=$(sed -n 's/^grafana_package=//p' <(tar -xzOf "$arch" ./manifest.txt 2>/dev/null) | head -1)
  [ -n "$from" ] || die "cannot determine the version to return to"
  if [ "$OPT_YES" != 1 ]; then read -r -p "Roll back to grafana-$from using $(basename "$arch")? Grafana is stopped and its state replaced. [y/N] " ans; [ "$ans" = y ] || die "aborted"; fi
  PASS_N=0; WARN_N=0; FAIL_N=0
  rollback_inner "$arch" "$from"
  summary "ROLLBACK"
}

# push the datasource passwords currently in the secret files into Grafana (after you changed zabbix-password / clickhouse-password)
cmd_rotate_secrets() {
  require_root; load_env; log_to_file rotate-secrets
  [ -f "$RELEASE_JSON" ] || die "not a managed installation"
  info "writing the passwords from the secret files ($(required_secrets | tr '\n' ' ')) into the datasources"
  run_content_tool apply --rotate-secrets --item-map "$ZABBIX_ITEM_MAP_FILE" | grep -aE 'datasource|health|applied' || true
  step "Verification"; verify_all; summary "ROTATE-SECRETS"
}
