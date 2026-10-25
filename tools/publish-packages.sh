#!/usr/bin/env bash
# Maintainer tool: publish the pinned artifacts (Grafana RPM, plugins, Node.js) as small pieces on the `packages` branch,
# so the installer can fetch them from codeload.github.com in responses smaller than 200 KB each.
#
#   tools/publish-packages.sh <bundle-dir>      bundle-dir = rpm/ plugins/ node/ that match the pins of this release
#
# Every piece is one commit whose tree holds a single file "part"; the commits form one chain on refs/heads/packages.
# Writes packages/MANIFEST.txt (committed on main): "<commit> <part-sha256> <artifact-path> <index>" per piece.
# The installer downloads https://codeload.github.com/<repo>/tar.gz/<commit>, checks each piece's SHA-256, joins the
# pieces and checks every artifact against the pins in VERSIONS.env / plugins/plugins.txt. Nothing is trusted otherwise.
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
SRC=${1:?usage: $0 <bundle-dir>}
PART_BYTES=${PART_BYTES:-196608}          # 192 KiB: below the 208 KB response proven to pass the production proxy
RELEASE_DIR=$HERE; . "$HERE/VERSIONS.env"
info() { echo "  $*"; }; warn() { echo "WARN $*" >&2; }; pass() { echo "PASS $*"; }
. "$HERE/lib/bundle.sh"
bad=$(verify_pinned_bundle "$SRC") || { echo "refusing: $SRC does not match the pins:$bad" >&2; exit 1; }

artifacts=("rpm/$GRAFANA_RPM_NEVRA.rpm")
while read -r id ver _; do [ -n "$id" ] && artifacts+=("plugins/$id-$ver.zip"); done < <(sed 's/#.*//' "$HERE/plugins/plugins.txt" | awk 'NF')
artifacts+=("node/$NODE_BUNDLE_FILE")

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
n=0; : > "$W/stream"; : > "$W/index"
for a in "${artifacts[@]}"; do
  split -a 5 -d -b "$PART_BYTES" "$SRC/$a" "$W/p."
  i=0
  for p in "$W"/p.*; do
    n=$((n + 1)); size=$(stat -c %s "$p")
    {
      echo "blob"; echo "mark :$((2 * n))"; echo "data $size"; cat "$p"; echo
      echo "commit refs/heads/packages"; echo "mark :$((2 * n + 1))"
      echo "author grafana-platform <packages@grafana-platform> 1761350400 +0000"
      echo "committer grafana-platform <packages@grafana-platform> 1761350400 +0000"
      msg="$a part $i"; echo "data ${#msg}"; echo "$msg"
      [ "$n" -gt 1 ] && echo "from :$((2 * n - 1))"
      echo "deleteall"; echo "M 100644 :$((2 * n)) part"; echo
    } >> "$W/stream"
    echo "$((2 * n + 1)) $(sha256sum "$p" | cut -d' ' -f1) $a $i" >> "$W/index"
    rm -f "$p"; i=$((i + 1))
  done
done
git -C "$HERE" fast-import --quiet --force --export-marks="$W/marks" < "$W/stream"
mkdir -p "$HERE/packages"
{
  echo "# Pieces of the pinned artifacts on the 'packages' branch (tools/publish-packages.sh). Fetched by the installer from"
  echo "# https://codeload.github.com/<repo>/tar.gz/<commit>; each piece and each joined artifact is SHA-256 checked."
  echo "# commit part-sha256 artifact index"
  awk 'NR==FNR { sub(":", "", $1); m[$1] = $2; next } { print m[$1], $2, $3, $4 }' "$W/marks" "$W/index"
} > "$HERE/packages/MANIFEST.txt"
echo "published $n pieces of ${#artifacts[@]} artifacts on refs/heads/packages ($(git -C "$HERE" rev-parse packages)); manifest: packages/MANIFEST.txt"
