#!/usr/bin/env bash
# Download recovery tests (no root, no network): the real lib/bundle.sh against a local fault-injecting server.
#   tests/download/run-download-tests.sh <grafana-platform-1.0.1-rhel9-offline.tar.gz>
# Needs the 'packages' branch in this checkout (git fetch origin packages:packages) and the real 1.0.1 archive (SHA-256 pinned below).
set -uo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
ASSET=$(readlink -f "${1:?usage: $0 <grafana-platform-1.0.1-rhel9-offline.tar.gz>}")
. "$ROOT/VERSIONS.env"
[ "$(sha256sum < "$ASSET" | cut -c1-64)" = "$BUNDLE_FALLBACK_SHA256" ] || { echo "not the pinned 1.0.1 archive: $ASSET"; exit 2; }
git -C "$ROOT" rev-parse -q --verify "$(awk '!/^#/{print $1; exit}' "$ROOT/packages/MANIFEST.txt")^{commit}" >/dev/null || { echo "packages branch missing: git fetch origin packages:packages"; exit 2; }
W=$(mktemp -d); PORT=${PORT:-18977}; PASS_N=0; FAIL_N=0
trap 'kill $SRV 2>/dev/null; rm -rf "$W"' EXIT
python3 -I "$ROOT/tests/download/faultserver.py" "$PORT" "$(git -C "$ROOT" rev-parse --absolute-git-dir)" "$ASSET" "$W/control" & SRV=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/x" && break; sleep 0.1; done
SIZE=$(stat -c %s "$ASSET"); CUT190=$((190 * 1048576))

check() { if eval "$2"; then echo "  [PASS] $1"; PASS_N=$((PASS_N + 1)); else echo "  [FAIL] $1"; FAIL_N=$((FAIL_N + 1)); sed 's/^/        | /' "$W/out" | tail -8; fi; }
ctl() { printf '%s\n' "$@" > "$W/control"; : > "$W/control.log"; }
# run the installer's package step in a fresh state dir; $1 = plan to force (parts|download); extra env as arguments
run() {
  local plan=$1; shift
  ( set -euo pipefail
    RELEASE_DIR=$ROOT; LIBDIR=$ROOT/lib; . "$ROOT/VERSIONS.env"
    info() { echo "INFO $*"; }; warn() { echo "WARN $*"; }; pass() { echo "PASS $*"; }; die() { echo "DIE $*"; exit 1; }; CLI() { echo grafana-platform; }
    missing_artifacts() { echo rpm; }
    export GP_DNF_CONF=/nonexistent; unset https_proxy HTTPS_PROXY http_proxy HTTP_PROXY GP_PROXY
    for kv in "$@"; do export "${kv?}"; done
    GP_CACHE_DIR=$W/state/cache; . "$ROOT/lib/bundle.sh"
    BUNDLE_DIR=$W/state/bundle; PACKAGE_SOURCE=auto; GP_ARCHIVE_SEARCH="$W/state/root $W/state/cache"
    PACKAGES_URL_BASE=http://127.0.0.1:$PORT/pieces; BUNDLE_URL=http://127.0.0.1:$PORT/asset/grafana-platform-1.0.1-rhel9-offline.tar.gz; BUNDLE_URL_SHA256=$BUNDLE_FALLBACK_SHA256
    PARTS_JOBS=8; sleep() { :; }
    if [ "$plan" = download ]; then parts_reachable() { return 1; }; fi
    prepare_packages; echo "PKG_SRC=$PKG_SRC"
  ) > "$W/out" 2>&1
}
fresh() { rm -rf "$W/state"; mkdir -p "$W/state/root" "$W/state/cache"; }
bundle_ok() { [ -f "$W/state/bundle/SHA256SUMS" ] && RELEASE_DIR=$ROOT bash -c '. "$0/VERSIONS.env"; info(){ :; }; . "$0/lib/bundle.sh"; verify_pinned_bundle "$1" >/dev/null' "$ROOT" "$W/state/bundle"; }
no_bundle() { ! [ -e "$W/state/bundle/rpm/$GRAFANA_RPM_NEVRA.rpm" ]; }
# requests of a kind, without the 1-byte reachability probe that precedes every plan (bytes=0-0 / the first piece once)
reqs() { grep "^$1" "$W/control.log" 2>/dev/null | grep -vc " bytes=0-0 "; }
pieces_fetched() { echo $(( $(grep -c "^/pieces/" "$W/control.log") - 1 )); }

echo "### Pieces source: reuse of an interrupted 190 MiB download"
fresh; head -c "$CUT190" "$ASSET" > "$W/state/root/grafana-platform-1.0.1-rhel9-offline.tar.gz"; before=$(sha256sum < "$W/state/root/grafana-platform-1.0.1-rhel9-offline.tar.gz")
ctl; run parts
check "190 MiB partial (named like a complete archive) is NOT treated as a broken archive: no stop" '! grep -q "^DIE" "$W/out" && grep -q PKG_SRC=bundle "$W/out"'
check "pieces reused from it (Node.js, both plugins, first 149.6 MB of the RPM)" 'grep -qE "PASS reused 10[0-9][0-9] verified piece" "$W/out"'
check "only the missing pieces are fetched ($(pieces_fetched) of 1717)" '[ "$(pieces_fetched)" -lt 720 ] && [ "$(pieces_fetched)" -gt 650 ]'
check "joined packages equal the pins" 'bundle_ok'
check "the partial file itself is unchanged" '[ "$(sha256sum < "$W/state/root/grafana-platform-1.0.1-rhel9-offline.tar.gz")" = "$before" ]'

