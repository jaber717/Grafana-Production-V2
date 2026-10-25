#!/usr/bin/env python3
"""Reuse what an earlier (possibly interrupted or damaged) download already holds.

  seedparts.py MANIFEST PIECE_BYTES OUTDIR ARCHIVE...

ARCHIVE = an offline archive grafana-platform-*-rhel9-offline.tar.gz, complete or cut off (e.g. the 190 MiB of an interrupted
download, also *.part files). It is read as a stream, only read, never changed. Every bundle/<artifact> member found is cut into
PIECE_BYTES pieces; a piece is written to OUTDIR/<commit> only if its SHA-256 equals the one pinned for that artifact/index in
MANIFEST ("<commit> <sha256> <artifact> <index>"). A truncated or corrupt archive simply yields fewer pieces; nothing unverified
is ever written. Pieces already present in OUTDIR are left alone. Prints one line per archive: "<reused> <archive>".
"""
import hashlib
import os
import sys
import tarfile
import zlib


def main():
    manifest, piece, outdir, archives = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4:]
    want = {}
    for line in open(manifest):
        f = line.split()
        if len(f) == 4 and not line.startswith("#"):
            want[(f[2], int(f[3]))] = (f[0], f[1])
    names = {a for a, _ in want}
    os.makedirs(outdir, exist_ok=True)
    for arc in archives:
        reused = 0
        try:
            with tarfile.open(arc, "r|gz") as t:
                for m in t:
                    rel = m.name.split("/bundle/", 1)[-1] if "/bundle/" in m.name else None
                    if not m.isfile() or rel not in names:
                        continue
                    src, i = t.extractfile(m), 0
                    while True:
                        b = src.read(piece)
                        if not b:
                            break
                        hit = want.get((rel, i))
                        if hit and hashlib.sha256(b).hexdigest() == hit[1]:
                            dst = os.path.join(outdir, hit[0])
                            if not os.path.exists(dst):
                                with open(dst + ".seed", "wb") as o:
                                    o.write(b)
                                os.replace(dst + ".seed", dst)
                                reused += 1
                        i += 1
        except (EOFError, OSError, tarfile.TarError, zlib.error):
            pass  # end of what the cut-off/damaged file holds: everything before it is already checked and kept
        print(reused, arc)


if __name__ == "__main__":
    main()
