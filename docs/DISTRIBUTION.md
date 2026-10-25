# How the installer gets its packages from GitHub (release 2.2.x)

## Install command (production VM)

```bash
curl -fsSL -x http://172.20.129.10:8080 https://codeload.github.com/jaber717/Grafana-Production-V2/tar.gz/refs/heads/main | tar xz -C /root && sudo GP_PROXY=http://172.20.129.10:8080 /root/Grafana-Production-V2-main/install.sh
```

Existing answers in `/etc/grafana-platform` (platform.env, secrets, item map) are reused: press Enter at "Keep these settings?".

## Latest production failure (2.1.1, after the firewall correction)

`curl: (18) transfer closed with 136420190 bytes remaining to read` for the 335,649,630-byte release asset: the connection closed after
**exactly 199,229,440 bytes = 190.0 MiB**.

* **Confirmed** (from the code): 2.1.1 ran `rm -f` on the partial file after any curl error — if the installer made that download, the 190 MiB
  are gone; 2.2.1 never deletes a partial. 2.1.1 had no resume.
* **Strongly indicated, not confirmed**: a byte-count limit on one HTTP response (proxy/firewall), not a timeout — a time-based cut lands on an
  exact MiB boundary about once in a million. Which device and which setting is not known from here.
* **Not the cause**: TLS (data flowed for 190 MiB), the GitHub redirect (it had already been followed), the installer's timeout (`-m 3600`).
* **Irrelevant for 2.2.x**: the packages come in 1717 responses of < 200 KB; a per-response limit of 190 MiB (or 895 KB) is never reached.
* `yum update`: nothing in the installer depends on it; its outcome is not known here. If it left the rpm database locked, the install step
  stops with dnf's own message.

## Recovering an interrupted download (2.2.1)

| Situation | What the installer does |
|---|---|
| a cut-off or damaged `grafana-platform-*-offline.tar.gz*` exists (near the release, /root, /tmp, /var/tmp, cache, user home) | reads it (never changes it), keeps every piece whose SHA-256 matches the manifest, fetches only the rest. 190 MiB prefix → 1023 of 1717 pieces reused |
| the installer itself is interrupted | verified pieces stay in `/var/cache/grafana-platform/parts`; the next run fetches only the missing ones |
| fallback single download is cut | `.part` kept; continued with `Range: bytes=N-`; appended only from `206` with `Content-Range` starting at N |
| server/proxy ignores Range (`200`) or answers at another offset | nothing appended, partial kept, message says so |
| any byte wrong | the piece/archive fails its SHA-256 and is not used; nothing incomplete or unverified is ever installed |

## Root-cause assessment of the earlier 2.1.x failure (~895 KB)

| Observation on the production VM (reported by the operator) | What it shows |
|---|---|
| `api.github.com/.../tarball/main` → `codeload.github.com`, 208,055 bytes: succeeds through FortiProxy 172.20.129.10:8080 | codeload.github.com is reachable through the proxy for a response of ~208 KB |
| release asset `github.com/.../releases/download/...` → `release-assets.githubusercontent.com`, 336 MB: connection reset after ~895 KB | one long transfer through the proxy is cut |
| resume with `-C -` (Range request): HTTP 504; with `-k`: also 504; security profiles disabled: still fails | not certificate verification, not the security profiles |

The data is consistent with two explanations: (a) the proxy path cuts any single connection after ~1 MB or after a short time, on any host,
or (b) the release-asset host (Azure blob storage behind `release-assets.githubusercontent.com`) is handled differently on that path.
**The VM data cannot distinguish them** (the working download was both smaller and from another host); no further operator tests were requested.
The design below works under **both** explanations: every request goes to the host already proven to work (codeload.github.com) and every
response is smaller than the size already proven to pass (208 KB). It uses no Range requests and no release assets.

Installer defects found and fixed while testing (both independent of the proxy):

1. The 2.1.x single download restarted from zero after any interruption and deleted the partial file.
2. RHEL 9 minimal installs ship `curl-minimal`; the prerequisite check looked for the package `curl`, so it reported curl missing
   (isolated host) or ran `dnf install curl`, which conflicts with `curl-minimal`.
3. Preflight required Node.js before the packages were fetched, although the fetched packages contain Node.js.

## Architecture

```
main branch (source, ~208 KB tarball)          packages branch (1717 commits, one 192 KiB piece each)
  install.sh, lib/, dashboards/ ...              commit acf8de9…  tree: part  (rpm/grafana-13.2.3-1.x86_64.rpm, piece 0)
  VERSIONS.env    pins: RPM, Node.js SHA-256     commit 4e0a073…  tree: part  (piece 1)
  plugins/plugins.txt  pins: plugin SHA-256      ...
  packages/MANIFEST.txt  commit + SHA-256 of every piece
        │                                                   ▲
        └── installer: GET codeload.github.com/jaber717/Grafana-Production-V2/tar.gz/<commit>  (≈ 197 KB each, 4 in parallel)
            → piece SHA-256 check → join per artifact → artifact SHA-256 = pin → RPM signature check (pinned key) → install
```

