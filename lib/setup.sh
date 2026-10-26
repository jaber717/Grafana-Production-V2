# shellcheck shell=bash
# grafana-platform setup — the ONE entry point (./install.sh calls it).
#
#   sudo ./install.sh                 first installation: a few questions, then everything (config, secrets, packages, Grafana, dashboards)
#   sudo ./install.sh                 again: shows the current settings, Enter keeps them -> safe re-run (repairs, changes nothing that matches)
#   sudo ./install.sh --zabbix        add or change only the Zabbix connection (and its NOC dashboards)
#   sudo ./install.sh --dashboards    (re)import all dashboards into the running Grafana; no reinstall, no restart
#   sudo ./install.sh --clickhouse    add or change only the ClickHouse/Akvorado connection (and its NetFlow dashboards)
#   sudo ./install.sh --yes           non-interactive re-run with the saved settings (automation)
#
# Answers are read from the terminal (or, without a terminal, one line each from standard input). Secrets are never echoed or logged.
# Zabbix and ClickHouse are optional and independent: Grafana is installed without them, and an integration that cannot be reached can be
# skipped and added later. Nothing insecure is enabled without an explicit "yes" to a question that says what it means.

SETUP_TTY=0
ans() { # $1 prompt  -> REPLY (one line). Reads fd 3 = the operator.
  local p=$1; REPLY=""
  if [ "$SETUP_TTY" = 1 ]; then IFS= read -r -p "$p" REPLY <&3 || die "input closed"
  else printf '%s' "$p" >&2; IFS= read -r REPLY <&3 || die "no answer for: $p (standard input ended)"; printf '%s\n' "${REPLY:+(answered)}" >&2; fi
  REPLY=${REPLY%$'\r'}; REPLY=${REPLY#"${REPLY%%[![:space:]]*}"}; REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
}
ask() { # $1 var  $2 question  $3 default -> var
  local d=${3:-}; ans "  $2${d:+ [$d]}: "; printf -v "$1" '%s' "${REPLY:-$d}"
}
ask_required() { # like ask, but repeats until non-empty
  local v=""; while :; do ask v "$2" "${3:-}"; [ -n "$v" ] && break; echo "    (required)" >&2; done; printf -v "$1" '%s' "$v"
}
ask_yn() { # $1 question  $2 default y|n  -> rc 0 = yes
  local d=$2 hint; [ "$d" = y ] && hint="Y/n" || hint="y/N"
  while :; do
    ans "  $1 [$hint]: "; case "${REPLY,,}" in "") [ "$d" = y ]; return ;; y|yes) return 0 ;; n|no) return 1 ;; esac
    echo "    please answer y or n" >&2
  done
}
ask_secret() { # $1 var  $2 question  $3 allow-empty(1)
  local a b
  while :; do
    if [ "$SETUP_TTY" = 1 ]; then
      IFS= read -r -s -p "  $2: " a <&3 || true; echo >&2
      if [ -n "$a" ]; then IFS= read -r -s -p "  repeat: " b <&3 || true; echo >&2; [ "$a" = "$b" ] || { echo "    the two entries differ, again" >&2; continue; }; fi
    else printf '  %s: ' "$2" >&2; IFS= read -r a <&3 || die "no answer for: $2 (standard input ended)"; a=${a%$'\r'}; echo "(hidden)" >&2; fi
    [ -n "$a" ] || [ "${3:-0}" = 1 ] && break; echo "    (required)" >&2
  done
  printf -v "$1" '%s' "$a"
}
store_secret() { # $1 name, value on stdin
  install -d -m 0750 "$SECRETS_DIR"; getent group grafana >/dev/null 2>&1 && chgrp grafana "$SECRETS_DIR"
  local tmp; tmp=$(umask 077; mktemp "$SECRETS_DIR/.$1.XXXXXX"); cat > "$tmp"; chown root:root "$tmp"; chmod 0600 "$tmp"; mv -f "$tmp" "$SECRETS_DIR/$1"
}
head1() { printf '\n%s\n' "== $*" >&2; }

