# Grafana — NOC / WAN / NetFlow dashboards

Dashboards-as-code **and** a production installer for Grafana OSS **13.2.3** (Zabbix app 6.8.0, ClickHouse datasource 4.22.0):
seven dashboards (UIDs preserved), two folders, two datasources, one playlist.

> **Grafana-Production-V2 — release 2.0.0.** Independent continuation of `jaber717/Grafana` 1.0.1 (that repository is unchanged).
> Same dashboards, UIDs, datasources and pinned versions; corrected installer for the isolated RHEL 9 production server.
> **Install: [INSTALL.md](INSTALL.md)** · why 1.0.1 failed: [docs/ROOT-CAUSE-V2.md](docs/ROOT-CAUSE-V2.md) · migration: [docs/MIGRATION-FROM-V1.md](docs/MIGRATION-FROM-V1.md) ·
> rollback: [docs/ROLLBACK.md](docs/ROLLBACK.md) · evidence: [docs/VALIDATION-V2.md](docs/VALIDATION-V2.md) (**simulated host only**) · still to prove live: [docs/LIVE-VERIFICATION.md](docs/LIVE-VERIFICATION.md)

| | |
|---|---|
| **Production target** | **RHEL 9.x**, native signed RPM + systemd, SELinux Enforcing, firewalld, secrets in files — `bin/grafana-platform` · [INSTALL.md](INSTALL.md) · reference: [docs/PRODUCTION-RHEL9.md](docs/PRODUCTION-RHEL9.md) |
| **LAB (unchanged)** | grafana-01, Debian 12 LXC — `lab/scripts/*-lxc.sh`, API tools `scripts/apply.sh`, `verify.sh` · [docs/LAB-VS-PRODUCTION.md](docs/LAB-VS-PRODUCTION.md) |
| **Evidence** | 2.0: [docs/VALIDATION-V2.md](docs/VALIDATION-V2.md) (unit tests + simulated RHEL 9.8 host). 1.0.1: [docs/VALIDATION-RHEL9.md](docs/VALIDATION-RHEL9.md) (RHEL 9.6 acceptance as recorded by that release) |

> **2.0.0 has not yet been run on a real RHEL host.** It was built and tested while the LAB was unavailable, against a simulated RHEL 9.8 host.

## Production in short (details and placeholders: [INSTALL.md](INSTALL.md))

```bash
tools/build-offline-bundle.sh dist                                   # once, on a machine with Internet -> copy the archive to the server
tar xzf grafana-platform-2.0.0-rhel9-offline.tar.gz && cd grafana-platform-2.0.0
bin/grafana-platform init-env GRAFANA_DOMAIN=… ZABBIX_URL=… ZABBIX_USER=… …     # configuration in one line, validated
bin/grafana-platform secret set zabbix-password                      # prompted, never echoed
bin/grafana-platform preflight && bin/grafana-platform install       # every FAIL prints its fix
grafana-platform item-map && grafana-platform apply                  # NOC dashboards; ClickHouse later: INSTALL.md step 6
```

Afterwards: `grafana-platform verify | status | apply | backup | restore | upgrade | rollback | rotate-secrets | uninstall`.

## Repository map

| Path | Content |
|---|---|
| `bin/grafana-platform`, `lib/` | the production control script (setup: init-env, config, secret, zabbix-check, item-map; lifecycle: preflight, install, apply, verify, status, backup, restore, upgrade, rollback, uninstall); `lib/envparse.py` = the one environment-file parser |
| `env/production.env.example`, `env/lab.env.example` | every environment-specific setting; no secrets |
| `dashboards/netflow/` · `dashboards/noc/` | 5 NetFlow dashboards (ClickHouse/Akvorado) and 2 NOC dashboards (Zabbix) |
| `config/` | folders, playlist, `datasources.tmpl.json` (rendered from the environment), the captured LAB `datasources.json`, Zabbix item descriptors |
| `vendor/rpm/RPM-GPG-KEY-grafana` | Grafana Labs signing key, fingerprint pinned in `VERSIONS.env` |
| `plugins/plugins.txt`, `VERSIONS.env` | pinned versions and SHA-256 values |
| `scripts/*.mjs`, `tools/` | content tools (apply/verify/backup/restore through the Grafana API), Zabbix item-map builder, offline bundle builder, panel smoke test |
| `systemd/` | daily backup timer |
| `tests/unit`, `tests/sim`, `tests/rhel` | unit tests; simulated RHEL 9.8 host (mock systemd/rpm/dnf/firewalld, mock Grafana/Zabbix/ClickHouse) — `sudo tests/sim/run-sim.sh`; 1.x acceptance helpers |
| `lab/` | Debian/LXC LAB scripts (not used on RHEL) |
| `docs/` | production guide, backup/restore, offline, security, LAB-vs-production, item map, GitHub access, validation, + the original LAB documents |

## Design rules
* **Idempotent and fail-safe**: every step checks before it changes; `preflight` changes nothing; an interrupted install resumes; a failed upgrade rolls back by itself.
* **No secrets in Git**, no secrets on command lines, no silently disabled certificate verification.
* **Dashboards are never rewritten by the platform**: the Zabbix item ids of the NOC dashboards are mapped in memory at deployment ([docs/ZABBIX-ITEM-MAP.md](docs/ZABBIX-ITEM-MAP.md)).
* The LAB (`grafana-01`) is not touched by this release; its documents stay in `docs/` (`installation.md`, `live-inventory.md`, …).

## Release discipline
`VERSION`, `CHANGELOG.md`, `scripts/release-gate.sh` (must PASS), annotated tags `vX.Y.Z`, release assets with SHA-256 files; `docs/VALIDATION-RHEL9.md` states what was verified, on what, and what is still open.
