# Install Grafana on the isolated RHEL 9 production server

Release **2.0.0** of `Grafana-Production-V2`. One command does everything: `grafana-platform`. No configuration file is edited by hand,
no password is typed on a command line, nothing is downloaded on the server.

Values below that are **yours to supply** are written `<like this>`. Nothing here invents a user name, password, subnet or item id.
The addresses are the ones of this deployment: Grafana `10.20.8.27`, Zabbix `http://10.20.8.24:8080`, ClickHouse/Akvorado `10.20.8.28`.

> Status: this procedure is proven on a **simulated** RHEL 9.8 host (`tests/sim/run-sim.sh`, see [docs/VALIDATION-V2.md](docs/VALIDATION-V2.md)).
> It has **not yet been run on the real server**. [docs/LIVE-VERIFICATION.md](docs/LIVE-VERIFICATION.md) lists what only the real server can prove.

---

## 0. Build the offline package (once, on any machine WITH Internet)

Linux, macOS or Windows "Git Bash"; needs `git curl sha256sum tar gzip python3`.

```bash
git clone https://github.com/jaber717/Grafana-Production-V2.git && cd Grafana-Production-V2 && tools/build-offline-bundle.sh dist
```

Already have the published 1.0.1 offline archive (`jaber717/Grafana` release asset `grafana-platform-1.0.1-rhel9-offline.tar.gz`)? 2.0.0 pins the
same Grafana RPM, plugins and Node.js, so nothing else needs downloading — its artifacts are reused and re-verified against the 2.0 pins:

```bash
tools/build-offline-bundle.sh --from-bundle grafana-platform-1.0.1-rhel9-offline.tar.gz dist
```

Result: `dist/grafana-platform-2.0.0-rhel9-offline.tar.gz` and its `.sha256`. Every download is checked against the SHA-256
pinned in this repository; a mismatch stops the build. Copy **both files** to `/root` on the server (approved media / SCP).

## 1. Prepare the files (server, as root)

```bash
cd /root && sha256sum -c grafana-platform-2.0.0-rhel9-offline.tar.gz.sha256 && tar xzf grafana-platform-2.0.0-rhel9-offline.tar.gz && cd grafana-platform-2.0.0
```

All following commands run **from this directory** until step 4. The offline bundle inside it is found automatically.

## 2. Create the configuration (one line)

```bash
bin/grafana-platform init-env GRAFANA_DOMAIN=10.20.8.27 GRAFANA_PROTOCOL=http GRAFANA_ALLOW_INSECURE_HTTP=yes "GRAFANA_ALLOWED_CIDRS=<user and NOC subnets, space separated>" ZABBIX_URL=http://10.20.8.24:8080/api_jsonrpc.php ZABBIX_USER=<read-only Zabbix user> ALLOW_INSECURE_DATASOURCES=yes CLICKHOUSE_ENABLED=no ALLOW_NOC_WITHOUT_ITEM_MAP=yes
```

What this sets: Grafana on plain HTTP (temporary, because TLS is not ready), the Zabbix datasource over HTTP (explicitly allowed),
NetFlow/ClickHouse **deferred** (nothing ClickHouse-related is created yet), and the two NOC dashboards **deferred** until the item map exists
(step 5). Every exception is reported as a WARN on each `preflight`/`verify`, so it cannot be forgotten.
Check what was written: `bin/grafana-platform config show`. Change one value: `bin/grafana-platform config set KEY=VALUE`.

## 3. Create the secrets (prompted twice, never echoed, never logged)

```bash
bin/grafana-platform secret set zabbix-password
```
```bash
bin/grafana-platform secret set admin-password
```
```bash
bin/grafana-platform zabbix-check
```

`zabbix-password` is the password of `<read-only Zabbix user>`. `admin-password` becomes the initial Grafana `admin` password (skip it and
the installer generates one into `/etc/grafana-platform/secrets/admin-password`). `zabbix-check` logs in to Zabbix once with that user,
counts the hosts it can see and logs out — a wrong password or a user without host permissions is found **before** installing.

## 4. Install Grafana

```bash
bin/grafana-platform preflight && bin/grafana-platform install
```

