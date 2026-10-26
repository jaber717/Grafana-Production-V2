#!/usr/bin/env python3
"""Canonical parser for grafana-platform environment files (KEY=VALUE, never executed).

One parser for every consumer: lib/common.sh (bash) calls it and hands the Node content tools a NORMALIZED copy of the result, so the
shell and Node can never disagree about a value again (release 1.x had two parsers that did: see docs/ROOT-CAUSE-V2.md).

Rules
  * UTF-8; a byte-order mark, CRLF line ends and non-breaking spaces are tolerated.
  * Blank lines and lines whose first non-blank character is '#' are comments.
  * KEY=VALUE, optional leading 'export ', optional blanks around '='.
  * VALUE may be "double" or 'single' quoted (anything after the closing quote must be blank or a # comment);
    unquoted values end at the first blank-preceded '#'. Typographic quotes are rejected with an explanation.
  * Keys must be known to this release (a misspelled flag is an ERROR, not a silently ignored line) and may appear only once.
  * Boolean settings accept yes/no, true/false, on/off, 1/0 in any case and are normalized to the spelling the platform uses.

Usage
  envparse.py parse FILE                 NUL-separated records on stdout: V\\0KEY\\0VALUE\\0 ... and W\\0message\\0 / E\\0message\\0
  envparse.py set FILE KEY=VALUE ...     change/add keys in FILE in place (comments kept, validated first, atomic; old file kept as FILE.previous)
  envparse.py keys                       print the known keys with their type and default
Exit codes: 0 ok, 2 the file has errors (all of them are reported), 64 usage.
"""
import difflib
import os
import re
import sys
import tempfile

YESNO, TRUEFALSE, STR, INT, ENUM = "yesno", "truefalse", "str", "int", "enum"

# key: (type, default or None, extra)   extra = allowed values for ENUM
SCHEMA = {
    "PLATFORM_ENV": (STR, "production", None),
    # Grafana listener
    "GRAFANA_DOMAIN": (STR, None, None),
    "GRAFANA_HTTP_PORT": (INT, "3000", None),
    "GRAFANA_PROTOCOL": (ENUM, "https", ("https", "http")),
    "GRAFANA_ALLOW_INSECURE_HTTP": (YESNO, "no", None),
    "GRAFANA_TLS_CERT_FILE": (STR, None, None),
    "GRAFANA_TLS_KEY_FILE": (STR, None, None),
    "GRAFANA_TLS_CA_FILE": (STR, None, None),
    "GRAFANA_ALLOWED_CIDRS": (STR, None, None),
    "GRAFANA_ADMIN_USER": (STR, "admin", None),
    "GRAFANA_ROOT_URL": (STR, None, None),
    "GRAFANA_FIREWALL_ZONE": (STR, None, None),
    # Zabbix datasource (no = Grafana without Zabbix; the NOC dashboards wait for it)
    "ZABBIX_ENABLED": (YESNO, "yes", None),
    "ZABBIX_DS_NAME": (STR, "Zabbix", None),
    # uid of a Zabbix datasource that already exists in Grafana: it is used by the NOC dashboards and never modified (empty = the
    # installer manages its own datasource 'zabbix-lab')
    "ZABBIX_DATASOURCE_UID": (STR, None, None),
    # how long the Zabbix plugin caches host groups, hosts and items: a device added to Zabbix appears in the NOC pickers within this time
    "ZABBIX_CACHE_TTL": (STR, "5m", None),
    # NOC dashboards, "Device Type": Zabbix host groups of each type, as /regex/i over the group names (empty = default pattern);
    # set by 'install.sh --dashboards' from the groups that exist in Zabbix
    "NOC_GROUPS_ROUTER": (STR, None, None),
    "NOC_GROUPS_SWITCH": (STR, None, None),
    "NOC_GROUPS_FIREWALL": (STR, None, None),
    "ZABBIX_URL": (STR, None, None),
    "ZABBIX_USER": (STR, None, None),
    "ZABBIX_CA_FILE": (STR, None, None),
    "ZABBIX_TLS_SKIP_VERIFY": (TRUEFALSE, "false", None),
    "ALLOW_INSECURE_DATASOURCES": (YESNO, "no", None),
    # ClickHouse datasource (Akvorado)
    "CLICKHOUSE_ENABLED": (YESNO, "yes", None),
    "CLICKHOUSE_HOST": (STR, None, None),
    "CLICKHOUSE_PORT": (INT, None, None),
    "CLICKHOUSE_SECURE": (TRUEFALSE, "true", None),
    "CLICKHOUSE_USER": (STR, None, None),
    "CLICKHOUSE_CA_FILE": (STR, None, None),
    # NOC dashboards
    "ZABBIX_ITEM_MAP_FILE": (STR, None, None),
    "ALLOW_NOC_WITHOUT_ITEM_MAP": (YESNO, "yes", None),
    # packages
    "PACKAGE_SOURCE": (ENUM, "auto", ("auto", "repo", "bundle")),
    "BUNDLE_DIR": (STR, None, None),
    "BUNDLE_URL": (STR, None, None),
    "BUNDLE_URL_SHA256": (STR, None, None),
    # storage / operations
    "SECRETS_DIR": (STR, None, None),
    "BACKUP_DIR": (STR, "/var/backups/grafana-platform", None),
    "BACKUP_KEEP": (INT, "8", None),
    "BACKUP_GPG_PASSPHRASE_FILE": (STR, None, None),
    "UPGRADE_AUTO_ROLLBACK": (YESNO, "yes", None),
    "PLATFORM_ALLOW_EL_CLONE": (YESNO, "no", None),
}
# Spellings seen in the field for keys of this release; reported with the right name instead of "unknown".
ALIASES = {
    "ALLOW_INSECURE_DATASOURCE": "ALLOW_INSECURE_DATASOURCES",
    "ALLOW_INSECURE_DS": "ALLOW_INSECURE_DATASOURCES",
    "ZABBIX_ALLOW_INSECURE": "ALLOW_INSECURE_DATASOURCES",
    "ZABBIX_ALLOW_HTTP": "ALLOW_INSECURE_DATASOURCES",
    "ALLOW_INSECURE_HTTP": "GRAFANA_ALLOW_INSECURE_HTTP",
    "GRAFANA_INSECURE_HTTP": "GRAFANA_ALLOW_INSECURE_HTTP",
    "ALLOW_HTTP": "GRAFANA_ALLOW_INSECURE_HTTP",
    "ZABBIX_INSECURE_SKIP_VERIFY": "ZABBIX_TLS_SKIP_VERIFY",
    "CLICKHOUSE_TLS": "CLICKHOUSE_SECURE",
}
TRUE_WORDS, FALSE_WORDS = ("yes", "true", "on", "1"), ("no", "false", "off", "0")
SMART_QUOTES = "“”‘’«»"
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def _clean(text):
    if text.startswith("﻿"):
        text = text[1:]
    return text.replace("\r\n", "\n").replace("\r", "\n").replace(" ", " ").replace(" ", " ").replace(" ", " ")


