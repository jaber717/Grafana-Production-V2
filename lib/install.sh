# shellcheck shell=bash
# Idempotent installation steps. Every step checks the current state first and changes nothing when it already matches.

PREREQS=(curl tar xz unzip openssl sqlite policycoreutils-python-utils python3 python3-dnf-plugin-versionlock gnupg2)

ensure_prereqs() {
  local missing=() p
  for p in "${PREREQS[@]}"; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [ "${#missing[@]}" -gt 0 ]; then info "installing prerequisites: ${missing[*]}"; dnf -y -q install "${missing[@]}" >/dev/null; fi
  pass "prerequisites present"
}

ensure_node() {
  if [ -n "$(node_bin)" ]; then pass "Node.js $("$(node_bin)" -v)"; return; fi
  # the pinned Node.js of the offline bundle is preferred whenever it is present: no dependency on AppStream module streams
  if [ -f "$BUNDLE_DIR/node/$NODE_BUNDLE_FILE" ]; then
    [ "$(sha256sum "$BUNDLE_DIR/node/$NODE_BUNDLE_FILE" | cut -d' ' -f1)" = "$NODE_BUNDLE_SHA256" ] || die "bundled Node.js tarball fails its pinned SHA-256: refusing to install"
    rm -rf "${OPT:?}/node"; mkdir -p "$OPT/node"; tar -xJf "$BUNDLE_DIR/node/$NODE_BUNDLE_FILE" -C "$OPT/node" --strip-components=1 --no-same-owner
    ln -sfn "$OPT/node/bin/node" /usr/local/bin/node
    pass "Node.js $("$(node_bin)" -v) installed to $OPT/node from the offline bundle (SHA-256 verified)"; return
  fi
  # AppStream: the default (non-modular) nodejs of RHEL 9 is too old for the tools, so the nodejs:20 module stream is selected explicitly.
  # An existing older nodejs package is NOT replaced behind the operator's back (other software on the host may depend on it).
  if rpm -q nodejs >/dev/null 2>&1; then
    die "nodejs $(rpm -q --qf '%{VERSION}' nodejs) is installed but the tools need >= 18. Either put the offline bundle next to this release (preferred), or switch it yourself: dnf -y module switch-to nodejs:20"
  fi
  dnf -y -q module reset nodejs >/dev/null 2>&1 || true
  dnf -y -q module enable nodejs:20 >/dev/null 2>&1 || true
  dnf -y -q install nodejs </dev/null >/dev/null 2>&1 || true
  [ -n "$(node_bin)" ] && pass "Node.js $("$(node_bin)" -v) installed from AppStream (module nodejs:20)" || die "could not provide Node.js >= 18 (AppStream nodejs:20 not available and no offline bundle at $BUNDLE_DIR)"
}

gpg_fingerprint() { GNUPGHOME=$(mktemp -d) gpg --batch --quiet --show-keys --with-colons "$1" 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}'; }

import_rpm_key() {
  local key="$RELEASE_DIR/vendor/rpm/RPM-GPG-KEY-grafana" fpr
  fpr=$(gpg_fingerprint "$key")
  [ "$fpr" = "$GRAFANA_RPM_GPG_FPR" ] || die "vendored Grafana signing key has fingerprint '$fpr', expected $GRAFANA_RPM_GPG_FPR: refusing to import"
  install -m 0644 "$key" /etc/pki/rpm-gpg/RPM-GPG-KEY-grafana
  rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-grafana
  pass "Grafana RPM signing key imported (fingerprint $fpr verified against the pinned value)"
  local exp_epoch; exp_epoch=$(date -d "$GRAFANA_RPM_GPG_EXPIRES" +%s 2>/dev/null || echo 0)
  [ "$exp_epoch" -gt $(( $(date +%s) + 90*86400 )) ] || warn "the Grafana signing key expires $GRAFANA_RPM_GPG_EXPIRES: refresh vendor/rpm/RPM-GPG-KEY-grafana from a verified source before then"
}

