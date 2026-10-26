# NOC dashboards (release 2.3.0): every device is chosen in Grafana, from what Zabbix reports

Two dashboards in the folder **NOC** (same uids as before, so links and bookmarks keep working):

| Dashboard | uid | What it shows |
|---|---|---|
| NOC — Device Health | `noc-device-health` | one device: ICMP reachability, response time and loss, SNMP availability, uptime, CPU, memory, interface status, traffic, errors/discards |
| NOC — Network Overview | `noc-wan-overview` | every device of the chosen type: ICMP and SNMP availability, CPU and memory (highest first), ICMP response time |

Nothing in them names a device, host id, item id, item key or interface. The old LAB-captured NOC dashboards (7 fixed routers, 47 item
ids, item map) are replaced; the LAB item map is no longer used by any dashboard.

## The three pickers at the top

| Picker | Where its values come from | When it changes |
|---|---|---|
| **Device Type** — All / Router / Switch / Firewall | each type = Zabbix **host groups** whose names match a pattern (settings `NOC_GROUPS_ROUTER`, `NOC_GROUPS_SWITCH`, `NOC_GROUPS_FIREWALL`) | chosen once by `install.sh --dashboards`, which lists your real host groups |
| **Device** | Zabbix `host.get` over the host groups of the type | every dashboard load; a host added to one of those groups appears automatically |
| **Interface** (multi, default All) | the item tags `interface: <name>` that Zabbix interface discovery (LLD) puts on each interface's items; shown as the interface name | every dashboard load; a newly discovered interface appears automatically |

New devices: Grafana's Zabbix data source caches host groups, hosts and items for its **Cache TTL**. The data source the installer manages
uses 5 minutes (`ZABBIX_CACHE_TTL`); a Zabbix data source you created yourself keeps its own setting (Grafana: Connections → Data sources →
your Zabbix → Cache TTL; the plugin's default is 1 hour). Within that time a new host appears in the pickers with no action at all.

## How each panel finds its data (vendor-neutral)

Panels select Zabbix items by **item tag** and **item name**, never by item key, so templates whose keys differ (Cisco `cpmCPUTotal5minRev`,
Juniper `jnxOperatingCPU`, Huawei `hwEntityCpuUsage`, FortiGate `fgSysCpuUsage`, Palo Alto `hrProcessorLoad`, ...) all work:

| Panel | Item tag | Item name (regex) |
|---|---|---|
| Reachability (ICMP), response time, loss | — | `ICMP ping`, `ICMP response time`, `ICMP loss` (template *ICMP Ping*) |
| SNMP availability | — | `SNMP agent availability` (`zabbix[host,snmp,available]`: 0 not available, 1 available, 2 unknown) |
| Uptime | `component: system` | starts with `Uptime` / `System uptime` |
| CPU | `component: cpu` | contains utilization / usage / load (one series per CPU, engine or plane) |
| Memory | `component: memory` | contains utilization / usage |
| Interface status | the selected `interface: <name>` tags | ends with `Operational status` (IF-MIB ifOperStatus 1 up … 7 lowerLayerDown) |
| Interface traffic | the selected `interface: <name>` tags | ends with `Bits received` / `Bits sent` |
| Errors and discards | the selected `interface: <name>` tags | ends with `packets with errors` / `packets discarded` |

These are the conventions of the official Zabbix 7.0 SNMP templates (component tags, interface discovery tags `interface`/`description`,
item names "Interface <ifName>(<ifAlias>): …"). A device whose template does not follow them shows "no item" / "No data" in that panel —
see "To validate on your Zabbix" below.

## Changing the Device Type groups later

```bash
sudo grafana-platform setup --dashboards
```

It reads the host groups from Zabbix (read-only), shows which groups each type matches, and lets you name them (`;`-separated group names
or a `/regex/`). Only the two NOC dashboards are updated; Grafana is not restarted.

## What was tested, and how

* Real Grafana 13.2.3 and the real Zabbix plugin 6.8.0 (its frontend and Go backend), on AlmaLinux 9.8 (RHEL 9.8 rebuild, real systemd).
* Zabbix: `tests/noc/zabbix7-api.mjs`, a Zabbix 7.0 API stand-in that rejects any request parameter Zabbix 7.0 does not accept, with host
  groups, five vendors' templates (different keys), interface discovery tags, a firewall that is down, a switch without ICMP and a Linux
  server that must never appear.
* `tests/noc/ui-acceptance.py`: a real browser logs in and uses the pickers like an operator — Device Type → Device list per type,
  every device of every type chosen in the picker and every panel's answer checked, one interface chosen in the Interface picker, the
  overview per type. Result: **72 / 72** through a hand-made, adopted Zabbix data source, and **81 / 81** after adding a differently named
  group ("Network/WAN Edge") to Router in the Device Type step ([evidence/noc-ui-acceptance.txt](evidence/noc-ui-acceptance.txt), screenshots in
  [evidence/noc-screens/](evidence/noc-screens/)).
* A router added in Zabbix appeared in Device after the 5-minute cache, with nothing done in Grafana ([evidence/noc-new-device.txt](evidence/noc-new-device.txt)).

## To validate on your Zabbix (not provable here)

1. **Host groups**: the Device Type step shows which of your groups are routers / switches / firewalls — correct it there if needed.
2. **Templates**: open 2–3 devices of each vendor; a panel showing "no item" means that template names or tags the item differently.
   The item tag and name each panel uses are in its description (the ⓘ next to the title).
3. **Interface tags**: the Interface picker lists the `interface` tags of the device. If it is empty for a device that has interfaces in
   Zabbix, its template does not set the `interface` tag on interface items.
4. **The plugin's `applicationids: null`**: the Zabbix plugin 6.8 sends this removed parameter with the value null on every `item.get`;
   the test Zabbix accepts it on the assumption that Zabbix 7.0 ignores null parameters (the plugin is widely used with 7.0). Your working
   Explore queries already go through the same call.
5. **Permissions**: the Zabbix user of the data source must have read access to the host groups of all three types.
