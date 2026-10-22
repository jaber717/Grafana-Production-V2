# What still needs the real environment

Release 2.0.0 was produced without access to the LAB or to production. Its evidence is source review, unit tests and an end-to-end run on a
**simulated** RHEL 9.8 host ([VALIDATION-V2.md](VALIDATION-V2.md)). The simulation replaces the operating system services, Grafana, Zabbix,
ClickHouse and the downloaded artifacts with stand-ins. Everything in the table below is therefore **unproven** until it has been run for real.

| # | Item | Why the simulation cannot prove it | How it is proven on the real systems |
|---|---|---|---|
| 1 | Offline bundle downloads match the pinned SHA-256 (Grafana RPM 13.2.3-1, zabbix-app 6.8.0, clickhouse-datasource 4.22.0, Node.js v20.20.2) | rpm.grafana.com, grafana.com and nodejs.org were not reachable from the build environment; the builder ran against a local mirror with fake files | step 0 of [INSTALL.md](../INSTALL.md) succeeds (the builder aborts on any mismatch) |
| 2 | The real Grafana RPM installs on RHEL 9.8 from the bundle; signature check with the pinned key; `dnf versionlock` | rpm/dnf were simulated | `install` passes "RPM header signed by 963FA27710458545" and `verify` shows "version lock present" |
| 3 | Grafana 13.2.3 behaves like the mock for every API call the tools make | the mock implements only the request/response shapes (1.0.1 used the same calls against real Grafana) | `install` ends with `0 FAIL`; dashboards open in the browser |
| 4 | SELinux Enforcing + firewalld with the real Grafana process | simulated | `verify`: "no SELinux denials", "firewalld admits 3000/tcp only by source rule" |
| 5 | Zabbix login over HTTP at `10.20.8.24:8080` with the read-only user, and its host permissions | mock Zabbix | `grafana-platform zabbix-check` → "login OK … N host(s) visible" with N > 0 |
| 6 | Network path Grafana → Zabbix (and later → ClickHouse) | loopback only | preflight "Zabbix API answers at … (version …)"; datasource health OK |
| 7 | Item map against the production Zabbix: host names, item keys, and the **7 uptime items resolved through candidate keys** | synthetic hosts/items | `grafana-platform item-map` → "47 of 47"; confirm each REVIEW line in Zabbix (Data collection → Hosts → Items) |
| 8 | NOC panels show correct values (thresholds, UP/SNMP freshness logic) | no real data | open both NOC dashboards; compare 2–3 values with Zabbix "Latest data" |
| 9 | ClickHouse/Akvorado (port, TLS, user, NetFlow queries) | `/ping` stand-in only | after step 6: datasource health OK and the five NetFlow dashboards show traffic |
| 10 | Bundled Node.js runs on RHEL 9.8 | the simulation used the build machine's Node | `install` prints "Node.js v20.20.2 installed to /opt/grafana-platform/node" (or uses an existing Node ≥ 18) |
| 11 | Daily backup timer, `backup`/`restore` with real SQLite | not exercised in 2.0's simulation (unchanged 1.0.1 code) | `grafana-platform backup` then `ls /var/backups/grafana-platform` |
| 12 | Which byte sequence made 1.0.1 ignore `ALLOW_INSECURE_DATASOURCES` | the production file was not available | `grep -n -i insecure /root/grafana.env /etc/grafana-platform/platform.env 2>/dev/null \| cat -A` (read-only) — see [ROOT-CAUSE-V2.md](ROOT-CAUSE-V2.md) |

## Acceptance record to fill in on the server

Run after [INSTALL.md](../INSTALL.md) steps 1–4 (and 5/6 when done). Keep the outputs; none of these commands prints a secret.

```bash
grafana-platform version; grafana-platform verify; grafana-platform status
```

| Check | Expected | Observed |
|---|---|---|
| `verify` summary | `0 FAIL`; WARNs only for HTTP / deferred parts | |
| Zabbix datasource health | `OK` | |
| `item-map` result | `47 of 47 item(s) mapped`; REVIEW lines confirmed | |
| NOC dashboards | values match Zabbix latest data | |
| ClickHouse datasource health (when enabled) | `OK` | |
| Browser access from a user subnet / blocked from others | allowed / refused | |

Until this record is complete the deployment must be described as **"installer validated in simulation"**, not as "production validated".
