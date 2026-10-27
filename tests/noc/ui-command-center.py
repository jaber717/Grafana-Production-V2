#!/usr/bin/env python3
"""Browser acceptance test of "NOC — Command Center" (real Grafana + real Zabbix plugin; Zabbix = tests/noc/zabbix7-api.mjs --fleet).

  python3 tests/noc/ui-command-center.py <grafana-url> <admin-password> tests/noc/command-center-expect.json

An operator's actions in a real browser: open the dashboard, use the Device Type and Devices pickers, reload a bookmarked URL, follow the
drill-down link. Every check compares what the page SHOWS (KPI tiles, fleet table rows, problems list) with what the Zabbix data contains.
Prints one PASS/FAIL line per check; exit 1 if any failed. Screenshots: ./cc-*.png (1920x1080, the wall-display size).
"""
import asyncio, json, re, sys
from urllib.parse import unquote, urlencode
from playwright.async_api import async_playwright

BASE, PW, E = sys.argv[1].rstrip("/"), sys.argv[2], json.load(open(sys.argv[3]))
VAL = "data-testid Dashboard template variables Variable Value DropDown value link text "
DASH = "/d/noc-command-center"
FLEET, PROBLEMS = "Fleet health — selected devices", "Active problems — selected devices"
KPIS = ["Selected devices", "UP", "DOWN", "UNKNOWN", "High / Disaster problems"]
ALL = sorted(sum(E["types"].values(), []))
TYPE_OF = {h: t for t, hs in E["types"].items() for h in hs}
RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append(bool(ok)); print(f"  [{'PASS' if ok else 'FAIL'}] {name}{(' - ' + str(detail)) if detail and not ok else ''}", flush=True)


def expected(devs):
    st = {d: E["status"].get(d, "UP") for d in devs}
    return {"rows": sorted(devs), "status": st,
            "kpi": {"Selected devices": len(devs), "UP": sum(v == "UP" for v in st.values()), "DOWN": sum(v == "DOWN" for v in st.values()),
                    "UNKNOWN": sum(v == "UNKNOWN" for v in st.values()), "High / Disaster problems": sum(E["high_disaster"].get(d, 0) for d in devs)},
            "problems": sum(E["problems"].get(d, 0) for d in devs)}


class Net:
    """Every data request of the page: /api/ds/query (metrics) and the Zabbix plugin's API resource calls (problems)."""
    def __init__(self, page):
        self.errors, self.count = [], 0
        page.on("response", lambda r: asyncio.ensure_future(self._on(r)))
    async def _on(self, r):
        if "/api/ds/query" not in r.url and "/resources/zabbix-api" not in r.url: return
        self.count += 1
        try: body = await r.json()
        except Exception: body = {}
        errs = [v.get("error") for v in (body.get("results") or {}).values() if v.get("error")] if isinstance(body, dict) else []
        if r.status >= 400 or errs or (isinstance(body, dict) and body.get("error")): self.errors.append((r.status, r.url[-60:], errs or body.get("error") or body))


async def settle(page, ms=3500):
    await page.wait_for_load_state("networkidle"); await page.wait_for_timeout(ms)


async def kpis(page):
    out = {}
    for t in KPIS:
        txt = (await page.locator(f'[data-testid="data-testid Panel header {t}"]').inner_text()).strip().splitlines()
        out[t] = int(txt[-1]) if txt[-1].strip().isdigit() else txt[-1]
    return out


async def rows(page):
    """Fleet table rows as rendered (only the rows the table has drawn, i.e. the visible ones plus a small overscan)."""
    panel = page.locator(f'[data-testid="data-testid Panel header {FLEET}"]')
    out = []
    for r in (await panel.locator("[role=row]").all_inner_texts())[1:]:
        c = [x.strip() for x in r.split("\n")]
        out.append({"device": c[0], "type": c[1], "status": c[2], "cpu": c[3], "mem": c[4]})
    return out


async def all_rows(page):
    """Every row: the fleet table alone in view mode on a tall page (no virtualisation cut-off)."""
    url = page.url
    await page.set_viewport_size({"width": 1920, "height": 2600})
    await page.goto(url + ("&" if "?" in url else "?") + "viewPanel=panel-10", wait_until="networkidle"); await page.wait_for_timeout(4000)
    r = await rows(page)
    await page.set_viewport_size({"width": 1920, "height": 1080})
    await page.goto(url, wait_until="networkidle"); await settle(page, 2500)
    return r


async def problem_rows(page):
    texts = await page.locator(f'[data-testid="data-testid Panel header {PROBLEMS}"] tbody tr').all_inner_texts()
    return len([t for t in texts if "No problems found" not in t])


async def device_picker_input(page):
    return page.locator(f'[data-testid^="{VAL}"][data-testid$="-input"]').nth(1)


async def choose_type(page, t):
    await page.locator(f'[data-testid^="{VAL}"]:not([data-testid$="-input"])').nth(0).click(); await page.wait_for_timeout(700)
    await page.get_by_role("option", name=t, exact=True).first.click(); await settle(page)


