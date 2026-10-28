# NOC — Network Traffic (release 2.6.0): operator guide

> **Status: not yet validated in production.** Built from the query and transformation patterns that were proven in NOC — Command Center and
> NOC — Device Health, checked statically only (JSON/syntax/unit checks). No lab or browser test was run for this dashboard. Verify it on
> your Grafana and Zabbix with the checklist at the bottom.

Folder **NOC**, uid `noc-network-traffic` (`/d/noc-network-traffic`). Interface traffic for any routers, switches and firewalls; everything is read
from Zabbix at view time. Nothing names a device, interface, item id or vendor.

## Selection (Grafana only; kept in the URL)

| Picker | Offers |
|---|---|
| **Device Type** — All / Router / Switch / Firewall | the Zabbix host groups chosen for each type (same setting as the other NOC dashboards, `NOC_GROUPS_*`) |
| **Devices** — multi-select, searchable, All | every Zabbix host of the type |
| **Interfaces** — multi-select, searchable, All | the interfaces Zabbix discovered on the **selected devices** (item tag `interface: <name>`); the list follows the Devices selection |

Native Grafana time range (default last 3 h) and refresh (default 30 s). A new Zabbix device or interface appears by itself (after the data
source's cache time); no dashboard edit and no GitHub update.

## Panels

| Panel | What it shows |
|---|---|
| **Total inbound / Total outbound** | sum of `Bits received` / `Bits sent` of the selected interfaces, with a 1-minute trend |
| **Total traffic** | the two sums as a graph |
| **Top 10 busiest interface directions** | the 10 highest inbound/outbound series (average over the time range) |
| **Top 10 utilization — inbound / outbound** | the 10 most utilized interfaces: bit/s divided by the interface `Speed` item (green < 70 %, orange < 90 %, red from 90 %) |
| **Inbound / Outbound by interface — top 10** | per-interface graphs, both directions drawn upwards (positive) |
| **Errors and discards — top 10** | `packets with errors` / `packets discarded`, inbound and outbound, packets per second |
| **Interfaces / UP / DOWN** | counted from the detail table; DOWN = ifOperStatus down or lowerLayerDown (unused access ports are down by design: choose the interfaces you care about) |
| **Interfaces DOWN — selected** | the list of those interfaces |
| **Interfaces — detail** | Device (click → NOC — Device Health), Interface, Status, Speed, Rx, Tx, Utilization in, Utilization out; busiest inbound first; column headers sort/filter |

## Units, signs and N/A

* Traffic items are bit/s (Zabbix unit `bps`); Grafana scales them (kbit/s, Mbit/s, Gbit/s). Inbound and outbound are always positive: a negative
  value (counter reset) is dropped by `removeBelowValue(0)`; there is no negative "outbound" axis.
* **N/A, never 0**, for a metric that is not available: no item, no sample in the last 15 minutes, no Speed. A real 0 traffic shows `0 bps`.
* Utilization = Rx (or Tx) ÷ Speed. Speed missing, 0, or polled less often than every 15 minutes → `N/A`. The Speed item is the one of the
  official "Network interfaces by SNMP" template (`Interface <name>(<alias>): Speed`, bit/s).

## Multi-vendor

Metrics are selected by item **name** and by the interface **tag**, never by key, so templates with different keys (Cisco, Huawei, Fortinet,
Palo Alto, Juniper, Gigamon, any SNMP device on the official interface template) work together in one view:

| Metric | Item name ends with |
|---|---|
| inbound / outbound | `Bits received` / `Bits sent` |
| speed | `: Speed` |
| status | `Operational status` |
| errors / discards | `packets with errors` / `packets discarded` |

A device whose interface items are named differently (or not tagged `interface:`) shows nothing for those interfaces.

## Deploy (this dashboard only)

```bash
curl -fsSL -x http://172.20.129.10:8080 https://codeload.github.com/jaber717/Grafana-Production-V2/tar.gz/refs/heads/main | tar xz -C /root && /root/Grafana-Production-V2-main/install.sh --network-traffic
```

Same safe update tool as `--command-center`: it creates (or updates) **only** the dashboard `noc-network-traffic` through the Grafana API, asks nothing,
touches no other dashboard, data source, plugin, config or provisioning, does not restart Grafana, backs the current JSON up first when it replaces one
(`/var/lib/grafana-platform/backups/command-center/`), says `unchanged` on a rerun, and prints a before/after proof that everything else is identical.
It needs the NOC folder (created by the earlier installer run) and a connected Zabbix. Roll back a replaced dashboard:
`GP_RESTORE_FILE=<backup file> /root/Grafana-Production-V2-main/install.sh --network-traffic`; to remove the new dashboard, delete it in Grafana.

## What to verify on production

1. Pick 2–3 devices of different vendors, then all their interfaces: Interfaces list follows the Devices selection; Total inbound/outbound are plausible
   against Zabbix → Latest data (sum of the selected interfaces).
2. Detail table: Rx/Tx/Speed of a few interfaces match Latest data; Status matches; an interface without a Speed shows N/A utilization (not 0 %).
3. Utilization of a busy link is plausible (Rx ÷ Speed); no negative values anywhere.
4. Errors and discards: an interface with known errors appears. Device name opens NOC — Device Health.
5. 30+ devices with Interfaces = All: if Grafana shows `request failed, status: 500`, the Zabbix frontend's PHP/nginx log at that time tells why
   (see the HTTP 500 section of [NOC-COMMAND-CENTER.md](NOC-COMMAND-CENTER.md)); select fewer interfaces.
6. Anything that differs: send the exact Zabbix item names of one interface (Bits received / Speed / Operational status).