def _split_value(raw, where):
    """Return (value, error)."""
    v = raw.strip()
    if v and v[0] in SMART_QUOTES:
        return None, f"{where}: value starts with a typographic quote ({v[:1]!r}); use plain \" or ' (or no quotes)"
    if v[:1] in ("'", '"'):
        q = v[0]
        end = v.find(q, 1)
        if end < 0:
            return None, f"{where}: unterminated {q} quote"
        rest = v[end + 1:].strip()
        if rest and not rest.startswith("#"):
            return None, f"{where}: unexpected text after the closing quote: {rest[:30]!r}"
        return v[1:end], None
    m = re.search(r"\s#", v)
    if m:
        v = v[: m.start()]
    v = v.strip()
    if v.startswith("#"):
        v = ""
    if any(c in v for c in SMART_QUOTES):
        return None, f"{where}: value contains a typographic quote ({v!r}); retype it with plain quotes or none"
    return v, None


def normalize(key, value, where):
    """Return (normalized value, error)."""
    typ, _default, extra = SCHEMA[key]
    if typ in (YESNO, TRUEFALSE):
        low = value.strip().lower()
        if low in TRUE_WORDS:
            return ("yes" if typ == YESNO else "true"), None
        if low in FALSE_WORDS:
            return ("no" if typ == YESNO else "false"), None
        if low == "":
            return "", None
        return None, f"{where}: {key} must be yes or no (accepted: yes/no, true/false, on/off, 1/0); got {value!r}"
    if typ == INT and value != "" and not value.isdigit():
        return None, f"{where}: {key} must be a whole number; got {value!r}"
    if typ == ENUM and value != "":
        low = value.lower()
        if low not in extra:
            return None, f"{where}: {key} must be one of {', '.join(extra)}; got {value!r}"
        return low, None
    return value, None


