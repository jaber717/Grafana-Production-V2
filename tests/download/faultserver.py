"""Fault-injecting HTTP server for tests/download/run-download-tests.sh (test use only).

  faultserver.py PORT GIT_DIR ASSET_FILE CONTROL_FILE

GET /pieces/<commit>  -> tar.gz of that commit (git archive), like codeload.github.com/<repo>/tar.gz/<commit>
GET /asset/<name>     -> ASSET_FILE, honouring "Range: bytes=N-" with 206 + Content-Range, like the release-asset host
CONTROL_FILE (re-read on every request), one "key=value" per line:
  asset_cut=N          close every /asset answer after N body bytes (reproduces "curl: (18) transfer closed")
  asset_range=ignore   answer a Range request with 200 and the whole file
  asset_range=wrong    answer a Range request with 206 starting 4096 bytes too early
  asset_tamper=1       flip one byte at offset 1000 of every /asset answer
  pieces_drop=K        the first K requests for every piece are cut after 1000 bytes (each piece fails K times, then works)
  pieces_bad=<commit>  that piece is always answered with wrong content
Logs "<path> <status> <range> <bytes-sent>" per request to CONTROL_FILE.log.
"""
import http.server
import os
import re
import subprocess
import sys
import threading

PORT, GIT_DIR, ASSET, CONTROL = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
seen = {}
lock = threading.Lock()


def control():
    c = {}
    try:
        for line in open(CONTROL):
            if "=" in line:
                k, v = line.strip().split("=", 1)
                c[k] = v
    except OSError:
        pass
    return c


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def log(self, status, rng, sent):
        with lock, open(CONTROL + ".log", "a") as f:
            f.write(f"{self.path} {status} {rng or '-'} {sent}\n")

    def send_body(self, status, body, headers, cut=None):
        self.send_response(status)
        for k, v in headers.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        data = body if cut is None else body[:cut]
        try:
            self.wfile.write(data)
            self.wfile.flush()
        except OSError:
            return -1  # the client closed early (e.g. curl --max-filesize)
        if cut is not None and cut < len(body):
            self.close_connection = True
            self.connection.shutdown(2)
        return len(data)

    def do_GET(self):
        c = control()
        m = re.match(r"^/pieces/([0-9a-f]{40})$", self.path)
        if m:
            commit = m.group(1)
            with lock:
                seen[commit] = seen.get(commit, 0) + 1
                n = seen[commit]
            body = subprocess.run(["git", "--git-dir", GIT_DIR, "archive", "--format=tar.gz", f"--prefix=Grafana-Production-V2-{commit}/", commit],
                                  capture_output=True, check=True).stdout
            if c.get("pieces_bad") == commit:
                body = subprocess.run(["git", "--git-dir", GIT_DIR, "archive", "--format=tar.gz", "--prefix=x/", "HEAD", "VERSION"],
                                      capture_output=True, check=True).stdout
            cut = 1000 if n <= int(c.get("pieces_drop", "0")) else None
            self.log(200, None, self.send_body(200, body, {"Content-Type": "application/x-gzip"}, cut))
            return
        if self.path.startswith("/asset/"):
            data = open(ASSET, "rb").read()
            if c.get("asset_tamper") == "1":
                data = data[:1000] + bytes([data[1000] ^ 0xFF]) + data[1001:]
            rng = self.headers.get("Range")
            status, start, hdr = 200, 0, {"Content-Type": "application/octet-stream", "Accept-Ranges": "bytes"}
            if rng and c.get("asset_range") != "ignore":
                mr = re.match(r"bytes=(\d+)-(\d*)", rng)
                start, end = int(mr.group(1)), int(mr.group(2) or len(data) - 1)
                if c.get("asset_range") == "wrong":
                    start = max(0, start - 4096)
                status = 206
                hdr["Content-Range"] = f"bytes {start}-{end}/{len(data)}"
                data = data[:end + 1]
            cut = int(c["asset_cut"]) if "asset_cut" in c else None
            self.log(status, rng, self.send_body(status, data[start:], hdr, cut))
            return
        self.log(404, None, self.send_body(404, b"not found", {}))


class S(http.server.ThreadingHTTPServer):
    daemon_threads = True


S(("127.0.0.1", PORT), H).serve_forever()