detect_ip() { local ip; ip=$(command -v ip >/dev/null && ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'); [ -n "$ip" ] || ip=$(hostname -I 2>/dev/null | awk '{print $1}'); echo "$ip"; }
detect_subnet() { # network of the interface that carries $1
  local cidr; cidr=$(ip -o -4 addr show 2>/dev/null | awk -v ip="$1" '{split($4,a,"/"); if (a[1]==ip) {print $4; exit}}')
  [ -n "$cidr" ] && python3 -c 'import ipaddress,sys;print(ipaddress.ip_interface(sys.argv[1]).network)' "$cidr" 2>/dev/null; return 0
}
zabbix_api_url() { local u=${1%/}; case "$u" in *api_jsonrpc.php) echo "$u" ;; *) echo "$u/api_jsonrpc.php" ;; esac; }

probe() { python3 "$LIBDIR/probe.py" "$@" </dev/null; }

# ---------------------------------------------------------------------------------------------------------------- questions
SET=()   # KEY=VALUE pairs to write
q_base() {
  local cur_domain=${GRAFANA_DOMAIN:-} cur_cidrs=${GRAFANA_ALLOWED_CIDRS:-} ip sub proto
  [ "$SETUP_FRESH" = 1 ] && cur_domain=""; [ "$cur_cidrs" = 10.0.0.0/24 ] && [ "$SETUP_FRESH" = 1 ] && cur_cidrs=""
  ip=$(detect_ip); sub=$(detect_subnet "$ip")
  head1 "Grafana"
  ask_required v_domain "Address users will open (IP or DNS name of this server)" "${cur_domain:-$ip}"
  echo "    Only these source networks may reach Grafana (firewalld). Space-separated, e.g. 10.20.8.0/24 10.50.0.0/16" >&2
  while :; do
    ask_required v_cidrs "Allowed networks" "${cur_cidrs:-$sub}"
    validate_cidrs $v_cidrs >/dev/null 2>&1 && break; echo "    not a valid list of networks: $(validate_cidrs $v_cidrs 2>/dev/null)" >&2
  done
  echo "    Web protocol: https needs a certificate + key file; http is unencrypted (choose it only on an isolated network)." >&2
  while :; do ask proto "Protocol, type http or https" "${GRAFANA_PROTOCOL_SET:-}"; case "${proto,,}" in http|https) break ;; esac; echo "    type http or https" >&2; done
  SET+=("GRAFANA_DOMAIN=$v_domain" "GRAFANA_ALLOWED_CIDRS=$v_cidrs" "GRAFANA_PROTOCOL=${proto,,}")
  if [ "${proto,,}" = http ]; then SET+=("GRAFANA_ALLOW_INSECURE_HTTP=yes")
  else
    local c k ca
    while :; do ask_required c "Certificate file (PEM, may include the chain)" "${GRAFANA_TLS_CERT_FILE:-}"; [ -r "$c" ] && break; echo "    cannot read $c" >&2; done
    while :; do ask_required k "Private key file (PEM)" "${GRAFANA_TLS_KEY_FILE:-}"; [ -r "$k" ] && break; echo "    cannot read $k" >&2; done
    ask ca "CA certificate file if it is a private CA (Enter = none)" "${GRAFANA_TLS_CA_FILE:-}"
    SET+=("GRAFANA_ALLOW_INSECURE_HTTP=no" "GRAFANA_TLS_CERT_FILE=$c" "GRAFANA_TLS_KEY_FILE=$k" "GRAFANA_TLS_CA_FILE=$ca")
  fi
}

allow_insecure_ds() { # $1 = what; asks once per run
  [ "${INSECURE_DS_OK:-}" = yes ] && return 0
  [ "${ALLOW_INSECURE_DATASOURCES:-no}" = yes ] && [ "${INSECURE_DS_ASKED:-}" != 1 ] && { INSECURE_DS_OK=yes; return 0; }
  echo "    $1 uses plain HTTP: its password crosses the network unencrypted." >&2
  if ask_yn "Allow unencrypted data-source connections on this isolated network?" n; then INSECURE_DS_OK=yes; SET+=("ALLOW_INSECURE_DATASOURCES=yes"); return 0; fi
  INSECURE_DS_ASKED=1; return 1
}

