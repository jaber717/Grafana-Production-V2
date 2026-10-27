#!/usr/bin/env bash
# Proof that `install.sh --command-center` updates ONLY the dashboard noc-command-center. TEST-VM harness (not for production):
# needs the AlmaLinux test container (docker name in $VM, default alma98) with Grafana 13.2.3 + the installed platform, and Zabbix =
# the SIMULATED API tests/noc/zabbix7-api.mjs. Grafana's state is read independently of the tool under test, through its HTTP API.
#   tests/noc/single-dashboard-update.sh   -> prints the evidence; exit 1 when a check fails
set -uo pipefail
VM=${VM:-alma98}; REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd); W=$(mktemp -d)
PW=$(docker exec "$VM" cat /etc/grafana-platform/secrets/admin-password)
FAIL=0; ok() { echo "[PASS] $1"; }; bad() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
inst() { docker exec "$VM" bash -c "cd /root/GP-new && echo | GP_OS_RELEASE_FILE=/root/os-release.test-as-rhel ${1:-} ./install.sh --command-center 2>&1" | sed 's/\x1b\[[0-9;]*m//g'; }
snap() { python3 - "$PW" "$1" <<'PY'
import sys, json, base64, urllib.request, hashlib
pw, out = sys.argv[1:3]
H = {"Authorization": "Basic " + base64.b64encode(("admin:" + pw).encode()).decode()}
g = lambda p: json.load(urllib.request.urlopen(urllib.request.Request("http://localhost:3000" + p, headers=H)))
r = {"dashboards": {}, "datasources": {}, "plugins": {}, "settings": g("/api/frontend/settings")["buildInfo"]["version"]}
for h in g("/api/search?type=dash-db&limit=500"):
    f = g("/api/dashboards/uid/" + h["uid"])
    r["dashboards"][h["uid"]] = {"version": f["dashboard"]["version"], "folder": f["meta"].get("folderUid", ""), "url": f["meta"]["url"],
                                 "sha": hashlib.sha256(json.dumps({k: v for k, v in f["dashboard"].items() if k not in ("id", "version")}, sort_keys=True).encode()).hexdigest()[:16]}
for d in g("/api/datasources"): r["datasources"][d["uid"]] = hashlib.sha256(json.dumps(d, sort_keys=True).encode()).hexdigest()[:16] + " v%s" % d.get("version")
for p in g("/api/plugins?core=0"): r["plugins"][p["id"]] = p["info"]["version"]
json.dump(r, open(out, "w"), indent=1, sort_keys=True)
PY
}
others() { python3 - "$1" <<'PY'
import sys, json
r = json.load(open(sys.argv[1])); r["dashboards"].pop("noc-command-center", None); print(json.dumps(r, indent=1, sort_keys=True))
PY
}
pid() { docker exec "$VM" systemctl show grafana-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' '; }
cc() { python3 -c "import json;print(json.load(open('$1'))['dashboards']['noc-command-center']['sha'], json.load(open('$1'))['dashboards']['noc-command-center']['version'], json.load(open('$1'))['dashboards']['noc-command-center']['url'])"; }

