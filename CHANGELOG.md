# Changelog

## [2.0.0] - 2026-10-22

First release of **Grafana-Production-V2**, an independent continuation of `jaber717/Grafana` 1.0.1 (commit `7c5b9f9`; that repository is not modified).
**No change to any dashboard, dashboard/folder/datasource UID, datasource template, plugin or Grafana version pin.** Root causes: [docs/ROOT-CAUSE-V2.md](docs/ROOT-CAUSE-V2.md).

### Fixed
* `ALLOW_INSECURE_DATASOURCES=yes` not honored: one strict parser (`lib/envparse.py`) for bash and Node. 1.x silently dropped indented lines containing `#`, compared case-sensitively, ignored unknown/misspelled keys and accepted duplicates; 2.0 accepts yes/no/true/false/on/off/1/0 in any case and turns every ambiguity into an error naming the line and the fix. The key is now in the template.
* Offline installation: `PACKAGE_SOURCE=auto` (default) uses `<release>/bundle` automatically; `BUNDLE_DIR` defaults to it; the bundle is deployed with the release and the RPM cached for rollbacks; package sources are checked only when something must be installed; one FAIL instead of two.
* Item map: the 7 previously unresolved descriptors (SNMP uptime behind the "UP" signal) resolve through standard template keys (REVIEW output); production host names via `--host`; partial maps can be deferred.
* `install` aborted when `clickhouse-password` was absent; Node.js on RHEL 9 (old default stream installed before the module stream was selected); "read-only" preflight created `/var/lib/grafana`; playlist referenced undeployed dashboards.

### Added
* Commands: `init-env` (configuration in one line), `config set|show|check|keys` (validated edits, previous file kept), `secret set|status` (prompted, never echoed), `zabbix-check`, `item-map`, `apply`, `uninstall [--purge]`.
* Deferral without broken objects: `CLICKHOUSE_ENABLED=no` (no ClickHouse datasource, NetFlow dashboards or playlist, no ClickHouse secret); `ALLOW_NOC_WITHOUT_ITEM_MAP=yes` also for incomplete maps.
* Every preflight FAIL is followed by a `-> fix:` line with the exact command; read-only reachability probes for Zabbix (`apiinfo.version`) and ClickHouse (`/ping`).
* `tools/zabbix-item-map.mjs`: user/password login with the datasource credentials (session per Zabbix version, logout), `--host`, `--set`, `--merge`, `--search`, `--check`, request timeouts.
* Offline builder: finds the RPM through the repository metadata when it is not at `/Packages/`; overridable download bases (tests).
* Tests: `tests/unit/v2-*.test.mjs` (parser parity bash/Node, deferral, item-map tool), `tests/sim/run-sim.sh` (simulated RHEL 9.8 host, executes INSTALL.md verbatim, reproduces the 1.0.1 failure); release gate runs shellcheck and the simulation.
* Documents: `INSTALL.md`, `docs/ROOT-CAUSE-V2.md`, `docs/MIGRATION-FROM-V1.md`, `docs/ROLLBACK.md`, `docs/LIVE-VERIFICATION.md`, `docs/VALIDATION-V2.md`.

### Known limitations
Not yet run on a real RHEL host, real Grafana, the production Zabbix or ClickHouse; the offline bundle was not built against the real download sites (they were unreachable from the build environment). See [docs/LIVE-VERIFICATION.md](docs/LIVE-VERIFICATION.md).

## [1.0.1] - 2026-10-11

RHEL 9 production platform. **No change to any dashboard, UID, datasource definition or plugin version** (a unit test proves the LAB environment renders the captured LAB datasources byte-for-byte).

### Added
* `bin/grafana-platform` (+ `lib/`): `preflight`, `install`, `verify`, `status`, `backup`, `restore` (incl. `--bootstrap` for bare-host recovery), `upgrade` (backup first, automatic rollback), `rollback`, `rotate-secrets`. Idempotent, PASS/WARN/FAIL.
* Native Grafana RPM install: vendored signing key with pinned fingerprint, `gpgcheck`/`repo_gpgcheck`, `includepkgs`, `dnf versionlock`; plugins pinned by SHA-256; Node.js content tools.
* Environment separation: `env/production.env.example`, `env/lab.env.example`, `config/datasources.tmpl.json`; secrets only in files; HTTPS listener, firewalld source rules, SELinux/firewalld checks.
* Zabbix item map for the NOC dashboards (`config/zabbix-item-descriptors.json`, `tools/zabbix-item-map.mjs`).
* Offline bundle builder (`tools/build-offline-bundle.sh`), daily backup timer, `tools/panel-smoke.mjs`.
* Documents: production guide, backup/restore, offline, security, LAB-vs-production, item map, GitHub access, RHEL validation. Release gate extended (unit tests, template and pin checks).

### Changed
* Debian/LXC host scripts moved to `lab/` (unchanged apart from paths).
* `GRAFANA_VERSION_OVERRIDE`-aware version checks in `scripts/verify.mjs`.

### Known limitations
See [docs/VALIDATION-RHEL9.md](docs/VALIDATION-RHEL9.md): accepted on RHEL 9.6 test machines, **RHEL 9 run pending**; Grafana is not SELinux-confined (no policy ships with RHEL); NOC panel *values* need a production Zabbix to be validated; release assets are not signed.

## [1.0.0] - 2026-10-10

First published release. Content = the **running** grafana-01 (Grafana OSS 13.2.3), captured through its API.

### Captured (unchanged behaviour)
* 7 dashboards (5 NetFlow / ClickHouse, 2 NOC / Zabbix) with their uids, variables, queries and panels; folders `NetFlow` and `NOC`; datasources `zabbix-lab` and `netflow-clickhouse` (definitions only); playlist `NetFlow NOC Rotation`; plugin pins (Zabbix app 6.8.0, ClickHouse 4.22.0).
* `scripts/verify.mjs` against the live instance: PASS (19 checks). `scripts/apply.mjs --dry-run`: 12 unchanged.

### Added
* API tooling: `apply` (idempotent, duplicate-safe, `--dry-run`, `--rotate-secrets`), `verify` (read-only), `backup`, `restore` (manifest-verified, dry-run default), `tools/export-live.mjs`, `tools/inventory.mjs`.
* Host tooling for the Debian 12 LXC: `install-lxc.sh`, `upgrade-lxc.sh`, `backup-lxc.sh`, `rollback-lxc.sh`, `verify-lxc.sh` (**not yet executed**).
* NetFlow dashboard generator (`tools/netflow`) with a test proving it reproduces the committed dashboards.
* Optional file provisioning (clean installs only), `scripts/release-gate.sh`, `tests/clean-room-local.sh` (13 checks against a throw-away Grafana), documentation.

### Known gaps
See `docs/live-inventory.md` findings G1-G7 and `docs/validation.md` (LXC scripts and clean-room Debian install: PENDING).
