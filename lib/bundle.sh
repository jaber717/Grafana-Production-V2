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

online_reachable() { curl -fsSI -m 10 "$GRAFANA_RPM_REPO_URL/repodata/repomd.xml" >/dev/null 2>&1 && curl -fsSI -m 10 "https://grafana.com/api/plugins/alexanderzobnin-zabbix-app" >/dev/null 2>&1; }
bundle_url() { echo "${BUNDLE_URL:-$BUNDLE_FALLBACK_URL}"; }
bundle_url_sha() { if [ -n "${BUNDLE_URL:-}" ]; then echo "${BUNDLE_URL_SHA256:-}"; else echo "$BUNDLE_FALLBACK_SHA256"; fi; }

# Outbound proxy for the one pinned-archive download only (Grafana, Zabbix and ClickHouse are internal and never use it).
# Order: GP_PROXY, https_proxy / HTTPS_PROXY (https URLs) or http_proxy / HTTP_PROXY (http URLs), proxy= in /etc/dnf/dnf.conf.
dl_proxy() {
  local p=${GP_PROXY:-}
  if [ -z "$p" ]; then case "$1" in https://*) p=${https_proxy:-${HTTPS_PROXY:-}} ;; *) p=${http_proxy:-${HTTP_PROXY:-}} ;; esac; fi
  [ -z "$p" ] && [ -r "${GP_DNF_CONF:-/etc/dnf/dnf.conf}" ] && p=$(sed -n 's/^[[:space:]]*proxy[[:space:]]*=[[:space:]]*//p' "${GP_DNF_CONF:-/etc/dnf/dnf.conf}" | tr -d '[:space:]' | tail -1)
  case "$p" in ""|_none_) echo "" ;; *://*) echo "$p" ;; *) echo "http://$p" ;; esac
}
# curl for the pinned download: explicit proxy, follows GitHub's redirect, retries transient errors (incl. 502/503/504).
# DL_INSECURE=1 only after a certificate failure caused by TLS inspection: the file is still accepted only if its SHA-256 equals the pin.
dl_curl() {
  local url=$1 p; shift; p=$(dl_proxy "$url")
  local a=(-fSL --connect-timeout 20 --retry 3 --retry-delay 5 --noproxy '')
  [ -n "$p" ] && a+=(--proxy "$p")
  [ "${DL_INSECURE:-0}" = 1 ] && a+=(-k)
  curl "${a[@]}" "$@" "$url"
}
dl_hint() { # $1 = curl exit code
  local p; p=$(dl_proxy "$(bundle_url)")
  case "$1" in
    5|7) [ -n "$p" ] && echo "proxy $p does not accept connections (check address/port)" || echo "no proxy configured and no direct route; rerun with: sudo GP_PROXY=http://<proxy>:<port> $(CLI 2>/dev/null || echo ./install.sh)" ;;
    6) echo "DNS cannot resolve github.com; use the proxy: GP_PROXY=http://<proxy>:<port>" ;;
    28) echo "timed out; the proxy must allow codeload.github.com (port 443)" ;;
    22|56) echo "the proxy refused or the server answered an error; allow codeload.github.com on ${p:-the proxy}" ;;
    *) echo "see the curl message above" ;;
  esac
}
# Ranged GET (1 byte) through the same path as the real download; sets DL_ERR / DL_RC on failure, DL_INSECURE=1 if only the certificate failed.
download_reachable() {
  local out rc; DL_ERR=""; DL_RC=0
  out=$(dl_curl "$(bundle_url)" -sS -r 0-0 -m 60 -o /dev/null 2>&1) && return 0 || rc=$?
  if [ "$rc" = 60 ] || [ "$rc" = 35 ]; then
    rc=0; out=$(DL_INSECURE=1 dl_curl "$(bundle_url)" -sS -r 0-0 -m 60 -o /dev/null 2>&1) || rc=$?
    if [ "$rc" = 0 ]; then DL_INSECURE=1; export DL_INSECURE; return 0; fi
  fi
  DL_RC=$rc; DL_ERR=$(echo "$out" | tail -1); return 1
}

