# shellcheck shell=bash
# Where the pinned Grafana RPM, plugins and Node.js come from — found automatically, never built by the operator.
# Order: already installed > bundle/ next to the release > an offline archive lying nearby > rpm.grafana.com + grafana.com >
#        download of the published offline archive (BUNDLE_URL, default BUNDLE_FALLBACK_URL). Every artifact is checked against the pins.

ARCHIVE_GLOB='grafana-platform-*-rhel9-offline.tar.gz'
CACHE_DIR=${GP_CACHE_DIR:-/var/cache/grafana-platform}

nearby_archives() { # newest first, unique
  local d f
  local dirs=("$RELEASE_DIR" "$(dirname "$RELEASE_DIR")" "$PWD" /root /tmp "$CACHE_DIR")
  [ -n "${GP_ARCHIVE_SEARCH:-}" ] && read -r -a dirs <<<"$GP_ARCHIVE_SEARCH"    # tests: restrict the search
  for d in "${dirs[@]}"; do
    for f in "$d"/$ARCHIVE_GLOB; do [ -f "$f" ] && readlink -f "$f"; done
  done 2>/dev/null | awk '!seen[$0]++' | xargs -r ls -1t 2>/dev/null || true   # no match is not an error (pipefail)
}

# $1 = directory with rpm/ plugins/ node/; prints what is wrong, returns 0 when every pinned artifact is present and matches
verify_pinned_bundle() {
  local d=$1 bad="" id ver sha _
  [ "$(sha256sum "$d/rpm/$GRAFANA_RPM_NEVRA.rpm" 2>/dev/null | cut -d' ' -f1)" = "$GRAFANA_RPM_SHA256" ] || bad+=" rpm/$GRAFANA_RPM_NEVRA.rpm"
  while read -r id ver sha _; do
    [ -z "$id" ] && continue
    [ "$(sha256sum "$d/plugins/$id-$ver.zip" 2>/dev/null | cut -d' ' -f1)" = "$sha" ] || bad+=" plugins/$id-$ver.zip"
  done < <(sed 's/#.*//' "$RELEASE_DIR/plugins/plugins.txt" | awk 'NF')
  [ "$(sha256sum "$d/node/$NODE_BUNDLE_FILE" 2>/dev/null | cut -d' ' -f1)" = "$NODE_BUNDLE_SHA256" ] || bad+=" node/$NODE_BUNDLE_FILE"
  [ -z "$bad" ] && return 0; echo "$bad"; return 1
}

# Unpack only bundle/ of an offline archive (nothing in it is executed) into $BUNDLE_DIR, after verifying it against THIS release's pins.
extract_bundle_from() {
  local a=$1 tmp src bad
  tmp=$(mktemp -d)
  tar -xzf "$a" -C "$tmp" --no-same-owner --wildcards '*/bundle/*' 2>/dev/null || { rm -rf "$tmp"; warn "$a is not a readable offline archive"; return 1; }
  src=$(find "$tmp" -path '*/bundle/SHA256SUMS' -printf '%h\n' | head -1)
  if [ -z "$src" ] || ! bad=$(verify_pinned_bundle "$src"); then rm -rf "$tmp"; warn "$a does not carry the artifacts pinned by this release (${bad:-no bundle/})"; return 1; fi
  mkdir -p "$BUNDLE_DIR"; cp -a "$src/." "$BUNDLE_DIR/"; rm -rf "$tmp"
  pass "offline bundle unpacked from $a (Grafana RPM, plugins and Node.js match the pins)"
}

online_reachable() { curl -sSI -m 10 "$GRAFANA_RPM_REPO_URL/repodata/repomd.xml" >/dev/null 2>&1 && curl -sSI -m 10 "https://grafana.com/api/plugins/alexanderzobnin-zabbix-app" >/dev/null 2>&1; }
bundle_url() { echo "${BUNDLE_URL:-$BUNDLE_FALLBACK_URL}"; }
bundle_url_sha() { if [ -n "${BUNDLE_URL:-}" ]; then echo "${BUNDLE_URL_SHA256:-}"; else echo "$BUNDLE_FALLBACK_SHA256"; fi; }
download_reachable() { curl -sSIL -m 15 -o /dev/null "$(bundle_url)" 2>/dev/null; }

# Read-only: decide where the packages will come from. Sets PKG_PLAN (none|bundle|archive|repo|download|missing) and PKG_PLAN_DETAIL.
package_plan() {
  PKG_PLAN_DETAIL=""
  if [ -z "$(missing_artifacts)" ]; then PKG_PLAN=none; PKG_PLAN_DETAIL="Grafana and plugins are already at the pinned versions"; return; fi
  if [ "$PACKAGE_SOURCE" != repo ]; then
    if [ -f "$BUNDLE_DIR/SHA256SUMS" ]; then PKG_PLAN=bundle; PKG_PLAN_DETAIL=$BUNDLE_DIR; return; fi
    local a; a=$(nearby_archives | head -1)
    if [ -n "$a" ]; then PKG_PLAN=archive; PKG_PLAN_DETAIL=$a; return; fi
  fi
  if [ "$PACKAGE_SOURCE" != bundle ] && online_reachable; then PKG_PLAN=repo; PKG_PLAN_DETAIL="rpm.grafana.com + grafana.com"; return; fi
  if [ "$PACKAGE_SOURCE" != repo ] && download_reachable; then PKG_PLAN=download; PKG_PLAN_DETAIL=$(bundle_url); return; fi
  PKG_PLAN=missing
}

# Make the plan real (install only). Sets PKG_SRC for the installer.
prepare_packages() {
  package_plan
  case "$PKG_PLAN" in
    none) PKG_SRC=${PKG_SRC:-bundle} ;;
    bundle) PKG_SRC=bundle ;;
    repo) PKG_SRC=repo ;;
    archive) extract_bundle_from "$PKG_PLAN_DETAIL" || die "the offline archive $PKG_PLAN_DETAIL cannot be used (see above); remove it or replace it with a good copy"; PKG_SRC=bundle ;;
    download)
      local url sha f; url=$(bundle_url); sha=$(bundle_url_sha); f="$CACHE_DIR/$(basename "$url")"
      [ -n "$sha" ] || die "BUNDLE_URL is set without BUNDLE_URL_SHA256: refusing an unverified download"
      install -d -m 0755 "$CACHE_DIR"
      info "downloading the pinned offline bundle ($(basename "$url"), ~330 MB) — this is the only download"
      curl -fSL --retry 2 -m 3600 -o "$f.part" "$url" || { rm -f "$f.part"; die "download failed: $url"; }
      [ "$(sha256sum "$f.part" | cut -d' ' -f1)" = "$sha" ] || { rm -f "$f.part"; die "the downloaded archive does not match its pinned SHA-256: refusing it"; }
      mv -f "$f.part" "$f"; extract_bundle_from "$f" || die "the downloaded archive does not carry the pinned artifacts"; PKG_SRC=bundle ;;
    missing) die "$(missing_packages_message)" ;;
  esac
  export PKG_SRC
}

missing_packages_message() {
  printf 'the Grafana package is not available (no offline bundle, no Internet, %s unreachable). Fix: download %s on any PC from %s, copy it next to install.sh (or to /root), and run the installer again.' "$(bundle_url)" "$(basename "$(bundle_url)")" "$(bundle_url)"
}