# Zabbix datasources already in the running Grafana, except the installer's own: "uid<TAB>name<TAB>url<TAB>user" (nothing if Grafana is not up)
existing_zabbix_datasources() {
  [ -s "$SECRETS_DIR/admin-password" ] || return 0
  curl_local -f -u "$GRAFANA_ADMIN_USER:$(secret admin-password)" "$(base_url)/api/datasources" 2>/dev/null | python3 -c '
import json, sys
for d in json.load(sys.stdin):
    if d.get("type") == "alexanderzobnin-zabbix-datasource" and d.get("uid") != "zabbix-lab":
        print("\t".join([d["uid"], d.get("name", ""), d.get("url", ""), (d.get("jsonData") or {}).get("username", "")]))' 2>/dev/null || true
}

q_zabbix() { # sets ZBX_STATE = on|off ; ZBX_PW_NEW
  head1 "Zabbix (optional: the NOC dashboards and the Zabbix data source)"
  local dflt=y; [ "${ZABBIX_ENABLED:-yes}" = no ] && [ "$SETUP_FRESH" = 0 ] && [ "${ZBX_ASK_DEFAULT:-}" != y ] && dflt=n
  if ! ask_yn "Connect Zabbix now?" "$dflt"; then SET+=("ZABBIX_ENABLED=no"); ZBX_STATE=off; return; fi
  local u url user pw r tries=0 have_pw=0
  local cur=${ZABBIX_URL:-}; [ "$SETUP_FRESH" = 1 ] && cur=""
  local curuser=${ZABBIX_USER:-}; [ "$SETUP_FRESH" = 1 ] && curuser=""
  # a Zabbix datasource created in Grafana by hand is used as is (never modified), instead of creating a second one
  local ex_uid="" ex_name ex_url ex_user adopt_uid=""
  while IFS=$'\t' read -r ex_uid ex_name ex_url ex_user; do
    [ -n "$ex_uid" ] || continue
    if ask_yn "Use the Zabbix data source that already exists in Grafana, \"$ex_name\" ($ex_url), for the NOC dashboards? (it is not modified)" y; then
      adopt_uid=$ex_uid; cur=$ex_url; [ -n "$ex_user" ] && curuser=$ex_user
      echo "    the Zabbix login is still needed once: it translates the LAB item ids of the NOC dashboards to this Zabbix (read-only)" >&2
      break
    fi
  done < <(existing_zabbix_datasources)
  [ -s "$SECRETS_DIR/zabbix-password" ] && have_pw=1
  while :; do
    ask_required u "Zabbix URL (e.g. http://10.20.8.24:8080)" "$cur"; url=$(zabbix_api_url "$u")
    case "$url" in http://*) allow_insecure_ds "Zabbix" || { echo "    use the https URL of Zabbix, or answer y" >&2; cur=""; continue; } ;; https://*) ;; *) echo "    must start with http:// or https://" >&2; continue ;; esac
    break
  done
  ask_required user "Zabbix API user (read-only)" "$curuser"
  while :; do
    if [ "$have_pw" = 1 ] && [ "$tries" = 0 ]; then ask_secret pw "Zabbix password (Enter = keep the stored one)" 1; [ -z "$pw" ] && pw=$(secret zabbix-password)
    else ask_secret pw "Zabbix password for $user"; fi
    printf '    testing login ... ' >&2
    r=$(PROBE_PASSWORD="$pw" PROBE_CA_FILE="${ZABBIX_CA_FILE:-}" probe zabbix "$url" "$user")
    case "$r" in
      OK*) read -r _ zver zhosts <<<"$r"; echo "OK (Zabbix $zver, $zhosts host(s) visible)" >&2
           [ "$zhosts" = 0 ] && echo "    warning: this user sees no hosts; give its user group read access to the monitored host groups" >&2
           break ;;
      *) echo "${r#ERR }" >&2; tries=$((tries+1))
         if [ "$tries" -ge 3 ] || ! ask_yn "Try again? (n = install without Zabbix now, add it later with --zabbix)" y; then SET+=("ZABBIX_ENABLED=no"); ZBX_STATE=off; return; fi
         case "$r" in *"not reachable"*) ask_required u "Zabbix URL" "$u"; url=$(zabbix_api_url "$u") ;; *"login"*) ask_required user "Zabbix API user" "$user" ;; esac ;;
    esac
  done
  SET+=("ZABBIX_ENABLED=yes" "ZABBIX_URL=$url" "ZABBIX_USER=$user" "ZABBIX_DATASOURCE_UID=$adopt_uid")
  ZBX_PW_NEW=$pw; ZBX_STATE=on
}