echo "== setup: Grafana holds the 2.4.0 Command Center (today's production state), and two OTHER managed dashboards have drifted from the repository"
git -C "$REPO" show bdba610:dashboards/noc/noc-command-center.json > "$W/cc240.json" 2>/dev/null || cp /tmp/claude-0/-home-claude/97dacfc0-044d-555d-84f1-774c60725ab9/scratchpad/deployed.json "$W/cc240.json"
python3 - "$PW" "$W/cc240.json" <<'PY'
import sys, json, base64, urllib.request
pw, f = sys.argv[1:3]
H = {"Content-Type": "application/json", "Authorization": "Basic " + base64.b64encode(("admin:" + pw).encode()).decode()}
def call(p, b=None): return json.load(urllib.request.urlopen(urllib.request.Request("http://localhost:3000" + p, data=json.dumps(b).encode() if b else None, headers=H)))
txt = open(f).read()
for k, v in {"@@NOC_ALL@@": "/(?:router|rtr)|(?:switch)|(?:firewall)/i", "@@NOCQ_ALL@@": "/(?:router|rtr)|(?:switch)|(?:firewall)/i", "@@NOC_ROUTER@@": "/router|rtr/i", "@@NOCQ_ROUTER@@": "/router|rtr/i", "@@NOC_SWITCH@@": "/switch/i", "@@NOCQ_SWITCH@@": "/switch/i", "@@NOC_FIREWALL@@": "/firewall/i", "@@NOCQ_FIREWALL@@": "/firewall/i", "zabbix-lab": "dg2evelbngb9cb"}.items(): txt = txt.replace(k, v)
d = json.loads(txt); d = d.get("dashboard", d)
old = call("/api/dashboards/uid/noc-command-center"); d["id"] = old["dashboard"]["id"]; d["version"] = old["dashboard"]["version"]
call("/api/dashboards/db", {"dashboard": d, "folderUid": old["meta"]["folderUid"], "overwrite": True})
for uid in ("noc-device-health", "noc-wan-overview"):       # drift: a general --dashboards run WOULD rewrite these two
    o = call("/api/dashboards/uid/" + uid); x = o["dashboard"]; x["tags"] = list(x.get("tags", [])) + ["operator-edit"]
    call("/api/dashboards/db", {"dashboard": x, "folderUid": o["meta"]["folderUid"], "overwrite": True})
PY
docker exec "$VM" bash -c 'rm -rf /root/GP-new && mkdir /root/GP-new' && (cd "$REPO" && tar --exclude=.git -czf - .) | docker exec -i "$VM" tar xzf - -C /root/GP-new
docker exec "$VM" rm -rf /var/lib/grafana-platform/backups/command-center
snap "$W/before.json"; P0=$(pid)
echo "   Command Center before: sha/version/url = $(cc "$W/before.json")"
echo "== for contrast: what the general --dashboards step would do (apply.mjs --dry-run, nothing written)"
docker exec "$VM" bash -c "cd /root/GP-new && GRAFANA_URL=http://127.0.0.1:3000 GRAFANA_USER=admin GRAFANA_PASSWORD='$PW' /opt/grafana-platform/node/bin/node scripts/apply.mjs --env-file /etc/grafana-platform/platform.env --dry-run --skip-playlists 2>&1" | grep -E "^(updated|created|refused) |would apply" | sed 's/^/   /'
snap "$W/after-dry.json"; cmp -s "$W/before.json" "$W/after-dry.json" && ok "the dry run wrote nothing" || bad "dry run changed Grafana"

echo; echo "== run 1: install.sh --command-center"; inst | tee "$W/run1.txt"
snap "$W/after1.json"
echo; echo "== run 2 (rerun): install.sh --command-center"; inst | tee "$W/run2.txt"
snap "$W/after2.json"