async def device_options(page):
    await (await device_picker_input(page)).click(); await page.wait_for_timeout(1200)
    opts = [o.strip() for o in await page.locator("[role=option]").all_inner_texts()]
    await page.keyboard.press("Escape"); await page.wait_for_timeout(300)
    return opts


async def toggle_devices(page, names):
    """Open the Devices picker, type each name and click its option (toggles it), then close the picker (applies the selection)."""
    inp = await device_picker_input(page)
    await inp.click(); await page.wait_for_timeout(700)
    for n in names:
        await inp.fill(n); await page.wait_for_timeout(500)
        await page.get_by_role("option", name=n, exact=True).click(); await page.wait_for_timeout(300)
    await page.mouse.click(1000, 30); await settle(page)


def url_devices(url):
    return sorted(unquote(v) for v in re.findall(r"[?&]var-device=([^&]*)", url))


async def verify(page, label, devs, shot=None, full=True):
    want = expected(devs)
    k = await kpis(page)
    check(f"{label}: KPI tiles {want['kpi']}", k == want["kpi"], f"got {k}")
    n = await problem_rows(page)
    check(f"{label}: problems list = {want['problems']} problems of the selected devices", n == want["problems"], f"got {n}")
    if shot: await page.screenshot(path=f"cc-{shot}.png")
    r = await (all_rows(page) if full else rows(page))
    got = sorted(x["device"] for x in r)
    check(f"{label}: fleet table = the {len(devs)} selected devices", got == want["rows"], f"got {got}")
    check(f"{label}: no non-network / unmapped host", not set(got) & set(E["never"]))
    check(f"{label}: Status per device (UP / DOWN / UNKNOWN)", all(x["status"] == want["status"].get(x["device"]) for x in r),
          [(x["device"], x["status"]) for x in r if x["status"] != want["status"].get(x["device"])])
    order = {"DOWN": 0, "UNKNOWN": 1, "UP": 2}
    check(f"{label}: DOWN first, then UNKNOWN, then UP", [order[x["status"]] for x in r] == sorted(order[x["status"]] for x in r), [x["status"] for x in r])
    check(f"{label}: Type per device", all(x["type"] == TYPE_OF[x["device"]] for x in r), [(x["device"], x["type"]) for x in r if x["type"] != TYPE_OF.get(x["device"])])
    miss = [x for x in r if x["device"] in E["no_cpu_mem"]]
    check(f"{label}: missing CPU/Memory shown as N/A (never 0)", all(x["cpu"] == "N/A" and x["mem"] == "N/A" for x in miss), miss)
    check(f"{label}: devices with CPU/Memory items show a percentage", all(re.fullmatch(r"\d+%", x["cpu"]) and re.fullmatch(r"\d+%", x["mem"]) for x in r if x["device"] not in E["no_cpu_mem"]),
          [x for x in r if x["device"] not in E["no_cpu_mem"] and not re.fullmatch(r"\d+%", x["cpu"])][:3])
    return r


