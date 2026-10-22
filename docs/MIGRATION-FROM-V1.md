# Migration from the original repository (`jaber717/Grafana`, release 1.x)

`Grafana-Production-V2` (release 2.0.0) is an independent continuation of `jaber717/Grafana` at commit `7c5b9f9` (tag `v1.0.1`). The original
repository is not modified by this release and keeps working on its own. Dashboards, datasource UIDs (`zabbix-lab`, `netflow-clickhouse`),
folder UIDs, the playlist, pinned Grafana/plugin versions and the RPM signing-key pin are **identical**; only the installer, the
configuration handling, the item-map tool, the item descriptors (7 uptime items) and the documentation changed.

## Which case are you in?

```bash
test -f /etc/grafana-platform/release.json && echo "MANAGED 1.x install exists" || { rpm -q grafana >/dev/null && echo "foreign Grafana package" || echo "no Grafana installed"; }
```

### A. No Grafana installed (the reported situation: 1.x stopped at preflight, nothing was changed)

Nothing to migrate. Follow [INSTALL.md](../INSTALL.md) from step 1. The 1.x checkout in `/root/Grafana` is not used any more; leave it or delete it.
Your 1.x environment file can be reused instead of step 2:

```bash
bin/grafana-platform config check --env-file /root/grafana.env
```

`check` names every line 2.0 does not accept (with the correct key). Typical edits, one line each:

```bash
bin/grafana-platform config set PACKAGE_SOURCE=auto BUNDLE_DIR= CLICKHOUSE_ENABLED=no ALLOW_NOC_WITHOUT_ITEM_MAP=yes ALLOW_INSECURE_DATASOURCES=yes --env-file /root/grafana.env
```

Then continue with steps 3–4 adding `--env-file /root/grafana.env` to `preflight` and `install` (after installation it is copied to
`/etc/grafana-platform/platform.env` and no option is needed any more). Secret files that already exist in `/etc/grafana-platform/secrets/` are used as they are.

### B. A managed 1.x installation exists

2.0 reads the 1.x state (`/etc/grafana-platform/{platform.env,release.json,secrets/,zabbix-item-map.json}`) unchanged; the Grafana package and
plugin versions are the same, so no package changes. From the unpacked 2.0 release:

```bash
bin/grafana-platform config check && bin/grafana-platform backup && bin/grafana-platform install
```

`install` on a managed host re-converges: it re-renders `grafana.ini` (only its header line changes, which restarts Grafana once), deploys release 2.0.0 to
`/opt/grafana-platform/releases/2.0.0`, points `/opt/grafana-platform/current` and `/usr/local/sbin/grafana-platform` at it, and re-applies content
(normally "unchanged"). The 1.x release directory stays in `/opt/grafana-platform/releases/1.0.1`.

### C. A Grafana not installed by grafana-platform

Preflight refuses to touch it (CONFLICT), exactly as in 1.x. Remove it deliberately first, only if it holds nothing you need.

## Configuration differences

| 1.x | 2.0 |
|---|---|
| unknown / misspelled keys silently ignored; duplicates: last wins | error with line number and the correct key |
| `ALLOW_INSECURE_DATASOURCES` only `yes` (lower case) | yes/no, true/false, on/off, 1/0, any case; documented in the template |
| indented line containing `#` silently dropped | parsed normally |
| `PACKAGE_SOURCE=repo` default; `BUNDLE_DIR` must be set by hand | `PACKAGE_SOURCE=auto` default; `BUNDLE_DIR` defaults to `<release>/bundle` |
| ClickHouse always required | `CLICKHOUSE_ENABLED=no` defers NetFlow completely |
| partial item map refused even with `ALLOW_NOC_WITHOUT_ITEM_MAP=yes` | missing or partial map + flag = NOC dashboards deferred |
| secrets created by hand | `grafana-platform secret set <name>` |
| item map needs a Zabbix API token | `grafana-platform item-map` uses `ZABBIX_USER` + the `zabbix-password` secret (token still possible when running the tool directly) |
| `CLICKHOUSE_PORT` required | empty = 8443 with TLS, 8123 without |
| `UPGRADE_AUTO_ROLLBACK` could also be given as a shell variable | settings come only from the environment file (`config set UPGRADE_AUTO_ROLLBACK=no`); shell variables are ignored, so a stray exported value can no longer change behaviour |

New commands: `init-env`, `config set|show|check|keys`, `secret set|status`, `zabbix-check`, `item-map`, `apply`, `uninstall`.
Unchanged commands: `preflight`, `install`, `verify`, `status`, `backup`, `restore`, `upgrade`, `rollback`, `rotate-secrets`, `version`.

## Going back to 1.x

See [ROLLBACK.md](ROLLBACK.md) §3.
