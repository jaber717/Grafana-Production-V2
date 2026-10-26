# shellcheck shell=bash
# Shared helpers for grafana-platform: paths, logging, PASS/WARN/FAIL accounting, environment loading, small utilities.

ETC=${GP_ETC:-/etc/grafana-platform}
OPT=${GP_OPT:-/opt/grafana-platform}
ENV_INSTALLED="$ETC/platform.env"
RELEASE_JSON="$ETC/release.json"
GRAFANA_ETC=${GP_GRAFANA_ETC:-/etc/grafana}
GRAFANA_VAR=${GP_GRAFANA_VAR:-/var/lib/grafana}
LOGDIR=${GP_LOGDIR:-/var/log/grafana-platform}
OS_RELEASE_FILE=${GP_OS_RELEASE_FILE:-/etc/os-release}   # GP_* overrides exist for the simulated test host only (tests/sim)

ENV_FILE_ARG=""; OPT_YES=0; OPT_INCLUDE_SECRETS=0; OPT_ARGS=()
PASS_N=0; WARN_N=0; FAIL_N=0
ENV_WARNINGS=()

c_ok=""; c_warn=""; c_bad=""; c_off=""
if [ -t 1 ]; then c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_bad=$'\033[31m'; c_off=$'\033[0m'; fi
pass() { printf '%s[PASS]%s %s\n' "$c_ok" "$c_off" "$*"; PASS_N=$((PASS_N+1)); }
warn() { printf '%s[WARN]%s %s\n' "$c_warn" "$c_off" "$*"; WARN_N=$((WARN_N+1)); }
fail() { printf '%s[FAIL]%s %s\n' "$c_bad" "$c_off" "$*"; FAIL_N=$((FAIL_N+1)); }
info() { printf '       %s\n' "$*"; }
fix()  { printf '       %s-> fix:%s %s\n' "$c_warn" "$c_off" "$*"; }    # the exact action that resolves the line above
step() { printf '\n== %s\n' "$*"; }
die()  { printf '%s[FATAL]%s %s\n' "$c_bad" "$c_off" "$*" >&2; exit 1; }
summary() { printf '\n%s: %d PASS, %d WARN, %d FAIL\n' "$1" "$PASS_N" "$WARN_N" "$FAIL_N"; [ "$FAIL_N" -eq 0 ]; }

# How the operator invokes this command (bin/grafana-platform of an unpacked release, or the installed /usr/local/sbin link).
CLI() {
  if [ "$(readlink -f /usr/local/sbin/grafana-platform 2>/dev/null)" = "$RELEASE_DIR/bin/grafana-platform" ] || [ "$(readlink -f /usr/sbin/grafana-platform 2>/dev/null)" = "$RELEASE_DIR/bin/grafana-platform" ]; then echo "grafana-platform"
  elif [ "$PWD" = "$RELEASE_DIR" ]; then echo "bin/grafana-platform"
  else echo "$RELEASE_DIR/bin/grafana-platform"; fi
}
# "--env-file F" for fix hints, only when the operator had to name the file (the default file needs no option)
ENV_HINT() { [ -n "${ENV_FILE_ARG:-}" ] && [ "$ENV_FILE_ARG" != "$ENV_INSTALLED" ] && printf -- '--env-file %s' "$ENV_FILE_ARG"; return 0; }

parse_common_args() {
  OPT_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --env-file) ENV_FILE_ARG=${2:?--env-file needs a path}; shift 2 ;;
      --yes|-y) OPT_YES=1; shift ;;
      --include-secrets) OPT_INCLUDE_SECRETS=1; shift ;;
      *) OPT_ARGS+=("$1"); shift ;;
    esac
  done
}

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"; }

env_parser() { command -v python3 >/dev/null 2>&1 || die "python3 is required (it is part of every RHEL 9 installation: dnf install python3)"; python3 "$LIBDIR/envparse.py" "$@"; }
schema_keys() { env_parser keys | awk '{print $1}'; }