async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch()
        ctx = await b.new_context(locale="en-US", viewport={"width": 1920, "height": 1080})
        page = await ctx.new_page()
        await page.goto(BASE + "/login", wait_until="networkidle")
        await page.fill("input[name=user]", "admin"); await page.fill("input[name=password]", PW); await page.click("button[type=submit]")
        await page.wait_for_url(lambda u: "/login" not in u, timeout=30000)
        net = Net(page)

        print("### Default view: Device Type All, Devices All")
        await page.goto(BASE + DASH + "?orgId=1", wait_until="networkidle"); await settle(page, 5000)
        await verify(page, "All / All", ALL, shot="all")
        check("All / All: agent-monitored firewall is UP", any(x["device"] == E["agent_monitored"] and x["status"] == "UP" for x in await all_rows(page)))

        print("### Device Type filter (host groups)")
        for t, devs in E["types"].items():
            await page.goto(BASE + DASH + "?orgId=1", wait_until="networkidle"); await settle(page)
            await choose_type(page, t)
            opts = [o for o in await device_options(page) if o != "All"]
            check(f"Type {t}: Devices picker offers exactly the {len(devs)} hosts of the type", sorted(opts) == sorted(devs), f"got {opts}")
            await verify(page, f"Type {t}", devs, shot=f"type-{t.lower()}")

        print("### 1 device chosen in the picker")
        await page.goto(BASE + DASH + "?orgId=1", wait_until="networkidle"); await settle(page)
        one = E["one"]
        await toggle_devices(page, [one])
        check("1 device: URL holds the selection", url_devices(page.url) == [one], page.url)
        await verify(page, "1 device", [one], shot="one")

        print("### 9 mixed devices chosen in the picker")
        await page.goto(BASE + DASH + "?orgId=1", wait_until="networkidle"); await settle(page)
        nine = E["nine"]
        await toggle_devices(page, nine)
        check("9 devices: URL holds the 9 selected devices", url_devices(page.url) == sorted(nine), url_devices(page.url))
        r = await rows(page)
        check("9 devices: all 9 rows shown at once on a 1920x1080 screen (no scrolling)", sorted(x["device"] for x in r) == sorted(nine), [x["device"] for x in r])
        grid = await page.locator(f'[data-testid="data-testid Panel header {FLEET}"]').bounding_box()
        boxes = [await e.bounding_box() for e in await page.locator(f'[data-testid="data-testid Panel header {FLEET}"] [role=gridcell][aria-colindex="1"]').all()]
        check(f"9 devices: every row inside the visible table area ({len(boxes)} rows drawn)", len(boxes) == 9 and all(bb["y"] >= grid["y"] - 1 and bb["y"] + bb["height"] <= grid["y"] + grid["height"] + 1 for bb in boxes), (grid, boxes[-1]))
        check("9 devices: mixes routers, switches and firewalls", {TYPE_OF[x["device"]] for x in r} == {"Router", "Switch", "Firewall"})
        await verify(page, "9 devices", nine, shot="nine", full=False)

        print("### Changing the selection: one device removed, another added")
        await toggle_devices(page, [nine[0]])
        eight = sorted(nine[1:])
        check("remove 1: URL now holds 8 devices", url_devices(page.url) == eight, url_devices(page.url))
        await verify(page, "8 devices", eight, full=False)
        await toggle_devices(page, ["JED-FW-03"])
        nine2 = sorted(eight + ["JED-FW-03"])
        await verify(page, "8 devices + JED-FW-03", nine2, full=False)

        print("### Bookmark: the URL alone restores the selection")
        bookmark = page.url
        await page.goto(BASE + "/d/noc-wan-overview?orgId=1", wait_until="networkidle"); await settle(page, 1500)
        await page.goto(bookmark, wait_until="networkidle"); await settle(page)
        check("bookmark: same devices selected after reopening", url_devices(page.url) == nine2, url_devices(page.url))
        await verify(page, "bookmark", nine2, full=False)

        print("### 20+ devices selected one by one (URL with every device)")
        q = urlencode([("orgId", "1")] + [("var-device", d) for d in ALL])
        await page.goto(BASE + DASH + "?" + q, wait_until="networkidle"); await settle(page, 5000)
        r = await verify(page, f"{len(ALL)} devices", ALL, shot="twentytwo")
        vis = await rows(page)
        check(f"{len(ALL)} devices: table scrolls (not all rows drawn at once on the wallboard)", 0 < len(vis) < len(ALL), len(vis))
        await page.locator(f'[data-testid="data-testid Panel header {FLEET}"] [role=row]').nth(2).hover()
        for _ in range(12): await page.mouse.wheel(0, 400); await page.wait_for_timeout(250)
        await page.wait_for_timeout(800)
        last = (await rows(page))[-1]["device"]
        check(f"{len(ALL)} devices: scrolling reaches the last device ({r[-1]['device']})", last == r[-1]["device"], last)
        hdr = await page.locator(f'[data-testid="data-testid Panel header {FLEET}"] [role=columnheader]').all_inner_texts()
        check("fleet table columns: Device, Type, Status, CPU, Memory", [h.strip() for h in hdr] == ["Device", "Type", "Status", "CPU", "Memory"], hdr)

        print("### Refresh")
        await page.goto(BASE + DASH + "?orgId=1", wait_until="networkidle"); await settle(page, 2000)
        c0 = net.count; await page.wait_for_timeout(36000)
        check("auto-refresh (30s default) re-queried Zabbix", net.count > c0, net.count - c0)
        c1 = net.count
        await page.get_by_role("button", name=re.compile(r"^Refresh")).first.click(); await settle(page, 2500)
        check("Refresh button re-queries Zabbix", net.count > c1)
        await verify(page, "after refresh", ALL)

        print("### Drill-down to NOC — Device Health")
        await page.goto(BASE + DASH + "?orgId=1", wait_until="networkidle"); await settle(page)
        target = "JED-RTR-04"
        link = page.locator(f'[data-testid="data-testid Panel header {FLEET}"] a', has_text=target).first
        href = await link.get_attribute("href")
        await link.click(); await settle(page, 5000)
        check(f"drill-down: '{target}' opens NOC — Device Health for that device", "/d/noc-device-health" in page.url and url_devices(page.url) == [target], page.url)
        shown = (await page.locator(f'[data-testid^="{VAL}"]:not([data-testid$="-input"])').nth(1).inner_text()).strip()
        check("drill-down: Device Health's Device picker shows it", shown == target, shown)
        await page.screenshot(path="cc-drilldown.png")

        print("### No query error anywhere")
        check("every Zabbix query of every page answered without error", not net.errors, net.errors[:3])
        await b.close()


asyncio.run(main())
print(f"\nCOMMAND CENTER UI ACCEPTANCE: {sum(RESULTS)} PASS, {len(RESULTS) - sum(RESULTS)} FAIL")
sys.exit(0 if all(RESULTS) else 1)
