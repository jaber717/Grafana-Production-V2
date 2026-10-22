# Rollback procedures (release 2.0)

Every procedure below starts with a backup or keeps one. Nothing here touches Zabbix or ClickHouse (Grafana only reads them).

## 1. Undo a configuration change

Every `grafana-platform config set` keeps the previous file next to it:

```bash
mv /etc/grafana-platform/platform.env.previous /etc/grafana-platform/platform.env && grafana-platform install
```

(`install` on an installed host only re-converges: it changes nothing that already matches.)

## 2. Remove the installation (back to "no Grafana on this host")

Safety backup first (when a database exists), then service, package, version lock, firewall rules, timer, release and command link are removed.
**Kept**: `/etc/grafana-platform` (configuration, secrets, item map), `/var/lib/grafana` (database), `/etc/grafana`, all backups.

```bash
grafana-platform uninstall --yes
```

Reinstall later from the unpacked release — same configuration, same data, no questions:

```bash
cd /root/grafana-platform-2.0.0 && bin/grafana-platform install
```

Complete removal including configuration, secrets and the Grafana database (backups in `/var/backups/grafana-platform` are still kept):

```bash
grafana-platform uninstall --yes --purge
```

## 3. Go back to the original repository (`jaber717/Grafana`, 1.x)

Release 1.0.1 never completed an installation on this server, so there is normally nothing of 1.x to restore. If 2.0 was installed and 1.x tooling
is wanted instead: `grafana-platform uninstall --yes` (keeps data and configuration), then install 1.x by its own documentation. 1.x reads the same
`/etc/grafana-platform` layout; note that 1.x silently ignores the 2.0-only settings (`CLICKHOUSE_ENABLED`, `PACKAGE_SOURCE=auto`) and then
requires the ClickHouse secret, an online repository or a hand-set `BUNDLE_DIR`, and a complete item map — the reasons it failed before.

## 4. Grafana version / content rollback (unchanged from 1.x)

| Situation | Command |
|---|---|
| a `grafana-platform upgrade` went wrong (it already rolls back automatically on failure) | `grafana-platform rollback --yes` |
| return to any backup archive | `grafana-platform restore /var/backups/grafana-platform/<archive> --yes` (takes a safety backup first) |
| take a backup now | `grafana-platform backup` (add `--include-secrets` only if the archive is protected like a credential) |

Restoring needs the original `secret-key` (it encrypts the datasource passwords inside the database): keep `/etc/grafana-platform/secrets/secret-key`
with your backups — see [BACKUP-RESTORE.md](BACKUP-RESTORE.md).

## 5. What was proven, and how

`uninstall`, re-`install` with the kept state and `uninstall --purge` are exercised by `tests/sim/run-sim.sh` on the **simulated** host
([VALIDATION-V2.md](VALIDATION-V2.md)). `backup`/`restore`/`upgrade`/`rollback` are the 1.0.1 code paths (validated by the 1.x acceptance on RHEL 9.6,
[VALIDATION-RHEL9.md](VALIDATION-RHEL9.md)); 2.0 did not change them except for the package-source variable. None of this has run on the production host yet
([LIVE-VERIFICATION.md](LIVE-VERIFICATION.md)).
