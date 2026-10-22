# Root-cause analysis — why release 1.0.1 could not be installed on the production server

Reported preflight (production host `10.20.8.27`, RHEL 9.8, release 1.0.1 of `jaber717/Grafana`, commit `7c5b9f9`):
**27 PASS, 1 WARN, 6 FAIL**. Analysis by source review of 1.0.1 and by running the **unchanged 1.0.1 code** on a simulated RHEL 9.8 host
(`tests/sim/run-sim.sh <1.x checkout>`). The production host itself was not accessed.

| # | Reported FAIL | Classification | Root cause | Fixed in 2.0 by |
|---|---|---|---|---|
| 1 | Zabbix URL uses HTTP despite `ALLOW_INSECURE_DATASOURCES=yes` | **software defect** (parser + validation), not a naming mismatch in the code | see §1 | one strict parser for bash and Node; every spelling of yes accepted; unknown/misspelled/duplicate keys are errors; key documented in the template |
| 2 | Missing Zabbix password secret | expected (not created yet) + **documentation defect** | the documented method put the password on the command line (shell history) | `grafana-platform secret set zabbix-password` (prompted, not echoed) and an exact fix line |
| 3 | Missing ClickHouse password secret | **design defect** | 1.x required the ClickHouse secret although Akvorado is not available; there was no way to defer NetFlow | `CLICKHOUSE_ENABLED=no` defers datasource, 5 dashboards, playlist and the secret |
| 4 | Cannot reach rpm.grafana.com | configuration + **design defect** | template default `PACKAGE_SOURCE=repo` on an isolated host; the offline path needed hand-set `BUNDLE_DIR` and the documented value `$PWD/bundle` is never expanded | `PACKAGE_SOURCE=auto` (default): a bundle next to the release is used automatically |
| 5 | Cannot reach grafana.com for plugins | same cause as #4, reported twice | — | one package-source check, one FAIL, with the way out |
| 6 | Missing `/etc/grafana-platform/zabbix-item-map.json` | expected + **design defect** | 7 of 47 item descriptors were "unresolved", so the 1.x tool could never build a complete map; a partial map was refused even with `ALLOW_NOC_WITHOUT_ITEM_MAP=yes`; the tool needed a separate API token | candidate keys for the 7 uptime items, `--host` renames, `--set`, `--merge`; login with the datasource user; partial map + deferral = NOC dashboards skipped, never half-deployed |

## 1. `ALLOW_INSECURE_DATASOURCES=yes` not honored

**The check itself is correct.** In 1.0.1 (`lib/preflight.sh`) the Zabbix check is
`[ "${ALLOW_INSECURE_DATASOURCES:-no}" = yes ] && warn … || fail …`. With a file containing the byte-exact line `ALLOW_INSECURE_DATASOURCES=yes`
the unchanged 1.0.1 code reports **WARN** (simulation: `30 PASS, 2 WARN, 5 FAIL`). So the value the 1.x parser *saw* was not `yes`.

**What makes 1.0.1 see something else** — every variant below reproduces the reported result exactly (**1 WARN, 6 FAIL**: the only WARN is
Grafana-over-HTTP, as in the report) on the unchanged 1.0.1 code:

| Line as written in the environment file | Why 1.0.1 fails |
|---|---|
| `␣␣ALLOW_INSECURE_DATASOURCES=yes   # temporary` | **bug**: the comment filter `case … [[:space:]]*\#*)` drops *every indented line that contains a `#` anywhere*, silently. The Node half of the installer parses the same line as `yes` — the two halves disagree |
| `ALLOW_INSECURE_DATASOURCES=YES` / `=true` / `=1` / `=on` | case-sensitive comparison with `yes` only; the Node side accepts `true/yes/1`; nothing documents that only lower-case `yes` works |
| `ALLOW_INSECURE_DATASOURCES=“yes”` (typographic quotes) or `yes` + non-breaking space | text copied from a chat, e-mail or Word document; 1.x keeps the bytes and compares them with `yes` |
| `ALLOW_INSECURE_DATASOURCE=yes` (or any other spelling) | unknown keys are **silently ignored** |
| the key appears twice, the later one `no` | duplicates are silently accepted, last one wins |
| `--env-file` not given | 1.x then reads `/etc/grafana-platform/platform.env` (if present) before anything else — not the edited `/root/grafana.env` |

Contributing documentation defect: `ALLOW_INSECURE_DATASOURCES` is **not** in `env/production.env.example` and not in the configuration table of
`docs/PRODUCTION-RHEL9.md`; it appears only in an error message and in `SECURITY-PRODUCTION.md`, so the operator has to type it from memory.

Which variant the production file contains can only be confirmed on the host; this one read-only command shows it (control characters and
non-ASCII bytes become visible, nothing is changed):