* Artifacts: Grafana RPM 13.2.3-1 (1455 pieces), zabbix-app 6.8.0 (58), clickhouse-datasource 4.22.0 (70), Node.js v20.20.2 (134); 337 MB total.
  Largest file in the repository: 196,608 bytes (GitHub limits: 100 MB per file, warning at 50 MB).
* Integrity: the manifest and the pins arrive with the source; a piece is used only if its SHA-256 matches, an artifact only if it equals
  the pin, the RPM only if its signature verifies with the pinned Grafana key. If the proxy re-signs TLS with a certificate the VM does not
  trust, the download continues with a WARN — integrity still rests on the SHA-256 checks.
* Resumable: verified pieces are kept in `/var/cache/grafana-platform/parts`; a re-run fetches only what is missing. Each piece is retried 5 times.
* Proxy: `GP_PROXY`, else `https_proxy`, else `proxy=` in `/etc/dnf/dnf.conf`; used only for GitHub. Grafana, Zabbix and ClickHouse
  connections never use it.
* Source order (automatic): installed → `bundle/` → offline archive nearby → **pieces from codeload.github.com** → single release-asset
  download → rpm.grafana.com/grafana.com.
* Why not `git clone`: the packages are not on `main`; cloning the `packages` branch is one long transfer (same failure mode as the release
  asset) and git over HTTPS was not proven through the proxy. Why not Git LFS: LFS content is served from GitHub's object storage
  (`*.githubusercontent.com`), the same class of host as the failing release asset; uploading it is also refused from the build environment.
* Why a branch and not a separate repository: this build session cannot create repositories, tags or custom refs (refused by GitHub/session
  policy). The pieces live on the `packages` branch of this repository; `git clone` of the repository downloads them too — use
  `git clone --single-branch` if you clone. Moving them to a separate repository only needs `PACKAGES_URL_BASE` in VERSIONS.env changed.
* Maintainer: `tools/publish-packages.sh <verified bundle dir>` re-creates the pieces and the manifest (deterministic commits).

## Tests (none of them through the production FortiProxy)

| Test | Result | Evidence |
|---|---|---|
| Stand-in proxy that resets every tunnel after 895 KB (chained to this build environment's real egress proxy): old single release-asset download | fails at 897,215 bytes (same symptom as production); resume also fails | this document |
| Same proxy: 1717 pieces from codeload.github.com, interrupted after 40 s, then re-run | 505 pieces kept, rest fetched; 1725 tunnels, 0 cut, largest response 203,333 B; all 4 artifacts equal the pins | — |
| Clean install on **AlmaLinux 9.8** (RHEL 9.8 rebuild, real systemd, real rpm/dnf, real Grafana 13.2.3, real plugins, bundled Node.js) through the cutting proxy; TLS of the proxy not trusted in the container | `rc=0`, 3 min 11 s; RPM signature OK; `verify` 37 PASS 0 FAIL; real Zabbix-plugin health check OK against the Zabbix 7.0 mock; 47/47 items mapped; 2 NOC dashboards | [evidence/alma98-install-through-cutting-proxy.txt](evidence/alma98-install-through-cutting-proxy.txt) |
| Re-run `install.sh --yes` | 12 s, nothing downloaded, 0 FAIL | same file |
| Download recovery: 19 checks, fault-injecting server (cut at 190 MiB, ignored/wrong Range, tampering, damaged partial, retries, re-run) | 19/19 | [evidence/download-recovery-tests.txt](evidence/download-recovery-tests.txt) |
| AlmaLinux 9.8, 190 MiB partial in /root, real GitHub through the 895 KB-cutting proxy | 1023 pieces reused, 694 fetched, partial unchanged, rc=0, 0 FAIL | [evidence/alma98-reuse-190mib-partial.txt](evidence/alma98-reuse-190mib-partial.txt) |
| Unit tests / simulated RHEL host | 25/25; simulation see [VALIDATION-V2.md](VALIDATION-V2.md) | evidence/ |

Test-environment substitutions on the AlmaLinux host (the AlmaLinux repositories are unreachable from the build environment, so these
packages could not be installed): `/etc/os-release` presented as `ID=rhel` (`GP_OS_RELEASE_FILE`, test-only), and stand-ins for `firewalld`
(rules kept in a file), `unzip` (Python zipfile), `ss` and `ps` (read /proc), `getenforce` (containers have no SELinux). Zabbix is a mock
(Zabbix 7.0 JSON-RPC subset). Not tested here: real firewalld/SELinux, real Zabbix, ClickHouse, the production FortiProxy.

## Remaining production-network limitation

The design depends on `codeload.github.com` answering through FortiProxy 172.20.129.10:8080 for ~200 KB responses, which the production VM
has already shown once (the source tarball). It is **not** proven that the proxy accepts ~1,700 such requests in a few minutes (rate limits,
connection limits) or that GitHub does not throttle them. If it fails, the installer stops with the curl error and a fix line, and a re-run
continues from the pieces already fetched.
