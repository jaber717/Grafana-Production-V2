# shellcheck shell=bash
# Read-only readiness checks. Sets PLATFORM_STATE to FRESH | MANAGED | CONFLICT. Never changes the system.
# Every FAIL is followed by a "-> fix:" line with the exact action that resolves it.

check_pkg_installable() { rpm -q "$1" >/dev/null 2>&1 || dnf -q list --available "$1" >/dev/null 2>&1; }

validate_cidrs() {
  python3 - "$@" <<'PY'
import ipaddress, sys
bad = []
for c in sys.argv[1:]:
    try:
        n = ipaddress.ip_network(c, strict=False)
        if n.prefixlen == 0:
            bad.append(c + " (matches everything)")
    except ValueError:
        bad.append(c)
print(" ".join(bad)); sys.exit(1 if bad else 0)
PY
}

# Which pinned artifacts are still missing on this host (empty = nothing has to be downloaded or taken from a bundle).
missing_artifacts() {
  local id ver _sha out=()
  [ "$(installed_version)" = "$(want_version)" ] || out+=("rpm:grafana-$(want_version)")
  while read -r id ver _sha _; do
    [ -z "$id" ] && continue
    [ "$(plugin_version "$id")" = "$ver" ] || out+=("plugin:$id-$ver")
  done < <(sed 's/#.*//' "$RELEASE_DIR/plugins/plugins.txt" | awk 'NF')
  echo "${out[*]:-}"
}

ca_bundle_with() { # $@ extra CA files -> path of a temporary bundle (system store + extras)
  local b; b=$(mktemp); cat "${GP_CA_BUNDLE:-/etc/pki/tls/certs/ca-bundle.crt}" "$@" > "$b" 2>/dev/null || true; echo "$b"
}

probe_zabbix() { # read-only: apiinfo.version needs no credentials. Prints the version or nothing.
  local args=(-sS -m 8 --noproxy '*' -H 'Content-Type: application/json-rpc' -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}') cab=""
  case "$ZABBIX_URL" in https://*)
    if [ "$ZABBIX_TLS_SKIP_VERIFY" = true ]; then args+=(-k); elif [ -n "${ZABBIX_CA_FILE:-}" ]; then cab=$(ca_bundle_with "$ZABBIX_CA_FILE"); args+=(--cacert "$cab"); fi ;;
  esac
  curl "${args[@]}" "$ZABBIX_URL" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result",""))' 2>/dev/null || true
  [ -n "$cab" ] && rm -f "$cab"; return 0
}

probe_clickhouse() { # read-only: GET /ping answers "Ok." without credentials
  local scheme=http args=(-sS -m 8 --noproxy '*') cab=""
  if [ "$CLICKHOUSE_SECURE" = true ]; then scheme=https; [ -n "${CLICKHOUSE_CA_FILE:-}" ] && { cab=$(ca_bundle_with "$CLICKHOUSE_CA_FILE"); args+=(--cacert "$cab"); }; fi
  curl "${args[@]}" "$scheme://$CLICKHOUSE_HOST:$CLICKHOUSE_PORT/ping" 2>/dev/null | tr -d '\r\n' || true
  [ -n "$cab" ] && rm -f "$cab"; return 0
}

