#!/usr/bin/env bash
# release-gate.sh — mandatory static pre-release checks (offline; touches no Grafana). Needs bash + Node >= 18.
#   1 shell syntax   2 JS syntax   3 every JSON/YAML-free config parses   4 dashboards: unique uid, directory == folder uid, every
#   datasource reference exists in config/datasources.json, no id/version baked in   5 plugins.txt covers the datasource types
#   6 no secrets / forbidden files   7 inventory doc current   8 NetFlow generator reproduces the committed dashboards   9 VERSION == CHANGELOG
# Exit 0 = PASS. Anything that cannot run is reported SKIPPED, never PASS.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0; SKIP=0
ok() { printf '[PASS] %s\n' "$1"; }; bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }; skip() { printf '[SKIPPED] %s\n' "$1"; SKIP=$((SKIP+1)); }
files() { if git rev-parse --git-dir >/dev/null 2>&1; then git ls-files; else find . -type f -not -path './.git/*' | sed 's#^\./##'; fi; }

echo "== 1. shell syntax"
n=0; while IFS= read -r f; do n=$((n+1)); bash -n "$f" 2>/tmp/rg_err || bad "bash -n $f: $(head -1 /tmp/rg_err)"; done < <(files | grep -E '\.sh$')
ok "$n shell scripts checked"

echo "== 2. JavaScript syntax"
command -v node >/dev/null || { skip "node not available"; }
if command -v node >/dev/null; then n=0; while IFS= read -r f; do n=$((n+1)); node --check "$f" 2>/tmp/rg_err || bad "node --check $f: $(head -1 /tmp/rg_err)"; done < <(files | grep -E '\.mjs$'); ok "$n .mjs files checked"; fi

