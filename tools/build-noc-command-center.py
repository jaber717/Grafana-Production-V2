#!/usr/bin/env python3
"""Generates dashboards/noc/noc-command-center.json: "NOC — Command Center", the NOC wallboard for any set of devices.

  python3 tools/build-noc-command-center.py      (re-run after editing this file; the JSON file is committed)

Independent of tools/build-noc-dashboards.py on purpose: the existing NOC dashboards are not regenerated or changed by this file.

Selection (Grafana variables only, kept in the URL):
  Device Type  same option list as the other NOC dashboards: each option is a regex over Zabbix HOST GROUP names, rendered at deploy
               time from NOC_GROUPS_ROUTER / NOC_GROUPS_SWITCH / NOC_GROUPS_FIREWALL (@@NOC_*@@ placeholders, scripts/lib/content.mjs).
  Device       Zabbix "Host" query over those groups, MULTI-select with "All". The Zabbix plugin turns several values into one
               regex /^(a|b|c)$/ with every value regex-escaped, and "All" into the same list of every offered host (no allValue:
               the plugin would escape a custom "match all" regex).

Fleet table (one row per selected device). Every query below is a plain Zabbix "Metrics" query whose series is renamed with the
plugin's setAlias to  <COLUMN>␟<host>  (the alias macro $__zbx_host_name is filled in per series by the plugin). The table then splits
that name back into column + host. WHY: the plugin only copies an alias into the field NAME when the series of ALL queries start at
exactly the same two timestamps (responseHandler.isConvertibleToWide); real Zabbix items are polled at their own times, so in
production they never do, the alias stays in field.config.displayNameFromDS, and Grafana's "Reduce" transformation (labelsToFields on)
then reads the field name "Value" for every series: every column collapsed into one "Value" and the Status was always UNKNOWN (release
2.4.0 defect, see CHANGELOG 2.5.0). The display name is honoured by "Reduce" with labelsToFields off, in both cases, and carrying the
host inside the alias needs no label at all.
  AVI / AVS / AVA   availability: item 'ICMP ping' (0/1), 'SNMP agent availability' and 'Zabbix agent availability' (0 not available,
               1 available, 2 unknown). Backend functions turn each into a weighted signal: up -> +w, down -> -w, unknown -> no sample
               (removeAboveValue(1)); w = 100 / 10 / 1.
  Status       SUM of the three weighted signals: the strongest signal present decides (ICMP beats SNMP beats agent: 100 > 10 + 1), > 0
               UP, < 0 DOWN, 0 = no usable signal = UNKNOWN. Only samples of the last WINDOW count (older = stale = no signal).
  TYP          the same availability items queried per Device Type group set (scale(0) + offset(1/2/3)) -> Router / Switch / Firewall.
  C1 C2 / M1 M2  CPU and memory utilization %, TIERS tried in this order (first tier that has a value wins, see METRICS below):
               tier 1 = utilization / usage item, tier 2 = idle% (CPU) or free/available% (memory), inverted by the backend (100 - x).
               Item names are matched by anchored patterns (no broad words), values outside 0..100 are discarded, several items of one
               tier (CPU boards, memory pools) -> the highest.
KPIs: re-use the fleet table's result (data source "-- Dashboard --"), so they always agree with the table and cost no query; a
               filter that leaves no row counts 0, while no answer from Zabbix at all shows "—" (never a reassuring 0).
Problems: the Zabbix plugin's own query types (Triggers count, Problems), over the same Device selection.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DS = {"type": "alexanderzobnin-zabbix-datasource", "uid": "zabbix-lab"}     # retargeted to the adopted data source at deploy time
DASH_DS = {"type": "datasource", "uid": "-- Dashboard --"}
GROUP = "${devtype:raw}"      # raw: the option value is already a /regex/ and must not be escaped by the plugin
DEVICES = "$device"
WINDOW = "10m"                # the fleet table's "now": a sample older than this is stale and ignored (no signal / not reported)
SEP = "\u241f"                # separates COLUMN and host inside the series alias (a character no Zabbix host name contains)

# ---- METRICS: the documented matching order (docs/NOC-COMMAND-CENTER.md). Item NAMES are matched by anchored patterns (RE2, case
# insensitive): the whole name must read "[prefix: ][up to 3 plain words ]CPU utilization" - so "CPU temperature", "CPU fan", "CPU core 3
# utilization", "CPU load average", "Memory usage, bytes" never match, while "#1: CPU utilization", "MPU Board 0: CPU utilization",
# "Management plane CPU utilization", "CPU usage", "Memory usage" do. No tag is required (vendors tag differently or not at all).
_PFX = r"(?:(?:[^:]{1,40}|#?\d+): )?(?:[A-Za-z-]+ ){0,3}"
_PCT_OPT = r"(?: ?\(%\)|, ?%| in %| percent(?:age)?)?"
_PCT_REQ = r"(?: ?\(%\)|, ?%| in %| percent(?:age)?)"
METRICS = {
    "CPU": [
        # tier 1: total CPU utilization (several CPUs / boards / planes of one device -> the highest)
        {"col": "C1", "invert": False, "item": "/^" + _PFX + r"(?:CPU|Processor)(?: total)? (?:utili[sz]ation|usage)" + _PCT_OPT + "$/i"},
        # tier 2: idle percentage, shown as 100 - idle (a percentage is required: a bare 'idle' might be a time)
        {"col": "C2", "invert": True, "item": "/^" + _PFX + r"(?:CPU|Processor) idle(?: time)?" + _PCT_REQ + "$/i"},
    ],
    "Memory": [
        # tier 1: memory utilization / usage as a percentage
        {"col": "M1", "invert": False, "item": "/^" + _PFX + r"(?:memory (?:utili[sz]ation|usage)" + _PCT_OPT + r"|(?:used memory|memory used)" + _PCT_REQ + ")$/i"},
        # tier 2: free / available percentage, shown as 100 - free
        {"col": "M2", "invert": True, "item": "/^" + _PFX + r"(?:free memory|memory free|available memory|memory available)" + _PCT_REQ + "$/i"},
    ],
}
ITEM_AVAIL = "/^(ICMP ping|SNMP agent availability|Zabbix agent availability)$/"
TYPE_TAGS = "component: health, component: network"   # only the Type column needs a tag (official 7.0 templates set it); Status/CPU/Memory do not
# availability signals: precedence = weight (ICMP 100 > SNMP 10 > agent 1; 100 > 10 + 1, 10 > 1)
AVAIL = [("AVI", "ICMP", "/^ICMP ping$/", 100, False), ("AVS", "SNMP", "/^SNMP agent availability$/", 10, True), ("AVA", "agent", "/^Zabbix agent availability$/", 1, True)]
HELPER_COLS = ["AVI", "AVS", "AVA", "C1", "C2", "M1", "M2"]

FN_DEF = {
    "scale": {"name": "scale", "category": "Transform", "params": [{"name": "factor", "type": "float", "options": [100, 0.01, 10, -1]}], "defaultParams": [100]},
    "offset": {"name": "offset", "category": "Transform", "params": [{"name": "delta", "type": "float", "options": [-100, 100]}], "defaultParams": [100]},
    "removeAboveValue": {"name": "removeAboveValue", "category": "Filter", "params": [{"name": "number", "type": "float"}], "defaultParams": [0]},
    "top": {"name": "top", "category": "Filter", "params": [{"name": "number", "type": "int"}, {"name": "value", "type": "string", "options": ["avg", "min", "max", "sum", "count", "median", "first", "last"]}], "defaultParams": [5, "avg"]},
    "setAlias": {"name": "setAlias", "category": "Alias", "params": [{"name": "alias", "type": "string"}], "defaultParams": []},
}


def fn(name, *params):
    return {"def": FN_DEF[name], "params": [str(p) for p in params], "text": f"{name}({', '.join(str(p) for p in params)})", "added": False}


def target(ref, item, item_tag="", host=DEVICES, group=GROUP, functions=()):
    return {
        "refId": ref, "datasource": DS, "queryType": "0",
        "group": {"filter": group}, "host": {"filter": host}, "application": {"filter": ""},
        "itemTag": {"filter": item_tag}, "item": {"filter": item},
        "functions": list(functions), "proxy": {"filter": ""}, "trigger": {"filter": ""}, "tags": {"filter": ""}, "macro": {"filter": ""},
        "options": {"showDisabledItems": False, "skipEmptyValues": False, "disableDataAlignment": True, "useZabbixValueMapping": False},
        "table": {"skipEmptyValues": False},
    }


def triggers_count(ref, min_severity):
    """Zabbix plugin query type 'Triggers', count mode: trigger.get countOutput over the hosts of group+host filters, value = 1 (PROBLEM)."""
    return {
        "refId": ref, "datasource": DS, "queryType": "4", "countTriggersBy": "",
        "group": {"filter": GROUP}, "host": {"filter": DEVICES}, "application": {"filter": ""}, "itemTag": {"filter": ""}, "item": {"filter": ""},
        "proxy": {"filter": ""}, "trigger": {"filter": ""}, "tags": {"filter": ""}, "macro": {"filter": ""}, "functions": [],
        "options": {"minSeverity": min_severity, "acknowledged": 2, "count": True, "useTimeRange": False, "showDisabledItems": False,
                    "skipEmptyValues": False, "disableDataAlignment": False, "useZabbixValueMapping": False, "hostsInMaintenance": False,
                    "hostProxy": False, "limit": 1001, "sortProblems": "default"},
        "showProblems": "problems", "table": {"skipEmptyValues": False},
    }


def problems_query(ref):
    return {
        "refId": ref, "datasource": DS, "queryType": "5",
        "group": {"filter": GROUP}, "host": {"filter": DEVICES}, "application": {"filter": ""}, "itemTag": {"filter": ""}, "item": {"filter": ""},
        "proxy": {"filter": ""}, "trigger": {"filter": ""}, "tags": {"filter": ""}, "macro": {"filter": ""}, "functions": [],
        "showProblems": "problems", "evaltype": "0",
        "options": {"minSeverity": 0, "acknowledged": 2, "count": False, "useTimeRange": False, "hostsInMaintenance": False, "hostProxy": False,
                    "limit": 200, "sortProblems": "default", "showDisabledItems": False, "skipEmptyValues": False, "disableDataAlignment": False,
                    "useZabbixValueMapping": False},
        "table": {"skipEmptyValues": False},
    }


_id = [0]


def pid():
    _id[0] += 1
    return _id[0]


# ---- colors (Grafana palette names; the same meaning everywhere) ----
UP, DOWN, UNKNOWN, NEUTRAL = "green", "red", "#8e8e8e", "text"
STATUS_MAP = [
    {"type": "range", "options": {"from": -1e9, "to": -0.5, "result": {"text": "DOWN", "color": DOWN, "index": 0}}},
    {"type": "value", "options": {"0": {"text": "UNKNOWN", "color": UNKNOWN, "index": 1}}},
    {"type": "range", "options": {"from": 0.5, "to": 1e9, "result": {"text": "UP", "color": UP, "index": 2}}},
    {"type": "special", "options": {"match": "null+nan", "result": {"text": "UNKNOWN", "color": UNKNOWN, "index": 3}}},
]
TYPE_MAP = [{"type": "value", "options": {"1": {"text": "Router", "index": 0}, "2": {"text": "Switch", "index": 1}, "3": {"text": "Firewall", "index": 2}}},
            {"type": "special", "options": {"match": "null+nan", "result": {"text": "—", "index": 3}}}]
PCT = {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 70}, {"color": "red", "value": 90}]}
ALERT = {"mode": "absolute", "steps": [{"color": "transparent", "value": None}, {"color": "red", "value": 1}]}   # tile turns red when > 0
NO_VALUE = [{"type": "special", "options": {"match": "null+nan", "result": {"text": "N/A", "color": UNKNOWN, "index": 0}}}]

TABLE_ID = 10
TOP_N = 10                    # trend panels: the TOP_N series with the highest value in the time range (Zabbix plugin top())
LINK_DEVICE = ("/d/noc-device-health/noc-device-health?orgId=1&${devtype:queryparam}&var-device=${__value.raw:percentencode}"
               "&var-interface=$__all")


def alias(col):
    return col + SEP + "$__zbx_host_name"


def fleet_table(x, y, w, h):
    T = []
    # availability: the strongest signal present decides (weights 100 / 10 / 1); 'unknown' (2) of SNMP/agent availability is dropped
    for ref, label, item, weight, drop_unknown in AVAIL:
        fns = ([fn("removeAboveValue", 1)] if drop_unknown else []) + [fn("scale", 2 * weight), fn("offset", -weight), fn("setAlias", alias(ref))]
        T.append(target(ref, item, functions=fns))
    # type: the same availability items per Device Type host-group set -> 1 Router / 2 Switch / 3 Firewall (tag-scoped: cheap)
    for n, (ref, ph) in enumerate([("TR", "@@NOC_ROUTER@@"), ("TS", "@@NOC_SWITCH@@"), ("TF", "@@NOC_FIREWALL@@")], start=1):
        T.append(target(ref, ITEM_AVAIL, item_tag=TYPE_TAGS, group=ph, functions=[fn("scale", 0), fn("offset", n), fn("setAlias", alias("TYP"))]))
    # CPU / memory tiers (METRICS); an inverted tier (idle%, free%) is turned into utilization by the backend: 100 - x
    for kind in ("CPU", "Memory"):
        for t in METRICS[kind]:
            fns = ([fn("scale", -1), fn("offset", 100)] if t["invert"] else []) + [fn("setAlias", alias(t["col"]))]
            T.append(target("Q" + t["col"], t["item"], functions=fns))
    pct = lambda name: {"matcher": {"id": "byName", "options": name}, "properties": [
        {"id": "unit", "value": "percent"}, {"id": "decimals", "value": 0}, {"id": "thresholds", "value": PCT}, {"id": "mappings", "value": NO_VALUE},
        {"id": "custom.cellOptions", "value": {"type": "color-text"}}, {"id": "custom.width", "value": 110}, {"id": "custom.align", "value": "center"}]}
    guard = lambda cond, value: {"id": "filterByValue", "options": {"type": "exclude", "match": "all", "filters": [
        {"fieldName": "col", "config": {"id": "regex", "options": {"value": "^[CM][0-9]$"}}},
        {"fieldName": "Last *", "config": {"id": cond, "options": {"value": value}}}]}}
    return {
        "id": TABLE_ID, "type": "table", "title": "Fleet health — selected devices",
        "description": ("One row per selected device, DOWN first, then UNKNOWN, then UP. Status: the strongest fresh signal decides - ICMP ping, else SNMP "
                        "availability, else Zabbix agent availability (1 = UP, 0 = DOWN); a signal that says 'unknown' or has no sample in the last " + WINDOW +
                        " is ignored; no usable signal = UNKNOWN. CPU / Memory: utilization percentage (0-100) of the device's CPU / memory items, "
                        "tier 1 'utilization / usage', tier 2 'idle' / 'free' inverted; several items (CPU boards, memory pools) -> the highest; "
                        "N/A = no such item or no sample. Click a device to open NOC — Device Health."),
        "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y}, "timeFrom": WINDOW, "hideTimeOverride": True,
        "targets": T,
        "transformations": [
            # 1 one row per series: Field = the alias (COLUMN + SEP + host), Last * = last sample of the window that is not empty
            {"id": "reduce", "options": {"mode": "seriesToRows", "reducers": ["lastNotNull"], "labelsToFields": False, "includeTimeField": False}},
            # 2 split the alias: col, host
            {"id": "extractFields", "options": {"source": "Field", "format": "regexp", "regExp": "/^(?<col>[^" + SEP + "]*)" + SEP + "(?<host>.*)$/", "replace": False, "keepTime": False}},
            # 3 a CPU / memory sample outside 0..100 is not a percentage (wrong item): dropped, never clipped
            guard("greater", 100), guard("lower", 0),
            # 4 one value per host and column; several items of one tier -> the highest
            {"id": "groupBy", "options": {"fields": {"host": {"operation": "groupby", "aggregations": []}, "col": {"operation": "groupby", "aggregations": []},
                                                     "Last *": {"operation": "aggregate", "aggregations": ["max"]}}}},
            # 5 hosts as rows, columns as columns
            {"id": "groupingToMatrix", "options": {"columnField": "col", "rowField": "host", "valueField": "Last * (max)", "emptyValue": "null"}},
            # 6 CPU / memory: first tier that has a value; Status: sum of the weighted signals (0 = nothing usable)
            {"id": "calculateField", "options": {"mode": "reduceRow", "reduce": {"include": [t["col"] for t in METRICS["CPU"]], "reducer": "firstNotNull"}, "alias": "CPU", "replaceFields": False}},
            {"id": "calculateField", "options": {"mode": "reduceRow", "reduce": {"include": [t["col"] for t in METRICS["Memory"]], "reducer": "firstNotNull"}, "alias": "Memory", "replaceFields": False}},
            {"id": "calculateField", "options": {"mode": "reduceRow", "reduce": {"include": [a[0] for a in AVAIL], "reducer": "sum"}, "alias": "Status", "replaceFields": False}},
            # 7 DOWN (< 0), UNKNOWN (0), UP (> 0); the device name breaks ties: the order is recomputed on every refresh and selection
            {"id": "sortBy", "options": {"sort": [{"field": "Status", "desc": False}, {"field": "host\\col", "desc": False}]}},
            {"id": "organize", "options": {"excludeByName": {c: True for c in HELPER_COLS},
                                           "indexByName": {"host\\col": 0, "TYP": 1, "Status": 2, "CPU": 3, "Memory": 4},
                                           "renameByName": {"host\\col": "Device", "TYP": "Type"}}},
        ],
        "fieldConfig": {
            "defaults": {"custom": {"align": "left", "cellOptions": {"type": "auto"}, "inspect": False, "filterable": False},
                         "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": NEUTRAL, "value": None}]}},
            "overrides": [
                {"matcher": {"id": "byName", "options": "Device"}, "properties": [
                    {"id": "custom.minWidth", "value": 180},
                    {"id": "links", "value": [{"title": "Open ${__value.raw} in NOC — Device Health", "url": LINK_DEVICE}]}]},
                {"matcher": {"id": "byName", "options": "Type"}, "properties": [{"id": "mappings", "value": TYPE_MAP}, {"id": "custom.width", "value": 110}]},
                {"matcher": {"id": "byName", "options": "Status"}, "properties": [
                    {"id": "mappings", "value": STATUS_MAP}, {"id": "custom.cellOptions", "value": {"type": "color-background", "mode": "basic"}},
                    {"id": "custom.width", "value": 130}, {"id": "custom.align", "value": "center"}]},
                pct("CPU"), pct("Memory"),
            ]},
        "options": {"showHeader": True, "cellHeight": "md", "footer": {"show": False, "reducer": ["sum"], "fields": ""}, "sortBy": []},
    }


def kpi(title, x, y, w, h, color, transformations, desc, calc="count", field="/^Device$/", targets=None, datasource=None, no_value="—"):
    return {
        "id": pid(), "type": "stat", "title": title, "description": desc,
        "datasource": datasource or DASH_DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": targets or [{"refId": "A", "datasource": DASH_DS, "panelId": TABLE_ID, "withTransforms": True}],
        "transformations": transformations,
        "fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": color} if isinstance(color, str) else {"mode": "thresholds"},
                                     "thresholds": color if isinstance(color, dict) else {"mode": "absolute", "steps": [{"color": "text", "value": None}]},
                                     "decimals": 0, "noValue": no_value, "unit": "none"}, "overrides": []},
        "options": {"reduceOptions": {"calcs": [calc], "fields": field, "values": False}, "colorMode": "background" if isinstance(color, dict) else "value",
                    "graphMode": "none", "justifyMode": "center", "textMode": "value", "orientation": "auto", "wideLayout": True, "showPercentChange": False},
    }


def status_filter(cond, value):
    return [{"id": "filterByValue", "options": {"type": "include", "match": "any",
                                                "filters": [{"fieldName": "Status", "config": {"id": cond, "options": {"value": value}}}]}}]


def trend(title, item, x, y, w, h, desc):
    return {
        "id": pid(), "type": "timeseries", "title": title, "description": desc, "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [target("A", item, functions=[fn("top", TOP_N, "max")])],
        "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100, "decimals": 0, "color": {"mode": "palette-classic"},
                                     "custom": {"drawStyle": "line", "lineWidth": 1, "fillOpacity": 0, "showPoints": "never", "spanNulls": True,
                                                "thresholdsStyle": {"mode": "dashed"}},
                                     "thresholds": {"mode": "absolute", "steps": [{"color": "transparent", "value": None}, {"color": "orange", "value": 70}, {"color": "red", "value": 90}]}},
                        "overrides": []},
        "options": {"legend": {"displayMode": "table", "placement": "right", "showLegend": True, "calcs": ["lastNotNull", "max"], "sortBy": "Last *", "sortDesc": True, "width": 330},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
    }


def command_center():
    _id[0] = 0
    P = []
    # --- row 1: KPIs (from the fleet table) + problems count (from Zabbix) ---
    P.append(kpi("Selected devices", 0, 0, 4, 4, NEUTRAL, [], "Devices in the fleet table (the current Device selection)."))
    P.append(kpi("UP", 4, 0, 5, 4, UP, status_filter("greater", 0), "Selected devices whose ICMP / SNMP / agent availability reports reachable."))
    P.append(kpi("DOWN", 9, 0, 5, 4, ALERT, status_filter("lower", 0), "Selected devices that Zabbix reports unreachable (ICMP / SNMP / agent) and nothing reports reachable."))
    P.append(kpi("UNKNOWN", 14, 0, 5, 4, UNKNOWN, status_filter("equal", 0), "Selected devices with no availability answer: no ICMP/SNMP/agent item, 'unknown', or no data in the last " + WINDOW + "."))
    P.append(kpi("High / Disaster problems", 19, 0, 5, 4, ALERT, [],
                 "Zabbix triggers in PROBLEM state with severity High or Disaster on the selected devices (monitored hosts, dependent triggers skipped).",
                 calc="lastNotNull", field="", targets=[triggers_count("A", 4)], datasource=DS, no_value="—"))
    # --- row 2: fleet table + active problems ---
    P.append(fleet_table(0, 4, 13, 14))
    P.append({
        "id": pid(), "type": "alexanderzobnin-zabbix-triggers-panel", "title": "Active problems — selected devices",
        "description": "Zabbix problems of the selected devices, newest first (Zabbix plugin Problems panel). Acknowledged problems are marked.",
        "datasource": DS, "gridPos": {"h": 14, "w": 11, "x": 13, "y": 4},
        "targets": [problems_query("A")],
        "options": {"schemaVersion": 8, "layout": "table", "fontSize": "100%", "pageSize": 12, "sortProblems": "lastchange",
                    "hostField": True, "hostTechNameField": False, "hostIpField": False, "hostProxy": False, "hostGroups": False,
                    "showTags": False, "statusField": False, "statusIcon": False, "severityField": True, "ackField": True, "ageField": True,
                    "opdataField": False, "descriptionField": False, "descriptionAtNewLine": False, "showDatasourceName": False,
                    "showSearchFilter": False, "problemTimeline": False, "highlightBackground": False, "highlightNewEvents": True,
                    "highlightNewerThan": "15m", "customLastChangeFormat": True, "lastChangeFormat": "DD MMM HH:mm", "resizedColumns": [{"id": "host", "value": 140}, {"id": "priority", "value": 90}, {"id": "acknowledged", "value": 45}, {"id": "age", "value": 85}, {"id": "lastchange", "value": 105}],
                    "allowDangerousHTML": False, "markAckEvents": False, "okEventColor": "rgb(56, 189, 113)", "ackEventColor": "rgb(56, 219, 156)",
                    "triggerSeverity": [
                        {"priority": 0, "severity": "Not classified", "color": "rgb(108, 108, 108)", "show": True},
                        {"priority": 1, "severity": "Information", "color": "rgb(120, 158, 183)", "show": True},
                        {"priority": 2, "severity": "Warning", "color": "rgb(175, 180, 36)", "show": True},
                        {"priority": 3, "severity": "Average", "color": "rgb(255, 137, 30)", "show": True},
                        {"priority": 4, "severity": "High", "color": "rgb(255, 101, 72)", "show": True},
                        {"priority": 5, "severity": "Disaster", "color": "rgb(215, 0, 0)", "show": True}]},
    })
    # --- row 3: trends ---
    P.append(trend(f"CPU utilization — top {TOP_N} of the selected devices", METRICS["CPU"][0]["item"], 0, 18, 12, 8,
                   f"The {TOP_N} highest CPU series (peak in the time range) among the selected devices: items tagged component: cpu, one line "
                   "per CPU / engine / plane. Legend sorted by current value."))
    P.append(trend(f"Memory utilization — top {TOP_N} of the selected devices", METRICS["Memory"][0]["item"], 12, 18, 12, 8,
                   f"The {TOP_N} highest memory series (peak in the time range) among the selected devices: items tagged component: memory. "
                   "Legend sorted by current value."))
    if sorted(p["id"] for p in P) != sorted(set(p["id"] for p in P)):
        raise SystemExit("duplicate panel id")
    return {
        "uid": "noc-command-center", "title": "NOC — Command Center",
        "description": ("NOC wallboard for any set of routers, switches and firewalls: choose Device Type and any number of Devices at the top "
                        "(kept in the URL). Everything is read from Zabbix — host groups, hosts, item tags and names; nothing is hardcoded."),
        "tags": ["noc", "netops", "command-center"], "editable": True, "graphTooltip": 1, "id": None,
        "fiscalYearStartMonth": 0, "liveNow": False, "refresh": "30s", "schemaVersion": 39, "style": "dark", "timezone": "browser", "weekStart": "",
        "time": {"from": "now-6h", "to": "now"}, "timepicker": {"refresh_intervals": ["30s", "1m", "5m", "15m"]},
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
        ]},
        "links": [{"title": "NOC dashboards", "type": "dashboards", "tags": ["noc"], "asDropdown": False, "includeVars": False, "keepTime": True, "icon": "external link"}],
        "panels": P,
    }


d = command_center()
out = ROOT / "dashboards" / "noc" / f"{d['uid']}.json"
out.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
print("wrote", out.relative_to(ROOT), len(d["panels"]), "panels")
