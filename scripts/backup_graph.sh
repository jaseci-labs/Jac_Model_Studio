#!/bin/bash
# Snapshot the OSP graph + user DB (.jac/data/) AND the runtime data root
# (JAC_STUDIO_DATA_ROOT, default <studio>/data: projects/ results/ audit/ — see
# server/core/paths.sv.jac data_root) for disaster recovery.
# Run from cron / studio-backup.timer, e.g. 0 3 * * * /opt/jac_ml_studio/scripts/backup_graph.sh
#
# SQLite files (detected by header, any name) are copied with sqlite3's ONLINE
# BACKUP API — a consistent snapshot even while the server writes, WAL contents
# included. Tarring the live .db/-wal/-shm files could capture a torn DB. All
# other files are copied as-is. Tarball layout: data/ (-> .jac/data) and, when
# the runtime root exists, runtime/ (-> the data root). restore_graph.sh reads
# both, and still accepts old data/-only tarballs.
set -euo pipefail
STUDIO_DIR="${JAC_STUDIO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DATA_DIR="$STUDIO_DIR/.jac/data"
RUNTIME_DIR="${JAC_STUDIO_DATA_ROOT:-$STUDIO_DIR/data}"
[[ "$RUNTIME_DIR" = /* ]] || RUNTIME_DIR="$STUDIO_DIR/$RUNTIME_DIR"
DEST="${JAC_BACKUP_DIR:-$STUDIO_DIR/backups}"
PY="${JAC_PYTHON:-python3}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$DEST"
if [[ ! -d "$DATA_DIR" ]]; then
  echo "no data dir at $DATA_DIR" >&2
  exit 1
fi

STAGE="$(mktemp -d "$DEST/.stage-XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

"$PY" - "$DEST" "$DATA_DIR" "$STAGE/data" "$RUNTIME_DIR" "$STAGE/runtime" <<'PY'
import os, shutil, sqlite3, sys

dest = os.path.realpath(sys.argv[1])
pairs = [(sys.argv[2], sys.argv[3]), (sys.argv[4], sys.argv[5])]
MAGIC = b"SQLite format 3\x00"
SIDECARS = ("-wal", "-shm", "-journal")


def is_sqlite(p):
    try:
        with open(p, "rb") as f:
            return f.read(16) == MAGIC
    except OSError:
        return False


def inside(p, d):
    p = os.path.realpath(p)
    return p == d or p.startswith(d + os.sep)


for src, dst in pairs:
    if not os.path.isdir(src):
        continue
    for root, dirs, files in os.walk(src):
        out = os.path.join(dst, os.path.relpath(root, src))
        os.makedirs(out, exist_ok=True)
        keep = []
        for d in dirs:
            full = os.path.join(root, d)
            if inside(full, dest):          # never back up the backups
                continue
            if os.path.islink(full):        # os.walk won't descend; keep the link
                os.symlink(os.readlink(full), os.path.join(out, d))
                continue
            keep.append(d)
        dirs[:] = keep
        dbs = {f for f in files if is_sqlite(os.path.join(root, f))}
        for f in files:
            s, d = os.path.join(root, f), os.path.join(out, f)
            try:
                if f in dbs:
                    a = sqlite3.connect(s, timeout=60)
                    b = sqlite3.connect(d)
                    try:
                        a.backup(b)
                    finally:
                        b.close()
                        a.close()
                elif any(f == db + sfx for db in dbs for sfx in SIDECARS):
                    continue                # folded into the online backup
                elif os.path.islink(s):
                    os.symlink(os.readlink(s), d)
                else:
                    shutil.copy2(s, d)
            except FileNotFoundError:
                continue                    # vanished mid-walk (live tree)
PY

PARTS=(data)
[[ -d "$STAGE/runtime" ]] && PARTS+=(runtime)
OUT="$DEST/graph-$STAMP.tar.gz"
# Write under a non-matching name, then rename: restore_graph.sh picks the newest
# graph-*.tar.gz, so it must never see a half-written one.
tar -czf "$OUT.partial" -C "$STAGE" "${PARTS[@]}"
mv "$OUT.partial" "$OUT"
echo "wrote $OUT (${PARTS[*]})"
# keep last 14 backups
ls -1t "$DEST"/graph-*.tar.gz 2>/dev/null | tail -n +15 | xargs -r rm -f
