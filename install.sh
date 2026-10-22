#!/usr/bin/env bash
# Grafana platform — the one installation command.
#   sudo ./install.sh                 install (asks a few questions), or re-run safely with the saved answers
#   sudo ./install.sh --zabbix        add / change the Zabbix connection later
#   sudo ./install.sh --clickhouse    add / change the ClickHouse (Akvorado) connection later
#   sudo ./install.sh --reconfigure   answer all questions again;   --yes  re-run without questions
# The Grafana package comes from (automatically): ./bundle, an offline archive next to this directory or in /root, the Internet,
# or a download of the pinned offline archive — always verified against the SHA-256 values pinned in this release.
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
if [ "$(id -u)" -ne 0 ]; then command -v sudo >/dev/null && exec sudo "$HERE/install.sh" "$@"; echo "run as root" >&2; exit 1; fi
exec "$HERE/bin/grafana-platform" setup "$@"
