#!/usr/bin/env bash
# Builds the OFFLINE installation bundle for grafana-platform: the pinned Grafana RPM, the pinned plugin archives and the pinned Node.js tarball,
# next to this release, in ONE archive that can be carried to an isolated RHEL 9 server.
#
#   tools/build-offline-bundle.sh [--from-bundle <dir|archive>] [output-dir]   (needs: bash, curl, sha256sum, tar, gzip, python3)
#   Works on Linux, macOS and Windows "Git Bash". Run it from a git checkout of THIS release or an unpacked release tarball.
#   --from-bundle reuses the artifacts of an existing offline bundle (a bundle/ directory, or a grafana-platform-*-rhel9-offline.tar.gz such as
#   the published 1.0.1 asset): every reused file must match the SHA-256 pinned HERE, anything missing is downloaded. No Internet needed when
#   the pins are unchanged (2.0.0 pins the same Grafana, plugins and Node.js as 1.0.1).
#
# Every download is checked against a SHA-256 that is pinned in this repository (VERSIONS.env, plugins/plugins.txt); a mismatch aborts.
# The RPM keeps its vendor signature, which the installer verifies again with the pinned key (rpm -K) on the target host.
# Result: <output-dir>/grafana-platform-<version>-rhel9-offline.tar.gz  (+ .sha256). On the isolated server: extract it and run
# grafana-platform-<version>/bin/grafana-platform from inside: the bundle in ./bundle is detected automatically (PACKAGE_SOURCE=auto).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
# shellcheck disable=SC1091
. ./VERSIONS.env
VERSION=$(cat VERSION)
FROM=""
if [ "${1:-}" = --from-bundle ]; then FROM=${2:?--from-bundle needs a directory or archive}; shift 2; fi
OUT=${1:-$ROOT/dist}
NAME=grafana-platform-$VERSION
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUT" "$STAGE/$NAME/bundle/rpm" "$STAGE/$NAME/bundle/plugins" "$STAGE/$NAME/bundle/node"
OUT=$(cd "$OUT" && pwd)

if [ -n "$FROM" ]; then
  if [ -f "$FROM" ]; then   # an offline archive: take only its bundle/ directory, nothing it contains is executed
    mkdir -p "$STAGE/from"
    tar -xzf "$FROM" -C "$STAGE/from" --no-same-owner --wildcards '*/bundle/*' 2>/dev/null || tar -xzf "$FROM" -C "$STAGE/from" '*/bundle/*'   # GNU tar | bsdtar (macOS)
    FROM=$(dirname "$(find "$STAGE/from" -path '*/bundle/SHA256SUMS' | head -1)")
  elif [ -d "$FROM/bundle" ]; then FROM="$FROM/bundle"; fi
  [ -d "$FROM" ] && [ -f "$FROM/SHA256SUMS" ] || { echo "ERROR: --from-bundle: no bundle (bundle/SHA256SUMS) found" >&2; exit 1; }
  echo "== reusing artifacts from $FROM (each one is checked against the pins of this release)"
fi

