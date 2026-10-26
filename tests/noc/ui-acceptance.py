#!/usr/bin/env python3
"""Browser acceptance test of the dynamic NOC dashboards (real Grafana + real Zabbix plugin; Zabbix = tests/noc/zabbix7-api.mjs).

  python3 tests/noc/ui-acceptance.py <grafana-url> <admin-password> <expect.json> [--only-devices]

Everything is done the way an operator does it: log in, open the dashboard, click the Device Type / Device / Interface pickers and
choose options. Every /api/ds/query answer of the page is checked against what the Zabbix data contains (expect.json).
Prints one PASS/FAIL line per check and exits 1 if any check failed. Screenshots go to ./ui-*.png.
"""
import asyncio, json, re, sys
from urllib.parse import unquote
from playwright.async_api import async_playwright

BASE, PW, EXPECT = sys.argv[1].rstrip("/"), sys.argv[2], json.load(open(sys.argv[3]))
VAL = "data-testid Dashboard template variables Variable Value DropDown value link text "
RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append(ok); print(f"  [{'PASS' if ok else 'FAIL'}] {name}{(' - ' + detail) if detail and not ok else ''}", flush=True)


async def login(p):
    b = await p.chromium.launch()
    ctx = await b.new_context(locale="en-US", viewport={"width": 1600, "height": 1300})
    page = await ctx.new_page()
    await page.goto(BASE + "/login", wait_until="networkidle")
    await page.fill("input[name=user]", "admin"); await page.fill("input[name=password]", PW)
    await page.click("button[type=submit]")
    await page.wait_for_url(lambda u: "/login" not in u, timeout=30000); await page.wait_for_load_state("networkidle")
    return b, page


class Queries:
    """Collects every /api/ds/query request+answer of the page, keyed by the item filter (identifies the panel)."""
    def __init__(self, page):
        self.got = {}; page.on("response", lambda r: asyncio.ensure_future(self._on(r)))
    async def _on(self, r):
        if "/api/ds/query" not in r.url: return
        try:
            req = json.loads(r.request.post_data or "{}"); body = await r.json()
        except Exception: return
        for q in req.get("queries", []):
            res = body.get("results", {}).get(q["refId"], {})
            frames = res.get("frames") or []
            nonempty = [f for f in frames if f.get("data", {}).get("values") and any(len(v) for v in f["data"]["values"][1:] or f["data"]["values"])]
            self.got[(q.get("item", {}).get("filter"), q.get("itemTag", {}).get("filter"), q.get("host", {}).get("filter"))] = {
                "status": r.status, "error": res.get("error"), "frames": len(nonempty), "group": q.get("group", {}).get("filter")}
    def clear(self): self.got = {}
    def by_item(self, item_re, host=None):
        return [(k, v) for k, v in self.got.items() if k[0] and re.search(item_re, k[0]) and (host is None or (k[2] or "").replace(chr(92), "") in (f"/^{host}$/", host))]


async def picker(page, label_index):
    # single-value pickers open on their value text; the multi-value Interface picker on its text input (its value area holds "clear")
    sel = f'[data-testid^="{VAL}"][data-testid$="-input"]' if label_index == 2 else f'[data-testid^="{VAL}"]:not([data-testid$="-input"])'
    return page.locator(sel).nth(label_index)


async def choose(page, index, text, settle=2500):
    """Open the picker at position `index` (0 Device Type, 1 Device, 2 Interface) and click the option `text`."""
    await (await picker(page, index)).click(); await page.wait_for_timeout(700)
    await page.get_by_role("option", name=text, exact=True).first.click()
    if index == 2: await page.mouse.click(1200, 140)          # a multi-value choice is applied when the picker closes
    await page.wait_for_load_state("networkidle"); await page.wait_for_timeout(settle)


async def options(page, index):
    await (await picker(page, index)).click(); await page.wait_for_timeout(1200)
    opts = [o.strip() for o in await page.locator("[role=option]").all_inner_texts()]
    await page.keyboard.press("Escape"); await page.wait_for_timeout(300)
    return opts