echo "### Pieces source: damaged partial (bytes overwritten in the middle, garbage appended)"
fresh; head -c "$CUT190" "$ASSET" > "$W/state/root/grafana-platform-1.0.1-rhel9-offline.tar.gz.part"
printf 'XXXXXXXXXXXXXXXX' | dd of="$W/state/root/grafana-platform-1.0.1-rhel9-offline.tar.gz.part" bs=1 seek=120000000 conv=notrunc status=none
head -c 300000 /dev/urandom >> "$W/state/root/grafana-platform-1.0.1-rhel9-offline.tar.gz.part"
ctl; run parts
check "nothing unverified is used: packages equal the pins" 'bundle_ok'
reused=$(sed -n 's/^PASS reused \([0-9]*\) verified piece.*/\1/p' "$W/out" | awk '{s+=$1} END{print s+0}')
check "only the pieces hit by the damage are dropped (reused $reused, fetched $(pieces_fetched)); fetched = 1717 - reused" '[ "$reused" -gt 900 ] && [ "$reused" -lt 1023 ] && [ "$(pieces_fetched)" = $((1717 - reused)) ]'

echo "### Pieces source: connection cuts, retries, a re-run after a failure"
fresh; ctl pieces_drop=2; run parts
check "every piece cut twice, third attempt succeeds: packages equal the pins" 'bundle_ok'
fresh; bad=$(awk '!/^#/ && $3 ~ /rpm/ && $4==900 {print $1}' "$ROOT/packages/MANIFEST.txt"); ctl "pieces_bad=$bad"; run parts
check "a piece with wrong content is refused after 5 attempts; nothing installed; clear message" 'grep -q "^DIE a package piece could not be fetched after 5 attempts: piece $bad: content does not match its SHA-256" "$W/out" && no_bundle'
kept=$(ls "$W/state/cache/parts" | grep -cv "\.")
check "the verified pieces are kept for the next run ($kept)" '[ "$kept" -gt 100 ]'
ctl; run parts
check "re-run fetches only the $((1717 - kept)) missing pieces and completes" '[ "$(pieces_fetched)" = $((1717 - kept)) ] && bundle_ok'

echo "### Single-archive source (release asset): resume with byte ranges"
fresh; ctl "asset_cut=$CUT190"; run download
check "connection closed after 190 MiB (curl 18) -> resumed with Range, 206 validated, completed" 'grep -q "PKG_SRC=bundle" "$W/out" && grep -q "^/asset/[^ ]* 206 bytes=$CUT190- " "$W/control.log" && bundle_ok'
check "exactly 2 requests: no data downloaded twice" '[ "$(reqs /asset)" = 2 ]'
fresh; head -c "$CUT190" "$ASSET" > "$W/state/cache/grafana-platform-1.0.1-rhel9-offline.tar.gz.part"; ctl; run download
check "existing 190 MiB .part is continued, not restarted" '[ "$(reqs /asset)" = 1 ] && grep -q "^/asset/[^ ]* 206 bytes=$CUT190- " "$W/control.log" && bundle_ok'
fresh; head -c "$CUT190" "$ASSET" > "$W/state/cache/grafana-platform-1.0.1-rhel9-offline.tar.gz.part"; ctl asset_range=ignore; run download
check "server ignores Range (200): nothing appended, partial kept at 190 MiB, clear message" 'grep -q "ignored the byte range (HTTP 200 instead of 206)" "$W/out" && [ "$(stat -c %s "$W/state/cache/grafana-platform-1.0.1-rhel9-offline.tar.gz.part")" = "$CUT190" ] && no_bundle'
fresh; head -c "$CUT190" "$ASSET" > "$W/state/cache/grafana-platform-1.0.1-rhel9-offline.tar.gz.part"; ctl asset_range=wrong; run download
check "206 starting at the wrong byte: refused, partial kept" 'grep -q "instead of $CUT190; nothing was appended" "$W/out" && [ "$(stat -c %s "$W/state/cache/grafana-platform-1.0.1-rhel9-offline.tar.gz.part")" = "$CUT190" ] && no_bundle'
fresh; ctl asset_tamper=1; run download
check "tampered archive: SHA-256 mismatch, refused, kept as .rejected, nothing installed" 'grep -q "does not match its pinned SHA-256: refused" "$W/out" && [ -f "$W/state/cache/grafana-platform-1.0.1-rhel9-offline.tar.gz.rejected" ] && no_bundle'
fresh; ctl asset_range=ignore "asset_cut=$CUT190"; run download
check "no Range support at all + cut at 190 MiB: the 1-byte probe does not stream the file; the 190 MiB are kept, nothing appended, clear message" 'grep -q "ignored the byte range (HTTP 200 instead of 206); the 190 MiB already downloaded are kept" "$W/out" && [ "$(stat -c %s "$W/state/cache/grafana-platform-1.0.1-rhel9-offline.tar.gz.part")" = "$CUT190" ] && no_bundle'
fresh; ctl "asset_cut=1000000"; run download
check "server keeps cutting (6 attempts, 1 MB each): stops with the size reached, partial kept" 'grep -q "^DIE download of grafana-platform-1.0.1-rhel9-offline.tar.gz stopped at 5 MiB" "$W/out" && [ -s "$W/state/cache/grafana-platform-1.0.1-rhel9-offline.tar.gz.part" ] && no_bundle'

echo; echo "DOWNLOAD TESTS: $PASS_N PASS, $FAIL_N FAIL"
[ "$FAIL_N" = 0 ]
