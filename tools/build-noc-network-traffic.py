#!/usr/bin/env python3
"""Generates dashboards/noc/noc-network-traffic.json: "NOC — Network Traffic", interface traffic for any set of devices and interfaces.

  python3 tools/build-noc-network-traffic.py      (re-run after editing this file; the JSON file is committed)

Independent of the other NOC generators (they are not regenerated or changed by this file). It re-uses the patterns that are proven in
this repository:
  * variables  Device Type (custom, regexes over Zabbix HOST GROUP names, rendered at deploy time from NOC_GROUPS_*), Devices (Zabbix
               "Host" query, multi-select + All, as in NOC — Command Center) and Interfaces (Zabbix "Item tag" query over the SELECTED
               devices: the tags `interface: <name>` created by interface discovery in the official SNMP templates, as in NOC — Device
               Health, here multi-device). Nothing names a device, interface, item id or vendor.
  * metrics    Zabbix items of the official "Network interfaces by SNMP" convention (Cisco, Huawei, Fortinet, Palo Alto, Juniper, ...):
                 "Interface <name>(<alias>): Bits received | Bits sent | Speed | Operational status |
                  Inbound/Outbound packets with errors | Inbound/Outbound packets discarded"
               selected by NAME (never by key) and by the interface tag chosen in the Interfaces variable.
  * table      the alias trick of NOC — Command Center (docs/NOC-COMMAND-CENTER.md): every query renames its series, with the plugin's
               setAlias, to  ROLE<SEP><host> · <item name>  ; the transformations split that text back into role + "device · interface".
               This does not depend on the series sharing timestamps (real Zabbix items never do; that was the 2.4.0 defect).

Units and signs
  Traffic items are in bit/s (Zabbix unit "bps", per-second change already applied by the template). removeBelowValue(0) drops a negative
  value (a counter reset) so inbound and outbound stay positive; both directions are drawn upwards in separate graphs.
  Totals: groupBy(1m, avg) puts every series on a common 1-minute grid, then sumSeries() adds them.
N/A (never 0) for a metric that is not available
  Table: a missing cell is null; the Rx / Tx values are queried shifted by +1 bit/s and un-shifted in the table (-1 = missing -> "N/A");
  utilization = (Rx+1)*Speed / Speed^2: Speed missing or 0 -> 0/0 = NaN, Rx missing -> exactly 0 -> both mapped to "N/A" (Grafana's
  binary calculation treats a missing value as 0, so the shift is what keeps "missing" apart from "0 traffic").
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DS = {"type": "alexanderzobnin-zabbix-datasource", "uid": "zabbix-lab"}     # retargeted to the adopted data source at deploy time
DASH_DS = {"type": "datasource", "uid": "-- Dashboard --"}
GROUP = "${devtype:raw}"      # raw: the option value is already a /regex/ and must not be escaped by the plugin
DEVICES = "$device"
IFACE = "$interface"          # item tag filter: "interface: <name>" values chosen in the Interfaces variable
WINDOW = "15m"                # the detailed table's "now": the last sample inside this window counts (Speed items are polled slowly)
SEP = "␟"                # separates ROLE from "host · item name" inside the series alias
TABLE_ID = 20
TOP_N = 10

FN_DEF = {
    "scale": {"name": "scale", "category": "Transform", "params": [{"name": "factor", "type": "float", "options": [100, 0.01, 10, -1]}], "defaultParams": [100]},
    "offset": {"name": "offset", "category": "Transform", "params": [{"name": "delta", "type": "float", "options": [-100, 100]}], "defaultParams": [100]},
    "removeBelowValue": {"name": "removeBelowValue", "category": "Filter", "params": [{"name": "number", "type": "float"}], "defaultParams": [0]},
    "top": {"name": "top", "category": "Filter", "params": [{"name": "number", "type": "int"}, {"name": "value", "type": "string", "options": ["avg", "min", "max", "sum", "count", "median", "first", "last"]}], "defaultParams": [5, "avg"]},
    "groupBy": {"name": "groupBy", "category": "Transform", "params": [{"name": "interval", "type": "string"}, {"name": "function", "type": "string", "options": ["avg", "min", "max", "sum", "count", "median", "first", "last"]}], "defaultParams": ["1m", "avg"]},
    "sumSeries": {"name": "sumSeries", "category": "Aggregate", "params": [], "defaultParams": []},
    "setAlias": {"name": "setAlias", "category": "Alias", "params": [{"name": "alias", "type": "string"}], "defaultParams": []},
}


def fn(name, *params):
    return {"def": FN_DEF[name], "params": [str(p) for p in params], "text": f"{name}({', '.join(str(p) for p in params)})", "added": False}


def target(ref, item, item_tag=IFACE, host=DEVICES, group=GROUP, functions=(), align=False):
    return {
        "refId": ref, "datasource": DS, "queryType": "0",
        "group": {"filter": group}, "host": {"filter": host}, "application": {"filter": ""},
        "itemTag": {"filter": item_tag}, "item": {"filter": item},
        "functions": list(functions), "proxy": {"filter": ""}, "trigger": {"filter": ""}, "tags": {"filter": ""}, "macro": {"filter": ""},
        "options": {"showDisabledItems": False, "skipEmptyValues": False, "disableDataAlignment": not align, "useZabbixValueMapping": False},
        "table": {"skipEmptyValues": False},
    }


_id = [0]


def pid():
    _id[0] += 1
    return _id[0]


UP, DOWN, UNKNOWN, NEUTRAL = "green", "red", "#8e8e8e", "text"
NA = {"type": "special", "options": {"match": "null+nan", "result": {"text": "N/A", "color": UNKNOWN, "index": 90}}}
# IF-MIB ifOperStatus as Zabbix stores it
OPER = [{"type": "value", "options": {"1": {"text": "UP", "color": UP, "index": 0}, "2": {"text": "DOWN", "color": DOWN, "index": 1},
                                       "3": {"text": "testing", "color": "orange", "index": 2}, "4": {"text": "unknown", "color": UNKNOWN, "index": 3},
                                       "5": {"text": "dormant", "color": "blue", "index": 4}, "6": {"text": "not present", "color": UNKNOWN, "index": 5},
                                       "7": {"text": "lower layer down", "color": DOWN, "index": 6}}}, NA]
UTIL = {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 0.7}, {"color": "red", "value": 0.9}]}
ALERT = {"mode": "absolute", "steps": [{"color": "transparent", "value": None}, {"color": "red", "value": 1}]}
ALIAS_DI = "$__zbx_host_name · $__zbx_item_name"       # "device · Interface Gi0/1(WAN): Bits received"


def alias(role):
    return role + SEP + ALIAS_DI


def graph(title, targets, x, y, w, h, desc, unit="bps", stack=False):
    return {
        "id": pid(), "type": "timeseries", "title": title, "description": desc, "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": targets,
        "fieldConfig": {"defaults": {"unit": unit, "min": 0, "decimals": 2, "noValue": "N/A", "color": {"mode": "palette-classic"},
                                     "custom": {"drawStyle": "line", "lineWidth": 1, "fillOpacity": 12 if not stack else 25, "showPoints": "never", "spanNulls": True,
                                                "stacking": {"mode": "normal" if stack else "none", "group": "A"}}}, "overrides": []},
        "options": {"legend": {"displayMode": "table", "placement": "right", "showLegend": True, "calcs": ["lastNotNull", "max"], "sortBy": "Last *", "sortDesc": True, "width": 360},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
    }


def total_stat(title, ref, item, label, x, y, w, h, desc):
    t = target(ref, item, functions=[fn("removeBelowValue", 0), fn("groupBy", "1m", "avg"), fn("sumSeries"), fn("setAlias", label)], align=True)
    return {
        "id": pid(), "type": "stat", "title": title, "description": desc, "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [t],
        "fieldConfig": {"defaults": {"unit": "bps", "decimals": 2, "noValue": "N/A", "color": {"mode": "fixed", "fixedColor": "blue"},
                                     "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": None}]}}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "colorMode": "value", "graphMode": "area",
                    "justifyMode": "center", "textMode": "value", "orientation": "auto", "wideLayout": True, "showPercentChange": False},
    }


def kpi(title, x, y, w, h, color, transformations, desc, field="/^Interface$/"):
    return {
        "id": pid(), "type": "stat", "title": title, "description": desc, "datasource": DASH_DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [{"refId": "A", "datasource": DASH_DS, "panelId": TABLE_ID, "withTransforms": True}],
        "transformations": transformations,
        "fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": color} if isinstance(color, str) else {"mode": "thresholds"},
                                     "thresholds": color if isinstance(color, dict) else {"mode": "absolute", "steps": [{"color": "text", "value": None}]},
                                     "decimals": 0, "noValue": "—", "unit": "none"}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["count"], "fields": field, "values": False}, "colorMode": "background" if isinstance(color, dict) else "value",
                    "graphMode": "none", "justifyMode": "center", "textMode": "value", "orientation": "auto", "wideLayout": True, "showPercentChange": False},
    }


def status_filter(values):
    return [{"id": "filterByValue", "options": {"type": "include", "match": "any",
                                                "filters": [{"fieldName": "Status", "config": {"id": "equal", "options": {"value": v}}} for v in values]}}]


def bar_from_table(title, field, x, y, w, h, desc):
    """Top N interfaces by a utilization column of the detailed table (Dashboard data source: no extra Zabbix query)."""
    return {
        "id": pid(), "type": "bargauge", "title": title, "description": desc, "datasource": DASH_DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [{"refId": "A", "datasource": DASH_DS, "panelId": TABLE_ID, "withTransforms": True}],
        "transformations": [
            # only interfaces that have a utilization (N/A = 0 or NaN is not a utilization)
            {"id": "filterByValue", "options": {"type": "include", "match": "all", "filters": [{"fieldName": field, "config": {"id": "greater", "options": {"value": 0}}}]}},
            {"id": "sortBy", "options": {"sort": [{"field": field, "desc": True}]}},
            {"id": "limit", "options": {"limitField": TOP_N}},
            {"id": "organize", "options": {"excludeByName": {c: True for c in ["Device", "Interface", "Status", "Speed", "Rx", "Tx", "Utilization in", "Utilization out"] if c != field},
                                           "indexByName": {"key\\role": 0, field: 1}, "renameByName": {"key\\role": "Interface"}}},
        ],
        "fieldConfig": {"defaults": {"unit": "percentunit", "min": 0, "max": 1, "decimals": 1, "noValue": "N/A", "color": {"mode": "thresholds"}, "thresholds": UTIL}, "overrides": []},
        "options": {"reduceOptions": {"calcs": [], "fields": f"/^{field}$/", "values": True}, "displayMode": "gradient", "orientation": "horizontal",
                    "valueMode": "color", "showUnfilled": True, "namePlacement": "left", "minVizHeight": 16, "minVizWidth": 8, "sizing": "auto", "legend": False},
    }


def bar_busiest(title, x, y, w, h, desc):
    return {
        "id": pid(), "type": "bargauge", "title": title, "description": desc, "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [target("A", "/Bits (received|sent)$/", functions=[fn("removeBelowValue", 0), fn("top", TOP_N, "avg")])],
        "fieldConfig": {"defaults": {"unit": "bps", "min": 0, "decimals": 2, "noValue": "N/A", "color": {"mode": "continuous-BlPu"}}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "displayMode": "gradient", "orientation": "horizontal",
                    "valueMode": "color", "showUnfilled": True, "namePlacement": "left", "minVizHeight": 16, "minVizWidth": 8, "sizing": "auto", "legend": False},
    }


def calc_binary(alias_name, left, op, right):
    return {"id": "calculateField", "options": {"mode": "binary", "alias": alias_name, "replaceFields": False,
                                                 "binary": {"left": {"matcher": {"id": "byName", "options": left}}, "operator": op,
                                                            "right": {"matcher": {"id": "byName", "options": right}} if not right.startswith("#") else {"fixed": right[1:]}}}}


def detail_table(x, y, w, h):
    T = [
        target("RX", "/Bits received$/", functions=[fn("removeBelowValue", 0), fn("offset", 1), fn("setAlias", alias("RX"))]),
        target("TX", "/Bits sent$/", functions=[fn("removeBelowValue", 0), fn("offset", 1), fn("setAlias", alias("TX"))]),
        target("SPD", "/: Speed$/", functions=[fn("setAlias", alias("SPD"))]),
        target("ST", "/Operational status$/", functions=[fn("setAlias", alias("ST"))]),
    ]
    bps = lambda name, width: {"matcher": {"id": "byName", "options": name}, "properties": [
        {"id": "unit", "value": "bps"}, {"id": "decimals", "value": 2}, {"id": "mappings", "value": [{"type": "value", "options": {"-1": {"text": "N/A", "color": UNKNOWN, "index": 0}}}, NA]},
        {"id": "custom.width", "value": width}, {"id": "custom.align", "value": "right"}]}
    util = lambda name: {"matcher": {"id": "byName", "options": name}, "properties": [
        {"id": "unit", "value": "percentunit"}, {"id": "decimals", "value": 1}, {"id": "thresholds", "value": UTIL},
        {"id": "mappings", "value": [{"type": "value", "options": {"0": {"text": "N/A", "color": UNKNOWN, "index": 0}}}, NA]},
        {"id": "custom.cellOptions", "value": {"type": "color-text"}}, {"id": "custom.width", "value": 130}, {"id": "custom.align", "value": "center"}]}
    return {
        "id": TABLE_ID, "type": "table", "title": "Interfaces — detail", "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "description": ("One row per selected interface (Device Type / Devices / Interfaces above), busiest inbound first. Speed = item 'Speed' (bit/s); "
                        "Rx / Tx = latest inbound / outbound bit/s (negative counter resets dropped); Utilization = Rx or Tx divided by Speed. "
                        "Anything not available is N/A, never 0 (Speed items polled less often than every " + WINDOW + " give N/A utilization). "
                        "Click a device to open NOC — Device Health."),
        "timeFrom": WINDOW, "hideTimeOverride": True, "targets": T,
        "transformations": [
            # 1 one row per series: Field = alias, Last * = latest sample of the window
            {"id": "reduce", "options": {"mode": "seriesToRows", "reducers": ["lastNotNull"], "labelsToFields": False, "includeTimeField": False}},
            # 2 split: role, key = "device · Interface name" (the item name without its trailing ": <metric>")
            {"id": "extractFields", "options": {"source": "Field", "format": "regexp", "regExp": "/^(?<role>[^" + SEP + "]*)" + SEP + "(?<key>.*?)(?:: [^:]*)$/", "replace": False, "keepTime": False}},
            {"id": "groupBy", "options": {"fields": {"key": {"operation": "groupby", "aggregations": []}, "role": {"operation": "groupby", "aggregations": []},
                                                     "Last *": {"operation": "aggregate", "aggregations": ["max"]}}}},
            # 3 interfaces as rows, roles as columns (RX TX SPD ST); a role without a sample stays null
            {"id": "groupingToMatrix", "options": {"columnField": "role", "rowField": "key", "valueField": "Last * (max)", "emptyValue": "null"}},
            # 4 device and interface names for display and drill-down
            {"id": "extractFields", "options": {"source": "key\\role", "format": "regexp", "regExp": "/^(?<Device>.*?) · (?:Interface )?(?<Interface>.*)$/", "replace": False, "keepTime": False}},
            # 5 un-shift Rx / Tx (missing -> -1 -> N/A)
            calc_binary("Rx", "RX", "-", "#1"), calc_binary("Tx", "TX", "-", "#1"),
            # 6 utilization = (rx+1)*speed / speed^2  (speed missing -> 0/0 = NaN, rx missing -> 0: both N/A)
            calc_binary("SPD2", "SPD", "*", "SPD"), calc_binary("NI", "RX", "*", "SPD"), calc_binary("NO", "TX", "*", "SPD"),
            calc_binary("Utilization in", "NI", "/", "SPD2"), calc_binary("Utilization out", "NO", "/", "SPD2"),
            {"id": "sortBy", "options": {"sort": [{"field": "Rx", "desc": True}]}},
            {"id": "organize", "options": {"excludeByName": {c: True for c in ["RX", "TX", "SPD2", "NI", "NO"]},
                                           "indexByName": {"Device": 0, "Interface": 1, "ST": 2, "SPD": 3, "Rx": 4, "Tx": 5, "Utilization in": 6, "Utilization out": 7, "key\\role": 8},
                                           "renameByName": {"ST": "Status", "SPD": "Speed"}}},
        ],
        "fieldConfig": {
            "defaults": {"custom": {"align": "left", "cellOptions": {"type": "auto"}, "inspect": False, "filterable": True},
                         "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": NEUTRAL, "value": None}]}},
            "overrides": [
                {"matcher": {"id": "byName", "options": "Device"}, "properties": [
                    {"id": "custom.minWidth", "value": 160},
                    {"id": "links", "value": [{"title": "Open ${__value.raw} in NOC — Device Health", "url": "/d/noc-device-health/noc-device-health?orgId=1&${devtype:queryparam}&var-device=${__value.raw:percentencode}&var-interface=$__all"}]}]},
                {"matcher": {"id": "byName", "options": "key\\role"}, "properties": [{"id": "custom.hidden", "value": True}]},
                {"matcher": {"id": "byName", "options": "Status"}, "properties": [
                    {"id": "mappings", "value": OPER}, {"id": "custom.cellOptions", "value": {"type": "color-background", "mode": "basic"}},
                    {"id": "custom.width", "value": 150}, {"id": "custom.align", "value": "center"}]},
                {"matcher": {"id": "byName", "options": "Speed"}, "properties": [
                    {"id": "unit", "value": "bps"}, {"id": "decimals", "value": 0}, {"id": "mappings", "value": [{"type": "value", "options": {"0": {"text": "N/A", "color": UNKNOWN, "index": 0}}}, NA]},
                    {"id": "custom.width", "value": 120}, {"id": "custom.align", "value": "right"}]},
                bps("Rx", 130), bps("Tx", 130), util("Utilization in"), util("Utilization out"),
            ]},
        "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False, "reducer": ["sum"], "fields": ""}, "sortBy": []},
    }


def network_traffic():
    _id[0] = 0
    P = []
    BITS_IN, BITS_OUT = "/Bits received$/", "/Bits sent$/"
    # --- row 1: totals + interface counts (from the detail table) ---
    P.append(total_stat("Total inbound", "A", BITS_IN, "Inbound", 0, 0, 6, 4, "Sum of the inbound traffic (Bits received) of the selected interfaces, latest value with a 1-minute trend. N/A = no data."))
    P.append(total_stat("Total outbound", "A", BITS_OUT, "Outbound", 6, 0, 6, 4, "Sum of the outbound traffic (Bits sent) of the selected interfaces, latest value with a 1-minute trend. N/A = no data."))
    P.append(kpi("Interfaces", 12, 0, 4, 4, NEUTRAL, [], "Interfaces in the detail table (the current Device / Interface selection)."))
    P.append(kpi("Interfaces UP", 16, 0, 4, 4, UP, status_filter([1]), "Selected interfaces whose operational status (ifOperStatus) is up."))
    P.append(kpi("Interfaces DOWN", 20, 0, 4, 4, ALERT, status_filter([2, 7]), "Selected interfaces whose operational status is down or lowerLayerDown. Unused access ports are down by design: choose the interfaces you care about."))
    # --- row 2: totals graph + busiest ---
    P.append(graph("Total traffic — inbound and outbound", [
        target("A", BITS_IN, functions=[fn("removeBelowValue", 0), fn("groupBy", "1m", "avg"), fn("sumSeries"), fn("setAlias", "Inbound")], align=True),
        target("B", BITS_OUT, functions=[fn("removeBelowValue", 0), fn("groupBy", "1m", "avg"), fn("sumSeries"), fn("setAlias", "Outbound")], align=True)],
        0, 4, 12, 9, "Sum of all selected interfaces, inbound and outbound, both positive. Native Grafana time range."))
    P.append(bar_busiest(f"Top {TOP_N} busiest interface directions", 12, 4, 12, 9,
                         f"The {TOP_N} highest series (average over the time range) among the selected interfaces' inbound (Bits received) and outbound (Bits sent) items."))
    # --- row 3: utilization ---
    P.append(bar_from_table(f"Top {TOP_N} utilization — inbound", "Utilization in", 0, 13, 12, 8, "Inbound bit/s divided by the interface Speed item. Interfaces without a Speed or a sample are left out (see the detail table: N/A)."))
    P.append(bar_from_table(f"Top {TOP_N} utilization — outbound", "Utilization out", 12, 13, 12, 8, "Outbound bit/s divided by the interface Speed item. Interfaces without a Speed or a sample are left out (see the detail table: N/A)."))
    # --- row 4: per-interface graphs ---
    P.append(graph(f"Inbound by interface — top {TOP_N}", [target("A", BITS_IN, functions=[fn("removeBelowValue", 0), fn("top", TOP_N, "avg")])], 0, 21, 12, 9,
                   f"Bits received of the {TOP_N} busiest selected interfaces (average over the time range). Legend sorted by current value."))
    P.append(graph(f"Outbound by interface — top {TOP_N}", [target("A", BITS_OUT, functions=[fn("removeBelowValue", 0), fn("top", TOP_N, "avg")])], 12, 21, 12, 9,
                   f"Bits sent of the {TOP_N} busiest selected interfaces (average over the time range). Legend sorted by current value."))
    # --- row 5: errors / discards + DOWN interfaces ---
    P.append(graph(f"Errors and discards — top {TOP_N}", [target("A", "/packets (with errors|discarded)$/", functions=[fn("removeBelowValue", 0), fn("top", TOP_N, "max")])], 0, 30, 12, 8,
                   f"Inbound/outbound packets with errors and discarded packets (packets per second) of the {TOP_N} worst selected interfaces (peak in the time range).", unit="pps"))
    P.append({
        "id": pid(), "type": "table", "title": "Interfaces DOWN — selected", "datasource": DASH_DS, "gridPos": {"h": 8, "w": 12, "x": 12, "y": 30},
        "description": "Selected interfaces whose operational status is down or lowerLayerDown (from the detail table).",
        "targets": [{"refId": "A", "datasource": DASH_DS, "panelId": TABLE_ID, "withTransforms": True}],
        "transformations": status_filter([2, 7]) + [{"id": "organize", "options": {"excludeByName": {c: True for c in ["Speed", "Rx", "Tx", "Utilization in", "Utilization out", "key\\role"]}, "indexByName": {"Device": 0, "Interface": 1, "Status": 2}}}],
        "fieldConfig": {"defaults": {"custom": {"align": "left", "cellOptions": {"type": "auto"}, "inspect": False}, "noValue": "No interface is down", "color": {"mode": "thresholds"},
                                     "thresholds": {"mode": "absolute", "steps": [{"color": NEUTRAL, "value": None}]}},
                        "overrides": [{"matcher": {"id": "byName", "options": "Status"}, "properties": [{"id": "mappings", "value": OPER}, {"id": "custom.cellOptions", "value": {"type": "color-background", "mode": "basic"}}, {"id": "custom.width", "value": 150}]}]},
        "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False, "reducer": ["sum"], "fields": ""}, "sortBy": []},
    })
    # --- row 6: detail ---
    P.append(detail_table(0, 38, 24, 14))
    if sorted(p["id"] for p in P) != sorted(set(p["id"] for p in P)) or TABLE_ID not in [p["id"] for p in P]:
        raise SystemExit("duplicate panel id or table id mismatch")
    return {
        "uid": "noc-network-traffic", "title": "NOC — Network Traffic",
        "description": ("Interface traffic wallboard for any routers, switches and firewalls: choose Device Type, Devices and Interfaces at the top "
                        "(kept in the URL). Inbound/outbound traffic, utilization, interface status, errors and discards — all read from Zabbix "
                        "(host groups, interface discovery tags, item names); nothing is hardcoded."),
        "tags": ["noc", "netops", "traffic"], "editable": True, "graphTooltip": 1, "id": None,
        "fiscalYearStartMonth": 0, "liveNow": False, "refresh": "30s", "schemaVersion": 39, "style": "dark", "timezone": "browser", "weekStart": "",
        "time": {"from": "now-3h", "to": "now"}, "timepicker": {"refresh_intervals": ["30s", "1m", "5m", "15m"]},
        "annotations": {"list": []},
        "templating": {"list": [
            {"name": "devtype", "label": "Device Type", "type": "custom", "hide": 0,
             "query": "All : @@NOCQ_ALL@@,Router : @@NOCQ_ROUTER@@,Switch : @@NOCQ_SWITCH@@,Firewall : @@NOCQ_FIREWALL@@",
             "current": {"selected": True, "text": "All", "value": "@@NOC_ALL@@"}, "options": [], "multi": False, "includeAll": False,
             "skipUrlSync": False, "description": "Zabbix host groups per device type (regex over group names); set once by 'install.sh --dashboards'"},
            {"name": "device", "label": "Devices", "type": "query", "datasource": DS, "hide": 0,
             "query": {"queryType": "host", "group": GROUP, "host": "/.*/", "application": "", "itemTag": "", "item": ""},
             "definition": "Zabbix hosts in the host groups of the selected Device Type",
             "refresh": 1, "sort": 1, "multi": True, "includeAll": True, "current": {"selected": True, "text": ["All"], "value": ["$__all"]},
             "options": [], "regex": "", "skipUrlSync": False,
             "description": "Any number of Zabbix hosts of the chosen type (type to search). All = every host of the type; kept in the URL."},
            {"name": "interface", "label": "Interfaces", "type": "query", "datasource": DS, "hide": 0,
             "query": {"queryType": "itemTag", "group": GROUP, "host": DEVICES, "application": "", "itemTag": "/^[Ii]nterface: /", "item": ""},
             "definition": "Zabbix item tags 'interface: <name>' of the selected devices (interface discovery)",
             "refresh": 1, "sort": 7, "multi": True, "includeAll": True, "current": {"selected": True, "text": ["All"], "value": ["$__all"]}, "options": [],
             "regex": "/^(?<value>[Ii]nterface: (?<text>.+))$/", "skipUrlSync": False,
             "description": "Interfaces Zabbix discovered on the selected devices (item tag 'interface'); the list follows the Devices selection. Type to search."},
        ]},
        "links": [{"title": "NOC dashboards", "type": "dashboards", "tags": ["noc"], "asDropdown": False, "includeVars": False, "keepTime": True, "icon": "external link"}],
        "panels": P,
    }


d = network_traffic()
out = ROOT / "dashboards" / "noc" / f"{d['uid']}.json"
out.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
print("wrote", out.relative_to(ROOT), len(d["panels"]), "panels")
