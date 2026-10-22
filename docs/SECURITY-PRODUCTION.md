# Security model — production (RHEL 9)

## Controls the platform sets up and then checks (`grafana-platform verify`)

| Area | Control | Check |
|---|---|---|
| Package supply | official RPM from `rpm.grafana.com`; repository key **vendored and fingerprint-pinned**; `gpgcheck=1`, `repo_gpgcheck=1`; `includepkgs=grafana`; version-locked | signature of the installed RPM, lock present |
| Plugins | pinned version **and SHA-256** (online and offline); plugin admin UI disabled | plugin versions |
| SELinux | host must be **Enforcing** (persistent); the installer refuses to continue otherwise; files labelled with `restorecon`; AVC denials since boot are a FAIL | `getenforce`, `ausearch -m avc` |
| firewalld | must be active; the Grafana port is opened **only by rich rules for `GRAFANA_ALLOWED_CIDRS`**, never as a plain port; stale rules for the port are removed | rich rules, no open port |
| Transport | HTTPS by default (TLS ≥ 1.2, HSTS, secure cookies); the certificate is verified in preflight (expiry, key match, SAN, chain); verification also proves TLS 1.0/1.1 are refused | `curl --tls-max 1.1` must fail |
| Outbound TLS | Zabbix and ClickHouse connections verify certificates against the system trust store (private CAs are installed into it); `ZABBIX_TLS_SKIP_VERIFY=true`, an `http://` Zabbix URL and `CLICKHOUSE_SECURE=false` are refused unless `ALLOW_INSECURE_DATASOURCES=yes` (default `no`; then WARN on every preflight/verify). Plain-HTTP Grafana needs `GRAFANA_ALLOW_INSECURE_HTTP=yes` (default `no`, WARN). Preflight prints the exceptions in effect | preflight, datasource health |
| Secrets | files under `/etc/grafana-platform/secrets` (root, 0600; admin password and secret key 0640 root:grafana because Grafana reads them via `$__file{}`); no secret in `grafana.ini`, Git, process arguments or logs; generated values are never printed | modes and owners, no literal password in `grafana.ini` |
| Least privilege | Grafana runs as the unprivileged `grafana` user from the RPM unit; `grafana-platform` is root only; datasource accounts are read-only (Zabbix API user, ClickHouse `grafana_ro` with `readonly=2`, row/memory/time limits and a source-IP restriction) | process owner, file modes |
| Hardening | sign-up disabled, anonymous disabled, gravatar off, analytics/update checks/news off, embedding off, `X-Content-Type-Options`, `X-XSS-Protection` | rendered `grafana.ini` |
| Auditing | every install/upgrade/restore/rollback logs to `/var/log/grafana-platform/` | |

## Known limitations (stated, not hidden)

1. **Grafana is not SELinux-confined.** RHEL 9 ships no policy module for the Grafana Labs RPM; the process runs as `unconfined_service_t` with SELinux in Enforcing mode (other services stay confined, no AVC denials were observed).
   Writing a custom module is deliberately not done here (an unreviewed policy is a larger risk than the documented gap). Compensating controls: unprivileged user, source-restricted port, TLS, read-only datasource accounts.
2. The signing key expires on **2027-08-22** (`GRAFANA_RPM_GPG_EXPIRES`); `preflight` warns 90 days before. Refresh `vendor/rpm/RPM-GPG-KEY-grafana` from a verified source and update the fingerprint pin when Grafana Labs rotates it.
3. TLS private keys are stored unencrypted on disk (`/etc/grafana/tls/grafana.key`, 0640 `root:grafana`), as for any service that restarts unattended.
4. The initial admin password is a file on disk; it only seeds the first start. Use SSO/LDAP (Grafana configuration) for people if your policy requires; this release does not configure an identity provider.
5. The backup archive is not encrypted unless `BACKUP_GPG_PASSPHRASE_FILE` is set; archives made with `--include-secrets` hold credentials.
6. The Node.js content tools talk to Grafana over HTTPS on the loopback with the system trust store (no `NODE_TLS_REJECT_UNAUTHORIZED=0` anywhere).

## Credential handling rules for the operator
* Never pass passwords on a command line; the platform reads them from files and from the environment of the child process only.
* Rotate: admin password (UI); `zabbix-password` / `clickhouse-password` — change the file, then run `grafana-platform rotate-secrets` (writes the new value into the datasource and verifies it); `secret-key` is **not** rotated casually: changing it makes every stored datasource password undecryptable (recover with `rotate-secrets`, which re-encrypts them with the new key).
* The platform never creates accounts in Zabbix or ClickHouse and never uses LAB credentials.

## Reporting
Security issues in this repository: see [../SECURITY.md](../SECURITY.md).