install_grafana() {
  local want cur; want=$(want_version); cur=$(installed_version)
  if [ "$cur" = "$want" ]; then pass "grafana-$want already installed"; return; fi
  if [ -n "$cur" ] && [ "$PLATFORM_STATE" != MANAGED ]; then die "grafana-$cur is installed and unmanaged"; fi
  install -d -m 0755 "$ETC"; date -u +%FT%TZ > "$ETC/.install-started"   # lets an interrupted install be resumed instead of being reported as a foreign Grafana
  if [ "$PKG_SRC" = repo ]; then
    cat > /etc/yum.repos.d/grafana-platform.repo <<EOF
# managed by grafana-platform - signed repository metadata and packages, restricted to the grafana package
[grafana-platform]
name=Grafana OSS (grafana-platform)
baseurl=$GRAFANA_RPM_REPO_URL
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-grafana
sslverify=1
includepkgs=grafana
EOF
    dnf -y -q makecache --repo grafana-platform >/dev/null 2>&1 </dev/null || true
    pkill -x gpg-agent 2>/dev/null || true; pkill -x scdaemon 2>/dev/null || true
    dnf -y install "grafana-$want" </dev/null >/dev/null || die "dnf could not install grafana-$want from the Grafana repository (signature, availability or network)"
    pkill -x gpg-agent 2>/dev/null || true; pkill -x scdaemon 2>/dev/null || true
  else
    local rpmf="$BUNDLE_DIR/rpm/grafana-$want.x86_64.rpm"
    [ -f "$rpmf" ] || die "offline bundle has no $rpmf (build the bundle from this release: tools/build-offline-bundle.sh)"
    local out; out=$(rpm -K "$rpmf" 2>&1) || die "RPM signature check failed: $out"
    echo "$out" | grep -qiE 'digests signatures OK|signatures ok|pgp.*OK' || die "RPM is not signed by an imported key: $out"
    dnf -y install "$rpmf" </dev/null >/dev/null || die "dnf could not install $rpmf (its dependencies come from your RHEL repositories)"
    install -d -m 0700 "$BACKUP_DIR/rpm"; cp -f "$rpmf" "$BACKUP_DIR/rpm/" 2>/dev/null || true   # kept for rollbacks after the bundle directory is gone
  fi
  [ "$(installed_version)" = "$want" ] || die "after installation grafana is $(installed_version), expected $want"
  local sig; sig=$(rpm -q --qf '%{RSAHEADER:pgpsig}' grafana 2>/dev/null || true)
  echo "$sig" | grep -qi "${GRAFANA_RPM_GPG_FPR: -16}" && pass "grafana-$want installed; RPM header signed by ${GRAFANA_RPM_GPG_FPR: -16}" || die "installed RPM signature is '$sig', expected key ${GRAFANA_RPM_GPG_FPR: -16}"
}

lock_version() {
  dnf -q versionlock delete grafana >/dev/null 2>&1 || true
  dnf -q versionlock add "grafana-$(want_version)" >/dev/null 2>&1 && pass "package version-locked (changes only through 'grafana-platform upgrade')" || warn "could not set a dnf versionlock"
}

ensure_secrets() {
  install -d -m 0750 -o root -g grafana "$SECRETS_DIR"
  local f
  if [ ! -s "$SECRETS_DIR/secret-key" ]; then head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | head -c 40 > "$SECRETS_DIR/secret-key"; info "generated $SECRETS_DIR/secret-key (database secrets are encrypted with it: it is part of every backup/restore decision)"; fi
  if [ ! -s "$SECRETS_DIR/admin-password" ]; then head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | head -c 24 > "$SECRETS_DIR/admin-password"; info "generated $SECRETS_DIR/admin-password (not printed; read it from that file)"; fi
  for f in secret-key admin-password; do chown root:grafana "$SECRETS_DIR/$f"; chmod 0640 "$SECRETS_DIR/$f"; done
  for f in zabbix-password clickhouse-password; do [ -f "$SECRETS_DIR/$f" ] || continue; chown root:root "$SECRETS_DIR/$f"; chmod 0600 "$SECRETS_DIR/$f"; done
  pass "secret files in place with least-privilege modes"
}

install_tls() {
  [ "$GRAFANA_PROTOCOL" = https ] || return 0
  install -d -m 0750 -o root -g grafana "$GRAFANA_ETC/tls"
  install -m 0640 -o root -g grafana "$GRAFANA_TLS_CERT_FILE" "$GRAFANA_ETC/tls/grafana.crt"
  install -m 0640 -o root -g grafana "$GRAFANA_TLS_KEY_FILE" "$GRAFANA_ETC/tls/grafana.key"
  restorecon -RF "$GRAFANA_ETC/tls" >/dev/null 2>&1 || true
  pass "TLS certificate and key installed in $GRAFANA_ETC/tls (key 0640 root:grafana)"
}