q_clickhouse() {
  head1 "ClickHouse / Akvorado (optional: the 5 NetFlow dashboards)"
  local dflt=n; [ "${CLICKHOUSE_ENABLED:-yes}" = yes ] && [ "$SETUP_FRESH" = 0 ] && dflt=y
  if ! ask_yn "Connect ClickHouse now?" "$dflt"; then SET+=("CLICKHOUSE_ENABLED=no"); CH_STATE=off; return; fi
  local host tls port user pw r cur=${CLICKHOUSE_HOST:-} have_pw=0 tries=0
  [ "$SETUP_FRESH" = 1 ] && cur=""; [ -s "$SECRETS_DIR/clickhouse-password" ] && have_pw=1
  while :; do
    ask_required host "ClickHouse host (IP or name)" "$cur"
    if ask_yn "Does ClickHouse use TLS (https)?" "$([ "${CLICKHOUSE_SECURE:-true}" = true ] && [ "$SETUP_FRESH" = 0 ] && [ "${CLICKHOUSE_ENABLED:-}" = yes ] && echo y || echo n)"; then tls=true; else tls=false; fi
    if [ "$tls" = false ] && ! allow_insecure_ds "ClickHouse"; then echo "    enable TLS on ClickHouse, or answer y" >&2; continue; fi
    ask_required port "ClickHouse HTTP port" "$([ "$tls" = true ] && echo 8443 || echo 8123)"
    printf '    testing %s ... ' "$host:$port" >&2
    r=$(PROBE_CA_FILE="${CLICKHOUSE_CA_FILE:-}" probe clickhouse "$([ "$tls" = true ] && echo https || echo http)://$host:$port")
    if [ "$r" = OK ]; then echo "OK" >&2; break; fi
    echo "${r#ERR }" >&2; tries=$((tries+1))
    if [ "$tries" -ge 3 ] || ! ask_yn "Try again? (n = install without ClickHouse now, add it later with --clickhouse)" y; then SET+=("CLICKHOUSE_ENABLED=no"); CH_STATE=off; return; fi
    cur=$host
  done
  local curuser=${CLICKHOUSE_USER:-grafana_ro}
  ask_required user "ClickHouse read-only user" "$curuser"
  if [ "$have_pw" = 1 ]; then ask_secret pw "ClickHouse password (Enter = keep the stored one)" 1; else ask_secret pw "ClickHouse password for $user"; fi
  SET+=("CLICKHOUSE_ENABLED=yes" "CLICKHOUSE_HOST=$host" "CLICKHOUSE_PORT=$port" "CLICKHOUSE_SECURE=$tls" "CLICKHOUSE_USER=$user")
  CH_PW_NEW=$pw; CH_STATE=on
}

show_settings() {
  printf '  %-18s %s\n' "Grafana" "$GRAFANA_PROTOCOL://$GRAFANA_DOMAIN:$GRAFANA_HTTP_PORT  (allowed: $GRAFANA_ALLOWED_CIDRS)" >&2
  if zabbix_enabled; then printf '  %-18s %s\n' "Zabbix" "$ZABBIX_URL as $ZABBIX_USER" >&2; else printf '  %-18s %s\n' "Zabbix" "not connected" >&2; fi
  if clickhouse_enabled; then printf '  %-18s %s\n' "ClickHouse" "$CLICKHOUSE_HOST:$CLICKHOUSE_PORT ($([ "$CLICKHOUSE_SECURE" = true ] && echo TLS || echo plain HTTP)) as $CLICKHOUSE_USER" >&2; else printf '  %-18s %s\n' "ClickHouse" "not connected" >&2; fi
}

