#!/usr/bin/env python3
"""Generates dashboards/noc/*.json: the NOC dashboards driven only by what Zabbix reports (no host, item, interface or LAB id).

  python3 tools/build-noc-dashboards.py          (re-run after editing this file; the JSON files are committed)

How a device and its data are found (Zabbix 7.0 + Grafana Zabbix plugin 6.x):
  Device Type  custom variable; each option is a regex over Zabbix HOST GROUP names, rendered at deploy time from the settings
               NOC_GROUPS_ROUTER / NOC_GROUPS_SWITCH / NOC_GROUPS_FIREWALL (placeholders @@NOC_*@@ below; see scripts/lib/content.mjs).
  Device       Zabbix "Host" query over the groups of the chosen type -> every host in those groups, refreshed on dashboard load.
  Interface    Zabbix "Item tag" query on the chosen device, tags "interface: <name>" created by interface discovery (LLD) in the
               official Zabbix SNMP templates; display text = the interface name.
  Metrics      selected by item TAG (component: cpu / memory / health / system / network) plus a tolerant item NAME regex,
               never by item key, so Cisco, Juniper, Huawei, FortiGate, Palo Alto ... templates with different keys all match.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DS = {"type": "alexanderzobnin-zabbix-datasource", "uid": "zabbix-lab"}
GROUP = "${devtype:raw}"            # raw: the option value is already a /regex/ and must not be escaped by the plugin


def target(ref, item, item_tag="", host="$device", group=GROUP, value_mapping=False):
    return {
        "refId": ref, "datasource": DS, "queryType": "0",
        "group": {"filter": group}, "host": {"filter": host}, "application": {"filter": ""},
        "itemTag": {"filter": item_tag}, "item": {"filter": item},
        "functions": [], "proxy": {"filter": ""}, "trigger": {"filter": ""}, "tags": {"filter": ""}, "macro": {"filter": ""},
        "options": {"showDisabledItems": False, "skipEmptyValues": False, "disableDataAlignment": False, "useZabbixValueMapping": value_mapping},
        "table": {"skipEmptyValues": False},
    }


_id = [0]


def pid():
    _id[0] += 1
    return _id[0]


def stat(title, targets, x, y, w, h, unit=None, mappings=None, thresholds=None, desc="", decimals=None, no_value="no item"):
    d = {"color": {"mode": "thresholds"}, "noValue": no_value,
         "thresholds": thresholds or {"mode": "absolute", "steps": [{"color": "gray", "value": None}, {"color": "blue", "value": -1e12}]}}
    if unit: d["unit"] = unit
    if mappings: d["mappings"] = mappings
    if decimals is not None: d["decimals"] = decimals
    return {"id": pid(), "type": "stat", "title": title, "description": desc, "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
            "fieldConfig": {"defaults": d, "overrides": []},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "colorMode": "background",
                        "graphMode": "none", "justifyMode": "center", "textMode": "value_and_name", "orientation": "auto", "wideLayout": True},
            "targets": targets}


def series(title, targets, x, y, w, h, unit=None, maxv=None, desc="", overrides=None, calcs=("lastNotNull", "max")):
    d = {"color": {"mode": "palette-classic"}, "custom": {"drawStyle": "line", "fillOpacity": 10, "lineWidth": 2, "showPoints": "never", "spanNulls": True}}
    if unit: d["unit"] = unit
    if maxv is not None: d["min"], d["max"] = 0, maxv
    return {"id": pid(), "type": "timeseries", "title": title, "description": desc, "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
            "fieldConfig": {"defaults": d, "overrides": overrides or []},
            "options": {"legend": {"calcs": list(calcs), "displayMode": "table", "placement": "bottom", "showLegend": True},
                        "tooltip": {"mode": "multi", "sort": "desc"}},
            "targets": targets}


def table(title, targets, x, y, w, h, desc="", unit=None, mappings=None, thresholds=None, value_header="Value", sort_desc=False):
    d = {"color": {"mode": "thresholds"}, "custom": {"align": "auto", "cellOptions": {"type": "color-background" if mappings or thresholds else "auto"}},
         "thresholds": thresholds or {"mode": "absolute", "steps": [{"color": "transparent", "value": None}]}}
    if unit: d["unit"] = unit
    if mappings: d["mappings"] = mappings
    return {"id": pid(), "type": "table", "title": title, "description": desc, "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
            "fieldConfig": {"defaults": d, "overrides": [{"matcher": {"id": "byName", "options": "Field"}, "properties": [{"id": "custom.cellOptions", "value": {"type": "auto"}}, {"id": "displayName", "value": "Device / item"}, {"id": "custom.minWidth", "value": 230}]},
                                              {"matcher": {"id": "byName", "options": value_header}, "properties": [{"id": "custom.width", "value": 120}]}]},
            "options": {"showHeader": True, "cellHeight": "sm", "sortBy": [{"displayName": value_header, "desc": sort_desc}] if sort_desc else []},
            "transformations": [{"id": "reduce", "options": {"reducers": ["lastNotNull"], "mode": "seriesToRows", "includeTimeField": False}},
                                {"id": "organize", "options": {"renameByName": {"Last *": value_header}}}],
            "targets": targets}


def row(title, y):
    return {"id": pid(), "type": "row", "title": title, "collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []}


UPDOWN = [{"type": "value", "options": {"0": {"text": "DOWN", "color": "red", "index": 0}, "1": {"text": "UP", "color": "green", "index": 1}}}]
# zabbix[host,snmp,available] in Zabbix 7.0: 0 = not available, 1 = available, 2 = unknown
SNMPAV = [{"type": "value", "options": {"0": {"text": "NOT AVAILABLE", "color": "red", "index": 0}, "1": {"text": "AVAILABLE", "color": "green", "index": 1}, "2": {"text": "UNKNOWN", "color": "orange", "index": 2}}}]
# IF-MIB ifOperStatus (also used by vendors' own templates); text values are shown as-is when Zabbix value mapping already applied
OPER = [{"type": "value", "options": {"1": {"text": "up", "color": "green", "index": 0}, "2": {"text": "down", "color": "red", "index": 1},
                                       "3": {"text": "testing", "color": "orange", "index": 2}, "4": {"text": "unknown", "color": "orange", "index": 3},
                                       "5": {"text": "dormant", "color": "blue", "index": 4}, "6": {"text": "notPresent", "color": "gray", "index": 5},
                                       "7": {"text": "lowerLayerDown", "color": "red", "index": 6}}},
        {"type": "regex", "options": {"pattern": "/^up/i", "result": {"color": "green", "index": 7}}},
        {"type": "regex", "options": {"pattern": "/^(down|lowerLayerDown)/i", "result": {"color": "red", "index": 8}}}]
# gray first: a panel without data ("no item") is gray, never green; any real value is >= 0
PCT = {"mode": "absolute", "steps": [{"color": "gray", "value": None}, {"color": "green", "value": 0}, {"color": "orange", "value": 70}, {"color": "red", "value": 90}]}

ITEM_CPU = "/(utili[sz]ation|usage|load)/i"
ITEM_MEM = "/(utili[sz]ation|usage)/i"
VAR_DEVTYPE = {
    "name": "devtype", "label": "Device Type", "type": "custom", "hide": 0,
    "query": "All : @@NOCQ_ALL@@,Router : @@NOCQ_ROUTER@@,Switch : @@NOCQ_SWITCH@@,Firewall : @@NOCQ_FIREWALL@@",
    "current": {"selected": True, "text": "All", "value": "@@NOC_ALL@@"},
    "options": [], "multi": False, "includeAll": False, "skipUrlSync": False,
    "description": "Zabbix host groups per device type (regex over group names); set once by 'install.sh --dashboards'",
}
VAR_DEVICE = {
    "name": "device", "label": "Device", "type": "query", "datasource": DS, "hide": 0,
    "query": {"queryType": "host", "group": GROUP, "host": "/.*/", "application": "", "itemTag": "", "item": ""},
    "definition": "Zabbix hosts in the host groups of the selected Device Type",
    "refresh": 1, "sort": 1, "multi": False, "includeAll": False, "current": {}, "options": [], "regex": "", "skipUrlSync": False,
    "description": "Every Zabbix host in the groups of the chosen type; new hosts appear on the next dashboard load",
}
VAR_IFACE = {
    "name": "interface", "label": "Interface", "type": "query", "datasource": DS, "hide": 0,
    "query": {"queryType": "itemTag", "group": GROUP, "host": "$device", "application": "", "itemTag": "/^[Ii]nterface: /", "item": ""},
    "definition": "Zabbix item tags 'interface: <name>' of the selected device (interface discovery)",
    "refresh": 1, "sort": 7, "multi": True, "includeAll": True, "current": {"selected": True, "text": ["All"], "value": ["$__all"]}, "options": [],
    "regex": "/^(?<value>[Ii]nterface: (?<text>.+))$/", "skipUrlSync": False,
    "description": "Interfaces Zabbix discovered on the device (item tag 'interface')",
}


def base(uid, title, desc, variables, panels, tags):
    return {
        "uid": uid, "title": title, "description": desc, "tags": tags, "editable": True, "graphTooltip": 1, "id": None,
        "fiscalYearStartMonth": 0, "liveNow": False, "refresh": "1m", "schemaVersion": 39, "style": "dark", "timezone": "browser", "weekStart": "",
        "time": {"from": "now-6h", "to": "now"}, "timepicker": {"refresh_intervals": ["30s", "1m", "5m", "15m"]},
        "annotations": {"list": []}, "templating": {"list": variables},
        "links": [{"title": "NOC dashboards", "type": "dashboards", "tags": ["noc"], "asDropdown": False, "includeVars": True, "keepTime": True, "icon": "external link"}],
        "panels": panels,
    }


def device_health():
    _id[0] = 0
    P = []
    P.append(row("Availability — $device", 0))
    P.append(stat("Reachability (ICMP)", [target("A", "/^ICMP ping$/")], 0, 1, 4, 4, mappings=UPDOWN,
                  desc="Zabbix item 'ICMP ping' (template ICMP Ping). 'no item' = the device has no ICMP ping item."))
    P.append(stat("SNMP availability", [target("A", "/^SNMP agent availability$/")], 4, 1, 4, 4, mappings=SNMPAV,
                  desc="Zabbix internal item zabbix[host,snmp,available] (official SNMP templates)."))
    P.append(stat("ICMP response time", [target("A", "/^ICMP response time$/")], 8, 1, 4, 4, unit="s", decimals=3))
    P.append(stat("ICMP loss", [target("A", "/^ICMP loss$/")], 12, 1, 4, 4, unit="percent",
                  thresholds={"mode": "absolute", "steps": [{"color": "gray", "value": None}, {"color": "green", "value": 0}, {"color": "orange", "value": 1}, {"color": "red", "value": 20}]}))
    P.append(stat("Uptime", [target("A", "/^(System )?[Uu]ptime/", item_tag="component: system")], 16, 1, 8, 4, unit="s",
                  desc="Items tagged component: system named 'Uptime ...' (network and/or hardware uptime, as the template provides)."))
    P.append(row("CPU and memory — $device", 5))
    P.append(stat("CPU now", [target("A", ITEM_CPU, item_tag="component: cpu")], 0, 6, 6, 8, unit="percent", thresholds=PCT,
                  desc="Items tagged component: cpu whose name says utilization/usage/load (one value per CPU / engine)."))
    P.append(series("CPU utilization", [target("A", ITEM_CPU, item_tag="component: cpu")], 6, 6, 18, 8, unit="percent", maxv=100))
    P.append(stat("Memory now", [target("A", ITEM_MEM, item_tag="component: memory")], 0, 14, 6, 8, unit="percent", thresholds=PCT,
                  desc="Items tagged component: memory whose name says utilization/usage."))
    P.append(series("Memory utilization", [target("A", ITEM_MEM, item_tag="component: memory")], 6, 14, 18, 8, unit="percent", maxv=100))
    P.append(row("Interfaces — $device", 22))
    P.append(table("Interface status", [target("A", "/Operational status$/", item_tag="$interface")], 0, 23, 8, 12, mappings=OPER, value_header="Status",
                   desc="Item 'Operational status' of every selected interface (IF-MIB ifOperStatus), with Zabbix's value mapping."))
    P.append(series("Interface traffic (bits/s)", [target("A", "/Bits (received|sent)$/", item_tag="$interface")], 8, 23, 16, 12, unit="bps",
                    overrides=[{"matcher": {"id": "byRegexp", "options": ".*Bits sent.*"}, "properties": [{"id": "custom.transform", "value": "negative-Y"}]}],
                    desc="Items 'Bits received' (up) and 'Bits sent' (down, negative) of the selected interfaces."))
    P.append(series("Interface errors and discards", [target("A", "/packets (with errors|discarded)$/", item_tag="$interface")], 0, 35, 24, 8, unit="pps"))
    return base("noc-device-health", "NOC — Device Health",
                "Any router, switch or firewall monitored by Zabbix: choose Device Type, Device and Interfaces at the top. Hosts, interfaces and "
                "metrics are read from Zabbix (host groups, interface discovery tags, item tags and names) — nothing is hardcoded.",
                [VAR_DEVTYPE, VAR_DEVICE, VAR_IFACE], P, ["noc", "netops", "device-health"])


def network_overview():
    _id[0] = 0
    P = []
    allh = "/.*/"
    P.append(table("Reachability (ICMP) — every device of the type", [target("A", "/^ICMP ping$/", host=allh)], 0, 0, 8, 14, mappings=UPDOWN,
                   value_header="ICMP", desc="One row per device in the host groups of the selected type."))
    P.append(table("SNMP availability — every device of the type", [target("A", "/^SNMP agent availability$/", host=allh)], 8, 0, 8, 14, mappings=SNMPAV,
                   value_header="SNMP"))
    P.append(table("CPU — highest first", [target("A", ITEM_CPU, item_tag="component: cpu", host=allh)], 16, 0, 8, 14, unit="percent",
                   thresholds=PCT, value_header="CPU %", sort_desc=True))
    P.append(table("Memory — highest first", [target("A", ITEM_MEM, item_tag="component: memory", host=allh)], 0, 14, 8, 12, unit="percent",
                   thresholds=PCT, value_header="Memory %", sort_desc=True))
    P.append(series("ICMP response time — every device of the type", [target("A", "/^ICMP response time$/", host=allh)], 8, 14, 16, 12, unit="s"))
    return base("noc-wan-overview", "NOC — Network Overview",
                "All devices of the selected Device Type (Zabbix host groups) at a glance. Open 'NOC — Device Health' for one device and its interfaces.",
                [VAR_DEVTYPE], P, ["noc", "netops", "overview"])


for d in (device_health(), network_overview()):
    out = ROOT / "dashboards" / "noc" / f"{d['uid']}.json"
    out.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
    print("wrote", out.relative_to(ROOT), len(d["panels"]), "panels")