# ---- package pieces from codeload.github.com (packages/MANIFEST.txt: "<commit> <piece-sha256> <artifact> <index>") ----
PARTS_MANIFEST="$RELEASE_DIR/packages/MANIFEST.txt"
PARTS_JOBS=${GP_PARTS_JOBS:-4}
parts_list() { grep -v '^#' "$PARTS_MANIFEST" | awk 'NF == 4'; }
# One piece: download the small tar.gz of that commit, take its single file, check the piece's SHA-256. Up to 5 attempts.
fetch_part() {
  local c=$1 s=$2 out=$3 try rc err
  for try in 1 2 3 4 5; do
    rc=0; err=$(dl_curl "$PACKAGES_URL_BASE/$c" -sS -m 120 -o "$out.tgz" 2>&1) || rc=$?
    if [ "$rc" = 0 ]; then
      if tar -xzOf "$out.tgz" --wildcards '*/part' > "$out.tmp" 2>/dev/null && [ "$(sha256sum < "$out.tmp" | cut -c1-64)" = "$s" ]; then
        mv -f "$out.tmp" "$out"; rm -f "$out.tgz"; return 0
      fi
      rc=22; err="piece $c: content does not match its SHA-256"
    fi
    rm -f "$out.tgz" "$out.tmp"; sleep $((try * 2))
  done
  echo "$rc $(echo "$err" | tail -1)" > "$out.err"; return 1
}
# Read-only check: the first piece can be fetched (sets DL_ERR / DL_RC; DL_INSECURE=1 if only certificate verification failed).
parts_reachable() {
  [ -s "$PARTS_MANIFEST" ] && [ -n "${PACKAGES_URL_BASE:-}" ] || return 1
  local c out rc; DL_ERR=""; DL_RC=0; c=$(parts_list | awk 'NR==1{print $1}')
  out=$(dl_curl "$PACKAGES_URL_BASE/$c" -sS -m 60 -o /dev/null 2>&1) && return 0 || rc=$?
  if [ "$rc" = 60 ] || [ "$rc" = 35 ]; then
    rc=0; out=$(DL_INSECURE=1 dl_curl "$PACKAGES_URL_BASE/$c" -sS -m 60 -o /dev/null 2>&1) || rc=$?
    if [ "$rc" = 0 ]; then DL_INSECURE=1; export DL_INSECURE; return 0; fi
  fi
  DL_RC=$rc; DL_ERR=$(echo "$out" | tail -1); return 1
}
# Fetch every missing piece (pieces already in the cache and matching their SHA-256 are kept: a re-run continues),
# join them per artifact into $BUNDLE_DIR and verify every artifact against this release's pins.
fetch_parts_bundle() {
  local dir="$CACHE_DIR/parts" total done=0 running=0 failed=0 c s a i f
  install -d -m 0755 "$dir"; rm -f "$dir"/*.err
  total=$(parts_list | wc -l)
  info "fetching $total package pieces from ${PACKAGES_URL_BASE%%/tar.gz}${PKG_PROXY:+ via proxy $PKG_PROXY} (each < 200 KB, SHA-256 checked)"
  while read -r c s a i; do
    done=$((done + 1)); if [ $((done % 172)) = 0 ]; then info "  $((done * 100 / total))% of the pieces"; fi
    if [ -f "$dir/$c" ] && [ "$(sha256sum < "$dir/$c" | cut -c1-64)" = "$s" ]; then continue; fi
    fetch_part "$c" "$s" "$dir/$c" &
    running=$((running + 1))
    if [ "$running" -ge "$PARTS_JOBS" ]; then wait -n || failed=1; running=$((running - 1)); fi
    if [ "$failed" = 1 ]; then break; fi
  done < <(parts_list)
  while [ "$running" -gt 0 ]; do wait -n || failed=1; running=$((running - 1)); done
  if [ "$failed" = 1 ]; then
    f=$(cat "$dir"/*.err 2>/dev/null | head -1); DL_RC=${f%% *}; DL_ERR=${f#* }
    die "a package piece could not be fetched after 5 attempts: $DL_ERR. Pieces already fetched are kept in $dir; run the installer again to continue — $(dl_hint "$DL_RC")"
  fi
  install -d -m 0755 "$BUNDLE_DIR"
  for a in $(parts_list | awk '!seen[$3]++ {print $3}'); do
    install -d -m 0755 "$BUNDLE_DIR/$(dirname "$a")"
    parts_list | awk -v a="$a" '$3 == a {print $4, $1}' | sort -n | while read -r _ c; do cat "$dir/$c"; done > "$BUNDLE_DIR/$a.tmp"
    mv -f "$BUNDLE_DIR/$a.tmp" "$BUNDLE_DIR/$a"
  done
  local bad; if ! bad=$(verify_pinned_bundle "$BUNDLE_DIR"); then die "the joined packages do not match the pins of this release:$bad (refusing them)"; fi
  (cd "$BUNDLE_DIR" && find rpm plugins node -type f -print0 | sort -z | xargs -0 sha256sum) > "$BUNDLE_DIR/SHA256SUMS"
  rm -rf "$dir"
  pass "packages fetched from GitHub in $total pieces; Grafana RPM, plugins and Node.js match the pins"
}

# Read-only: decide where the packages will come from. Sets PKG_PLAN (none|bundle|archive|repo|download|missing) and PKG_PLAN_DETAIL.
package_plan() {
  PKG_PLAN_DETAIL=""
  if [ -z "$(missing_artifacts)" ]; then PKG_PLAN=none; PKG_PLAN_DETAIL="Grafana and plugins are already at the pinned versions"; return; fi
  if [ "$PACKAGE_SOURCE" != repo ]; then
    if [ -f "$BUNDLE_DIR/SHA256SUMS" ]; then PKG_PLAN=bundle; PKG_PLAN_DETAIL=$BUNDLE_DIR; return; fi
    local a; a=$(nearby_archives | head -1)
    if [ -n "$a" ]; then PKG_PLAN=archive; PKG_PLAN_DETAIL=$a; return; fi
  fi
  PKG_PROXY=$(dl_proxy "$(bundle_url)")
  if [ "$PACKAGE_SOURCE" != repo ] && parts_reachable; then PKG_PLAN=parts; PKG_PLAN_DETAIL="$(parts_list | wc -l) pieces from ${PACKAGES_URL_BASE%%/tar.gz}"; return; fi
  if [ "$PACKAGE_SOURCE" != repo ] && download_reachable; then PKG_PLAN=download; PKG_PLAN_DETAIL=$(bundle_url); return; fi
  if [ "$PACKAGE_SOURCE" != bundle ] && online_reachable; then PKG_PLAN=repo; PKG_PLAN_DETAIL="rpm.grafana.com + grafana.com"; return; fi
  PKG_PLAN=missing
}

# Make the plan real (install only). Sets PKG_SRC for the installer.
prepare_packages() {
  package_plan
  case "$PKG_PLAN" in
    none) PKG_SRC=${PKG_SRC:-bundle} ;;
    bundle) PKG_SRC=bundle ;;
    repo) PKG_SRC=repo ;;
    parts)
      [ "${DL_INSECURE:-0}" = 1 ] && warn "TLS to GitHub is re-signed by an inspecting proxy (certificate not trusted here); continuing because every piece and every package is accepted only if its SHA-256 matches"
      fetch_parts_bundle; PKG_SRC=bundle ;;
    archive) extract_bundle_from "$PKG_PLAN_DETAIL" || die "the offline archive $PKG_PLAN_DETAIL cannot be used (see above); remove it or replace it with a good copy"; PKG_SRC=bundle ;;
    download)
      local url sha f; url=$(bundle_url); sha=$(bundle_url_sha); f="$CACHE_DIR/$(basename "$url")"
      [ -n "$sha" ] || die "BUNDLE_URL is set without BUNDLE_URL_SHA256: refusing an unverified download"
      install -d -m 0755 "$CACHE_DIR"
      info "downloading the pinned offline bundle ($(basename "$url"), ~330 MB) — this is the only download"
      [ "${DL_INSECURE:-0}" = 1 ] && warn "TLS to GitHub is re-signed by an inspecting proxy (certificate not trusted here); downloading anyway because the file is accepted only if its SHA-256 equals the pin in this release"
      local rc=0; dl_curl "$url" -m 3600 -o "$f.part" || rc=$?
      [ "$rc" = 0 ] || { rm -f "$f.part"; die "download failed (curl exit $rc): $url — $(dl_hint "$rc")"; }
      [ "$(sha256sum "$f.part" | cut -d' ' -f1)" = "$sha" ] || { rm -f "$f.part"; die "the downloaded archive does not match its pinned SHA-256: refusing it"; }
      mv -f "$f.part" "$f"; extract_bundle_from "$f" || die "the downloaded archive does not carry the pinned artifacts"; PKG_SRC=bundle ;;
    missing) die "$(missing_packages_message)" ;;
  esac
  export PKG_SRC
}

missing_packages_message() {
  local p; p=$(dl_proxy "$(bundle_url)")
  printf 'the Grafana package is not available: no offline bundle here and neither the package pieces on %s nor %s are reachable%s (%s). Fix: %s' "${PACKAGES_URL_BASE%%/tar.gz}" "$(bundle_url)" "${p:+ via proxy $p}" "${DL_ERR:-no answer}" "$(dl_hint "${DL_RC:-7}")"
}