fetch() { # url dest sha256   (taken from --from-bundle when it has the same file name)
  local rel=${2#"$STAGE/$NAME/bundle/"}
  if [ -n "$FROM" ] && [ -f "$FROM/$rel" ]; then echo "  reusing $rel"; cp "$FROM/$rel" "$2"
  else echo "  downloading $(basename "$2")"; curl -fsSL --retry 3 -o "$2" "$1"; fi
  local got; got=$(sha256sum "$2" | cut -d' ' -f1)
  [ "$got" = "$3" ] || { echo "ERROR: $(basename "$2") has SHA-256 $got, the repository pins $3" >&2; exit 1; }
}

echo "== release tree"
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$ROOT" ls-files -z | grep -zv "^dist/" | tar -C "$ROOT" --null -T - -cf - | tar -xf - -C "$STAGE/$NAME"
else
  tar -C "$ROOT" --exclude=./dist --exclude=./bundle --exclude=.git --exclude=node_modules -cf - . | tar -xf - -C "$STAGE/$NAME"
fi

find "$STAGE/$NAME" -type f \( -path "*/bin/*" -o -name "*.sh" -o -name "render.py" -o -name "*.mjs" -o -name "flowgen.py" -o -name "mock-zabbix.py" -o -name "envparse.py" -o -path "*/fakebin/*" \) -exec chmod 0755 {} +   # executable bits (a Windows checkout does not carry them)

echo "== Grafana RPM ($GRAFANA_RPM_NEVRA)"
RPM_OUT="$STAGE/$NAME/bundle/rpm/${GRAFANA_RPM_NEVRA}.rpm"
if [ -n "$FROM" ] && [ -f "$FROM/rpm/${GRAFANA_RPM_NEVRA}.rpm" ]; then echo "  reusing rpm/${GRAFANA_RPM_NEVRA}.rpm"; cp "$FROM/rpm/${GRAFANA_RPM_NEVRA}.rpm" "$RPM_OUT"
elif ! curl -fsSL --retry 3 -o "$RPM_OUT" "$GRAFANA_RPM_REPO_URL/Packages/$GRAFANA_RPM_FILE" 2>/dev/null; then
  # the file is not at the conventional path: ask the repository metadata where the pinned NEVRA lives
  echo "  locating $GRAFANA_RPM_NEVRA through the repository metadata"
  command -v python3 >/dev/null || { echo "ERROR: python3 is needed to read the repository metadata" >&2; exit 1; }
  href=$(python3 - "$GRAFANA_RPM_REPO_URL" "$GRAFANA_VERSION" "$GRAFANA_RPM_RELEASE" <<'PY'
import gzip, re, sys, urllib.request, xml.etree.ElementTree as ET
base, ver, rel = sys.argv[1].rstrip('/'), sys.argv[2], sys.argv[3]
ns = {'r': 'http://linux.duke.edu/metadata/repo', 'c': 'http://linux.duke.edu/metadata/common'}
md = ET.fromstring(urllib.request.urlopen(base + '/repodata/repomd.xml', timeout=60).read())
loc = [d.find('r:location', ns).get('href') for d in md.findall('r:data', ns) if d.get('type') == 'primary'][0]
raw = urllib.request.urlopen(base + '/' + loc, timeout=300).read()
for p in ET.fromstring(gzip.decompress(raw) if loc.endswith('.gz') else raw).findall('c:package', ns):
    v = p.find('c:version', ns)
    if p.findtext('c:name', namespaces=ns) == 'grafana' and p.findtext('c:arch', namespaces=ns) == 'x86_64' and v.get('ver') == ver and v.get('rel') == rel:
        print(p.find('c:location', ns).get('href')); break
PY
)
  [ -n "$href" ] || { echo "ERROR: $GRAFANA_RPM_NEVRA is not in $GRAFANA_RPM_REPO_URL" >&2; exit 1; }
  curl -fsSL --retry 3 -o "$RPM_OUT" "$GRAFANA_RPM_REPO_URL/$href"
fi
got=$(sha256sum "$RPM_OUT" | cut -d' ' -f1)
[ "$got" = "$GRAFANA_RPM_SHA256" ] || { echo "ERROR: $(basename "$RPM_OUT") has SHA-256 $got, the repository pins $GRAFANA_RPM_SHA256" >&2; exit 1; }
echo "  $(basename "$RPM_OUT") SHA-256 verified"

echo "== plugins"
while read -r id ver sha _; do
  [ -z "$id" ] && continue
  fetch "${GRAFANA_PLUGIN_BASE_URL:-https://grafana.com/api/plugins}/$id/versions/$ver/download?os=linux&arch=amd64" "$STAGE/$NAME/bundle/plugins/$id-$ver.zip" "$sha"
done < <(sed 's/#.*//' plugins/plugins.txt | awk 'NF')

echo "== Node.js $NODE_BUNDLE_VERSION"
fetch "${NODE_DIST_URL:-https://nodejs.org/dist}/$NODE_BUNDLE_VERSION/$NODE_BUNDLE_FILE" "$STAGE/$NAME/bundle/node/$NODE_BUNDLE_FILE" "$NODE_BUNDLE_SHA256"

echo "== manifest"
( cd "$STAGE/$NAME/bundle"
  { echo "grafana-platform $VERSION offline bundle"; echo "built: $(date -u +%FT%TZ)"; echo "grafana: $GRAFANA_RPM_NEVRA (key $GRAFANA_RPM_GPG_FPR)"; echo "node: $NODE_BUNDLE_VERSION"
    echo "plugins:"; sed 's/#.*//' ../plugins/plugins.txt | awk 'NF {print "  " $1 " " $2}'; } > MANIFEST.txt
  find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS )

echo "== archive"
ARCH="$OUT/$NAME-rhel9-offline.tar.gz"
tar -C "$STAGE" --owner=0 --group=0 --numeric-owner --sort=name -czf "$ARCH" "$NAME"
( cd "$OUT" && sha256sum "$(basename "$ARCH")" > "$(basename "$ARCH").sha256" )
echo "built: $ARCH ($(du -h "$ARCH" | cut -f1))"; cat "$ARCH.sha256"