def parse(text, name="env"):
    values, seen, errors, warnings = {}, {}, [], []
    for n, line in enumerate(_clean(text).split("\n"), 1):
        where = f"{name}:{n}"
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        s = re.sub(r"^export\s+", "", s)
        if "=" not in s:
            errors.append(f"{where}: not a KEY=VALUE line: {s[:40]!r}")
            continue
        key, raw = s.split("=", 1)
        key = key.strip()
        if not KEY_RE.match(key):
            errors.append(f"{where}: invalid key name {key[:40]!r}")
            continue
        if key not in SCHEMA:
            if key in ALIASES:
                errors.append(f"{where}: {key} is not a setting of this release; the setting is called {ALIASES[key]}")
            else:
                hint = difflib.get_close_matches(key, SCHEMA.keys(), n=1, cutoff=0.75)
                errors.append(f"{where}: unknown setting {key}" + (f" (did you mean {hint[0]}?)" if hint else " (see env/production.env.example)"))
            continue
        if key in seen:
            errors.append(f"{where}: {key} is already set on line {seen[key]} (each setting may appear only once)")
            continue
        seen[key] = n
        value, err = _split_value(raw, where)
        if err:
            errors.append(err)
            continue
        value, err = normalize(key, value, where)
        if err:
            errors.append(err)
            continue
        if "$" in value and re.search(r"\$\{?[A-Za-z_]", value):
            warnings.append(f"{where}: {key} contains {value!r}; shell variables are NOT expanded in this file (write the literal path)")
        values[key] = value
    return values, errors, warnings



def _quote(v):
    return '"' + v + '"'


def cmd_parse(path):
    values, errors, warnings = parse(open(path, encoding="utf-8", errors="replace").read(), path)
    out = sys.stdout.buffer
    for w in warnings:
        out.write(b"W\0" + w.encode() + b"\0")
    for e in errors:
        out.write(b"E\0" + e.encode() + b"\0")
    for k, v in values.items():
        out.write(b"V\0" + k.encode() + b"\0" + v.encode() + b"\0")
    return 2 if errors else 0



def cmd_set(path, assignments):
    text = _clean(open(path, encoding="utf-8").read()) if os.path.exists(path) else ""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    for a in assignments:
        if "=" not in a:
            print(f"not KEY=VALUE: {a}", file=sys.stderr)
            return 64
        key, value = a.split("=", 1)
        key = key.strip()
        if key not in SCHEMA:
            hint = ALIASES.get(key) or (difflib.get_close_matches(key, SCHEMA.keys(), n=1, cutoff=0.75) or [None])[0]
            print(f"unknown setting {key}" + (f" (did you mean {hint}?)" if hint else ""), file=sys.stderr)
            return 2
        if "\n" in value:
            print(f"{key}: value must be a single line", file=sys.stderr)
            return 2
        norm, err = normalize(key, value.strip(), "command line")
        if err:
            print(err, file=sys.stderr)
            return 2
        new = f"{key}={_quote(norm) if (' ' in norm or '#' in norm) else norm}"
        pat = re.compile(r"^\s*(export\s+)?" + re.escape(key) + r"\s*=")
        hit = [i for i, l in enumerate(lines) if pat.match(l)]
        if hit:
            lines[hit[0]] = new
            for i in reversed(hit[1:]):
                del lines[i]
        else:
            lines.append(new)
    body = "\n".join(lines) + "\n"
    _v, errors, _w = parse(body, path)
    if errors:
        print("refusing to write, the result would not be valid:\n  " + "\n  ".join(errors), file=sys.stderr)
        return 2
    d = os.path.dirname(os.path.abspath(path))
    st = os.stat(path) if os.path.exists(path) else None
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".env-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(body)
    if st:
        os.chmod(tmp, st.st_mode & 0o7777)
        try:
            os.chown(tmp, st.st_uid, st.st_gid)
        except PermissionError:
            pass
    else:
        os.chmod(tmp, 0o640)
    if st:   # the previous content stays next to the file: undo = mv FILE.previous FILE
        import shutil
        shutil.copy2(path, path + ".previous")
    os.replace(tmp, path)
    return 0


def cmd_keys():
    for k, (t, d, x) in SCHEMA.items():
        print(f"{k:30} {t + ('(' + '|'.join(x) + ')' if x else ''):24} {d or ''}")
    return 0


def main(argv):
    if len(argv) >= 3 and argv[1] == "parse":
        return cmd_parse(argv[2])
    if len(argv) >= 4 and argv[1] == "set":
        return cmd_set(argv[2], argv[3:])
    if len(argv) == 2 and argv[1] == "keys":
        return cmd_keys()
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