`preflight` changes nothing; each FAIL is followed by a `-> fix:` line with the exact command. Expected WARNs: Grafana on HTTP, Zabbix on HTTP,
NetFlow deferred, NOC dashboards deferred (and possibly "shares the root filesystem"). `install` ends with a full verification.
Open `http://10.20.8.27:3000` as `admin`. From now on the command is simply `grafana-platform` (any directory).

## 5. Zabbix NOC dashboards (item map)

The two NOC dashboards address Zabbix items by id; ids differ per Zabbix server. Build the map from your Zabbix (read-only):

```bash
grafana-platform item-map
```

* **Complete** → deploy them: `grafana-platform config set ALLOW_NOC_WITHOUT_ITEM_MAP=no && grafana-platform apply`
* **Incomplete** → the output lists every unmapped item; nothing is guessed. Usual cause: the production host names differ from the LAB
  names `SITE-A SITE-B STC MOBILY INT-CORE SAIX-A SAIX-B`. Tell the tool the real names, then deploy as above:
  `grafana-platform item-map --host SITE-A=<name>,SITE-B=<name>,STC=<name>,MOBILY=<name>,INT-CORE=<name>,SAIX-A=<name>,SAIX-B=<name>`
  To look at a host: `grafana-platform item-map --search <part of host name>`. To set one id you verified in Zabbix: `grafana-platform item-map --set <lab id>=<item id>`.
* Seven "SNMP uptime" items are resolved through a list of standard template keys; they are printed under **REVIEW** — confirm in Zabbix that the
  chosen item is the router's uptime.

## 6. ClickHouse / Akvorado (when that server is ready)

```bash
grafana-platform config set CLICKHOUSE_ENABLED=yes CLICKHOUSE_HOST=10.20.8.28 CLICKHOUSE_PORT=<8123 for http, 8443 for https> CLICKHOUSE_SECURE=<false|true> CLICKHOUSE_USER=<ClickHouse read-only user>
```
```bash
grafana-platform secret set clickhouse-password
```
```bash
grafana-platform apply
```

This creates the ClickHouse datasource, the five NetFlow dashboards and the NetFlow playlist, then verifies them (datasource health must be OK).
`CLICKHOUSE_SECURE=false` is accepted only because `ALLOW_INSECURE_DATASOURCES=yes` is already set.

## 7. Verify (any time)

```bash
grafana-platform verify
```
```bash
grafana-platform status
```

`verify` exits non-zero on any FAIL: service, port, firewall source rules, package signature, file modes, plugins, datasources (+ live health),
dashboards, playlist. Logs: `/var/log/grafana-platform/`, `journalctl -u grafana-server`.

---

### When TLS is ready (later)

```bash
grafana-platform config set GRAFANA_PROTOCOL=https GRAFANA_ALLOW_INSECURE_HTTP=no GRAFANA_DOMAIN=<name in the certificate> GRAFANA_TLS_CERT_FILE=<cert.pem> GRAFANA_TLS_KEY_FILE=<key.pem> GRAFANA_TLS_CA_FILE=<ca.pem or empty> && grafana-platform install
```
Zabbix over HTTPS: `grafana-platform config set ZABBIX_URL=https://<zabbix>/api_jsonrpc.php ZABBIX_CA_FILE=<ca.pem> ALLOW_INSECURE_DATASOURCES=no && grafana-platform install`.

### Something failed?

| Symptom | Command |
|---|---|
| Any preflight FAIL | run the `-> fix:` line printed under it, then `preflight` again |
| "unknown setting" / "must be yes or no" | the message names the line and the correct key; fix with `config set` |
| Zabbix datasource health ERROR | `grafana-platform zabbix-check` (password/permissions), then `grafana-platform rotate-secrets` after `secret set zabbix-password` |
| Want the previous state back | [docs/ROLLBACK.md](docs/ROLLBACK.md) |

Migration from the original repository (`jaber717/Grafana`, release 1.x): [docs/MIGRATION-FROM-V1.md](docs/MIGRATION-FROM-V1.md).
Why the 1.x installation failed: [docs/ROOT-CAUSE-V2.md](docs/ROOT-CAUSE-V2.md).