echo "== 3-5. content consistency"
if command -v node >/dev/null; then
node --input-type=module -e '
import { readFileSync, readdirSync } from "node:fs";
const j = (p) => JSON.parse(readFileSync(p, "utf8"));
const folders = j("config/folders.json"), ds = j("config/datasources.json"), pls = j("config/playlists.json");
const plugins = readFileSync("plugins/plugins.txt", "utf8").split(/\r?\n/).map((l) => l.replace(/#.*/, "").trim()).filter(Boolean).map((l) => l.split(/\s+/)[0]);
const dsUids = new Set(ds.map((d) => d.uid)); const fUids = new Set(folders.map((f) => f.uid));
let bad = 0; const fail = (m) => { console.log("[FAIL] " + m); bad++; };
const uids = new Set();
for (const dir of readdirSync("dashboards")) {
  if (!fUids.has(dir)) fail("dashboards/" + dir + " is not a folder in config/folders.json");
  for (const f of readdirSync("dashboards/" + dir)) {
    const d = j("dashboards/" + dir + "/" + f);
    if (uids.has(d.uid)) fail("duplicate dashboard uid " + d.uid); uids.add(d.uid);
    if (f !== d.uid + ".json") fail(f + ": file name must be <uid>.json (uid is " + d.uid + ")");
    if (d.id !== null && d.id !== undefined) fail(f + ": instance-specific id is baked in");
    if ("version" in d) fail(f + ": instance-specific version is baked in");
    const refs = new Set(); (function w(o) { if (o && typeof o === "object") { if (o.datasource && typeof o.datasource === "object" && o.datasource.uid) refs.add(o.datasource.uid); Object.values(o).forEach(w); } })(d);
    for (const r of refs) if (!dsUids.has(r) && !r.startsWith("-- ") && !r.startsWith("${") && r !== "grafana" && r !== "__expr__") fail(f + ": references unknown datasource uid " + r);
  }
}
for (const p of pls) for (const it of p.items) if (it.type === "dashboard_by_uid" && !uids.has(it.value)) fail("playlist " + p.name + " references missing dashboard " + it.value);
const types = new Set(ds.map((d) => d.type));
for (const t of types) { const base = t.replace(/-datasource$/, ""); if (!plugins.some((p) => p === t || p.startsWith(base))) fail("datasource type " + t + " has no matching plugin in plugins/plugins.txt"); }
console.log(bad ? "" : "[PASS] " + uids.size + " dashboards, " + ds.length + " datasources, " + pls.length + " playlist(s) consistent");
process.exit(bad ? 1 : 0);' || FAIL=$((FAIL+1))
else skip "content consistency (node missing)"; fi

echo "== 6. secrets and forbidden files"
BAD=$(files | grep -E '(^|/)(\.env|[^/]*\.(key|pem|p12|pfx|db|sqlite|log|tgz|zip))$|(^|/)backups/' | grep -v '\.env\.example$' || true)
[ -z "$BAD" ] && ok "no .env / key / database / log / archive / backup files tracked" || bad "forbidden tracked file(s): $BAD"
BIG=$(files | while read -r f; do [ -f "$f" ] && [ "$(wc -c < "$f")" -gt 1048576 ] && echo "$f"; done)
[ -z "$BIG" ] && ok "no file larger than 1 MiB" || bad "large file(s): $BIG"
PAT='(password|passwd|secret|token|api[_-]?key)[A-Za-z_]*["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9+/=_.-]{12,}|BEGIN [A-Z ]*PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{20,}|glsa_[A-Za-z0-9_]{20,}|eyJrIjoi|ssh-(rsa|ed25519) AAAA'
HITS=$(files | grep -vE 'release-gate\.sh$' | xargs grep -InE "$PAT" 2>/dev/null | grep -vE '\$[A-Z_]+|\$\{|<[a-z-]+>|process.env' || true)
[ -z "$HITS" ] && ok "no credential-like literal" || { bad "credential-like literal(s):"; echo "$HITS" | head -10; }

echo "== 7-8. generated documents and generator"
if command -v node >/dev/null; then
  node tools/inventory.mjs --check 2>&1 | sed 's/^/  /' && ok "dashboard inventory current" || bad "dashboard inventory out of date"
  bash tests/check-generator.sh >/tmp/rg_gen 2>&1 && ok "NetFlow generator reproduces the committed dashboards" || { bad "generator check failed"; tail -3 /tmp/rg_gen; }
else skip "inventory / generator (node missing)"; fi

echo "== 9. version"
V=$(cat VERSION 2>/dev/null || echo none)
grep -qE "^## \[?${V//./\\.}\]?( |$)" CHANGELOG.md && ok "VERSION $V has a CHANGELOG entry" || bad "VERSION $V not found in CHANGELOG.md"

echo "== 10. unit tests"
if command -v node >/dev/null; then node --test tests/unit/*.test.mjs >/tmp/rg_unit 2>&1 && ok "unit tests pass ($(grep -E '^# pass' /tmp/rg_unit | tr -dc 0-9))" || { bad "unit tests failed"; tail -8 /tmp/rg_unit; }; else skip "unit tests (node missing)"; fi

echo "== 11. production environment template and pins"
if grep -qE '192\.168\.1\.|grafana-01|netflow-01|\.lab\b' env/production.env.example; then bad "env/production.env.example contains LAB addresses or names"; else ok "env/production.env.example has no LAB addresses"; fi
if grep -qE '^[A-Z_]*(PASSWORD|SECRET|TOKEN)[A-Z_]*=.+' <(grep -v '^SECRETS_DIR=' env/production.env.example); then bad "env/production.env.example carries a secret-looking value"; else ok "env/production.env.example carries no secrets"; fi
if command -v gpg >/dev/null; then
  FPR=$(GNUPGHOME=$(mktemp -d) gpg --batch --quiet --show-keys --with-colons vendor/rpm/RPM-GPG-KEY-grafana 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}')
  PIN=$(sed -n 's/^GRAFANA_RPM_GPG_FPR=//p' VERSIONS.env)
  if [ -n "$FPR" ] && [ "$FPR" = "$PIN" ]; then ok "vendored Grafana RPM key fingerprint equals the pin ($PIN)"; else bad "vendored key fingerprint '$FPR' != pin '$PIN'"; fi
else skip "vendored key fingerprint (gpg missing)"; fi
BADP=$(sed 's/#.*//' plugins/plugins.txt | awk 'NF && $3 !~ /^[0-9a-f]{64}$/ {print $1}')
if [ -z "$BADP" ]; then ok "every plugin has a pinned SHA-256"; else bad "plugin(s) without a SHA-256 pin: $BADP"; fi
if grep -qE '^GRAFANA_RPM_SHA256=[0-9a-f]{64}$' VERSIONS.env; then ok "Grafana RPM SHA-256 pinned"; else bad "GRAFANA_RPM_SHA256 missing in VERSIONS.env"; fi
MISSING=""; for d in INSTALL.md docs/PRODUCTION-RHEL9.md docs/BACKUP-RESTORE.md docs/OFFLINE.md docs/SECURITY-PRODUCTION.md docs/LAB-VS-PRODUCTION.md docs/ZABBIX-ITEM-MAP.md docs/GITHUB-ACCESS.md docs/VALIDATION-RHEL9.md docs/ROOT-CAUSE-V2.md docs/MIGRATION-FROM-V1.md docs/ROLLBACK.md docs/LIVE-VERIFICATION.md docs/VALIDATION-V2.md; do [ -s "$d" ] || MISSING="$MISSING $d"; done
if [ -z "$MISSING" ]; then ok "required documents present"; else bad "missing document(s):$MISSING"; fi

echo "== 12. release 2.0: environment parser, shell lint, simulated RHEL host"
if command -v python3 >/dev/null; then
  python3 -m py_compile lib/envparse.py lib/probe.py && ok "lib/envparse.py, lib/probe.py compile" || bad "python helpers do not compile"
  ERRS=$(python3 lib/envparse.py parse env/production.env.example | tr '\0' '\n' | grep -A1 -x E | grep -v -x -e E -e -- || true)
  [ -z "$ERRS" ] && ok "env/production.env.example is valid for the parser" || bad "env/production.env.example: $ERRS"
else skip "parser checks (python3 missing)"; fi
if command -v shellcheck >/dev/null; then
  shellcheck -S warning -e SC2034,SC2154,SC1090,SC1091,SC2010,SC2046 install.sh bin/grafana-platform lib/*.sh tools/build-offline-bundle.sh tests/sim/run-sim.sh tests/sim/fakebin/* >/tmp/rg_sc 2>&1 && ok "shellcheck (warning level) clean" || { bad "shellcheck findings"; head -20 /tmp/rg_sc; }
else skip "shellcheck not installed"; fi
if [ "$(id -u)" = 0 ] && command -v unshare >/dev/null && command -v node >/dev/null; then
  bash tests/sim/run-sim.sh ${GATE_V1_CHECKOUT:+"$GATE_V1_CHECKOUT"} >/tmp/rg_sim 2>&1 && ok "simulated RHEL 9.8 host: $(grep -E "^SIMULATION:" /tmp/rg_sim | sed "s/^SIMULATION: //"), $(grep -c "isolation: host" /tmp/rg_sim) isolation check  (SIMULATION ONLY)" || { bad "simulation failed"; grep -E "FAIL|SIMULATION" /tmp/rg_sim | head -15; }
else skip "simulated RHEL host (needs root + unshare + node)"; fi

echo; if [ "$FAIL" -eq 0 ]; then echo "RELEASE GATE: PASS ($SKIP skipped)"; else echo "RELEASE GATE: FAIL ($FAIL)"; fi
[ "$FAIL" -eq 0 ]
