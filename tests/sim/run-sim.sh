#!/usr/bin/env bash
# SIMULATED RHEL 9.8 HOST — end-to-end test of grafana-platform WITHOUT a real RHEL host, Grafana, Zabbix or ClickHouse.
#
#   sudo tests/sim/run-sim.sh [path/to/release-1.x-checkout]     (root + util-linux unshare; Node >= 18, python3, unzip, xz, gpg)
#   SIM_REAL_BUNDLE=<grafana-platform-*-rhel9-offline.tar.gz or bundle dir>  use the REAL pinned artifacts (Grafana RPM file, plugin archives,
#   Node.js) through 'build-offline-bundle.sh --from-bundle' with the UNMODIFIED pins of this release; the platform then installs the real
#   plugins and the real bundled Node.js (the RPM payload itself is still not installed: rpm/dnf stay simulated).
#
# What is real:      every line of bin/ lib/ scripts/ tools/ of this release, bash, python3, node, gpg (pinned key check), unzip/tar,
#                    sha256 pins, the offline-bundle builder (against a local mirror), file modes/owners, users/groups.
# What is simulated: the OS identity (RHEL 9.8 os-release), SELinux/firewalld/systemd/rpm/dnf (tests/sim/fakebin), the Grafana server
#                    (tests/sim/mock-grafana.mjs: the HTTP API subset the tools use), Zabbix 7.0 API (mock-zabbix.mjs), ClickHouse /ping,
#                    the RPM/plugin/Node artifacts (fake bytes with their own pins), and "no Internet" (HTTPS_PROXY points at a closed port).
# Isolation: the script re-runs itself in a private mount namespace; /etc, /usr/local/sbin and /var/lib are replaced by throw-away copies,
# so nothing on this machine changes. A PASS here proves the installer logic, NOT a production deployment.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
V2=$(cd "$HERE/../.." && pwd)
V1=${1:-}

if [ -z "${SIM_IN_NS:-}" ]; then
  [ "$(id -u)" = 0 ] || { echo "[SKIPPED] simulation needs root (mount namespace)"; exit 77; }
  command -v unshare >/dev/null || { echo "[SKIPPED] unshare not available"; exit 77; }
  # isolation self-test: these host files must be byte-identical after the run
  sums() { sha256sum /usr/lib/os-release /etc/os-release /etc/passwd /etc/group /etc/shadow /etc/selinux/config 2>/dev/null; ls /usr/local/sbin /usr/local/bin 2>/dev/null | sha256sum; }
  before=$(sums)
  unshare -m --propagation private env SIM_IN_NS=1 bash "${BASH_SOURCE[0]}" "$@"; rc=$?
  if [ "$(sums)" = "$before" ]; then echo "  [PASS] isolation: host os-release, users/groups and /usr/local are unchanged"; else echo "  [FAIL] isolation: the simulation changed a host file"; rc=1; fi
  exit $rc
fi

W=$(mktemp -d /tmp/gp-sim.XXXXXX)
BG=()
cleanup() { local p; for p in "${BG[@]+"${BG[@]}"}"; do kill "$p" 2>/dev/null; done; [ -f "$W/sys/state/grafana.pid" ] && kill "$(cat "$W/sys/state/grafana.pid")" 2>/dev/null; sleep 0.3; [ -n "${SIM_KEEP_WORKDIR:-}" ] || rm -rf "$W"; true; }
trap cleanup EXIT
mkdir -p "$W/etc" && cp -a /etc/. "$W/etc/" && mount --bind "$W/etc" /etc
mount -t tmpfs tmpfs /usr/local/sbin
mount -t tmpfs tmpfs /usr/local/bin          # the installer may link the bundled node here
mount -t tmpfs tmpfs /var/lib
mkdir -p /var/backups 2>/dev/null; mount -t tmpfs tmpfs /var/backups
mkdir -p /etc/pki/rpm-gpg /etc/pki/ca-trust/source/anchors /etc/pki/tls/certs /etc/sysconfig /etc/yum.repos.d /etc/selinux
# files written below may be SYMLINKS in the copied /etc (Ubuntu: /etc/os-release -> ../usr/lib/os-release): remove the link, never write through it
rm -f /etc/os-release /etc/selinux/config /etc/pki/tls/certs/ca-bundle.crt
printf 'NAME="Red Hat Enterprise Linux"\nID="rhel"\nVERSION_ID="9.8"\nPRETTY_NAME="Red Hat Enterprise Linux 9.8 (Plow)"\n' > /etc/os-release
echo "SELINUX=enforcing" > /etc/selinux/config
cp /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt 2>/dev/null || : > /etc/pki/tls/certs/ca-bundle.crt

