#!/usr/bin/env python3
"""Browser test of "NOC — Command Center" against a rule matrix and large selections (real Grafana + real Zabbix plugin;
Zabbix = SIMULATED API tests/noc/zabbix7-api.mjs --matrix and/or --bulk N, which publishes its own expected results at /__truth).

  python3 tests/noc/ui-matrix.py <grafana-url> <admin-password> <truth-url> [--bulk]

Every device of the fixture has a hand-written expected Type / Status / CPU / Memory (see the fixture). The test selects devices through
the URL (the same state the Devices picker writes), reads the rendered fleet table and the KPI tiles, and compares. With --bulk it also
runs 9 / 30 / 100 selected devices, a selection change, and an automatic refresh, and prints the load time and the data the page fetched.
Prints one PASS/FAIL line per check; exit 1 if any failed.
"""
import asyncio, json, re, sys, time, urllib.request
from urllib.parse import urlencode
from playwright.async_api import async_playwright

BASE, PW, TRUTH_URL = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
BULK = "--bulk" in sys.argv
TRUTH = {t["name"]: t for t in json.load(urllib.request.urlopen(TRUTH_URL))}
DASH, FLEET = "/d/noc-command-center", "Fleet health — selected devices"
KPIS = ["Selected devices", "UP", "DOWN", "UNKNOWN"]
ORDER = {"DOWN": 0, "UNKNOWN": 1, "UP": 2}
RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append(bool(ok)); print(f"  [{'PASS' if ok else 'FAIL'}] {name}{(' - ' + str(detail)) if detail and not ok else ''}", flush=True)


class Net:
    def __init__(self, page):
        self.errors, self.count, self.bytes, self.calls = [], 0, 0, 0
        page.on("response", lambda r: asyncio.ensure_future(self._on(r)))
    def reset(self): self.count = self.bytes = 0
    async def _on(self, r):
        if "/api/ds/query" not in r.url and "/resources/zabbix-api" not in r.url: return
        self.count += 1
        try:
            raw = await r.body(); self.bytes += len(raw); body = json.loads(raw)
        except Exception: body = {}
        errs = [v.get("error") for v in (body.get("results") or {}).values() if v.get("error")] if isinstance(body, dict) else []
        if r.status >= 400 or errs or (isinstance(body, dict) and body.get("error")): self.errors.append((r.status, r.url[-60:], errs or body))


def url_for(devs, extra=""):
    return BASE + DASH + "?" + urlencode([("orgId", "1")] + [("var-device", d) for d in devs]) + extra


async def kpis(page):
    out = {}
    for t in KPIS:
        txt = (await page.locator(f'[data-testid="data-testid Panel header {t}"]').inner_text()).strip().splitlines()
        out[t] = int(txt[-1]) if txt[-1].strip().isdigit() else txt[-1]
    return out


async def fleet_rows(page, n):
    """All rows of the fleet table: the panel alone in view mode on a page tall enough to draw n rows."""
    out, seen = [], set()
    panel = page.locator(f'[data-testid="data-testid Panel header {FLEET}"]')
    for _ in range(40):
        for r in (await panel.locator("[role=row]").all_inner_texts())[1:]:
            c = [x.strip() for x in r.split("\n")]
            if c[0] not in seen: seen.add(c[0]); out.append({"device": c[0], "type": c[1], "status": c[2], "cpu": c[3], "mem": c[4]})
        if len(out) >= n: break
        await panel.locator("[role=row]").nth(2).hover(); await page.mouse.wheel(0, 1200); await page.wait_for_timeout(300)
    return out


def want_cell(v):
    return "N/A" if v == "N/A" else v


def cpu_ok(shown, exp):
    if exp == "N/A": return shown == "N/A"
    m = re.fullmatch(r"(\d+)%", shown)
    return bool(m) and abs(int(m.group(1)) - exp) <= 1


async def verify(page, net, label, devs, shot=None):
    """Load the dashboard for `devs`, compare KPI tiles; then the fleet table in view mode against /__truth."""
    t0 = time.time(); net.reset()
    await page.goto(url_for(devs), wait_until="networkidle"); await page.wait_for_selector('[data-testid="data-testid Panel header Selected devices"]'); await page.wait_for_timeout(3500)
    await page.wait_for_load_state("networkidle")
    secs, nreq, nbytes = time.time() - t0, net.count, net.bytes
    k = await kpis(page)
    exp_k = {"Selected devices": len(devs)} | {s: sum(TRUTH[d]["status"] == s for d in devs) for s in ("UP", "DOWN", "UNKNOWN")}
    check(f"{label}: KPI tiles {exp_k}", k == exp_k, f"got {k}")
    if shot: await page.screenshot(path=f"cc-{shot}.png")
    h = max(1100, 140 + 38 * len(devs) + 300)
    await page.set_viewport_size({"width": 1920, "height": min(h, 4800)})
    await page.goto(url_for(devs, "&viewPanel=panel-10"), wait_until="networkidle"); await page.wait_for_timeout(4000)
    rows = await fleet_rows(page, len(devs))
    got = [r["device"] for r in rows]
    check(f"{label}: fleet table lists exactly the {len(devs)} selected devices", sorted(got) == sorted(devs), f"missing {sorted(set(devs) - set(got))[:5]} extra {sorted(set(got) - set(devs))[:5]}")
    bad = {"status": [], "type": [], "cpu": [], "mem": []}
    for r in rows:
        t = TRUTH[r["device"]]
        if r["status"] != t["status"]: bad["status"].append((r["device"], r["status"], t["status"]))
        if r["type"] != t["type"]: bad["type"].append((r["device"], r["type"], t["type"]))
        if not cpu_ok(r["cpu"], t["cpu"]): bad["cpu"].append((r["device"], r["cpu"], t["cpu"]))
        if not cpu_ok(r["mem"], t["mem"]): bad["mem"].append((r["device"], r["mem"], t["mem"]))
    for col, name in (("status", "Availability status (UP / DOWN / UNKNOWN)"), ("type", "Device type"), ("cpu", "CPU %"), ("mem", "Memory %")):
        check(f"{label}: {name} of every device", not bad[col], bad[col][:6])
    check(f"{label}: sorted DOWN, then UNKNOWN, then UP", [ORDER[r["status"]] for r in rows] == sorted(ORDER[r["status"]] for r in rows), [r["status"] for r in rows][:12])
    check(f"{label}: a missing metric is N/A, never 0", not [r for r in rows if r["cpu"] in ("0%", "0") or r["mem"] in ("0%", "0")], [r for r in rows if r["cpu"].startswith("0") or r["mem"].startswith("0")][:3])
    await page.set_viewport_size({"width": 1920, "height": 1080})
    print(f"    ({label}: dashboard load {secs:.1f}s, {nreq} data requests, {nbytes / 1024:.0f} KiB fetched)", flush=True)
    return rows