run_preflight() {
  local mode=${1:-install} cli ef
  cli=$(CLI); ef=$(ENV_HINT)
  step "Operating system and security baseline"
  [ "$(id -u)" -eq 0 ] && pass "running as root" || { fail "must run as root"; fix "prefix the command with sudo"; }
  local id="" vid=""
  if [ -r "$OS_RELEASE_FILE" ]; then id=$(. "$OS_RELEASE_FILE"; echo "${ID:-}"); vid=$(. "$OS_RELEASE_FILE"; echo "${VERSION_ID:-}"); fi
  if [ "$id" = rhel ] && [[ "$vid" == 9.* ]]; then
    pass "Red Hat Enterprise Linux $vid (RHEL 9.x family)"
  elif [[ "$id" =~ ^(almalinux|rocky|centos)$ ]] && [[ "$vid" == 9.* ]] && [ "$PLATFORM_ALLOW_EL_CLONE" = yes ]; then
    warn "$id $vid is an EL9 rebuild, accepted only because PLATFORM_ALLOW_EL_CLONE=yes (acceptance testing); production must be RHEL"
  else
    fail "unsupported OS '$id $vid' (needs RHEL 9.x; RHEL 8, RHEL 10, Debian/Ubuntu and others are not supported)"
  fi
  [ "$(uname -m)" = x86_64 ] && pass "architecture x86_64" || fail "architecture $(uname -m) is not supported (x86_64 only)"
  # SELinux: recommended, not a blocker (RHEL ships no Grafana policy, the service runs unconfined_service_t either way)
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = Enforcing ] && grep -qiE '^SELINUX=enforcing' "${GP_SELINUX_CONFIG:-/etc/selinux/config}" 2>/dev/null; then pass "SELinux is Enforcing (and persistent)"
  else warn "SELinux is not (persistently) Enforcing: $(getenforce 2>/dev/null || echo unknown). Recommended: setenforce 1 and SELINUX=enforcing in /etc/selinux/config"; fi
  systemctl is-active --quiet firewalld && pass "firewalld is active" || { fail "firewalld is not active: Grafana's port would be open to every source"; fix "systemctl enable --now firewalld   (it is what restricts the port to GRAFANA_ALLOWED_CIDRS)"; }
  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && pass "system clock is NTP-synchronized" || warn "clock is not NTP-synchronized (certificate validation and Zabbix timestamps depend on it)"

  step "Environment file ($ENV_FILE_USED)"
  local w; for w in "${ENV_WARNINGS[@]+"${ENV_WARNINGS[@]}"}"; do warn "$w"; done
  pass "parsed: every setting is known, appears once and has a valid value"
  [ -n "$GRAFANA_DOMAIN" ] && [ "$GRAFANA_DOMAIN" != "grafana.example.com" ] && pass "GRAFANA_DOMAIN=$GRAFANA_DOMAIN" || { fail "GRAFANA_DOMAIN is empty or still the template value"; fix "$cli config set GRAFANA_DOMAIN=<name or IP users type in the browser> $ef"; }
  [ "$GRAFANA_HTTP_PORT" -ge 1024 ] && [ "$GRAFANA_HTTP_PORT" -le 65535 ] && pass "listener port $GRAFANA_HTTP_PORT" || fail "GRAFANA_HTTP_PORT must be 1024-65535 (the Grafana service does not run as root)"
  case "$GRAFANA_PROTOCOL" in
    https) pass "Grafana listens with https" ;;
    http) if [ "$GRAFANA_ALLOW_INSECURE_HTTP" = yes ]; then warn "Grafana listens with plain HTTP (GRAFANA_ALLOW_INSECURE_HTTP=yes): logins and cookies are unencrypted on the network"
          else fail "GRAFANA_PROTOCOL=http but GRAFANA_ALLOW_INSECURE_HTTP is '$GRAFANA_ALLOW_INSECURE_HTTP'"; fix "$cli config set GRAFANA_ALLOW_INSECURE_HTTP=yes $ef   (or provide a certificate and use https)"; fi ;;
  esac
  if [ -n "$GRAFANA_ALLOWED_CIDRS" ]; then
    local badc; if badc=$(validate_cidrs $GRAFANA_ALLOWED_CIDRS); then pass "firewall sources: $GRAFANA_ALLOWED_CIDRS"; else fail "GRAFANA_ALLOWED_CIDRS invalid: $badc"; fi
  else fail "GRAFANA_ALLOWED_CIDRS is empty (there is no default: the port is never opened to everyone)"; fix "$cli config set \"GRAFANA_ALLOWED_CIDRS=<subnet> <subnet>\" $ef   (the user/NOC subnets allowed to open Grafana)"; fi

  info "insecure-transport exceptions in effect: GRAFANA_ALLOW_INSECURE_HTTP=$GRAFANA_ALLOW_INSECURE_HTTP  ALLOW_INSECURE_DATASOURCES=$ALLOW_INSECURE_DATASOURCES  (both default to no)"
  if zabbix_enabled; then
    case "$ZABBIX_URL" in
      https://*) pass "Zabbix URL uses https" ;;
      http://*) if [ "$ALLOW_INSECURE_DATASOURCES" = yes ]; then warn "Zabbix API over plain HTTP (allowed by ALLOW_INSECURE_DATASOURCES=yes): the Zabbix password crosses the network unencrypted"
                else fail "ZABBIX_URL is http:// and ALLOW_INSECURE_DATASOURCES is '$ALLOW_INSECURE_DATASOURCES'"; fix "$cli config set ALLOW_INSECURE_DATASOURCES=yes $ef   (or use the https URL of Zabbix)"; fi ;;
      "") fail "ZABBIX_URL is not set"; fix "$cli config set ZABBIX_URL=http://<zabbix>/api_jsonrpc.php $ef" ;;
      *) fail "ZABBIX_URL must start with http:// or https:// (got '$ZABBIX_URL')" ;;
    esac
    case "$ZABBIX_URL" in *api_jsonrpc.php) ;; http*://*) warn "ZABBIX_URL does not end with /api_jsonrpc.php (the Zabbix datasource needs the API endpoint)" ;; esac
    [ -n "$ZABBIX_USER" ] && pass "Zabbix API user $ZABBIX_USER" || { fail "ZABBIX_USER is empty"; fix "$cli config set ZABBIX_USER=<read-only Zabbix user> $ef"; }
    if [ "$ZABBIX_TLS_SKIP_VERIFY" = true ]; then
      if [ "$ALLOW_INSECURE_DATASOURCES" = yes ]; then warn "Zabbix certificate verification is DISABLED (ALLOW_INSECURE_DATASOURCES=yes)"; else fail "ZABBIX_TLS_SKIP_VERIFY=true is refused unless ALLOW_INSECURE_DATASOURCES=yes"; fix "provide ZABBIX_CA_FILE instead"; fi
    elif [[ "$ZABBIX_URL" == https://* ]]; then pass "Zabbix certificate verification enabled"; fi
  else
    warn "Zabbix not configured (ZABBIX_ENABLED=no): no Zabbix datasource and no NOC dashboards yet (Grafana itself is installed normally)"
    info "add it later: sudo ./install.sh --zabbix"
  fi
  if clickhouse_enabled; then
    [ -n "$CLICKHOUSE_HOST" ] && [ "$CLICKHOUSE_HOST" != "netflow.example.com" ] && pass "ClickHouse host $CLICKHOUSE_HOST:$CLICKHOUSE_PORT" || { fail "CLICKHOUSE_HOST is empty or still the template value"; fix "$cli config set CLICKHOUSE_HOST=<akvorado host> $ef   (or defer NetFlow: $cli config set CLICKHOUSE_ENABLED=no $ef)"; }
    [ -n "$CLICKHOUSE_USER" ] || { fail "CLICKHOUSE_USER is empty"; fix "$cli config set CLICKHOUSE_USER=grafana_ro $ef"; }
    if [ "$CLICKHOUSE_SECURE" = true ]; then pass "ClickHouse connection uses TLS"
    elif [ "$ALLOW_INSECURE_DATASOURCES" = yes ]; then warn "ClickHouse over plain HTTP (allowed by ALLOW_INSECURE_DATASOURCES=yes)"
    else fail "CLICKHOUSE_SECURE=false and ALLOW_INSECURE_DATASOURCES is '$ALLOW_INSECURE_DATASOURCES'"; fix "enable TLS on ClickHouse, or: $cli config set ALLOW_INSECURE_DATASOURCES=yes $ef"; fi
  else
    warn "NetFlow not connected (CLICKHOUSE_ENABLED=no): no ClickHouse datasource and no NetFlow playlist; the 5 NetFlow dashboards are imported with a notice panel and stay empty until ClickHouse is connected"
    info "add it later: sudo ./install.sh --clickhouse"
  fi
  case "$PLATFORM_ENV" in production) pass "PLATFORM_ENV=production" ;; *) warn "PLATFORM_ENV=$PLATFORM_ENV (not production)" ;; esac
  if grep -qE '192\.168\.1\.(91|195|194)' "$ENV_FILE_USED" 2>/dev/null; then fail "the environment file still contains LAB addresses (192.168.1.x)"; else pass "no LAB addresses in the environment file"; fi

  step "Secrets ($SECRETS_DIR)"
  local f m
  for f in $(required_secrets); do
    if [ -s "$SECRETS_DIR/$f" ]; then
      m=$(mode_of "$SECRETS_DIR/$f")
      if [ "$m" = 600 ] || [ "$m" = 400 ]; then pass "secret $f present (mode $m)"; else fail "secret $f has mode $m (must be 600 or 400, owner root)"; fix "chmod 600 $SECRETS_DIR/$f"; fi
    else
      fail "secret $f is missing"
      fix "$cli secret set $f $ef   (asks for the value without echoing it; never stored in Git, history or logs)"
    fi
  done
  clickhouse_enabled || info "clickhouse-password not required while CLICKHOUSE_ENABLED=no"
  for f in admin-password secret-key; do [ -s "$SECRETS_DIR/$f" ] && pass "secret $f present" || info "secret $f will be generated by install (never printed)"; done

  step "TLS material"
  if [ "$GRAFANA_PROTOCOL" = https ]; then
    local crt=$GRAFANA_TLS_CERT_FILE key=$GRAFANA_TLS_KEY_FILE
    if [ -r "$crt" ] && [ -r "$key" ]; then
      if openssl x509 -in "$crt" -noout 2>/dev/null; then
        pass "certificate parses ($(openssl x509 -in "$crt" -noout -subject -enddate | tr '\n' ' '))"
        openssl x509 -in "$crt" -noout -checkend 0 >/dev/null && pass "certificate is not expired" || fail "certificate is expired"
        openssl x509 -in "$crt" -noout -checkend $((30*86400)) >/dev/null || warn "certificate expires within 30 days"
        if [ "$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | sha256sum | cut -d' ' -f1)" = "$(openssl pkey -in "$key" -pubout 2>/dev/null | sha256sum | cut -d' ' -f1)" ]; then pass "private key matches the certificate"; else fail "private key does not match the certificate"; fi
        if openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -qiE "(DNS|IP Address):${GRAFANA_DOMAIN//./\\.}(,|$| )|DNS:\\*\\.${GRAFANA_DOMAIN#*.}"; then pass "certificate covers $GRAFANA_DOMAIN"; else fail "certificate subjectAltName does not cover $GRAFANA_DOMAIN"; fi
        local cab; cab=$(ca_bundle_with ${GRAFANA_TLS_CA_FILE:+"$GRAFANA_TLS_CA_FILE"})
        if openssl verify -CAfile "$cab" -untrusted "$crt" "$crt" >/dev/null 2>&1; then pass "certificate chain validates against the system trust store${GRAFANA_TLS_CA_FILE:+ + GRAFANA_TLS_CA_FILE}"; else fail "certificate does not validate (add its CA as GRAFANA_TLS_CA_FILE, include intermediates in the certificate file)"; fi
        rm -f "$cab"
      else fail "GRAFANA_TLS_CERT_FILE is not a PEM certificate"; fi
    else fail "GRAFANA_TLS_CERT_FILE / GRAFANA_TLS_KEY_FILE not readable ('$crt' / '$key')"; fix "copy the PEM files there, or run Grafana on HTTP for now: $cli config set GRAFANA_PROTOCOL=http GRAFANA_ALLOW_INSECURE_HTTP=yes $ef"; fi
  else info "TLS checks skipped (Grafana on http)"; fi
  local caf; for caf in "$ZABBIX_CA_FILE" "$(clickhouse_enabled && echo "$CLICKHOUSE_CA_FILE")" "$GRAFANA_TLS_CA_FILE"; do
    [ -z "$caf" ] && continue; openssl x509 -in "$caf" -noout 2>/dev/null && pass "CA file $caf parses" || fail "CA file $caf is not a PEM certificate"
  done

  step "Reachability of the data sources (read-only, no credentials sent)"
  local zv; zabbix_enabled && zv=$(probe_zabbix)
  if ! zabbix_enabled; then :; elif [ -n "$zv" ]; then pass "Zabbix API answers at $ZABBIX_URL (version $zv)"; else warn "Zabbix API did not answer apiinfo.version at $ZABBIX_URL (firewall, URL or certificate); the datasource health check will fail until it does"; fi
  if clickhouse_enabled; then
    [ "$(probe_clickhouse)" = "Ok." ] && pass "ClickHouse answers /ping at $CLICKHOUSE_HOST:$CLICKHOUSE_PORT" || warn "ClickHouse did not answer /ping at $CLICKHOUSE_HOST:$CLICKHOUSE_PORT (firewall/TLS/port)"
  fi

  step "Packages and tooling"
  package_plan
  case "$PKG_PLAN" in
    none) pass "$PKG_PLAN_DETAIL: nothing has to be downloaded" ;;
    bundle)
      local bad; if bad=$(verify_pinned_bundle "$BUNDLE_DIR"); then pass "offline bundle at $BUNDLE_DIR (every artifact matches the pins)"
      else fail "offline bundle at $BUNDLE_DIR is damaged or for other pins:$bad"; fix "remove $BUNDLE_DIR and run the installer again (it re-takes the bundle from an archive or downloads it)"; fi ;;
    archive) pass "offline archive found: $PKG_PLAN_DETAIL (install unpacks and verifies its bundle)" ;;
    repo) pass "online package sources reachable ($PKG_PLAN_DETAIL)" ;;
    parts) pass "no local bundle; the packages will be fetched from GitHub${PKG_PROXY:+ via proxy $PKG_PROXY}: $PKG_PLAN_DETAIL (each SHA-256 checked)"
           [ "${DL_INSECURE:-0}" = 1 ] && warn "TLS to GitHub is re-signed by an inspecting proxy; every piece and package is accepted only if its SHA-256 matches" ;;
    download) pass "no local bundle; the pinned offline archive is reachable${PKG_PROXY:+ via proxy $PKG_PROXY} and will be downloaded once: $PKG_PLAN_DETAIL"
              [ "${DL_INSECURE:-0}" = 1 ] && warn "TLS to GitHub is re-signed by an inspecting proxy; the download is accepted only if its SHA-256 equals the pin" ;;
    missing) fail "the Grafana package cannot be obtained: no offline bundle here, and neither the package pieces on ${PACKAGES_URL_BASE%%/tar.gz} nor $(bundle_url) are reachable${PKG_PROXY:+ via proxy $PKG_PROXY}: ${DL_ERR:-no answer}"
             fix "$(dl_hint "${DL_RC:-7}")" ;;
  esac
  # required tools block; optional ones (backups, version lock, SELinux tooling) only warn
  local p; for p in $PREREQS_REQUIRED; do
    if prereq_installed "$p"; then pass "prerequisite $p installed"; elif check_pkg_installable "$p"; then info "prerequisite $p will be installed from your repositories"; else fail "prerequisite $p is missing and not available from the enabled dnf repositories"; fix "enable RHEL BaseOS/AppStream (Satellite, mirror or mounted ISO), or: dnf install $p"; fi
  done
  for p in $PREREQS_OPTIONAL; do
    if rpm -q "$p" >/dev/null 2>&1; then pass "optional $p installed"; elif check_pkg_installable "$p"; then info "optional $p will be installed from your repositories"; else warn "optional $p unavailable: $(optional_purpose "$p") will not work until it is installed"; fi
  done
  if [ -n "$(node_bin)" ]; then pass "Node.js $("$(node_bin)" -v) available"
  elif [ -f "$BUNDLE_DIR/node/$NODE_BUNDLE_FILE" ] || [[ "$PKG_PLAN" =~ ^(archive|parts|download|bundle)$ ]]; then pass "Node.js $NODE_BUNDLE_VERSION from the offline bundle"
  elif check_pkg_installable nodejs; then info "Node.js will be installed from your repositories (AppStream, stream nodejs:20)"
  else fail "Node.js >= 18 is required (AppStream nodejs:20 or the offline bundle)"; fi

  if zabbix_enabled; then
  step "NOC dashboards: Zabbix item map ($ZABBIX_ITEM_MAP_FILE)"
  local need_n missing_n missing_ids mapstate
  mapstate=$(python3 - "$RELEASE_DIR" "$ZABBIX_ITEM_MAP_FILE" <<'PY'
import json, glob, re, sys, os
ids = set()
for f in glob.glob(sys.argv[1] + "/dashboards/noc/*.json"):
    for s in re.findall(r'"itemids":\s*"([0-9,\s]+)"', open(f).read()):
        ids.update(i.strip() for i in s.split(',') if i.strip())
p = sys.argv[2]
if not os.path.exists(p):
    print("nomap", len(ids), len(ids), ""); sys.exit()
try:
    m = json.load(open(p))
    assert isinstance(m, dict) and all(str(k).isdigit() and str(v).isdigit() for k, v in m.items())
except Exception:
    print("invalid", len(ids), len(ids), ""); sys.exit()
miss = sorted(i for i in ids if i not in m)
print("ok" if not miss else "partial", len(ids), len(miss), ",".join(miss[:8]))
PY
)
  read -r mapstate need_n missing_n missing_ids <<<"$mapstate"
  case "$mapstate" in
    ok) pass "item map covers all $need_n Zabbix items used by the 2 NOC dashboards" ;;
    invalid) fail "$ZABBIX_ITEM_MAP_FILE is not a valid item map (JSON object of numeric ids)"; fix "rebuild it: $cli item-map $ef" ;;
    *)
      local what; [ "$mapstate" = nomap ] && what="no item map yet" || what="item map misses $missing_n of $need_n item ids (${missing_ids}...)"
      if [ "$ALLOW_NOC_WITHOUT_ITEM_MAP" = yes ]; then
        warn "NOC item map incomplete: $what. The 2 NOC dashboards are imported with a notice panel; unmapped panels stay empty (no LAB item id is ever used)"
        info "the installer builds the map from Zabbix after Grafana is up; later: sudo ./install.sh --dashboards"
      else
        fail "NOC dashboards cannot be deployed: $what"
        fix "either build the map now: $cli item-map $ef   (needs the Zabbix password secret; reads Zabbix only)"
        fix "or import them with empty unmapped panels: $cli config set ALLOW_NOC_WITHOUT_ITEM_MAP=yes $ef"
      fi ;;
  esac
  fi

  step "Storage and ports"
  local probe=$GRAFANA_VAR; while [ ! -d "$probe" ]; do probe=$(dirname "$probe"); done
  local avail; avail=$(df -Pk "$probe" | awk 'NR==2{print int($4/1024)}')
  [ "${avail:-0}" -ge 2048 ] && pass "free space for Grafana data: ${avail} MiB" || fail "less than 2 GiB free for $GRAFANA_VAR (${avail} MiB)"
  [ "$(df -P "$probe" | awk 'NR==2{print $1}')" != "$(df -P / | awk 'NR==2{print $1}')" ] && pass "$GRAFANA_VAR is on its own filesystem" || warn "$GRAFANA_VAR shares the root filesystem (a separate LV is recommended for the database)"
  local owner; owner=$(ss -ltnpH "sport = :$GRAFANA_HTTP_PORT" 2>/dev/null | head -1)
  if [ -z "$owner" ]; then pass "port $GRAFANA_HTTP_PORT is free"; elif echo "$owner" | grep -q grafana; then pass "port $GRAFANA_HTTP_PORT is used by grafana (managed)"; else fail "port $GRAFANA_HTTP_PORT is in use by another process"; fi

  step "Existing installation"
  if rpm -q grafana >/dev/null 2>&1 && [ ! -f "$RELEASE_JSON" ] && [ -f "$ETC/.install-started" ]; then PLATFORM_STATE=MANAGED; warn "an earlier install did not finish (marker $ETC/.install-started): it will be resumed"
  elif rpm -q grafana >/dev/null 2>&1 && [ ! -f "$RELEASE_JSON" ]; then PLATFORM_STATE=CONFLICT; fail "Grafana is already installed and was not installed by grafana-platform (no $RELEASE_JSON): refusing to touch it"; fix "remove it (dnf remove grafana) only if it holds nothing you need, then re-run"
  elif [ -f "$RELEASE_JSON" ]; then PLATFORM_STATE=MANAGED; pass "managed installation detected ($(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("platform",d.get("platform_version"),"grafana",d.get("grafana_version"))' "$RELEASE_JSON"))"
  else PLATFORM_STATE=FRESH; pass "fresh host (no Grafana installed)"; fi
  if [ "$mode" = "read-only" ]; then
    summary "PREFLIGHT" && { info "next: $cli install $ef"; return 0; }
    info "fix the FAIL lines above (each has a '-> fix:' line), then run preflight again"; return 1
  fi
  return 0
}