```bash
grep -n -i 'insecure' /root/grafana.env /etc/grafana-platform/platform.env 2>/dev/null | cat -A
```

**2.0 behaviour**: `lib/envparse.py` is the single parser (bash calls it; Node receives a normalized copy). It accepts yes/no, true/false,
on/off, 1/0 in any case, tolerates indentation, inline comments, quotes, CRLF, BOM and non-breaking spaces, and turns every remaining
ambiguity into an **error that names the line and the fix**: unknown key (`did you mean ALLOW_INSECURE_DATASOURCES?`), known misspellings,
duplicates, typographic quotes, invalid values, unexpanded `$VARS`. Preflight prints the active insecure-transport exceptions on every run.
The security default is unchanged: both exceptions default to `no`.

## 2. Secrets

1.x documented `install -m 0600 /dev/stdin … <<< 'the-password'`: the password lands in the shell history of root. The FAILs pointed to a
document instead of a command. 2.0: `grafana-platform secret set <name>` prompts twice without echo (or reads one line from a pipe), writes
mode 600 root:root atomically, never prints or logs the value; every missing-secret FAIL is followed by that exact command;
`grafana-platform zabbix-check` proves the password and the user's host permissions before installing.
Also fixed: 1.x `install` ran `chown`/`chmod` on `clickhouse-password` unconditionally (a missing file aborts the installation midway). In 1.x this
was masked because preflight insisted on both secrets; it would have broken as soon as ClickHouse could be deferred.

## 3. Offline installation

1.x supported an offline bundle, but: the template defaulted to `PACKAGE_SOURCE=repo`; `BUNDLE_DIR` had no default (`/root/grafana-platform-bundle`
in the template does not match the archive layout `grafana-platform-<ver>/bundle`); `docs/OFFLINE.md` said `BUNDLE_DIR=$PWD/bundle`, which the
parser keeps literally; the repository/plugin reachability checks ran even when the pinned package and plugins were already installed; one
cause produced two FAILs. 2.0: `PACKAGE_SOURCE=auto` uses `<release>/bundle` when present; the bundle is deployed with the release (so later
`install`/`upgrade`/`rollback` still find it) and the RPM is cached for rollbacks; preflight checks that the bundle actually contains the pinned
files; package sources are checked only when something must be installed. The builder also locates the RPM through the repository metadata
if it is not at `/Packages/` (hardening — the 1.x path could not be re-verified from here; the SHA-256 pin protects either way).

## 4. Zabbix item map / NOC dashboards

The NOC dashboards address 47 Zabbix items by id. 1.x shipped descriptors for 40 of them; the 7 "UP" items (the SNMP uptime freshness signal of
each router, refId `UP` in `noc-device-health`) were marked `unresolved`, so `tools/zabbix-item-map.mjs` always exited 3 and preflight always
failed unless ids were invented by hand. Production host names that differ from the LAB names (`SITE-A`, …) also had no remedy except editing
JSON. And `ALLOW_NOC_WITHOUT_ITEM_MAP=yes` only helped when **no** map existed — a partial map made `apply` refuse and `install` abort.
2.0: the 7 descriptors carry standard SNMP uptime keys as candidates (resolved only if exactly one matches, printed under REVIEW);
`grafana-platform item-map` logs in with the datasource user/secret (no extra token), supports `--host LAB=PROD`, `--set`, `--merge`, `--search`;
a missing **or partial** map with the deferral flag skips both NOC dashboards (WARN), never deploys them half-mapped.

## 5. Other defects found during the review (not in the reported output)

| Area | 1.0.1 behaviour | 2.0 |
|---|---|---|
| Node.js on RHEL 9 | when the default (non-modular) `nodejs` of the minor release is older than 18 (Node.js 16 on early RHEL 9 minors), 1.x installs it first; the following `module enable nodejs:20 && dnf install nodejs` cannot replace an installed package → `install` dies (offline bundle with Node.js avoids it) | bundled pinned Node preferred; otherwise the module stream is selected **before** installing; an existing old nodejs is reported, not silently replaced |
| "read-only" preflight | ran `mkdir -p /var/lib/grafana` | no writes |
| Datasource rendering | ClickHouse datasource always rendered; empty ClickHouse settings crash `apply` | deferred datasources are not rendered |
| Playlist | always created with all dashboards, including undeployed ones | restricted to deployed dashboards; skipped when empty |
| Local health checks (design change, not a 1.x defect) | https: via `--resolve`; http: via the public address | always via loopback (`curl --connect-to`, explicit Node target), also for an IP-literal `GRAFANA_DOMAIN` |
| `bin/grafana-platform --help` | fixed line range | prints the whole header |