async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch()
        page = await (await b.new_context(locale="en-US", viewport={"width": 1920, "height": 1080})).new_page()
        await page.goto(BASE + "/login", wait_until="load"); await page.wait_for_selector("input[name=user]", timeout=60000)
        await page.fill("input[name=user]", "admin"); await page.fill("input[name=password]", PW); await page.click("button[type=submit]")
        await page.wait_for_url(lambda u: "/login" not in u, timeout=30000)
        net = Net(page)
        mx = sorted(n for n in TRUTH if n.startswith("MX-"))
        bl = sorted(n for n in TRUTH if n.startswith("BLK-"))
        if mx:
            print(f"### Rule matrix: {len(mx)} devices (ICMP/SNMP/agent, stale, conflicting, vendors, units, missing metrics)")
            rows = await verify(page, net, "matrix", mx, shot="matrix")
            by = {r["device"]: r for r in rows}
            check("CPU/memory data alone never makes a device UP (MX-CPU-ONLY, MX-STALE-ALL are UNKNOWN)", all(by[d]["status"] == "UNKNOWN" for d in ("MX-CPU-ONLY", "MX-STALE-ALL")))
            check("ICMP outranks SNMP: ICMP down + SNMP up = DOWN; ICMP up + SNMP down = UP", by["MX-CONFLICT-ICMPDOWN-SNMPUP"]["status"] == "DOWN" and by["MX-CONFLICT-ICMPUP-SNMPDOWN"]["status"] == "UP")
            check("SNMP outranks the agent: SNMP down + agent up = DOWN; SNMP up + agent down = UP", by["MX-CONFLICT-SNMPDOWN-AGENTUP"]["status"] == "DOWN" and by["MX-CONFLICT-SNMPUP-AGENTDOWN"]["status"] == "UP")
            check("stale ICMP is ignored, fresh SNMP decides", by["MX-STALE-ICMP-SNMP-UP"]["status"] == "UP" and by["MX-STALE-ICMP-SNMP-DOWN"]["status"] == "DOWN")
            check("CPU temperature / fan / per-core items are not taken as CPU %", by["MX-BYTES-PERCORE"]["cpu"] == "N/A" and by["MX-CISCO-RTR"]["cpu"] == "30%" and by["MX-FORTI-FW"]["cpu"] == "44%")
            check("memory in bytes is not mixed with percentages", by["MX-BYTES-PERCORE"]["mem"] == "N/A" and by["MX-FORTI-FW"]["mem"] == "62%")
            print("### Matrix, one device removed and one added (selection change)")
            await verify(page, net, "matrix -3 +BLK" if bl else "matrix -3", [d for d in mx if d not in mx[:3]] + (bl[:1] if bl else []))
        if BULK and bl:
            for n in (9, 30, 100):
                if len(bl) < n: continue
                sel = bl[:n]
                print(f"### {n} devices selected")
                await verify(page, net, f"{n} devices", sel, shot=f"bulk-{n}")
                if n == 30:
                    print("### 30 devices: selection change, then automatic refresh keeps the order")
                    sel2 = sel[1:] + [bl[40]]
                    await verify(page, net, "30 devices, 1 out / 1 in", sel2)
                    await page.goto(url_for(sel2), wait_until="networkidle"); await page.wait_for_timeout(2000)
                    c0 = net.count; await page.wait_for_timeout(36000)
                    check("auto-refresh (30 s) re-queried Zabbix", net.count > c0, net.count - c0)
                    await page.goto(url_for(sel2, "&viewPanel=panel-10"), wait_until="networkidle"); await page.wait_for_timeout(2500)
                    c1 = net.count; await page.wait_for_timeout(34000)
                    rows = await fleet_rows(page, len(sel2))
                    check("table refreshed itself while open and is still sorted DOWN, UNKNOWN, UP", net.count > c1 and [ORDER[r["status"]] for r in rows] == sorted(ORDER[r["status"]] for r in rows), (net.count - c1, [r["status"] for r in rows][:8]))
        print("### No query error anywhere")
        check("every Zabbix query of every page answered without error", not net.errors, net.errors[:3])
        await b.close()


asyncio.run(main())
print(f"\nCOMMAND CENTER MATRIX/BULK: {sum(RESULTS)} PASS, {len(RESULTS) - sum(RESULTS)} FAIL")
sys.exit(0 if all(RESULTS) else 1)
