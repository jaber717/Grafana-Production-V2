# Validation record — release 2.1.0 (Grafana-Production-V2)

> **Scope of this evidence.** Everything here ran on a build machine (Ubuntu 24.04, bash 5.2, Python 3.13, Node.js 22 and the bundled 20.20.2)
> **without** the LAB, without the production server, without a real Grafana, Zabbix or ClickHouse, and without a real RHEL host.
> RHEL services, Grafana, Zabbix and ClickHouse were **simulated**. This proves the installer logic and the configuration handling;
> it does **not** prove a production deployment. What remains is listed in [LIVE-VERIFICATION.md](LIVE-VERIFICATION.md).

## Results

| Suite | Command | Result | Raw output |
|---|---|---|---|
| Unit tests (8 from 1.0.1 + 17 new) | `node --test tests/unit/*.test.mjs` | **25 / 25 pass** | [evidence/unit-tests.txt](evidence/unit-tests.txt) |
| Simulated RHEL 9.8 host, fake artifacts (exercises the bundle builder's mirror path incl. repository-metadata lookup and pin-mismatch abort) | `sudo tests/sim/run-sim.sh <1.0.1 checkout>` | **98 / 98 pass**, isolation check pass | [evidence/simulation-fake-artifacts.txt](evidence/simulation-fake-artifacts.txt) |
| Simulated RHEL 9.8 host, **real pinned artifacts** (real plugin archives installed, real bundled Node.js v20.20.2 installed and used; pins unmodified) | `sudo SIM_REAL_BUNDLE=<1.0.1 offline archive> tests/sim/run-sim.sh <1.0.1 checkout>` | **96 / 96 pass**, isolation check pass | [evidence/simulation-real-artifacts.txt](evidence/simulation-real-artifacts.txt) |
| Real artifacts vs. pins; real Grafana RPM signature with the vendored key (`rpmkeys -Kv`) | see file | SHA-256 of RPM, both plugins and Node.js **equal the 2.0 pins**; RPM signature **OK**, key ID `963fa27710458545` | [evidence/real-artifacts.txt](evidence/real-artifacts.txt) |
| shellcheck (warning level) of every shell file | release gate stage 12 | clean | — |
| Release gate (stages 1–12, includes the simulation) | `sudo GATE_V1_CHECKOUT=<1.0.1 checkout> scripts/release-gate.sh` | PASS | [evidence/release-gate.txt](evidence/release-gate.txt) |

## What the simulation does

`tests/sim/run-sim.sh` re-runs itself in a private mount namespace (copies of `/etc`, empty `/usr/local/{bin,sbin}`, `/var/lib`, `/var/backups`) and checks
afterwards that the host's os-release, users/groups and `/usr/local` are unchanged. It then plays an isolated RHEL 9.8 server:

* **Real**: every line of `bin/`, `lib/`, `scripts/`, `tools/`; bash, python3, node, gpg (pinned-key fingerprint), unzip/tar, SHA-256 checks, file
  modes and owners, users/groups, the offline-bundle builder.
* **Simulated** (`tests/sim/fakebin`, `mock-*.mjs`): os-release, SELinux, firewalld, systemd, rpm/dnf (installing the RPM *file* reproduces what the real
  package does: user/group, `/etc/grafana/grafana.ini`, `/var/lib/grafana`), the Grafana HTTP API (only the endpoints the tools call; basic auth with
  the admin password file; **datasource health performs a real Zabbix `user.login` / ClickHouse `/ping`**), Zabbix 7.0 JSON-RPC (production-style host names), ClickHouse `/ping`.
* **No Internet**: `HTTPS_PROXY` points at a closed port.

Scenarios (each line in the evidence files is one assertion):

1. **1.0.1 reproduction** — the unchanged 1.0.1 code: byte-exact `ALLOW_INSECURE_DATASOURCES=yes` → WARN (`30 PASS, 2 WARN, 5 FAIL`);
   indented-with-comment, `YES`, `true`, typographic quotes, trailing non-breaking space, misspelled key, duplicate key → each gives the reported
   pattern **`1 WARN, 6 FAIL`** ([ROOT-CAUSE-V2.md](ROOT-CAUSE-V2.md)).
2. **2.0 parser** — the same variants are normalized to `yes` or rejected with the exact reason (did-you-mean, duplicate line, typographic quote, `$VAR` not expanded).
3. **Reported situation on 2.0** — one-line `init-env`, no secrets, no Internet, no item map: HTTP Zabbix and HTTP Grafana are WARNs, the bundle is found
   automatically, each remaining FAIL carries its fix command ([evidence/preflight-reported-situation-v2.txt](evidence/preflight-reported-situation-v2.txt)).
4. **Secrets** — stored mode 600 root:root from a pipe; never in output or logs; `zabbix-check` fails on a wrong password and passes on the right one.
5. **Install** with NetFlow and NOC deferred — `0 FAIL`; Zabbix datasource over HTTP with a passing live login; ClickHouse datasource, 5 NetFlow
   dashboards, NOC dashboards and the playlist **skipped, not created**; release + bundle deployed; RPM cached for rollback.
6. **Item map** — incomplete without host renames (nothing guessed), complete (47/47) with `--host`, 7 REVIEW lines, only read-only Zabbix methods;
   NOC dashboards deployed carrying production ids only.
7. **ClickHouse later** — `config set` + `secret set` + `apply` creates datasource, 5 dashboards and playlist; health OK.
8. **Idempotency** — second `install`: 0 created, 0 updated; `verify` 0 FAIL; preflight on the installed host needs no package source.
9. **Partial item map** — FAIL with fix when not deferred; deferred = NOC dashboards skipped, nothing created.
10. **No bundle, no Internet** — exactly one package FAIL, explaining the offline bundle.
11. **`sudo ./install.sh` (2.1)** — from a git clone **without** bundle, with an offline archive next to it: archive auto-found, verified, unpacked;
    16 answers (incl. one wrong Zabbix password caught before installing, and 7 router host names for the item map); Zabbix URL completed with
    `/api_jsonrpc.php`; HTTP only after explicit consent; NOC dashboards deployed; ClickHouse skipped without blocking; no secret in any output or log;
    operator screen ≤ 70 lines ([evidence/install-sh-first-run-screen.txt](evidence/install-sh-first-run-screen.txt)). Re-run with Enter and `--yes`: nothing changed.
    `--clickhouse` later adds datasource + 5 NetFlow dashboards + playlist; base Grafana with **no** integration, then `--zabbix`; no package anywhere →
    stops before any change with the one file to copy; unusable archive refused; download with a wrong SHA-256 refused, with the right one installed.
12. **Rollback** — `uninstall` removes package/service/rules/release/link and keeps configuration+secrets+map; reinstall restores the state; `--purge` removes everything but backups.

## Not covered here

TLS listener of the real Grafana, real SELinux/firewalld/systemd/dnf behaviour, the real Grafana 13.2.3 API, the production Zabbix (permissions,
host names, keys, panel values), ClickHouse/Akvorado, `backup`/`restore`/`upgrade`/`rollback` with a real SQLite database (unchanged 1.0.1 code),
and building the bundle from the real download sites (they were unreachable; the published 1.0.1 archive was used instead, see above).
