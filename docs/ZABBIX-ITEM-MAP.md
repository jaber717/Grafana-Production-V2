> **Obsolete since 2.3.0.** No dashboard addresses Zabbix items by id any more ([NOC-DASHBOARDS.md](NOC-DASHBOARDS.md)); setup and preflight no
> longer use an item map. The `item-map` command is kept only as a legacy tool.

# Zabbix item map (NOC dashboards)

The two NOC dashboards (`noc-device-health`, `noc-wan-overview`) query the Zabbix datasource by **numeric item id** (query type 3): 47 items.
Item ids belong to one Zabbix database, so the ids captured on the LAB Zabbix mean nothing on another server. This release keeps, next to the
dashboards, a **descriptor** for every item id used (`config/zabbix-item-descriptors.json`: host name + item key) and a tool that finds the same
host + key on your Zabbix and writes `{ "<lab id>": "<your id>" }`. `grafana-platform` applies the map in memory when it deploys the dashboards
(the files in Git never change).

## Build the map (read-only against Zabbix)

```bash
grafana-platform item-map
```

It uses the datasource settings (`ZABBIX_URL`, `ZABBIX_USER`) and the `zabbix-password` secret — no extra API token. Methods called:
`apiinfo.version`, `user.login`, `host.get`, `item.get`, `user.logout`. It never guesses: an item that cannot be resolved exactly once is listed
and the exit code is 3; the file is still written (mode 0640) with everything that resolved.

| Situation | Command |
|---|---|
| production host names differ from the LAB names (`SITE-A SITE-B STC MOBILY INT-CORE SAIX-A SAIX-B`) | `grafana-platform item-map --host SITE-A=<name>,SITE-B=<name>,...` (technical host name or visible name) |
| look at what a host really has | `grafana-platform item-map --search <part of the host name>` (lists items with id, key, interval, last value time) |
| set an id you verified yourself | `grafana-platform item-map --set <lab id>=<item id>` (repeatable; kept on later runs) |
| map complete | `grafana-platform config set ALLOW_NOC_WITHOUT_ITEM_MAP=no && grafana-platform apply` |
| not ready yet | `grafana-platform config set ALLOW_NOC_WITHOUT_ITEM_MAP=yes` — both NOC dashboards are deferred (WARN), never deployed half-mapped |

Every run merges with the existing file (`--merge`): ids set by hand survive.

## The seven "UP" items (REVIEW)

`noc-device-health` derives each router's SNMP badge from a fresh sample of its SNMP uptime (`refId UP`, freshness window 2 minutes). In the LAB
these items had no history when the repository was captured, so 1.x shipped them as "unresolved". 2.0 describes them by host and a list of
**candidate keys** used by the standard Zabbix SNMP templates, tried in order:
`system.net.uptime[sysUpTime.0]`, `system.uptime[sysUpTime.0]`, `system.hw.uptime[hrSystemUptime.0]`. The first key that exists **exactly once**
on that host is used and printed under **REVIEW**. Confirm in Zabbix that the chosen item is the router's uptime and is polled often enough
(≤ 2 minutes); otherwise set the right id with `--set`.

## Running the tool directly (any host with Node.js ≥ 18)

```bash
ZABBIX_URL=http://<zabbix>/api_jsonrpc.php ZABBIX_USER=<read-only user> ZABBIX_PASSWORD_FILE=/root/zbx.pw node tools/zabbix-item-map.mjs --out zabbix-item-map.json
```
`ZABBIX_TOKEN_FILE=<file>` instead of user/password uses an API token. Private CA: `NODE_EXTRA_CA_CERTS=/path/ca.pem`. Never put a password on the command line.

## What `preflight` and `apply` do with the map

* map covers all 47 ids → NOC dashboards deployed with your ids;
* map missing or incomplete, `ALLOW_NOC_WITHOUT_ITEM_MAP=no` → **FAIL** with the two fix commands (nothing is installed);
* map missing or incomplete, `ALLOW_NOC_WITHOUT_ITEM_MAP=yes` → both NOC dashboards **skipped** (WARN); NetFlow dashboards unaffected.

## What the simulation proves and what it does not

`tests/sim/run-sim.sh` resolves all 47 ids against a mock Zabbix 7.0 with renamed hosts. That proves the mechanics, **not** that your Zabbix has
these keys or that the panels show correct values — see [LIVE-VERIFICATION.md](LIVE-VERIFICATION.md) items 7–8.