# Which environment file is used: --env-file, else the installed copy, else env/production.env next to this release.
resolve_env_file() {
  local f=${ENV_FILE_ARG:-}
  if [ -z "$f" ]; then if [ -f "$ENV_INSTALLED" ]; then f=$ENV_INSTALLED; elif [ -f "$RELEASE_DIR/env/production.env" ]; then f="$RELEASE_DIR/env/production.env"; fi; fi
  [ -n "$f" ] || die "no environment file: pass --env-file <file> (create one with: $(CLI) init-env /root/grafana.env)"
  [ -f "$f" ] || die "environment file not found: $f"
  printf '%s' "$f"
}

# Parse the environment file with lib/envparse.py (never executed, unknown/misspelled/duplicate keys are errors),
# then apply the defaults of the schema. Only the file decides: variables of the calling shell are ignored.
load_env() {
  local f; f=$(resolve_env_file); ENV_FILE_USED=$f
  local k t d tag key val errs=()
  while read -r k _t _d; do unset "$k"; done < <(env_parser keys)
  ENV_WARNINGS=()
  while IFS= read -r -d '' tag; do
    case "$tag" in
      V) IFS= read -r -d '' key; IFS= read -r -d '' val; printf -v "$key" '%s' "$val"; export "${key?}" ;;
      W) IFS= read -r -d '' val; ENV_WARNINGS+=("$val") ;;
      E) IFS= read -r -d '' val; errs+=("$val") ;;
    esac
  done < <(env_parser parse "$f")
  if [ "${#errs[@]}" -gt 0 ]; then
    printf '%s[FAIL]%s %s\n' "$c_bad" "$c_off" "environment file $f:" >&2
    for val in "${errs[@]}"; do printf '       %s\n' "$val" >&2; done
    die "the environment file has ${#errs[@]} error(s); nothing was changed. Fix them, or set a value with: $(CLI) config set KEY=VALUE --env-file $f"
  fi
  while read -r k t d; do
    printf -v "$k" '%s' "${!k:-${d:-}}"; export "${k?}"
  done < <(env_parser keys)
  : "${SECRETS_DIR:=$ETC/secrets}" "${ZABBIX_ITEM_MAP_FILE:=$ETC/zabbix-item-map.json}"
  if [ -z "${CLICKHOUSE_PORT:-}" ]; then if [ "$CLICKHOUSE_SECURE" = true ]; then CLICKHOUSE_PORT=8443; else CLICKHOUSE_PORT=8123; fi; fi
  if [ -z "${BUNDLE_DIR:-}" ]; then BUNDLE_DIR="$RELEASE_DIR/bundle"; fi
  if [ "$PACKAGE_SOURCE" = auto ]; then
    if [ -f "$BUNDLE_DIR/SHA256SUMS" ]; then PKG_SRC=bundle; PKG_SRC_WHY="auto: offline bundle found at $BUNDLE_DIR"; else PKG_SRC=repo; PKG_SRC_WHY="auto: no offline bundle at $BUNDLE_DIR"; fi
  else PKG_SRC=$PACKAGE_SOURCE; PKG_SRC_WHY="PACKAGE_SOURCE=$PACKAGE_SOURCE"; fi
  export SECRETS_DIR ZABBIX_ITEM_MAP_FILE CLICKHOUSE_PORT BUNDLE_DIR PKG_SRC
}

# The parsed, defaulted values as a KEY="VALUE" file (mode 0600) for the Node content tools: they never parse the operator's file themselves.
write_normalized_env() { # $1 output path
  local k
  ( umask 077
    printf '# normalized by grafana-platform from %s\n' "$ENV_FILE_USED"
    while read -r k _; do [ -n "${!k:-}" ] && printf '%s="%s"\n' "$k" "${!k}"; done < <(env_parser keys)
  ) > "$1"
}

log_to_file() { # tee everything to a log file for installs/upgrades
  mkdir -p "$LOGDIR"; chmod 750 "$LOGDIR"
  local f; f="$LOGDIR/$1-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$f") 2>&1
  echo "log: $f"
}