# ---------------------------------------------------------------------------------------------------------------- item map
setup_item_map() { # after Grafana is installed; never fatal
  zabbix_enabled || return 0
  head1 "Zabbix item map for the 2 NOC dashboards"
  local out rc=0 hosts=() h n
  out=$(zabbix_tool --out "$ZABBIX_ITEM_MAP_FILE" --merge </dev/null 2>&1) || rc=$?
  if [ "$rc" = 3 ] && [ "$OPT_YES" != 1 ]; then
    mapfile -t hosts < <(grep -E '^  - [0-9]+: host ".*not found' <<<"$out" | sed -E 's/.*\(LAB name ([^)]+)\) not found.*/\1/; s/.*host "([^"]+)" not found.*/\1/' | awk '!s[$0]++')
    if [ "${#hosts[@]}" -gt 0 ]; then
      echo "    These LAB router names are not in your Zabbix: ${hosts[*]}" >&2
      if ask_yn "Type their Zabbix host names now? (n = keep the NOC dashboards for later)" y; then
        local args=()
        for h in "${hosts[@]}"; do ask n "Zabbix host name for $h (Enter = skip)" ""; [ -n "$n" ] && args+=(--host "$h=$n"); done
        [ "${#args[@]}" -gt 0 ] && { rc=0; out=$(zabbix_tool --out "$ZABBIX_ITEM_MAP_FILE" --merge "${args[@]}" </dev/null 2>&1) || rc=$?; }
      fi
    fi
  fi
  [ -f "$ZABBIX_ITEM_MAP_FILE" ] && { chmod 0640 "$ZABBIX_ITEM_MAP_FILE"; getent group grafana >/dev/null 2>&1 && chgrp grafana "$ZABBIX_ITEM_MAP_FILE"; }
  printf '%s\n' "$out" > "$ETC/zabbix-item-map.report.txt"; chmod 0640 "$ETC/zabbix-item-map.report.txt"
  grep -E '^(wrote|all items|[0-9]+ item)' <<<"$out" | sed 's/^/    /' >&2 || true
  local nrev; nrev=$(grep -c 'via key' <<<"$out" || true)
  [ "${nrev:-0}" -gt 0 ] && echo "    $nrev router uptime item(s) were matched by standard SNMP keys: confirm them in Zabbix (list: $ETC/zabbix-item-map.report.txt)" >&2
  grep -E '^  - ' <<<"$out" | grep -v 'via key' | head -10 | sed 's/^/  /' >&2 || true
  case "$rc" in
    0) MAP_STATE=complete ;;
    3) MAP_STATE=partial ;;
    *) MAP_STATE=error; echo "    item map could not be built (Zabbix unreachable?); the NOC dashboards stay deferred" >&2 ;;
  esac
}

