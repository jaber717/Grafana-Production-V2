# Install Grafana — one command

```bash
sudo ./install.sh
```

Run it from the release directory (a `git clone` of this repository, or an extracted offline archive). It asks a few questions,
then does everything: configuration file, secrets, Grafana package, plugins, firewall, service, datasources, dashboards, verification.
Nothing has to be edited by hand. Re-running it is safe: Enter keeps the saved answers and nothing that already matches is changed.

> Status: tested end to end on a **simulated** RHEL 9.8 host ([docs/VALIDATION-V2.md](docs/VALIDATION-V2.md)); **not yet verified on the real server**
> ([docs/LIVE-VERIFICATION.md](docs/LIVE-VERIFICATION.md)).

## Getting the files onto the server — pick the line that fits

| Server can reach GitHub | Server is isolated |
|---|---|
| `git clone https://github.com/jaber717/Grafana-Production-V2.git && sudo Grafana-Production-V2/install.sh` (private repository: needs your GitHub credentials once) | copy **one file** — the offline archive — then: `tar xzf grafana-platform-2.1.0-rhel9-offline.tar.gz && sudo grafana-platform-2.1.0/install.sh` |

The Grafana RPM, plugins and Node.js are found **automatically**, in this order: `bundle/` next to `install.sh` → any
`grafana-platform-*-rhel9-offline.tar.gz` next to the release directory, in it, or in `/root` → rpm.grafana.com → a one-time download of the
pinned packages from GitHub in small pieces (the `packages` branch, see [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)), then the single
pinned offline archive (the published `jaber717/Grafana` 1.0.1 asset, identical pins). Every file is checked against the SHA-256 values pinned in this
release before anything is installed. You do **not** build a bundle.
**Production VM (through FortiProxy), one command** — packages come from GitHub in small pieces ([docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)):

```bash
curl -fsSL -x http://172.20.129.10:8080 https://codeload.github.com/jaber717/Grafana-Production-V2/tar.gz/refs/heads/main | tar xz -C /root && sudo GP_PROXY=http://172.20.129.10:8080 /root/Grafana-Production-V2-main/install.sh
```

**Behind an HTTP proxy** (e.g. a Fortinet explicit proxy): pass it once, e.g. `sudo GP_PROXY=http://172.20.129.10:8080 ./install.sh`.
It is used only for that one GitHub download (also taken from `https_proxy` or `proxy=` in `/etc/dnf/dnf.conf`); Grafana, Zabbix and ClickHouse
connections never go through it. If the proxy re-signs TLS, the download continues with a WARN — the file is still accepted only if its SHA-256 equals the pin.
Already have `grafana-platform-1.0.1-rhel9-offline.tar.gz`? Put it next to the cloned directory (or in `/root`): it is accepted as is.

## The questions (Enter = the value in brackets)

| # | Question | Your answer for this deployment |
|---|---|---|
| 1 | Address users will open | `10.20.8.27` (detected) |
| 2 | Allowed networks (firewall sources) | your user/NOC subnets, e.g. the detected one |
| 3 | Protocol, type `http` or `https` | `http` (explicit choice; https asks for the certificate and key files) |
| 4 | Connect Zabbix now? | Enter = yes → URL `http://10.20.8.24:8080` (`/api_jsonrpc.php` is added), confirm plain HTTP with `y`, read-only user, password |
| 5 | Connect ClickHouse now? | Enter = no (later: `sudo grafana-platform setup --clickhouse`) |
| 6 | Grafana `admin` password | type one, or Enter to generate |

Passwords are typed twice, never shown, stored in `/etc/grafana-platform/secrets/` (mode 600) — never on a command line, in Git or in a log.
The Zabbix login is **tested before installing**; a wrong password or URL is asked again, or Zabbix can be skipped and added later.
After Grafana is up the Zabbix item map for the NOC dashboards is built automatically. If your router host names differ from the LAB names,
it asks once for each name; Enter skips and the NOC dashboards simply wait.

## Later

| Task | Command |
|---|---|
| Add / change ClickHouse (Akvorado) | `sudo grafana-platform setup --clickhouse` |
| Add / change Zabbix, finish the NOC item map | `sudo grafana-platform setup --zabbix` |
| Change any answer (e.g. switch to https) | `sudo grafana-platform setup --reconfigure` |
| Repeat the installation without questions | `sudo grafana-platform setup --yes` |
| Health check | `sudo grafana-platform verify` |
| Remove Grafana (keeps config, secrets, data) | `sudo grafana-platform uninstall --yes` — see [docs/ROLLBACK.md](docs/ROLLBACK.md) |

## What can stop the installation (and only this)

Genuine problems only, each printed with a one-line fix: not RHEL 9 / not x86_64 / not root; firewalld not running (it is what restricts the port);
the Grafana package not obtainable (the fix names the one file to copy); a damaged or wrong offline archive; required tools missing from the
RHEL repositories; less than 2 GiB free; port 3000 taken; an existing Grafana not installed by this tool; an invalid certificate (https only).
Everything else is a WARN: plain HTTP (your choice), SELinux not enforcing, Zabbix/ClickHouse not connected, NOC dashboards waiting for the item map.

Advanced/manual use of the individual commands: [docs/PRODUCTION-RHEL9.md](docs/PRODUCTION-RHEL9.md). Migration from `jaber717/Grafana`: [docs/MIGRATION-FROM-V1.md](docs/MIGRATION-FROM-V1.md).