PASSN=0; FAILN=0; FAILED=()
ok()  { printf '  [PASS] %s\n' "$1"; PASSN=$((PASSN+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAILN=$((FAILN+1)); FAILED+=("$1"); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; [ -n "${SIM_VERBOSE:-}" ] && grep -E 'FAIL|FATAL|fix:|ERROR|rror|refused|bundle|archive|download|reachable' "$W/out" | head -14 | sed 's/^/        | /'; fi; return 0; }        # check "<description>" '<shell condition>'
section() { printf '\n### %s\n' "$*"; }
out_has() { grep -qE -- "$1" "$W/out"; }
out_lacks() { ! grep -qE -- "$1" "$W/out"; }

# ------------------------------------------------------------------ simulated services
export SIM_DIR="$HERE"
SIM_NODE=$(command -v node); export SIM_NODE
SIM_PATH=$PATH
if [ -n "${SIM_REAL_BUNDLE:-}" ]; then SIM_PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$(dirname "$SIM_NODE")" | paste -sd: -); fi   # the platform must provide Node itself
ZBX_PORT=18080; CH_PORT=18123; MIRROR_PORT=18900; GF_PORT=3000
ZBX_USER=sim-grafana-ro
printf 'sim-zabbix-secret-%s' "$RANDOM$RANDOM" > "$W/zbx.pw"; chmod 600 "$W/zbx.pw"
printf 'sim-clickhouse-secret-%s' "$RANDOM$RANDOM" > "$W/ch.pw"; chmod 600 "$W/ch.pw"
node "$HERE/mock-zabbix.mjs" "$ZBX_PORT" "$ZBX_USER" "$W/zbx.pw" "$V2/config/zabbix-item-descriptors.json" > "$W/zabbix.log" 2>&1 & BG+=($!)
node -e 'require("http").createServer((q,s)=>{s.end(q.url==="/ping"?"Ok.\n":"")}).listen(+process.argv[1],"127.0.0.1")' "$CH_PORT" > /dev/null 2>&1 & BG+=($!)
ZBX_URL="http://127.0.0.1:$ZBX_PORT/api_jsonrpc.php"

# ------------------------------------------------------------------ fake pinned artifacts + local mirror for the bundle builder
if [ -n "${SIM_REAL_BUNDLE:-}" ]; then
section "Offline bundle: built by tools/build-offline-bundle.sh --from-bundle with the REAL pinned artifacts (unmodified pins, no network)"
mkdir -p "$W/src"
(cd "$V2" && git ls-files --cached --others --exclude-standard -z | tar --null -T - -cf -) | tar -xf - -C "$W/src"
HTTPS_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 bash "$W/src/tools/build-offline-bundle.sh" --from-bundle "$SIM_REAL_BUNDLE" "$W/dist" > "$W/out" 2>&1; rc=$?
check "builder reuses every real artifact and verifies it against the unmodified pins (rc=$rc)" '[ $rc = 0 ] && [ "$(grep -c "^  reusing" "$W/out")" = 4 ] && out_has "SHA-256 verified" && out_lacks "downloading"'
else
section "Offline bundle: built by tools/build-offline-bundle.sh from a local mirror (fake artifacts, real pin checks)"
M="$W/mirror"; mkdir -p "$M/pool" "$M/repodata" "$M/dist/v20.20.2"
. "$V2/VERSIONS.env"
head -c 4096 /dev/urandom > "$M/pool/$GRAFANA_RPM_NEVRA.rpm"           # NOT at /Packages/: exercises the repository-metadata lookup
python3 - "$M" "$GRAFANA_VERSION" "$GRAFANA_RPM_RELEASE" "$GRAFANA_RPM_NEVRA" <<'PY'
import gzip, sys
m, ver, rel, nevra = sys.argv[1:5]
prim = f'''<?xml version="1.0"?><metadata xmlns="http://linux.duke.edu/metadata/common" packages="1"><package type="rpm"><name>grafana</name><arch>x86_64</arch>
<version epoch="0" ver="{ver}" rel="{rel}"/><location href="pool/{nevra}.rpm"/></package></metadata>'''
open(m + '/repodata/primary.xml.gz', 'wb').write(gzip.compress(prim.encode()))
open(m + '/repodata/repomd.xml', 'w').write('<?xml version="1.0"?><repomd xmlns="http://linux.duke.edu/metadata/repo"><data type="primary"><location href="repodata/primary.xml.gz"/></data></repomd>')
PY
mkdir -p "$W/nodepkg/node-v20.20.2-linux-x64/bin" && cp "$(command -v node)" "$W/nodepkg/node-v20.20.2-linux-x64/bin/node"
tar -C "$W/nodepkg" -cJf "$M/dist/v20.20.2/node-v20.20.2-linux-x64.tar.xz" node-v20.20.2-linux-x64
mkdir -p "$W/src"
(cd "$V2" && git ls-files --cached --others --exclude-standard -z | tar --null -T - -cf -) | tar -xf - -C "$W/src"
: > "$W/src/plugins/plugins.txt.new"
while read -r id ver _rest; do
  [ -z "$id" ] && continue; [[ "$id" == \#* ]] && { echo "$id $ver $_rest" >> "$W/src/plugins/plugins.txt.new"; continue; }
  mkdir -p "$W/pz/$id" "$M/api/plugins/$id/versions/$ver"
  inc='[]'; [ "$id" = alexanderzobnin-zabbix-app ] && inc='["alexanderzobnin-zabbix-datasource","alexanderzobnin-zabbix-triggers-panel"]'
  printf '{"id":"%s","type":"app","info":{"version":"%s"},"includes_ids":%s}\n' "$id" "$ver" "$inc" > "$W/pz/$id/plugin.json"
  (cd "$W/pz" && zip -qr - "$id") > "$M/api/plugins/$id/versions/$ver/download"
  echo "$id $ver $(sha256sum "$M/api/plugins/$id/versions/$ver/download" | cut -d' ' -f1)" >> "$W/src/plugins/plugins.txt.new"
done < <(sed 's/#.*//' "$V2/plugins/plugins.txt" | awk 'NF')
mv "$W/src/plugins/plugins.txt.new" "$W/src/plugins/plugins.txt"
sed -i -e "s#^GRAFANA_RPM_REPO_URL=.*#GRAFANA_RPM_REPO_URL=http://127.0.0.1:$MIRROR_PORT#" \
       -e "s#^GRAFANA_RPM_SHA256=.*#GRAFANA_RPM_SHA256=$(sha256sum "$M/pool/$GRAFANA_RPM_NEVRA.rpm" | cut -d' ' -f1)#" \
       -e "s#^NODE_BUNDLE_SHA256=.*#NODE_BUNDLE_SHA256=$(sha256sum "$M/dist/v20.20.2/node-v20.20.2-linux-x64.tar.xz" | cut -d' ' -f1)#" "$W/src/VERSIONS.env"
python3 -m http.server "$MIRROR_PORT" --bind 127.0.0.1 --directory "$M" >/dev/null 2>&1 & BG+=($!)
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$MIRROR_PORT/" && break; sleep 0.1; done
export GRAFANA_PLUGIN_BASE_URL="http://127.0.0.1:$MIRROR_PORT/api/plugins" NODE_DIST_URL="http://127.0.0.1:$MIRROR_PORT/dist"
bash "$W/src/tools/build-offline-bundle.sh" "$W/dist" > "$W/out" 2>&1; rc=$?
check "bundle builder succeeds against the mirror (rc=$rc)" '[ $rc = 0 ]'
check "builder found the RPM through the repository metadata" 'out_has "locating .* through the repository metadata" && out_has "SHA-256 verified"'
VER=$(cat "$W/src/VERSION"); ARCH="$W/dist/grafana-platform-$VER-rhel9-offline.tar.gz"
check "archive + .sha256 produced and verify" '(cd "$W/dist" && sha256sum -c --quiet "$(basename "$ARCH").sha256")'
cp -a "$W/src" "$W/src-bad"; sed -i "s#^GRAFANA_RPM_SHA256=.*#GRAFANA_RPM_SHA256=$(printf 0%.0s $(seq 64))#" "$W/src-bad/VERSIONS.env"
bash "$W/src-bad/tools/build-offline-bundle.sh" "$W/dist-bad" > "$W/out" 2>&1; rc=$?
check "builder ABORTS when a download does not match its pin (rc=$rc)" '[ $rc != 0 ] && out_has "pins"'
unset GRAFANA_PLUGIN_BASE_URL NODE_DIST_URL
fi
VER=$(cat "$W/src/VERSION"); ARCH="$W/dist/grafana-platform-$VER-rhel9-offline.tar.gz"
mkdir -p "$W/server" && tar -xzf "$ARCH" -C "$W/server"
REL="$W/server/grafana-platform-$VER"
check "extracted release carries bundle/ (rpm, plugins, node, SHA256SUMS)" '[ -f "$REL/bundle/SHA256SUMS" ] && ls "$REL"/bundle/rpm/*.rpm "$REL"/bundle/plugins/*.zip "$REL"/bundle/node/*.tar.xz >/dev/null'

# ------------------------------------------------------------------ host reset + command wrapper
reset_host() {
  [ -f "$W/sys/state/grafana.pid" ] && { kill "$(cat "$W/sys/state/grafana.pid")" 2>/dev/null; sleep 0.3; }
  rm -rf "$W/sys"; mkdir -p "$W/sys/state" "$W/sys/var/lib" "$W/sys/opt"
  rm -f /usr/local/sbin/grafana-platform
  getent passwd grafana >/dev/null && userdel grafana 2>/dev/null; getent group grafana >/dev/null && groupdel grafana 2>/dev/null; true
}
# shellcheck disable=SC2054
gp_env=(
  PATH="$HERE/fakebin:$SIM_PATH" SIM_STATE="$W/sys/state" SIM_DIR="$HERE" SIM_NODE="$SIM_NODE"
  SIM_RPMS_PRESENT="curl tar xz unzip openssl sqlite policycoreutils-python-utils python3 python3-dnf-plugin-versionlock gnupg2"
  GP_ETC="$W/sys/etc/grafana-platform" GP_OPT="$W/sys/opt/grafana-platform" GP_GRAFANA_ETC="$W/sys/etc/grafana"
  GP_GRAFANA_VAR="$W/sys/var/lib/grafana" GP_LOGDIR="$W/sys/var/log/grafana-platform"
  HTTPS_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
  GP_ARCHIVE_SEARCH="$W/server $W/clone"
)
gp()  { env "${gp_env[@]}" "$REL/bin/grafana-platform" "$@" > "$W/out" 2>&1; }          # run, output in $W/out
gpi() { env "${gp_env[@]}" "$REL/bin/grafana-platform" "$@" 2>&1; }                    # run, output on stdout
ENVF="$W/root/grafana.env"; mkdir -p "$W/root"
mgf() { curl -s -u "admin:$(cat "$W/sys/etc/grafana-platform/secrets/admin-password")" "http://127.0.0.1:$GF_PORT$1"; }
# dashboard content checks against the mock Grafana ($1 = fetch function mgf|mgf2, $2 = uid)
has_notice() { "$1" "/api/dashboards/uid/$2" | python3 -c "import json,sys;d=json.load(sys.stdin)[\"dashboard\"];sys.exit(0 if d[\"panels\"][0][\"title\"]==\"Setup still incomplete\" else 1)"; }
no_lab_ids() { "$1" "/api/dashboards/uid/$2" | python3 -c "import json,sys,re;s=json.dumps(json.load(sys.stdin));lab=set(json.load(open(\"$V2/config/zabbix-item-descriptors.json\"))[\"items\"]);ids=set(i for m in re.findall(r'\"itemids\": \"([^\"]*)\"',s) for i in m.split(\",\") if i);sys.exit(1 if ids & lab else 0)"; }

# ------------------------------------------------------------------ 1.x reproduction
if [ -n "$V1" ] && [ -x "$V1/bin/grafana-platform" ]; then
  section "Release 1.x reproduction: preflight of the ORIGINAL code with the reported configuration shape"
  reset_host
  v1env() { # $1 = how the operator wrote the flag line
    cat > "$W/v1.env" <<EOF
PLATFORM_ENV=production
GRAFANA_DOMAIN=10.20.8.27
GRAFANA_PROTOCOL=http
GRAFANA_ALLOW_INSECURE_HTTP=yes
GRAFANA_ALLOWED_CIDRS=10.0.0.0/8
ZABBIX_URL=$ZBX_URL
ZABBIX_USER=$ZBX_USER
CLICKHOUSE_HOST=192.0.2.28
CLICKHOUSE_PORT=8443
CLICKHOUSE_SECURE=true
CLICKHOUSE_USER=grafana_ro
SECRETS_DIR=$W/sys/etc/grafana-platform/secrets
PACKAGE_SOURCE=repo
EOF
    printf '%b\n' "$1" >> "$W/v1.env"
  }
  v1() { env "${gp_env[@]}" GP_ETC="$W/sys/etc/grafana-platform" "$V1/bin/grafana-platform" preflight --env-file "$W/v1.env" > "$W/out" 2>&1; }
  install -d -m 0750 "$W/sys/etc/grafana-platform/secrets"     # the reported run had the directory (two separate secret FAILs)
  v1env 'ALLOW_INSECURE_DATASOURCES=yes'; v1; cp "$W/out" "$W/v1-exact-yes.txt"
  printf '    exact "yes": %s\n' "$(grep -E '^(PREFLIGHT|\[(WARN|FAIL)\] Zabbix)' "$W/out" | tr '\n' ' ')"
  check "1.x: exact 'ALLOW_INSECURE_DATASOURCES=yes' IS honored (WARN) -> the reported FAIL needs a different byte sequence or file" 'out_has "\[WARN\] Zabbix over plain http"'
  check "1.x: missing secrets, unreachable rpm.grafana.com/grafana.com and missing item map FAIL as reported" 'out_has "secret file .*zabbix-password missing" && out_has "secret file .*clickhouse-password missing" && out_has "cannot reach http" && out_has "cannot reach grafana.com" && out_has "no Zabbix item map"'
  for variant in '  ALLOW_INSECURE_DATASOURCES=yes   # temporary, TLS failed' 'ALLOW_INSECURE_DATASOURCES=YES' 'ALLOW_INSECURE_DATASOURCES=true' 'ALLOW_INSECURE_DATASOURCES=\xe2\x80\x9cyes\xe2\x80\x9d' 'ALLOW_INSECURE_DATASOURCES=yes\xc2\xa0' 'ALLOW_INSECURE_DATASOURCE=yes' 'ALLOW_INSECURE_DATASOURCES=yes\nALLOW_INSECURE_DATASOURCES=no'; do
    v1env "$variant"; v1
    label=$(printf '%b' "$variant" | tr '\n' '|' | cat -v)
    check "1.x reproduces the reported Zabbix FAIL with: $label  ($(grep -oE "PREFLIGHT: .*" "$W/out"))" 'out_has "\[FAIL\] ZABBIX_URL is http://"'
  done
fi

# ------------------------------------------------------------------ 2.0: configuration errors are caught with the exact cause
section "2.0 environment parser: wrong files are rejected with the precise reason (nothing runs)"
reset_host
for case in 'ALLOW_INSECURE_DATASOURCE=yes|did you mean ALLOW_INSECURE_DATASOURCES|is not a setting of this release; the setting is called ALLOW_INSECURE_DATASOURCES' \
            'ZABBIX_ALLOW_HTTP=yes|the setting is called ALLOW_INSECURE_DATASOURCES' \
            'ALLOW_INSECURE_DATASOURCES=maybe|must be yes or no' \
            'ALLOW_INSECURE_DATASOURCES=\xe2\x80\x9cyes\xe2\x80\x9d|typographic quote' \
            'ALLOW_INSECURE_DATASOURCES=yes\nALLOW_INSECURE_DATASOURCES=no|already set on line' \
            'BUNDLE_DIR=$PWD/bundle|shell variables are NOT expanded'; do
  line=${case%%|*}; want=${case#*|}
  printf 'ZABBIX_URL=%s\nZABBIX_USER=x\nGRAFANA_DOMAIN=g\n%b\n' "$ZBX_URL" "$line" > "$W/bad.env"
  gp config check --env-file "$W/bad.env"
  check "2.0 reports: $(printf '%b' "$line" | tr '\n' '|' | cat -v)  ->  /$want/" 'out_has "$want"'
done
for v in '  ALLOW_INSECURE_DATASOURCES=yes   # temporary' 'ALLOW_INSECURE_DATASOURCES=YES' 'ALLOW_INSECURE_DATASOURCES=true' 'ALLOW_INSECURE_DATASOURCES=on' 'ALLOW_INSECURE_DATASOURCES=yes\xc2\xa0' '\xef\xbb\xbfALLOW_INSECURE_DATASOURCES=yes' 'export ALLOW_INSECURE_DATASOURCES="yes" # c' 'ALLOW_INSECURE_DATASOURCES=yes\r'; do
  printf '%b\nZABBIX_URL=%s\n' "$v" "$ZBX_URL" > "$W/v.env"
  gp config show --env-file "$W/v.env"
  check "2.0 normalizes $(printf '%b' "$v" | cat -v) to yes" 'out_has "^ALLOW_INSECURE_DATASOURCES +=  ?yes$"'
done

# ------------------------------------------------------------------ 2.0: the reported production situation, end to end
section "2.0 one-line environment creation + preflight in the reported situation (no secrets yet, no Internet, no item map)"
reset_host
gp init-env "$ENVF" GRAFANA_DOMAIN=10.20.8.27 GRAFANA_PROTOCOL=http GRAFANA_ALLOW_INSECURE_HTTP=yes "GRAFANA_ALLOWED_CIDRS=10.0.0.0/8" \
   "ZABBIX_URL=$ZBX_URL" "ZABBIX_USER=$ZBX_USER" ALLOW_INSECURE_DATASOURCES=yes CLICKHOUSE_ENABLED=no SECRETS_DIR="$W/sys/etc/grafana-platform/secrets" \
   BACKUP_DIR="$W/sys/backups" ZABBIX_ITEM_MAP_FILE="$W/sys/etc/grafana-platform/zabbix-item-map.json"
check "init-env creates the file in one line" '[ -f "$ENVF" ] && out_has "created"'
gp preflight --env-file "$ENVF"; rc=$?
cp "$W/out" "$W/preflight-1.txt"
check "preflight exits non-zero while secrets/map are missing" '[ $rc != 0 ]'
check "Zabbix over HTTP is a WARN (flag honored), not a FAIL" 'out_has "\[WARN\] Zabbix API over plain HTTP" && out_lacks "\[FAIL\] ZABBIX_URL"'
check "Grafana over HTTP is a WARN" 'out_has "\[WARN\] Grafana listens with plain HTTP"'
check "missing zabbix-password FAIL carries the exact command" 'out_has "\[FAIL\] secret zabbix-password is missing" && out_has "fix:.*secret set zabbix-password"'
check "clickhouse-password is NOT required while NetFlow is deferred" 'out_lacks "clickhouse-password is missing" && out_has "NetFlow not connected"'
check "offline bundle found automatically: no rpm.grafana.com/grafana.com FAIL" 'out_has "offline bundle at .*every artifact matches the pins" && out_lacks "cannot be obtained"'
check "missing item map is NOT a blocker: NOC dashboards imported with a notice (WARN)" 'out_has "\[WARN\] NOC item map incomplete: no item map yet" && out_lacks "\[FAIL\] NOC"'
check "Zabbix reachability probed read-only" 'out_has "Zabbix API answers at .* \(version 7.0.30\)"'
check "every FAIL line is followed by a fix line" '[ "$(grep -c "^\[FAIL\]" "$W/out")" -le "$(grep -c "fix:" "$W/out")" ]'

section "2.0 secrets: stored from a prompt/pipe, never echoed"
printf 'wrong-password\n' | gpi secret set zabbix-password --env-file "$ENVF" > "$W/out"
check "secret set stores mode 600 root:root" '[ "$(stat -c %a:%U "$W/sys/etc/grafana-platform/secrets/zabbix-password")" = 600:root ]'
check "the value never appears in the output" 'out_lacks "wrong-password"'
gp zabbix-check --env-file "$ENVF"; rc=$?
check "zabbix-check FAILS with a wrong password (rc=$rc) and says how to fix it" '[ $rc != 0 ] && out_has "Incorrect user name or password" && out_has "secret set zabbix-password"'
gpi secret set zabbix-password --env-file "$ENVF" < "$W/zbx.pw" > "$W/out"
gp zabbix-check --env-file "$ENVF"; rc=$?
check "zabbix-check PASSES with the right password (login + host count + logout)" '[ $rc = 0 ] && out_has "login OK as $ZBX_USER; [0-9]+ host"'
check "no secret in any log or output file" '! grep -rqF "$(cat "$W/zbx.pw")" "$W/out" "$W/sys/var/log" 2>/dev/null'

section "2.0 install with the NOC dashboards deferred (simplest first deployment)"
gp config set ALLOW_NOC_WITHOUT_ITEM_MAP=yes --env-file "$ENVF"
gp preflight --env-file "$ENVF"; rc=$?
cp "$W/out" "$W/preflight-2.txt"
check "preflight passes (rc=$rc) with only WARNs" '[ $rc = 0 ] && out_has "PREFLIGHT: [0-9]+ PASS, [0-9]+ WARN, 0 FAIL"'
gp install --env-file "$ENVF"; rc=$?
cp "$W/out" "$W/install-1.txt"
check "install completes (rc=$rc)" '[ $rc = 0 ] && out_has "INSTALL: [0-9]+ PASS, [0-9]+ WARN, 0 FAIL"'
check "grafana.ini rendered for http, cookie_secure=false, secrets by \$__file" 'grep -q "^protocol = http$" "$W/sys/etc/grafana/grafana.ini" && grep -q "cookie_secure = false" "$W/sys/etc/grafana/grafana.ini" && grep -q "admin_password = \$__file" "$W/sys/etc/grafana/grafana.ini"'
[ -z "${SIM_REAL_BUNDLE:-}" ] || check "REAL bundled Node.js v20.20.2 installed from the bundle and used by the content tools" 'out_has "Node.js v20.20.2 installed to .* from the offline bundle" && [ -x /usr/local/bin/node ]'
check "plugins extracted from the bundle after SHA-256 check" 'out_has "plugin alexanderzobnin-zabbix-app .* installed \(SHA-256 verified\)"'
check "Zabbix datasource created over HTTP and its health check logs in for real" 'out_has "created +datasource zabbix-lab" && out_has "health: OK Zabbix API login OK"'
check "ClickHouse datasource and playlist skipped; the 5 NetFlow dashboards ARE deployed, each with a notice panel" 'out_has "skipped +datasource netflow-clickhouse" && out_has "note +netflow-overview: deployed with a notice panel" && out_has "skipped +playlist" && has_notice mgf netflow-overview'
check "NOC dashboards deployed without an item map: notice panel, and NO LAB item id reaches this Zabbix" 'out_has "note +noc-device-health: deployed with a notice panel" && has_notice mgf noc-device-health && no_lab_ids mgf noc-device-health && no_lab_ids mgf noc-wan-overview'
check "mock Grafana holds 1 datasource and all 7 dashboards (no empty folder)" '[ "$(mgf /api/search | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")" = 7 ] && mgf /api/datasources/uid/zabbix-lab | grep -q "\"url\":\"$ZBX_URL\"" && [ "$(mgf /api/datasources/uid/netflow-clickhouse | grep -c uid)" = 0 ]'
check "release deployed with its bundle; command linked" '[ -L /usr/local/sbin/grafana-platform ] && [ -f "$W/sys/opt/grafana-platform/releases/$VER/bundle/SHA256SUMS" ]'
check "the bundled RPM is cached for rollbacks" 'ls "$W/sys/backups/rpm/"grafana-*.rpm >/dev/null 2>&1'

section "2.0 Zabbix item map: production host names differ from the LAB names"
gp item-map; rc=$?
check "without host renames the map is INCOMPLETE (rc=$rc), nothing guessed" 'out_has "item map written but INCOMPLETE" && out_has "host \"SITE-A\" not found"'
gp item-map --host SITE-A=RYD-SITE-A,SITE-B=RYD-SITE-B,STC=RYD-STC,MOBILY=RYD-MOBILY --host INT-CORE=RYD-INT-CORE,SAIX-A=RYD-SAIX-A,SAIX-B=RYD-SAIX-B; rc=$?
check "with --host renames the map is complete (rc=$rc)" '[ $rc = 0 ] && out_has "47 of 47 item\(s\) mapped" && out_has "item map complete"'
check "the 7 uptime items are listed for REVIEW with the key that matched" '[ "$(grep -c "via key system.net.uptime\[sysUpTime.0\]" "$W/out")" = 7 ]'
check "item map file 0640 and only numeric ids" '[ "$(stat -c %a "$W/sys/etc/grafana-platform/zabbix-item-map.json")" = 640 ] && python3 -c "import json,sys;m=json.load(open(sys.argv[1]));assert len(m)==47 and all(k.isdigit() and v.isdigit() for k,v in m.items())" "$W/sys/etc/grafana-platform/zabbix-item-map.json"'
check "only read-only Zabbix methods were called" 'curl -s "http://127.0.0.1:$ZBX_PORT/__calls" | python3 -c "import json,sys;c=set(json.load(sys.stdin));assert c<= {\"apiinfo.version\",\"user.login\",\"user.logout\",\"host.get\",\"item.get\"},c"'
gp config set ALLOW_NOC_WITHOUT_ITEM_MAP=no
gp apply; rc=$?
check "apply deploys the 2 NOC dashboards (rc=$rc)" '[ $rc = 0 ] && out_has "(created|updated) +dashboard noc-device-health" && out_has "(created|updated) +dashboard noc-wan-overview" && ! has_notice mgf noc-device-health && ! has_notice mgf noc-wan-overview'
check "deployed NOC dashboards carry production item ids, no LAB id remains" 'mgf /api/dashboards/uid/noc-device-health | python3 -c "
import json,sys,re
d=json.load(sys.stdin)[\"dashboard\"]; ids=re.findall(r\"\\\"itemids\\\": *\\\"([0-9,]+)\\\"\",json.dumps(d))
assert ids and all(int(i)>=900000 for s in ids for i in s.split(\",\")), ids"'
check "verify after apply: no FAIL" 'out_has "APPLY: [0-9]+ PASS, [0-9]+ WARN, 0 FAIL"'

section "2.0 enabling ClickHouse/Akvorado later (three single-line commands)"
gp config set CLICKHOUSE_ENABLED=yes CLICKHOUSE_HOST=127.0.0.1 CLICKHOUSE_PORT=$CH_PORT CLICKHOUSE_SECURE=false CLICKHOUSE_USER=grafana_ro
gpi secret set clickhouse-password < "$W/ch.pw" > /dev/null
gp apply; rc=$?
check "apply creates the ClickHouse datasource, 5 NetFlow dashboards and the playlist (rc=$rc)" '[ $rc = 0 ] && out_has "created +datasource netflow-clickhouse" && [ "$(grep -cE "(created|updated) +dashboard netflow-" "$W/out")" = 5 ] && out_has "created +playlist" && ! has_notice mgf netflow-overview'
check "ClickHouse datasource health OK, plain HTTP reported as WARN" 'out_has "health: OK ClickHouse" && out_has "APPLY: [0-9]+ PASS, [0-9]+ WARN, 0 FAIL"'

section "2.0 idempotency and verification"
gp install; rc=$?
check "a second install changes nothing (rc=$rc)" '[ $rc = 0 ] && out_lacks "^created|^updated" && out_has "applied: 0 created, 0 updated"'
gp verify; rc=$?
cp "$W/out" "$W/verify-final.txt"
check "verify: 0 FAIL (rc=$rc)" '[ $rc = 0 ] && out_has "VERIFY: [0-9]+ PASS, [0-9]+ WARN, 0 FAIL"'
gp preflight; rc=$?
check "preflight on the installed host needs no package source any more" '[ $rc = 0 ] && out_has "already at the pinned versions"'

section "2.0 a half-built item map is never deployed"
reset_host
gp init-env "$ENVF" --yes GRAFANA_DOMAIN=10.20.8.27 GRAFANA_PROTOCOL=http GRAFANA_ALLOW_INSECURE_HTTP=yes "GRAFANA_ALLOWED_CIDRS=10.0.0.0/8" ALLOW_NOC_WITHOUT_ITEM_MAP=no \
   "ZABBIX_URL=$ZBX_URL" "ZABBIX_USER=$ZBX_USER" ALLOW_INSECURE_DATASOURCES=yes CLICKHOUSE_ENABLED=no SECRETS_DIR="$W/sys/etc/grafana-platform/secrets" \
   BACKUP_DIR="$W/sys/backups" ZABBIX_ITEM_MAP_FILE="$W/sys/etc/grafana-platform/zabbix-item-map.json"
gpi secret set zabbix-password --env-file "$ENVF" < "$W/zbx.pw" > /dev/null
mkdir -p "$W/sys/etc/grafana-platform"; echo '{"51128":"900001"}' > "$W/sys/etc/grafana-platform/zabbix-item-map.json"
gp preflight --env-file "$ENVF"; rc=$?
check "partial map + ALLOW_NOC_WITHOUT_ITEM_MAP=no -> FAIL with fix (rc=$rc)" '[ $rc != 0 ] && out_has "item map misses 46 of 47"'
gp config set ALLOW_NOC_WITHOUT_ITEM_MAP=yes --env-file "$ENVF"
gp install --env-file "$ENVF"; rc=$?
check "partial map + ALLOW_NOC_WITHOUT_ITEM_MAP=yes -> installs; NOC dashboards deployed with a notice, mapped ids used, no LAB id (rc=$rc)" '[ $rc = 0 ] && out_has "note +noc-wan-overview: deployed with a notice panel - [0-9]+ of [0-9]+ Zabbix item" && [ "$(mgf /api/search | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")" = 7 ] && has_notice mgf noc-wan-overview && no_lab_ids mgf noc-wan-overview && no_lab_ids mgf noc-device-health'

section "2.0 repo mode on an isolated host: one FAIL, with the way out"
reset_host
mv "$REL/bundle" "$REL/bundle.off"
gp preflight --env-file "$ENVF"; rc=$?
check "no bundle + no Internet -> ONE package FAIL that names the fix (proxy)" '[ "$(grep -c "^\[FAIL\].*cannot be obtained" "$W/out")" = 1 ] && out_has "proxy http://127.0.0.1:9 does not accept connections"'
mv "$REL/bundle.off" "$REL/bundle"

section "ONE command: sudo ./install.sh from a git clone WITHOUT bundle; the offline archive lies next to it (auto-found, verified, unpacked)"
reset_host; rm -rf /etc/grafana-platform /var/backups/* "$W/clone"
# shellcheck disable=SC2054
doc_env=(
  PATH="$HERE/fakebin:/usr/local/sbin:$SIM_PATH" SIM_STATE="$W/sys/state" SIM_DIR="$HERE" SIM_NODE="$SIM_NODE"
  SIM_RPMS_PRESENT="curl tar xz unzip openssl sqlite policycoreutils-python-utils python3 python3-dnf-plugin-versionlock gnupg2"
  GP_OPT="$W/sys/opt/grafana-platform" GP_GRAFANA_ETC="$W/sys/etc/grafana" GP_GRAFANA_VAR="$W/sys/var/lib/grafana" GP_LOGDIR="$W/sys/var/log/grafana-platform"
  HTTPS_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
  GP_ARCHIVE_SEARCH="$W/server $W/clone"
)
mkdir -p "$W/clone" && cp -a "$W/src" "$W/clone/Grafana-Production-V2" && rm -rf "$W/clone/Grafana-Production-V2/bundle"
CLONE="$W/clone/Grafana-Production-V2"
if [ -n "${SIM_REAL_BUNDLE:-}" ] && [ -f "$SIM_REAL_BUNDLE" ]; then cp "$SIM_REAL_BUNDLE" "$W/clone/"; else cp "$ARCH" "$W/clone/"; fi
printf 'sim-admin-%s' "$RANDOM$RANDOM" > "$W/admin.pw"
setup() { local r=0; rm -f "$W/sys/var/log/grafana-platform/setup-last-install.txt"; (cd "$CLONE" && env "${doc_env[@]}" ./install.sh "$@") < "$W/answers" > "$W/out" 2>&1 || r=$?
          cp "$W/out" "$W/out.screen"; { echo "----- full installer output (log)"; cat "$W/sys/var/log/grafana-platform/setup-last-install.txt" 2>/dev/null; } >> "$W/out"; return $r; }
mgf2() { curl -s -u "admin:$(cat "$W/admin.pw")" "http://127.0.0.1:$GF_PORT$1"; }
count() { mgf2 "$1" | python3 -c "import json,sys;print(len(json.load(sys.stdin)))"; }
# answers, one per line: address, networks, protocol, Zabbix? URL, allow http?, user, WRONG password, try again?, user(keep), password,
#                        ClickHouse?, admin password, map host names? + 7 names
{ echo 10.20.8.27; echo 10.0.0.0/8; echo http; echo; echo "http://127.0.0.1:$ZBX_PORT"; echo y; echo "$ZBX_USER"; echo wrong-password; echo; echo; cat "$W/zbx.pw"; echo
  echo; cat "$W/admin.pw"; echo; echo
  for h in SITE-A SITE-B STC MOBILY INT-CORE SAIX-A SAIX-B; do echo "RYD-$h"; done; } > "$W/answers"
setup; rc=$?; cp "$W/out" "$W/setup-first.txt"
check "sudo ./install.sh completes in one run (rc=$rc)" '[ $rc = 0 ] && out_has "Grafana is installed:  http://10.20.8.27:3000/"'
check "the offline archive next to the clone was found, verified against the pins and unpacked" 'out_has "offline archive found: .*clone/grafana-platform-" && out_has "offline bundle unpacked from .* match the pins"'
check "the Zabbix URL got /api_jsonrpc.php appended, HTTP was allowed only after the explicit question" 'grep -q "^ZABBIX_URL=$ZBX_URL$" /etc/grafana-platform/platform.env && grep -q "^ALLOW_INSECURE_DATASOURCES=yes$" /etc/grafana-platform/platform.env && out_has "uses plain HTTP: its password crosses the network unencrypted"'
check "a wrong Zabbix password is caught BEFORE installing and asked again" 'out_has "login as $ZBX_USER failed" && out_has "testing login ... OK \(Zabbix 7.0.30"'
check "Grafana HTTP chosen explicitly; no configuration file edited by hand" 'grep -q "^GRAFANA_PROTOCOL=http$" /etc/grafana-platform/platform.env && grep -q "^GRAFANA_ALLOW_INSECURE_HTTP=yes$" /etc/grafana-platform/platform.env'
check "item map built automatically; the 7 production host names asked once; NOC dashboards deployed" 'out_has "These LAB router names are not in your Zabbix" && out_has "Zabbix: connected" && out_has "NOC: 2 of 2 dashboards in Grafana, complete" && out_has "NetFlow: 5 of 5 dashboards in Grafana; 5 with setup incomplete: ClickHouse" && ! has_notice mgf2 noc-device-health'
check "ClickHouse skipped without blocking anything; NetFlow dashboards present with a notice" 'out_has "ClickHouse: not connected -> add it with" && [ "$(count /api/search)" = 7 ] && has_notice mgf2 netflow-overview && ! has_notice mgf2 noc-device-health'
check "secrets: mode 600, never in the output or logs" '[ "$(stat -c %a /etc/grafana-platform/secrets/zabbix-password)" = 600 ] && ! grep -rqF -e "$(cat "$W/zbx.pw")" -e "$(cat "$W/admin.pw")" -e wrong-password "$W/out" "$W/sys/var/log" 2>/dev/null'
check "the admin password typed during setup is the one Grafana accepts" '[ "$(curl -s -o /dev/null -w "%{http_code}" -u "admin:$(cat "$W/admin.pw")" http://127.0.0.1:$GF_PORT/api/folders)" = 200 ]'
n_q=$(grep -c "(answered)\|(hidden)" "$W/out.screen"); check "number of questions on a first install: $n_q (incl. 1 retry and 7 host names)" '[ "$n_q" -le 22 ]'
n_lines=$(wc -l < "$W/out.screen"); cp "$W/out.screen" "$W/setup-screen.txt"
check "the operator sees a short screen: $n_lines lines for the whole first installation" '[ "$n_lines" -le 70 ]'

section "Re-run: Enter keeps everything (safe, changes nothing) / --yes without any question"
printf '\n' > "$W/answers"; setup; rc=$?
check "re-run with Enter = keep: completes, nothing created or updated (rc=$rc)" '[ $rc = 0 ] && out_has "Keep these settings" && out_has "applied: 0 created, 0 updated"'
: > "$W/answers"; setup --yes; rc=$?
check "--yes re-run asks nothing and changes nothing (rc=$rc)" '[ $rc = 0 ] && out_lacks "\(answered\)" && out_has "applied: 0 created, 0 updated"'

section "Add ClickHouse later: sudo ./install.sh --clickhouse"
{ echo y; echo 127.0.0.1; echo; echo "$CH_PORT"; echo; cat "$W/ch.pw"; echo; } > "$W/answers"
setup --clickhouse; rc=$?
check "--clickhouse adds the datasource, 5 NetFlow dashboards and the playlist (rc=$rc)" '[ $rc = 0 ] && out_has "created +datasource netflow-clickhouse" && [ "$(count /api/search)" = 7 ] && ! has_notice mgf2 netflow-overview && out_has "updated +dashboard netflow-overview" && [ "$(count /api/playlists)" = 1 ] && out_has "health: OK ClickHouse"'
check "the earlier HTTP permission is reused, not asked again" 'out_lacks "Allow unencrypted"'

section "Base Grafana without any integration, Zabbix added afterwards"
reset_host; rm -rf /etc/grafana-platform /var/backups/* "$CLONE/bundle"
{ echo 10.20.8.27; echo 10.0.0.0/8; echo http; echo n; echo n; echo; } > "$W/answers"
setup; rc=$?
cp /etc/grafana-platform/secrets/admin-password "$W/admin.pw" 2>/dev/null
check "Grafana installs with Zabbix AND ClickHouse not connected (rc=$rc)" '[ $rc = 0 ] && out_has "Zabbix: not connected" && [ "$(count /api/search)" = 7 ] && has_notice mgf2 noc-device-health && no_lab_ids mgf2 noc-device-health && [ "$(mgf2 /api/datasources/uid/zabbix-lab | grep -c "\"uid\"")" = 0 ]'
check "generated admin password: path shown, value not printed" 'out_has "password stored in /etc/grafana-platform/secrets/admin-password" && ! grep -qF "$(cat "$W/admin.pw")" "$W/out"'
{ echo y; echo "http://127.0.0.1:$ZBX_PORT"; echo y; echo "$ZBX_USER"; cat "$W/zbx.pw"; echo; echo; for h in SITE-A SITE-B STC MOBILY INT-CORE SAIX-A SAIX-B; do echo "RYD-$h"; done; } > "$W/answers"
setup --zabbix; rc=$?
check "--zabbix later: datasource + NOC dashboards (rc=$rc)" '[ $rc = 0 ] && out_has "created +datasource zabbix-lab" && [ "$(count /api/search)" = 7 ] && ! has_notice mgf2 noc-device-health'

section "Safety: no package anywhere -> stops before changing anything; tampered archive refused; pinned download works"
reset_host; rm -rf /etc/grafana-platform "$CLONE/bundle" "$W/clone"/grafana-platform-*-offline.tar.gz
{ echo 10.20.8.27; echo 10.0.0.0/8; echo http; echo n; echo n; echo; } > "$W/answers"
setup; rc=$?
check "no bundle, no archive, no Internet: one clear message, nothing installed (rc=$rc)" '[ $rc != 0 ] && out_has "neither the package pieces on .* nor .* are reachable" && ! grep -q "^grafana " "$W/sys/state/rpmdb" 2>/dev/null'
head -c 1000 /dev/urandom | gzip > "$W/clone/grafana-platform-9.9.9-rhel9-offline.tar.gz"
: > "$W/answers"; setup --yes; rc=$?
check "an unusable archive is refused, never installed from (rc=$rc)" '[ $rc != 0 ] && out_has "not a readable offline archive|cannot be used" && ! grep -q "^grafana " "$W/sys/state/rpmdb" 2>/dev/null'
rm -f "$W/clone"/grafana-platform-9.9.9-rhel9-offline.tar.gz
SRC_ARCH=$ARCH; [ -n "${SIM_REAL_BUNDLE:-}" ] && [ -f "$SIM_REAL_BUNDLE" ] && SRC_ARCH=$SIM_REAL_BUNDLE
mkdir -p "$W/dl" && cp "$SRC_ARCH" "$W/dl/offline.tar.gz"
python3 -m http.server 18901 --bind 127.0.0.1 --directory "$W/dl" >/dev/null 2>&1 & BG+=($!); sleep 0.5
env "${doc_env[@]}" "$CLONE/bin/grafana-platform" config set "BUNDLE_URL=http://127.0.0.1:18901/offline.tar.gz" "BUNDLE_URL_SHA256=$(printf 0%.0s $(seq 64))" > /dev/null 2>&1
: > "$W/answers"; setup --yes; rc=$?
check "download with a WRONG pinned SHA-256 is refused (rc=$rc)" '[ $rc != 0 ] && out_has "does not match its pinned SHA-256"'
env "${doc_env[@]}" "$CLONE/bin/grafana-platform" config set "BUNDLE_URL_SHA256=$(sha256sum "$W/dl/offline.tar.gz" | cut -d" " -f1)" > /dev/null 2>&1
setup --yes; rc=$?
check "download with the right SHA-256: fetched once, verified, installed (rc=$rc)" '[ $rc = 0 ] && out_has "downloading the pinned offline bundle" && out_has "Grafana is installed"'

section "Restore the full state for the rollback tests"
reset_host; rm -rf /etc/grafana-platform /var/backups/*
cp "$SRC_ARCH" "$W/clone/"
{ echo 10.20.8.27; echo 10.0.0.0/8; echo http; echo; echo "http://127.0.0.1:$ZBX_PORT"; echo y; echo "$ZBX_USER"; cat "$W/zbx.pw"; echo
  echo y; echo 127.0.0.1; echo; echo "$CH_PORT"; echo; cat "$W/ch.pw"; echo; cat "$W/admin.pw"; echo; echo
  for h in SITE-A SITE-B STC MOBILY INT-CORE SAIX-A SAIX-B; do echo "RYD-$h"; done; } > "$W/answers"
setup; rc=$?
check "everything in ONE run: Zabbix + ClickHouse + NOC + NetFlow (rc=$rc)" '[ $rc = 0 ] && [ "$(count /api/search)" = 7 ] && out_has "ClickHouse: connected"'
REL=$CLONE

section "Rollback: uninstall keeps configuration/secrets/data, reinstall restores the same state, --purge returns a clean host"
dgp() { (cd "$CLONE" && env "${doc_env[@]}" "$@") > "$W/out" 2>&1; }
dgp grafana-platform uninstall --yes; rc=$?
check "uninstall succeeds (rc=$rc)" '[ $rc = 0 ] && out_has "UNINSTALL: [0-9]+ PASS, [0-9]+ WARN, 0 FAIL"'
check "package, service, firewall rules, release and command link are gone" '! grep -q "^grafana " "$W/sys/state/rpmdb" && [ ! -e /usr/local/sbin/grafana-platform ] && [ ! -d "$W/sys/opt/grafana-platform" ] && [ ! -s "$W/sys/state/fw-rules" ] && ! [ -f "$W/sys/state/grafana.pid" -a -e "/proc/$(cat "$W/sys/state/grafana.pid" 2>/dev/null)" ]'
check "configuration, secrets and item map are kept" '[ -f /etc/grafana-platform/platform.env ] && [ -f /etc/grafana-platform/secrets/zabbix-password ] && [ -f /etc/grafana-platform/zabbix-item-map.json ]'
dgp bin/grafana-platform install; rc=$?
check "reinstall from the unpacked release with the kept configuration (rc=$rc), no prompts, no --env-file" '[ $rc = 0 ] && out_has "INSTALL: [0-9]+ PASS, [0-9]+ WARN, 0 FAIL"'
check "reinstalled state is complete again: 7 dashboards" '[ "$(curl -s -u "admin:$(cat "$W/admin.pw")" http://127.0.0.1:$GF_PORT/api/search | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")" = 7 ]'
dgp grafana-platform uninstall --yes --purge; rc=$?
check "uninstall --purge (rc=$rc) removes configuration, secrets and data" '[ $rc = 0 ] && [ ! -e /etc/grafana-platform ] && [ ! -e "$W/sys/var/lib/grafana" ] && [ ! -e "$W/sys/etc/grafana" ]'

printf '\nSIMULATION: %d PASS, %d FAIL\n' "$PASSN" "$FAILN"
[ "$FAILN" = 0 ] || { printf '  failed: %s\n' "${FAILED[@]}"; }
if [ -n "${SIM_KEEP:-}" ]; then mkdir -p "$SIM_KEEP"; cp "$W"/setup-*.txt "$W"/v1-*.txt "$W"/preflight-*.txt "$W"/install-1.txt "$W"/verify-final.txt "$SIM_KEEP"/ 2>/dev/null; fi
[ "$FAILN" = 0 ]