async def main():
    only_devices = "--only-devices" in sys.argv
    async with async_playwright() as p:
        b, page = await login(p)
        Q = Queries(page)
        await page.goto(BASE + "/d/noc-device-health?orgId=1", wait_until="networkidle"); await page.wait_for_timeout(4000)

        print("### Device Type -> Device list comes from Zabbix host groups")
        for t, want in EXPECT["devices_by_type"].items():
            await choose(page, 0, t)
            got = await options(page, 1)
            check(f"Device Type {t}: devices offered = {sorted(want)}", sorted(got) == sorted(want), f"got {sorted(got)}")
            check(f"Device Type {t}: no non-network host offered", not any(h in got for h in EXPECT["never"]))
        if only_devices:
            await b.close(); return

        print("### Every device: chosen in the UI, every panel answered from Zabbix")
        for t, devs in EXPECT["devices_by_type"].items():
            if t == "All": continue
            for dev in devs:
                await page.goto(BASE + "/d/noc-device-health?orgId=1", wait_until="networkidle"); await page.wait_for_timeout(2500)
                Q.clear(); await choose(page, 0, t)
                if dev != (await (await picker(page, 1)).inner_text()).strip(): await choose(page, 1, dev, settle=4000)
                else: await page.wait_for_timeout(3000)
                d = EXPECT["device"][dev]
                check(f"{dev}: URL follows the UI choice", f"var-device={dev}" in unquote(page.url))
                ifaces = [i for i in await options(page, 2) if i != "All"]
                if len(d["interfaces"]) <= 8:
                    check(f"{dev}: Interface list = the {len(d['interfaces'])} interfaces Zabbix discovered", sorted(ifaces) == sorted(d["interfaces"]), f"got {ifaces}")
                else:   # long lists are rendered lazily: the shown options must be real ones, and the last interface must be findable by typing
                    last = sorted(d["interfaces"])[-1]
                    await (await picker(page, 2)).click(); await page.keyboard.type(last); await page.wait_for_timeout(1000)
                    found = [o.strip() for o in await page.locator("[role=option]").all_inner_texts()]
                    await page.keyboard.press("Escape")
                    check(f"{dev}: Interface list shows Zabbix's interfaces ({len(ifaces)} rendered) and finds '{last}' by typing", set(ifaces) <= set(d["interfaces"]) and last in found, f"rendered {ifaces[:5]}, search {found[:5]}")
                errors = [(k, v) for k, v in Q.got.items() if v["error"] or v["status"] >= 400]
                check(f"{dev}: no query error", not errors, str(errors[:2]))
                for label, item_re, want_frames in [("ICMP ping", r"ICMP ping", d["icmp"]), ("SNMP availability", r"SNMP agent", 1),
                                                    ("CPU", r"utili.*usage.*load", d["cpu"]), ("Memory", r"utili[^|]*\|usage\)/i$", d["mem"]),
                                                    ("Interface status", r"Operational status", len(d["interfaces"])),
                                                    ("Interface traffic", r"Bits \(received", 2 * len(d["interfaces"]))]:
                    hits = Q.by_item(item_re, dev)
                    n = max((v["frames"] for _, v in hits), default=-1)
                    check(f"{dev}: {label} -> {want_frames} series", n == want_frames, f"got {n} ({[k for k, _ in hits][:1]})")
                await page.screenshot(path=f"ui-{dev}.png", full_page=True)

        print("### One interface chosen in the Interface picker")
        dev = EXPECT["single_interface"]["device"]; iface = EXPECT["single_interface"]["interface"]; t = EXPECT["single_interface"]["type"]
        await page.goto(BASE + "/d/noc-device-health?orgId=1", wait_until="networkidle"); await page.wait_for_timeout(2500)
        await choose(page, 0, t)
        if dev != (await (await picker(page, 1)).inner_text()).strip(): await choose(page, 1, dev)
        Q.clear(); await choose(page, 2, iface, settle=4000)
        traffic = Q.by_item(r"Bits \(received")
        check(f"{dev} / {iface}: traffic query asks for that interface only", any(k[1] and iface.replace("/", "\\/") in k[1] and "|" not in k[1] for k, _ in traffic), str([k[1] for k, _ in traffic]))
        check(f"{dev} / {iface}: traffic = 2 series (received, sent)", any(v["frames"] == 2 for _, v in traffic), str([v for _, v in traffic]))
        await page.screenshot(path="ui-single-interface.png", full_page=True)

        print("### NOC — Network Overview: every device of the type")
        for t, n_icmp in EXPECT["overview_icmp_rows"].items():
            Q.clear(); await page.goto(BASE + "/d/noc-wan-overview?orgId=1", wait_until="networkidle"); await page.wait_for_timeout(2500)
            if t != (await (await picker(page, 0)).inner_text()).strip(): Q.clear(); await choose(page, 0, t, settle=4000)
            else: await page.wait_for_timeout(3000)
            icmp = Q.by_item(r"ICMP ping"); cpu = Q.by_item(r"load\)/i")
            check(f"Overview {t}: ICMP table = {n_icmp} devices", any(v["frames"] == n_icmp for _, v in icmp), str([v for _, v in icmp]))
            check(f"Overview {t}: CPU table = {EXPECT['overview_cpu_series'][t]} series", any(v["frames"] == EXPECT["overview_cpu_series"][t] for _, v in cpu), str([v for _, v in cpu]))
            await page.screenshot(path=f"ui-overview-{t}.png", full_page=True)
        await b.close()


asyncio.run(main())
print(f"\nUI ACCEPTANCE: {sum(RESULTS)} PASS, {len(RESULTS) - sum(RESULTS)} FAIL")
sys.exit(0 if all(RESULTS) else 1)