# ---------------------------------------------------------------------------------------------------------------- main
cmd_setup() {
  require_root
  exec 3<&0; exec 0</dev/null     # answers come from fd 3; nothing else may consume them
  [ -t 3 ] && SETUP_TTY=1
  local only="" x; for x in "${OPT_ARGS[@]+"${OPT_ARGS[@]}"}"; do case "$x" in --zabbix) only=zabbix ;; --clickhouse) only=clickhouse ;; --reconfigure) only=all ;; --dashboards) only=dashboards ;; *) die "unknown option $x (use --zabbix, --clickhouse, --dashboards, --reconfigure, --yes)" ;; esac; done
  if [ "$only" = dashboards ]; then setup_dashboards_only; return; fi
  printf '\nGrafana platform %s — setup\n' "$(cat "$RELEASE_DIR/VERSION")" >&2
  install -d -m 0755 "$ETC"
  local fresh=1; [ -f "$ENV_INSTALLED" ] && fresh=0; SETUP_FRESH=$fresh
  ENV_FILE_ARG=$ENV_INSTALLED
  if [ "$fresh" = 1 ]; then
    [ "$OPT_YES" = 1 ] && die "no saved settings yet: run 'sudo ./install.sh' once without --yes"
    [ -n "$only" ] && [ "$only" != all ] && die "Grafana is not set up yet: run 'sudo ./install.sh' first"
    ( umask 027; cp "$RELEASE_DIR/env/production.env.example" "$ENV_INSTALLED" )
    env_parser set "$ENV_INSTALLED" ALLOW_NOC_WITHOUT_ITEM_MAP=yes >/dev/null; rm -f "$ENV_INSTALLED.previous"
    load_env; only=all
  else
    load_env
    if [ -z "$only" ] && [ "$OPT_YES" != 1 ]; then
      head1 "Current settings ($ENV_INSTALLED)"; show_settings
      ask_yn "Keep these settings?" y || only=all
    fi
  fi
  SET=(); ZBX_PW_NEW=""; CH_PW_NEW=""; ZBX_STATE=""; CH_STATE=""
  case "$only" in
    all) GRAFANA_PROTOCOL_SET=""; [ "$fresh" = 0 ] && GRAFANA_PROTOCOL_SET=$GRAFANA_PROTOCOL; q_base; q_zabbix; q_clickhouse ;;
    zabbix) q_zabbix ;;
    clickhouse) q_clickhouse ;;
  esac
  if [ "$fresh" = 1 ] && [ ! -s "$SECRETS_DIR/admin-password" ]; then
    head1 "Grafana administrator"
    local apw; ask_secret apw "Password for the Grafana user 'admin' (Enter = generate one)" 1
    [ -n "$apw" ] && { printf '%s' "$apw" | store_secret admin-password; ADMIN_PW_SET=1; }; apw=""
  fi
  if [ "${#SET[@]}" -gt 0 ]; then env_parser set "$ENV_INSTALLED" "${SET[@]}" >/dev/null || die "could not save the settings"; fi
  chmod 0640 "$ENV_INSTALLED"
  [ -n "$ZBX_PW_NEW" ] && { printf '%s' "$ZBX_PW_NEW" | store_secret zabbix-password; ZBX_PW_NEW=""; }
  [ -n "$CH_PW_NEW" ] && { printf '%s' "$CH_PW_NEW" | store_secret clickhouse-password; CH_PW_NEW=""; }
  load_env

  head1 "Installing (this takes a few minutes; log in $LOGDIR)"
  local rc=0 out; out=$(mktemp)
  # the full output goes to the install log; the operator sees the steps, every FAIL with its fix, and the WARNs that matter
  ( OPT_ARGS=(); cmd_install ) > "$out" 2>&1 &
  local pid=$!
  tail -n +1 -f --pid="$pid" "$out" 2>/dev/null | sed -u 's/\x1b\[[0-9;]*m//g' \
    | grep --line-buffered -E '^\[FAIL\]|-> fix:|^\[FATAL\]|downloading|offline (archive|bundle) (found|unpacked)|^(INSTALL|PREFLIGHT): ' | sed -u 's/^\[PASS\] //; s/^/  /' >&2
  wait "$pid" || rc=$?
  grep -E '^\[WARN\]' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -vE 'deferred|not deployed|setup incomplete|imported with a notice panel|not configured|no backup exists yet|HTTP only' | awk '!s[$0]++' | sed 's/^/  /' >&2
  install -d -m 0750 "$LOGDIR"; mv -f "$out" "$LOGDIR/setup-last-install.txt"; chmod 0640 "$LOGDIR/setup-last-install.txt"
  if [ "$rc" != 0 ]; then
    printf '\nThe installation stopped before changing anything that would leave Grafana broken. Fix the FAIL line(s) above and run sudo ./install.sh again (your answers are saved).\n' >&2
    exit "$rc"
  fi
  load_env
  MAP_STATE=""
  if zabbix_enabled; then
    local before=""; [ -f "$ZABBIX_ITEM_MAP_FILE" ] && before=$(sha256sum "$ZABBIX_ITEM_MAP_FILE")
    setup_item_map
    if [ "$MAP_STATE" != error ] && [ "$before" != "$(sha256sum "$ZABBIX_ITEM_MAP_FILE" 2>/dev/null)" ]; then
      head1 "Deploying the dashboards the item map enables"
      ( run_content_tool apply --item-map "$ZABBIX_ITEM_MAP_FILE" ) 2>&1 | tee -a "$LOGDIR/setup-last-install.txt" | grep -E '^(created|updated|refused)|health:|^applied' | sed 's/^/    /' >&2 || true
    fi
  fi
  setup_summary
}