echo; echo "== checks (state read independently through the Grafana API)"
[ "$(others "$W/before.json")" = "$(others "$W/after1.json")" ] && ok "every other dashboard (uid, version, folder, URL, full JSON hash without id/version, plus version), every data source (full definition + version) and every plugin: IDENTICAL after run 1" || { bad "something else changed"; diff <(others "$W/before.json") <(others "$W/after1.json"); }
[ "$(others "$W/after1.json")" = "$(others "$W/after2.json")" ] && ok "…and after the rerun" || bad "rerun changed something"
python3 - "$W" <<'PY' && ok "the two drifted dashboards (noc-device-health, noc-wan-overview) were NOT reset to the repository; a general --dashboards run would have rewritten them" || bad "drifted dashboards were touched"
import json, sys
a = json.load(open(sys.argv[1] + "/before.json"))["dashboards"]; b = json.load(open(sys.argv[1] + "/after2.json"))["dashboards"]
assert all(a[u] == b[u] for u in ("noc-device-health", "noc-wan-overview"))
PY
set -- $(cc "$W/before.json"); B_SHA=$1 B_V=$2 B_URL=$3; set -- $(cc "$W/after1.json"); A_SHA=$1 A_V=$2 A_URL=$3; set -- $(cc "$W/after2.json"); R_SHA=$1 R_V=$2
[ "$A_SHA" != "$B_SHA" ] && [ "$A_V" -eq $((B_V+1)) ] && ok "Command Center changed once: v$B_V -> v$A_V" || bad "Command Center sha/version: $B_SHA v$B_V -> $A_SHA v$A_V"
[ "$A_URL" = "$B_URL" ] && ok "uid and URL preserved: $A_URL" || bad "URL changed $B_URL -> $A_URL"
[ "$R_SHA" = "$A_SHA" ] && [ "$R_V" = "$A_V" ] && ok "rerun is idempotent: no write, version stays v$R_V" || bad "rerun changed the Command Center"
grep -q "unchanged  noc-command-center" "$W/run2.txt" && ok "rerun said 'unchanged' and made no backup" || bad "rerun output"
N=$(docker exec "$VM" bash -c 'ls /var/lib/grafana-platform/backups/command-center | wc -l'); [ "$N" = 1 ] && ok "exactly one backup exists after run 1 + rerun" || bad "backups: $N"
BK=$(docker exec "$VM" bash -c 'ls /var/lib/grafana-platform/backups/command-center/*.json | head -1'); echo "   backup file: $BK ($(docker exec "$VM" stat -c '%a %U' "$BK"), dir $(docker exec "$VM" stat -c '%a' /var/lib/grafana-platform/backups/command-center))"
docker exec "$VM" cat "$BK" > "$W/backup.json"
python3 - "$W/backup.json" "$B_SHA" <<'PY' && ok "the backup holds the previous Command Center exactly (content hash equals the one read before the update)" || bad "backup content differs"
import json, sys, hashlib
d = {k: v for k, v in json.load(open(sys.argv[1]))["dashboard"].items() if k not in ("id", "version")}
assert hashlib.sha256(json.dumps(d, sort_keys=True).encode()).hexdigest()[:16] == sys.argv[2], "hash"
PY
[ "$(pid)" = "$P0" ] && ok "Grafana not restarted ($P0)" || bad "Grafana PID/start changed"

echo; echo "== refusals: nothing is written when the update cannot be done safely"
docker exec "$VM" bash -c 'cp /etc/grafana-platform/platform.env /root/env.nods && sed -i "s/^ZABBIX_DATASOURCE_UID=.*/ZABBIX_DATASOURCE_UID=doesnotexist/" /root/env.nods && cp /etc/grafana-platform/platform.env /root/env.nozbx && sed -i "s/^ZABBIX_ENABLED=.*/ZABBIX_ENABLED=no/" /root/env.nozbx'
for e in nods nozbx; do
  docker exec "$VM" bash -c "cd /root/GP-new && GRAFANA_URL=http://127.0.0.1:3000 GRAFANA_USER=admin GRAFANA_PASSWORD='$PW' /opt/grafana-platform/node/bin/node scripts/update-command-center.mjs --env-file /root/env.$e --backup-dir /root/bk-$e 2>&1; echo exit=\$?" | sed 's/^/   /' | tail -4
done
snap "$W/after-refuse.json"; cmp -s "$W/after2.json" "$W/after-refuse.json" && ok "both refusals (missing Zabbix data source / Zabbix disabled) left Grafana byte-identical" || bad "a refusal wrote something"

echo; echo "== rollback with the backup, then update again"
inst "GP_RESTORE_FILE=$BK" | grep -E "backup|updated|verified|restore" ; snap "$W/after-restore.json"
set -- $(cc "$W/after-restore.json"); [ "$1" = "$B_SHA" ] && ok "restore put the previous Command Center back (content hash equals the original)" || bad "restore content $1 != $B_SHA"
[ "$(others "$W/before.json")" = "$(others "$W/after-restore.json")" ] && ok "restore touched nothing else" || bad "restore changed something else"
inst | grep -E "updated|backup|verified" ; snap "$W/after3.json"
set -- $(cc "$W/after3.json"); [ "$1" = "$A_SHA" ] && ok "update after restore gives the 2.5.0 Command Center again" || bad "final sha"
[ "$(others "$W/before.json")" = "$(others "$W/after3.json")" ] && ok "final state: every other object still identical to the start" || bad "final others differ"
[ "$(pid)" = "$P0" ] && ok "Grafana still not restarted" || bad "Grafana restarted"
echo; echo "SINGLE-DASHBOARD UPDATE: $FAIL failure(s)"; cp "$W"/*.json "${EVIDENCE_DIR:-/dev/null}" 2>/dev/null; exit $((FAIL>0))
