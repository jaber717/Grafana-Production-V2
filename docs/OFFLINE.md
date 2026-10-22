# Offline (air-gapped) installation

For a RHEL 9 server with **no Internet access**. "Offline" means the *Grafana platform* needs nothing from the Internet; the server must still have the
RHEL BaseOS and AppStream repositories (Satellite, a local mirror, or the RHEL 9 installation ISO mounted as a repository) because the prerequisites
(`unzip`, `sqlite`, `xz`, `gnupg2`, `python3-dnf-plugin-versionlock`, `policycoreutils-python-utils`) come from them. `preflight` checks each one.

## What the bundle contains

One archive: `grafana-platform-<version>-rhel9-offline.tar.gz` (+ `.sha256`):

| Path | Content | Integrity |
|---|---|---|
| `grafana-platform-<version>/` | the complete release (scripts, dashboards, templates, docs) | `git ls-files` of the commit it was built from |
| `bundle/rpm/grafana-13.2.3-1.x86_64.rpm` | the official signed Grafana RPM | SHA-256 pinned in `VERSIONS.env` at build time **and** vendor signature checked on the server with the pinned key |
| `bundle/plugins/*.zip` | the two pinned plugin archives | SHA-256 pinned in `plugins/plugins.txt`, checked again before extraction |
| `bundle/node/node-v20.20.2-linux-x64.tar.xz` | Node.js for the content tools (used if the host has no Node.js ≥ 18) | SHA-256 pinned in `VERSIONS.env` |
| `bundle/SHA256SUMS`, `bundle/MANIFEST.txt` | checksums of every file / manifest | `preflight` runs `sha256sum -c` |

## Build it (any machine with Internet; Linux, macOS or Windows Git Bash; no root, no RHEL)

```bash
tools/build-offline-bundle.sh dist
```
Needs `bash curl sha256sum tar gzip python3`. A mismatch against any pinned SHA-256 aborts the build. If the RPM is not at the repository's
`/Packages/` path, the builder looks up the pinned version in the repository metadata.

## Install it

[INSTALL.md](../INSTALL.md) steps 1–4. Extract the archive and run `bin/grafana-platform` from the extracted directory: with the default
`PACKAGE_SOURCE=auto` the `bundle/` next to the release is used automatically — no `BUNDLE_DIR` to set. `install` copies the release **with** its
bundle to `/opt/grafana-platform/releases/<version>` and keeps the RPM in `/var/backups/grafana-platform/rpm` for rollbacks, so the extracted
directory may be deleted afterwards. Upgrades: bring the next release's bundle, extract, `bin/grafana-platform upgrade`.