# What Grafana really holds (GET /api/search, /api/dashboards/uid/...), not what was intended. Exit 1 if a managed dashboard is missing.
dashboards_report() { run_content_tool dashboards-report --item-map "$ZABBIX_ITEM_MAP_FILE" "$@" 2>&1; }

# sudo ./install.sh --dashboards : (re)import every managed dashboard into the running Grafana. Does not touch the Grafana package,
# grafana.ini, the service, the firewall or the datasources' settings; updates this release's tool files, builds/extends the Zabbix item
# map (asks the Zabbix host names it cannot find), applies the content idempotently (matched by uid: no duplicates) and reports from the API.
setup_dashboards_only() {
  [ -f "$ENV_INSTALLED" ] && [ -f "$RELEASE_JSON" ] || die "Grafana is not installed by this tool yet: run 'sudo ./install.sh' first"
  SETUP_FRESH=0
  load_env; log_to_file dashboards
  head1 "Dashboards (Grafana itself is not reinstalled or restarted)"
  curl_local -o /dev/null -f "$(base_url)/api/health" || die "Grafana does not answer at $(base_url) — start it first: systemctl start grafana-server"
  deploy_release >&2; write_release_json
  if ! zabbix_enabled || { [ -z "${ZABBIX_DATASOURCE_UID:-}" ] && [ -n "$(existing_zabbix_datasources)" ] && ! curl_local -sf -o /dev/null -u "$GRAFANA_ADMIN_USER:$(secret admin-password)" "$(base_url)/api/datasources/uid/zabbix-lab"; }; then
    SET=(); ZBX_PW_NEW=""; ZBX_ASK_DEFAULT=y q_zabbix
    if [ "${#SET[@]}" -gt 0 ]; then env_parser set "$ENV_INSTALLED" "${SET[@]}" >/dev/null || die "could not save the settings"; chmod 0640 "$ENV_INSTALLED"; fi
    [ -n "$ZBX_PW_NEW" ] && { printf '%s' "$ZBX_PW_NEW" | store_secret zabbix-password; ZBX_PW_NEW=""; }
    load_env
  fi
  MAP_STATE=""; setup_item_map
  head1 "Importing the dashboards (matched by uid: re-running never duplicates)"
  ( run_content_tool apply --item-map "$ZABBIX_ITEM_MAP_FILE" ) 2>&1 | tee -a "$LOGDIR/setup-last-dashboards.txt" | grep -E '^(created|updated|unchanged|refused|note) |health:|^applied' | sed 's/^/    /' >&2 || true
  head1 "What Grafana holds now (read back through its API)"
  local rc=0; dashboards_report | sed 's/^/  /' >&2 || rc=$?
  [ "$rc" = 0 ] || die "not every dashboard is in Grafana (see above); log: $LOGDIR/setup-last-dashboards.txt"
}

setup_summary() {
  local cli; cli="grafana-platform"
  printf '\n==================================================================\n' >&2
  printf ' Grafana is installed:  %s/\n' "$(base_url)" >&2
  if [ "${ADMIN_PW_SET:-0}" = 1 ]; then printf ' Login: admin / the password you entered\n' >&2
  else printf ' Login: admin — password stored in %s (sudo cat it once, then change it in Grafana)\n' "$SECRETS_DIR/admin-password" >&2; fi
  if zabbix_enabled; then printf ' Zabbix: connected\n' >&2; else printf ' Zabbix: not connected -> add it with: sudo %s setup --zabbix\n' "$cli" >&2; fi
  if clickhouse_enabled; then printf ' ClickHouse: connected\n' >&2; else printf ' ClickHouse: not connected -> add it with: sudo %s setup --clickhouse\n' "$cli" >&2; fi
  dashboards_report --brief | sed 's/^/ /' >&2 || printf ' WARNING: not every dashboard is in Grafana (see above): sudo %s setup --dashboards\n' "$cli" >&2
  [ "$GRAFANA_PROTOCOL" = http ] && printf ' Note: plain HTTP (your explicit choice). Switch to https later: sudo %s setup --reconfigure\n' "$cli" >&2
  printf ' Health check any time: sudo %s verify\n' "$cli" >&2
  printf '==================================================================\n' >&2
}