installed_version() { rpm -q --qf '%{VERSION}-%{RELEASE}' grafana 2>/dev/null | grep -E '^[0-9]' || true; }
want_version() { echo "${GRAFANA_VERSION_OVERRIDE:-$GRAFANA_VERSION}-$GRAFANA_RPM_RELEASE"; }

base_url() { printf '%s://%s:%s' "$GRAFANA_PROTOCOL" "${GRAFANA_DOMAIN:-localhost}" "$GRAFANA_HTTP_PORT"; }
curl_local() { # curl against the local instance by its public name (or IP), always connected via loopback; TLS verified for that name
  local args=(-sS -m 15 --noproxy '*' --connect-to "::127.0.0.1:")
  curl "${args[@]}" "$@"
}

wait_health() { # $1 seconds
  local i=0 max=${1:-90}
  while [ "$i" -lt "$max" ]; do
    if curl_local -f "$(base_url)/api/health" 2>/dev/null | grep -q '"database": *"ok"'; then return 0; fi
    sleep 2; i=$((i+2))
  done
  return 1
}

secret() { cat "$SECRETS_DIR/$1" 2>/dev/null | tr -d '\r\n'; }
clickhouse_enabled() { [ "${CLICKHOUSE_ENABLED:-yes}" = yes ]; }
zabbix_enabled() { [ "${ZABBIX_ENABLED:-yes}" = yes ]; }
required_secrets() { zabbix_enabled && echo zabbix-password; clickhouse_enabled && echo clickhouse-password; return 0; }

# Node.js for the content tools. sudo's secure_path usually omits /usr/local/bin, where the offline bundle links node.
node_bin() {
  local n; for n in "$(command -v node 2>/dev/null || true)" /usr/local/bin/node "$OPT/node/bin/node" "${NODE_TMP:-/nonexistent}/bin/node"; do
    [ -n "$n" ] && [ -x "$n" ] && [ "$("$n" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -ge 18 ] && { echo "$n"; return; }
  done
}
# For commands that need Node before 'install' has provided it (item-map): unpack the bundled, SHA-256-pinned Node.js into a temporary directory.
node_runtime() {
  [ -n "$(node_bin)" ] && return 0
  local tb="$BUNDLE_DIR/node/$NODE_BUNDLE_FILE"
  [ -f "$tb" ] || die "Node.js >= 18 is needed for this step: run '$(CLI) install' first, or put the offline bundle at $BUNDLE_DIR"
  [ "$(sha256sum "$tb" | cut -d' ' -f1)" = "$NODE_BUNDLE_SHA256" ] || die "bundled Node.js fails its pinned SHA-256"
  NODE_TMP=$(mktemp -d); tar -xJf "$tb" -C "$NODE_TMP" --strip-components=1 --no-same-owner
  trap 'rm -rf "${NODE_TMP:-/nonexistent-dir}"' EXIT
}

run_content_tool() { # $1 script name (apply|verify|backup|restore), rest = args
  local tool=$1; shift
  local node; node=$(node_bin); [ -n "$node" ] || die "Node.js >= 18 not found"
  local nenv rc=0; nenv=$(mktemp); write_normalized_env "$nenv"
  GRAFANA_URL="$(base_url)" GRAFANA_USER="$GRAFANA_ADMIN_USER" GRAFANA_PASSWORD="$(secret admin-password)" \
  GRAFANA_CONNECT_ADDR=127.0.0.1 GRAFANA_CA_FILE=${GP_CA_BUNDLE:-/etc/pki/tls/certs/ca-bundle.crt} \
  ZABBIX_GRAFANA_PASSWORD="$(zabbix_enabled && secret zabbix-password || true)" CLICKHOUSE_RO_PASSWORD="$(clickhouse_enabled && secret clickhouse-password || true)" \
  PLATFORM_ENV_FILE="$nenv" \
  "$node" "$RELEASE_DIR/scripts/$tool.mjs" --env-file "$nenv" "$@" || rc=$?
  rm -f "$nenv"
  return $rc
}

mode_of() { stat -c %a "$1" 2>/dev/null || echo "?"; }
owner_of() { stat -c %U:%G "$1" 2>/dev/null || echo "?"; }
