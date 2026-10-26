#!/usr/bin/env python3
"""Device Type <-> Zabbix host groups for the NOC dashboards (used by setup; reads nothing but its input).

  nocgroups.py show ROUTER SWITCH FIREWALL        stdin: "<group name><TAB><host count>" per line (probe.py hostgroups)
      -> "<TYPE><US><regex><US><matched groups '; '-separated>" for ROUTER, SWITCH, FIREWALL, then "OTHER<US><US><unmatched groups>"
         (US = \\x1f, the ASCII unit separator: never in a group name, and not merged by bash `read` like consecutive tabs)
  nocgroups.py regex "<answer>"                   an operator answer -> the regex stored in NOC_GROUPS_<TYPE>
      answer = "/regex/" (kept as is) or group names separated by ";" (exact names, case-insensitive)

An empty ROUTER/SWITCH/FIREWALL argument means the default pattern (the same as NOC_DEFAULT_GROUPS in scripts/lib/envcfg.mjs).
Matching = the Grafana Zabbix plugin's: regex search over the group name, case-insensitive.
"""
import re
import sys

DEFAULTS = {"ROUTER": "/router|rtr/i", "SWITCH": "/switch/i", "FIREWALL": "/firewall/i"}


def esc(s):
    """Escape only regex metacharacters: the result must be valid in JavaScript AND Go RE2 (RE2 rejects escaped spaces/letters)."""
    return re.sub(r"([.^$*+?()\[\]{}|\\])", r"\\\1", s).replace('"', "\\x22")


def compile_(v):
    m = re.match(r"^/(.*)/([gimsuy]*)$", v, re.S)
    body = m.group(1) if m else esc(v)
    return re.compile(body.replace("\\x3A", ":"), re.I)


def to_regex(answer):
    a = answer.strip()
    if re.match(r"^/.*/[gimsuy]*$", a, re.S):
        compile_(a)
        return a.replace('"', "\\x22")   # a double quote would end the quoted value in platform.env
    names = [n.strip() for n in a.split(";") if n.strip()]
    return "/^(?:" + "|".join(esc(n) for n in names) + ")$/i" if names else ""


def main():
    if sys.argv[1] == "regex":
        print(to_regex(sys.argv[2]))
        return
    regs = {t: (sys.argv[2 + i].strip() or DEFAULTS[t]) for i, t in enumerate(["ROUTER", "SWITCH", "FIREWALL"])}
    groups = [line.rstrip("\n").split("\t") for line in sys.stdin if line.strip()]
    used = set()
    for t, r in regs.items():
        rx = compile_(r)
        hit = [(g[0], g[1] if len(g) > 1 else "?") for g in groups if rx.search(g[0])]
        used.update(n for n, _ in hit)
        print(f"{t}\x1f{r}\x1f" + "; ".join(f"{n} ({c} hosts)" for n, c in hit))
    print("OTHER\x1f\x1f" + "; ".join(f"{g[0]} ({g[1] if len(g) > 1 else '?'} hosts)" for g in groups if g[0] not in used))


if __name__ == "__main__":
    main()
