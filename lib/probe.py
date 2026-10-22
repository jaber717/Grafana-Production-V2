#!/usr/bin/env python3
"""Read-only connection tests used by the interactive installer (no Node.js needed, nothing is written anywhere).

  probe.py zabbix URL USER        password from the environment variable PROBE_PASSWORD (never argv)
      -> "OK <api-version> <visible hosts>"  or  "ERR <reason>"         calls: apiinfo.version, user.login, host.get(count), user.logout
  probe.py clickhouse URL         GET URL/ping -> "OK" or "ERR <reason>"

Env: PROBE_CA_FILE (extra CA, PEM), PROBE_INSECURE=1 (skip certificate verification; only when the operator allowed it).
Proxies from the environment are NOT used: Zabbix and ClickHouse are internal services.
"""
import json
import os
import ssl
import sys
import urllib.request


def opener():
    ctx = ssl.create_default_context()
    if os.environ.get("PROBE_CA_FILE"):
        ctx.load_verify_locations(os.environ["PROBE_CA_FILE"])
    if os.environ.get("PROBE_INSECURE") == "1":
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ctx))


def rpc(op, url, method, params, auth=None, header=True):
    body = {"jsonrpc": "2.0", "method": method, "params": params, "id": 1}
    headers = {"Content-Type": "application/json-rpc"}
    if auth and header:
        headers["Authorization"] = "Bearer " + auth
    elif auth:
        body["auth"] = auth
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method="POST")
    with op.open(req, timeout=15) as r:
        j = json.loads(r.read().decode("utf-8", "replace"))
    if "error" in j:
        raise RuntimeError((j["error"].get("data") or j["error"].get("message") or "error").strip())
    return j["result"]


def zabbix(url, user):
    op = opener()
    try:
        ver = rpc(op, url, "apiinfo.version", {})
    except Exception as e:  # noqa: BLE001 - every failure is reported, nothing else
        return f"ERR Zabbix API not reachable at {url}: {e}"
    maj, mi = (int(x) for x in ver.split(".")[:2])
    header = maj > 6 or (maj == 6 and mi >= 4)
    params = {"username": user, "password": os.environ.get("PROBE_PASSWORD", "")}
    if not (maj > 5 or (maj == 5 and mi >= 4)):
        params = {"user": user, "password": params["password"]}
    try:
        sid = rpc(op, url, "user.login", params)
    except Exception as e:  # noqa: BLE001
        return f"ERR login as {user} failed: {e}"
    try:
        n = rpc(op, url, "host.get", {"countOutput": True}, sid, header)
    finally:
        try:
            rpc(op, url, "user.logout", [], sid, header)
        except Exception:  # noqa: BLE001
            pass
    return f"OK {ver} {n}"


def clickhouse(url):
    try:
        with opener().open(url.rstrip("/") + "/ping", timeout=10) as r:
            return "OK" if r.read().decode().strip() == "Ok." else "ERR unexpected answer from /ping"
    except Exception as e:  # noqa: BLE001
        return f"ERR {e}"


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "zabbix":
        print(zabbix(sys.argv[2], sys.argv[3]))
    elif len(sys.argv) == 3 and sys.argv[1] == "clickhouse":
        print(clickhouse(sys.argv[2]))
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(64)
