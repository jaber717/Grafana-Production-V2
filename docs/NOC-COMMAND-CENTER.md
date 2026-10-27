# NOC — Command Center (release 2.4.0): operator guide

The NOC wallboard for **any set of routers, switches and firewalls**. Folder **NOC**, uid `noc-command-center`
(`/d/noc-command-center`). Everything on it is read from Zabbix at view time; nothing names a device, host id, item id or interface.

![Wallboard, 22 devices](evidence/command-center/cc-wallboard-kiosk.jpg)

## Choosing devices (Grafana only — no file, installer run or restart)

| Picker | What it offers | Notes |
|---|---|---|
| **Device Type** — All / Router / Switch / Firewall | the Zabbix host groups chosen for each type (same setting as the other NOC dashboards, `NOC_GROUPS_*`) | change the groups: `sudo grafana-platform setup --dashboards` |
| **Devices** — multi-select, type to search | every Zabbix host in those groups; **All** = all of them | pick 1, 9, 20 or more, mixed types |

* Click **Devices**, type part of a name, click the device; repeat; click outside the list to apply. Click a device again (or its ×) to remove it.
* The selection is in the address bar (`var-device=...` once per device): **bookmark the URL** or add it to a playlist to keep a wallboard
  for a site, a customer or a shift. Opening the URL restores exactly that selection.
* A host added to one of the type's host groups in Zabbix appears in the Devices list by itself (after the data source's cache time,
  5 minutes for the data source the installer manages).
* Wall display: append `&kiosk` to the URL (hides menus). The page refreshes every 30 s (change at the top right).

## What each part shows

| Part | Meaning |
|---|---|
| **Selected devices / UP / DOWN / UNKNOWN** | counted from the fleet table below, so they always agree with it. DOWN turns red when > 0. `—` = Zabbix did not answer (never a reassuring 0). |
| **High / Disaster problems** | Zabbix triggers in PROBLEM state with severity High or Disaster on the selected devices (monitored hosts; dependent triggers skipped). Red when > 0. |
| **Fleet health** (one row per device, DOWN first, then UNKNOWN, then UP) | **Status**: UP = ICMP ping, SNMP availability or Zabbix agent availability says reachable; DOWN = they only say unreachable; UNKNOWN = no answer, availability "unknown", or nothing reported in the last 15 minutes. **CPU / Memory**: highest current value of the items tagged `component: cpu` / `component: memory` (several CPUs or planes → the highest); `—` = not reported (never 0). **Type** from the host groups. Click a device name → **NOC — Device Health** for that device (interfaces, traffic, history). Column headers sort. |
| **Active problems** | the Zabbix problems of the selected devices, newest first, with severity, age and acknowledgement (the Zabbix plugin's own Problems panel, already installed with the plugin). |
| **CPU / Memory — top 10** | the 10 highest series (peak in the time range) among the selected devices; legend sorted by current value. The full per-device history is on NOC — Device Health. |

Interface status and traffic are deliberately not on the wallboard: a fleet of switches has hundreds of ports, most "down" by design
(unused access ports), which is noise on a wall. Link-down events reach the wallboard through the Zabbix problems (template trigger
"Link down"); per-interface detail is one click away on NOC — Device Health.

## Which Zabbix items are used (vendor-neutral)

| Column | Zabbix item (name) | Template |
|---|---|---|
| Status | `ICMP ping`, `SNMP agent availability`, `Zabbix agent availability` | ICMP Ping; every 7.0 SNMP template; agent templates |
| CPU | item tag `component: cpu`, name contains utilization / usage / load | official 7.0 SNMP templates (Cisco, Juniper, Huawei, FortiGate, Palo Alto, ...) |
| Memory | item tag `component: memory`, name contains utilization / usage | same |
| Problems | `trigger.get` / `problem.get` for the selected hosts | any |

A device is listed when Zabbix has at least one of these items for it. A device with none of them (no ICMP, no SNMP/agent availability,
no tagged CPU/memory) is not in the table — give it the ICMP Ping template.

## Install / update

The installer's dashboards step creates it; nothing else changes (Grafana is not reinstalled or restarted, data sources, credentials,
firewall and the other dashboards are untouched; re-running finds it "unchanged"):

```bash
curl -fsSL -x http://172.20.129.10:8080 https://codeload.github.com/jaber717/Grafana-Production-V2/tar.gz/refs/heads/main | tar xz -C /root && sudo /root/Grafana-Production-V2-main/install.sh --dashboards
```

The step shows your saved host-group choice for Router / Switch / Firewall and asks once to keep it: press **Enter**.

To customise the wallboard, use **Save as** in Grafana (a copy under a new name): the dashboard with uid `noc-command-center` is managed
by the installer and is reset to the release version when the dashboards step runs again.

## Tested, and what is left to confirm on your Zabbix

Tested with the real Grafana 13.2.3 and Zabbix plugin 6.8.0 on AlmaLinux 9.8 (RHEL 9 rebuild), Zabbix = the Zabbix 7.0 API stand-in
`tests/noc/zabbix7-api.mjs --fleet` (24 network devices, 5 vendors' templates, a DOWN router and firewall, an UNKNOWN switch, a firewall
without CPU/memory items, an agent-monitored firewall, 10 problems). Browser test `tests/noc/ui-command-center.py`: **118 / 118**
([evidence/command-center/](evidence/command-center/)). This is a test Zabbix, not yours: on production confirm

1. the Devices list per Device Type is right (else correct the groups with `sudo grafana-platform setup --dashboards`);
2. a device you know is down shows DOWN, and the Active problems match Zabbix → Monitoring → Problems for the same hosts;
3. CPU / Memory for 2–3 devices of each vendor match Zabbix's Latest data (a `—` means that template tags or names the item differently);
4. the Zabbix user of the data source can read the triggers of those hosts (otherwise problems stay empty).