install_ca_trust() {
  local changed=0 f name
  for pair in "ZABBIX_CA_FILE:grafana-platform-zabbix" "CLICKHOUSE_CA_FILE:grafana-platform-clickhouse" "GRAFANA_TLS_CA_FILE:grafana-platform-grafana"; do
    local var=${pair%%:*}; f=${!var:-}; name=${pair##*:}
    [ -n "$f" ] || continue
    if ! cmp -s "$f" "/etc/pki/ca-trust/source/anchors/$name.pem" 2>/dev/null; then install -m 0644 "$f" "/etc/pki/ca-trust/source/anchors/$name.pem"; changed=1; fi
  done
  if [ "$changed" = 1 ]; then update-ca-trust extract; CONFIG_CHANGED=1; pass "private CA certificate(s) added to the system trust store"; else pass "CA trust store up to date"; fi
}

render_grafana_ini() {
  local cookie_secure=true proto=$GRAFANA_PROTOCOL tlsl=""
  [ "$GRAFANA_PROTOCOL" = http ] && cookie_secure=false
  [ "$GRAFANA_PROTOCOL" = https ] && tlsl=$'cert_file = /etc/grafana/tls/grafana.crt\ncert_key = /etc/grafana/tls/grafana.key\nmin_tls_version = TLS1.2'
  [ -f "$GRAFANA_ETC/grafana.ini.rpm-default" ] || cp -a "$GRAFANA_ETC/grafana.ini" "$GRAFANA_ETC/grafana.ini.rpm-default"
  local new; new=$(mktemp)
  cat > "$new" <<EOF
# Managed by grafana-platform $(cat "$RELEASE_DIR/VERSION") — edit env/platform.env and re-run 'grafana-platform install', not this file.
# The packaged default is kept in grafana.ini.rpm-default. Secrets are read from files (\$__file{}), never stored here.
[paths]
data = $GRAFANA_VAR
logs = /var/log/grafana
plugins = $GRAFANA_VAR/plugins
provisioning = $GRAFANA_ETC/provisioning

[server]
protocol = $proto
http_addr = 0.0.0.0
http_port = $GRAFANA_HTTP_PORT
domain = $GRAFANA_DOMAIN
root_url = ${GRAFANA_ROOT_URL:-$proto://$GRAFANA_DOMAIN:$GRAFANA_HTTP_PORT/}
enforce_domain = false
$tlsl

[security]
admin_user = $GRAFANA_ADMIN_USER
admin_password = \$__file{$SECRETS_DIR/admin-password}
secret_key = \$__file{$SECRETS_DIR/secret-key}
cookie_secure = $cookie_secure
cookie_samesite = lax
disable_gravatar = true
allow_embedding = false
strict_transport_security = $cookie_secure
x_content_type_options = true
x_xss_protection = true

[users]
allow_sign_up = false
allow_org_create = false
auto_assign_org_role = Viewer
default_theme = dark

[auth.anonymous]
enabled = false

[auth.basic]
enabled = true

[analytics]
reporting_enabled = false
check_for_updates = false
check_for_plugin_updates = false

[plugins]
plugin_admin_enabled = false

[snapshots]
external_enabled = false

[news]
news_feed_enabled = false

[log]
mode = console file
level = info
EOF
  if ! cmp -s "$new" "$GRAFANA_ETC/grafana.ini"; then install -m 0640 -o root -g grafana "$new" "$GRAFANA_ETC/grafana.ini"; CONFIG_CHANGED=1; pass "grafana.ini rendered ($GRAFANA_PROTOCOL, port $GRAFANA_HTTP_PORT)"; else pass "grafana.ini already up to date"; fi
  rm -f "$new"; restorecon -F "$GRAFANA_ETC/grafana.ini" >/dev/null 2>&1 || true
}

plugin_version() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["info"]["version"])' "$GRAFANA_VAR/plugins/$1/plugin.json" 2>/dev/null || true; }

install_plugins() {
  local id ver sha cur tmp zip
  while read -r id ver sha _; do
    [ -z "$id" ] && continue
    cur=$(plugin_version "$id")
    if [ "$cur" = "$ver" ]; then pass "plugin $id $ver already installed"; continue; fi
    tmp=$(mktemp -d)
    if [ "$PKG_SRC" = repo ]; then
      curl -fsSL -m 300 -o "$tmp/p.zip" "https://grafana.com/api/plugins/$id/versions/$ver/download?os=linux&arch=amd64" || die "download of plugin $id $ver failed"
    else
      cp "$BUNDLE_DIR/plugins/$id-$ver.zip" "$tmp/p.zip" || die "offline bundle has no plugin $id-$ver.zip"
    fi
    [ "$(sha256sum "$tmp/p.zip" | cut -d' ' -f1)" = "$sha" ] || die "plugin $id $ver fails its pinned SHA-256 (expected $sha): refusing to install"
    unzip -q -o "$tmp/p.zip" -d "$tmp/x"
    [ -f "$tmp/x/$id/plugin.json" ] || die "plugin archive for $id has an unexpected layout"
    rm -rf "${GRAFANA_VAR:?}/plugins/$id"; install -d -o grafana -g grafana "$GRAFANA_VAR/plugins"
    mv "$tmp/x/$id" "$GRAFANA_VAR/plugins/$id"; chown -R grafana:grafana "$GRAFANA_VAR/plugins/$id"; restorecon -RF "$GRAFANA_VAR/plugins/$id" >/dev/null 2>&1 || true
    rm -rf "$tmp"; PLUGINS_CHANGED=1
    [ "$(plugin_version "$id")" = "$ver" ] && pass "plugin $id $ver installed (SHA-256 verified)" || die "plugin $id is not at $ver after installation"
  done < <(sed 's/#.*//' "$RELEASE_DIR/plugins/plugins.txt" | awk 'NF')
}

configure_firewall() {
  local zone=${GRAFANA_FIREWALL_ZONE:-$(firewall-cmd --get-default-zone)} cidr fam rule want=()
  for cidr in $GRAFANA_ALLOWED_CIDRS; do
    fam=ipv4; [[ "$cidr" == *:* ]] && fam=ipv6
    rule="rule family=\"$fam\" source address=\"$cidr\" port port=\"$GRAFANA_HTTP_PORT\" protocol=\"tcp\" accept"
    want+=("$rule")
    firewall-cmd -q --permanent --zone="$zone" --query-rich-rule="$rule" || firewall-cmd -q --permanent --zone="$zone" --add-rich-rule="$rule"
  done
  # remove any other rule for this port (a stale CIDR, or an unrestricted port opening)
  local r; while IFS= read -r r; do
    [ -z "$r" ] && continue; [[ "$r" == *"port=\"$GRAFANA_HTTP_PORT\""* ]] || continue
    local keep=0 w; for w in "${want[@]}"; do [ "$r" = "$w" ] && keep=1; done
    [ "$keep" = 1 ] || firewall-cmd -q --permanent --zone="$zone" --remove-rich-rule="$r"
  done < <(firewall-cmd --permanent --zone="$zone" --list-rich-rules)
  firewall-cmd -q --permanent --zone="$zone" --query-port="$GRAFANA_HTTP_PORT/tcp" && firewall-cmd -q --permanent --zone="$zone" --remove-port="$GRAFANA_HTTP_PORT/tcp"
  firewall-cmd -q --reload
  pass "firewalld ($zone): $GRAFANA_HTTP_PORT/tcp admitted only from: $GRAFANA_ALLOWED_CIDRS"
}

start_service() {
  systemctl daemon-reload
  systemctl enable grafana-server >/dev/null 2>&1
  if systemctl is-active --quiet grafana-server; then
    if [ "${CONFIG_CHANGED:-0}" = 1 ] || [ "${PLUGINS_CHANGED:-0}" = 1 ]; then systemctl restart grafana-server; info "grafana-server restarted (configuration or plugins changed)"; fi
  else systemctl start grafana-server; fi
  wait_health 120 && pass "Grafana answers /api/health over $GRAFANA_PROTOCOL" || { journalctl -u grafana-server -n 25 --no-pager >&2; die "Grafana did not become healthy; see 'journalctl -u grafana-server'"; }
}

install_units() {
  local u changed=0
  for u in grafana-platform-backup.service grafana-platform-backup.timer; do
    cmp -s "$RELEASE_DIR/systemd/$u" "/etc/systemd/system/$u" 2>/dev/null || { install -m 0644 "$RELEASE_DIR/systemd/$u" "/etc/systemd/system/$u"; changed=1; }
  done
  [ "$changed" = 1 ] && systemctl daemon-reload
  systemctl enable --now grafana-platform-backup.timer >/dev/null 2>&1
  pass "daily backup timer installed and enabled (grafana-platform-backup.timer)"
}

deploy_release() {
  local ver dest; ver=$(cat "$RELEASE_DIR/VERSION"); dest="$OPT/releases/$ver"
  install -d -m 0755 "$OPT/releases"
  if [ "$RELEASE_DIR" != "$dest" ]; then
    rm -rf "$dest.new"; mkdir -p "$dest.new"
    (cd "$RELEASE_DIR" && tar --exclude=.git --exclude=./dist --exclude=backups --exclude=node_modules --exclude='env/production.env' --exclude='env/production.env.previous' -cf - .) | tar -xf - -C "$dest.new"
    rm -rf "$dest"; mv "$dest.new" "$dest"
  fi
  ln -sfn "$dest" "$OPT/current"; ln -sfn "$OPT/current/bin/grafana-platform" /usr/local/sbin/grafana-platform
  RELEASE_DIR=$dest; LIBDIR="$dest/lib"
  pass "release $ver deployed to $dest (command: /usr/local/sbin/grafana-platform)"
}

write_release_json() {
  install -d -m 0755 "$ETC"
  python3 - "$RELEASE_JSON" "$(cat "$RELEASE_DIR/VERSION")" "$(installed_version)" "$PLATFORM_ENV" "$PKG_SRC" <<'PY'
import json, sys, time, platform
path, pv, gv, env, src = sys.argv[1:6]
try:
    old = json.load(open(path))
except Exception:
    old = {}
d = {"platform_version": pv, "grafana_version": gv, "environment": env, "package_source": src,
     "installed_at": old.get("installed_at") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
     "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "os": platform.platform(), "last_upgrade": old.get("last_upgrade")}
json.dump(d, open(path, "w"), indent=2); open(path, "a").write("\n")
PY
  chmod 0644 "$RELEASE_JSON"; rm -f "$ETC/.install-started"
}

apply_content() {
  info "applying folders, datasources, dashboards and playlist (idempotent)"
  run_content_tool apply --item-map "$ZABBIX_ITEM_MAP_FILE" || die "content deployment failed (see output above)"
  pass "content deployed"
}

cmd_install() {
  require_root; load_env; log_to_file install
  step "Preflight"
  PLATFORM_STATE=""; run_preflight install
  if [ "$FAIL_N" -gt 0 ]; then summary "PREFLIGHT"; die "preflight failed: nothing was changed"; fi
  info "state: $PLATFORM_STATE"
  [ "$PLATFORM_STATE" = CONFLICT ] && die "conflicting installation"
  PASS_N=0; WARN_N=0; FAIL_N=0; CONFIG_CHANGED=0; PLUGINS_CHANGED=0
  step "Prerequisites"; ensure_prereqs; ensure_node
  step "Grafana package"; import_rpm_key; install_grafana; lock_version
  step "Secrets, TLS and trust"; install -d -m 0755 "$ETC"; ensure_secrets; install_tls; install_ca_trust
  step "Configuration"
  if [ ! "$ENV_FILE_USED" -ef "$ENV_INSTALLED" ]; then install -m 0640 -o root -g grafana "$ENV_FILE_USED" "$ENV_INSTALLED"; fi
  chmod 0640 "$ENV_INSTALLED"; chown root:grafana "$ENV_INSTALLED"; ENV_FILE_USED=$ENV_INSTALLED
  if [ -f "$ZABBIX_ITEM_MAP_FILE" ] && [ "$(dirname "$ZABBIX_ITEM_MAP_FILE")" != "$ETC" ]; then install -m 0640 -o root -g grafana "$ZABBIX_ITEM_MAP_FILE" "$ETC/zabbix-item-map.json"; ZABBIX_ITEM_MAP_FILE="$ETC/zabbix-item-map.json"; sed -i "s#^ZABBIX_ITEM_MAP_FILE=.*#ZABBIX_ITEM_MAP_FILE=$ZABBIX_ITEM_MAP_FILE#" "$ENV_INSTALLED"; fi
  render_grafana_ini
  step "Plugins"; install_plugins
  step "Network policy"; configure_firewall
  step "Service"; start_service
  step "Release and content"; deploy_release; install_units; apply_content; write_release_json
  step "Final verification"; PASS_N=0; WARN_N=0; FAIL_N=0; verify_all
  summary "INSTALL"
}
