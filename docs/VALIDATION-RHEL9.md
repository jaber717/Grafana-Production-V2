# Validation record — Grafana platform on RHEL 9 (release 1.0.1)

> Historical record of release **1.0.1**, kept unchanged. Release 2.0.0 evidence: [VALIDATION-V2.md](VALIDATION-V2.md).

## Support statement
* **Supported platform: Red Hat Enterprise Linux 9.x**, x86_64. `grafana-platform preflight` accepts any 9.x (subject to the actual dependency checks it performs), and **rejects RHEL 8, RHEL 10, other distributions and other architectures**. No minor version is hard-coded.
* **Tested: RHEL 9.6** (`Red Hat Enterprise Linux release 9.6 (Plow)`, kernel 5.14.0-570.12.1.el9_6). Other RHEL 9.x releases are **supported targets that were not individually validated**; a failing preflight dependency check is the intended signal there.
* AlmaLinux/Rocky/CentOS Stream 9 are accepted only with `PLATFORM_ALLOW_EL_CLONE=yes` (WARN) and were not tested.

## Test environment
| | |
|---|---|
| Machines | disposable Proxmox VMs cloned from a clean RHEL 9.6 baseline for every run (2 vCPU, 3 GiB), RHEL 9.6 DVD repositories, **in-guest egress isolation** (no LAN host reachable; Internet only for the online runs; the offline runs dropped everything but loopback and replies) |
| SELinux / firewalld | Enforcing / active (never modified for the tests) |
| Grafana | grafana-13.2.3-1 (RPM from rpm.grafana.com, key B53AE77B…458545), plugins alexanderzobnin-zabbix-app 6.8.0 and grafana-clickhouse-datasource 4.22.0, Node.js 20.18.2 (AppStream) online / 20.20.2 (bundle) offline; previous release for the upgrade test: grafana-13.2.2-1 |
| Backends | **Zabbix: a TLS mock** answering a dummy credential (`tests/rhel/mock-zabbix.py`) with a synthetic item map — proves deployment and datasource health, **not** NOC panel values. **ClickHouse: the real Akvorado stack** of the companion repository (ClickHouse 26.8.18.2) over verified TLS with a throw-away CA, a dummy read-only password and synthetic NetFlow/IPFIX/sFlow data |
| Credentials | all dummy; all certificates throw-away; no LAB or production system, credential or dataset was used or modified |
| Driver | `tests/rhel/acceptance-grafana.sh` (this repository) run from a workstation; full logs in [acceptance-logs/](acceptance-logs/) |

## Results (the logs are the evidence)
| Run | Machine state | Result | Log |
|---|---|---|---|
| Online, clean RHEL 9.6 | fresh clone, Internet allowed | **66 PASS, 0 FAIL** | `acceptance-logs/grafana-online-rhel96.log` |
| Offline (air-gapped), clean RHEL 9.6 | fresh clone, every packet dropped except loopback/replies, installed from the 321 MB bundle | **53 PASS, 0 FAIL** (the upgrade test is online-only) | `acceptance-logs/grafana-offline-rhel96.log` |

## Acceptance matrix
| Gate | Status | Evidence (section of the log) |
|---|---|---|
| RHEL 9 compatibility: preflight accepts 9.x, rejects 8/10/other | **PASS** (9.6 tested; 8/10 rejection by code review of the OS test, not by a run on those releases) | §0, §1 |
| Clean install on a fresh host | **PASS** online and offline | §1-§2 |
| Idempotent re-run / no unnecessary change | **PASS** (`applied: 0 created, 0 updated, 12 unchanged`) | §2 |
| Configuration deployment: 7 dashboards (original UIDs), 2 folders, 2 datasources, playlist | **PASS** | §4 |
| Application health: both datasources healthy, every ClickHouse panel query of the NetFlow dashboards executes | **PASS** | §4 |
| Security: signed RPM key pinned, version lock, unprivileged service, TLS verified and TLS ≤ 1.1 refused, no literal password, firewalld source rule, no SELinux denial | **PASS** | §3 |
| Network admission (allowed / denied / restored) | **PASS** | §5 |
| Backup (plain and GPG-encrypted, wrong passphrase refused) | **PASS** | §6 |
| Restore after damage | **PASS** | §6 |
| Bare-host disaster recovery (everything deleted, rebuilt from one archive) | **PASS** | §8 |
| Secret rotation (wrong password detected, correct one restored) | **PASS** | §7 |
| Upgrade 13.2.2 → 13.2.3 with data kept | **PASS** (online) | §9 |
| Rollback (state of the pre-upgrade backup restored) | **PASS** (online) | §9 |
| Automatic rollback of a failing upgrade (non-existent package) | **PASS** (online) | §9 |
| Offline installation | **PASS** | offline log |
| Reboot persistence | **PASS** | §10 |
| Release gate (`scripts/release-gate.sh`) | **PASS** | run at release time |
| Real RHEL **9.7+** host | **NOT RUN** — supported target, not individually validated | — |
| NOC panel values against a real Zabbix | **NOT RUN** (needs the production Zabbix; the item map is the mechanism) | — |

## Defects found by these tests and fixed before release
* `rpm -q` text mistaken for an installed version (fresh host reported as "unmanaged"); `env` file copied onto itself on a second run; indirect-variable bug in the CA trust step.
* The sudo `secure_path` hides `/usr/local/bin`: the bundled Node.js was not found.
* A retention pipeline exited under `set -e` (backup finished but the command failed).
* Rollback replaced the database while the RPM scriptlets had restarted Grafana (stale state served): Grafana is now stopped again before the database is replaced; the derived search index is cleared on every restore.
* A trust-store change was not picked up by the running Grafana (restart added).
* An interrupted install was reported as a foreign installation (resume marker added); upgrade steps ignored errors inside an `if` context (explicit checks added).

## Known limitations
See [SECURITY-PRODUCTION.md](SECURITY-PRODUCTION.md): Grafana is not SELinux-confined (no policy ships with RHEL), release assets are not signed, archives made with `--include-secrets` hold credentials unless encrypted. The mock Zabbix does not validate NOC panel content.

## Reproduce
```bash
G=<grafana VM> A=<akvorado VM> SSH_KEY=~/.ssh/key tests/rhel/acceptance-grafana.sh [--offline-bundle <dir>]
```
(see the header of the script; it destroys and rebuilds Grafana on `G`, so use disposable machines only).
