#!/bin/bash
# Verify the backup -> restore round-trip actually recovers the graph data
# (.jac/data, including a live WAL-mode SQLite DB) AND the runtime data root
# (JAC_STUDIO_DATA_ROOT: projects/ results/ audit/), and that restore refuses to
# run under a live server in the SAME studio dir while ignoring servers in other
# checkouts. Runs entirely in throwaway temp dirs (JAC_STUDIO_DIR /
# JAC_STUDIO_DATA_ROOT overrides) — never touches the real .jac/data or data/.
# Exit 0 = round-trip verified.
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d -t studio-backup-test-XXXXXX)"
PY="${JAC_PYTHON:-python3}"
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

export JAC_STUDIO_DIR="$WORK/studio"
export JAC_BACKUP_DIR="$WORK/backups"
export JAC_STUDIO_DATA_ROOT="$WORK/runtime"
unset JAC_RESTORE_FORCE
DATA="$JAC_STUDIO_DIR/.jac/data"
RT="$JAC_STUDIO_DATA_ROOT"
mkdir -p "$DATA/nested" "$JAC_BACKUP_DIR" "$RT/projects/p1/dataset" "$RT/audit"

# Seed sentinels that must survive the round-trip.
SENTINEL="graph-state-$(date -u +%s)-$$"
echo "$SENTINEL" > "$DATA/sentinel.txt"
echo "nested-ok" > "$DATA/nested/deep.txt"
echo '{"rt": "ok"}' > "$RT/projects/p1/dataset/train.jsonl"
echo '{"audit": 1}' > "$RT/audit/audit.jsonl"

# A WAL-mode SQLite DB with 500 checkpointed rows, plus one row that lives ONLY
# in the -wal file because a writer still holds the DB open (like the server).
DB="$DATA/anchor_store.db"
"$PY" - "$DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("pragma journal_mode=wal")
c.execute("create table t(i integer)")
c.executemany("insert into t values(?)", [(i,) for i in range(500)])
c.commit()
c.close()
PY
"$PY" -c '
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("pragma wal_autocheckpoint=0")
c.execute("insert into t values(-1)")
c.commit()
open(sys.argv[1] + ".ready", "w").close()
time.sleep(120)
' "$DB" &
PIDS+=($!)
for _ in $(seq 1 100); do [[ -f "$DB.ready" ]] && break; sleep 0.05; done
rm -f "$DB.ready"
[[ -f "$DB-wal" ]] || fail "test setup: expected a live -wal file"

# 1. Back up.
bash "$SCRIPTS_DIR/backup_graph.sh" >/dev/null || fail "backup_graph.sh errored"
TARBALL="$(ls -1t "$JAC_BACKUP_DIR"/graph-*.tar.gz 2>/dev/null | head -n1 || true)"
[[ -n "$TARBALL" && -f "$TARBALL" ]] || fail "no backup tarball produced"
LISTING="$(tar -tzf "$TARBALL")"
grep -qE '(-wal|-shm)$' <<<"$LISTING" \
  && fail "tarball carries raw -wal/-shm files (live DB copied, not snapshotted)"
grep -q '^runtime/projects/p1/dataset/train.jsonl$' <<<"$LISTING" \
  || fail "runtime data root (projects/results/audit) not in the backup"
kill "${PIDS[0]}" 2>/dev/null || true; wait "${PIDS[0]}" 2>/dev/null || true

# 2. Simulate corruption of the live graph + runtime data.
echo "CORRUPTED" > "$DATA/sentinel.txt"
rm -f "$DATA/nested/deep.txt" "$DB" "$DB-wal" "$DB-shm"
echo "CORRUPTED" > "$RT/projects/p1/dataset/train.jsonl"
rm -f "$RT/audit/audit.jsonl"

# 3a. A dev server ('jac start --dev main.jac') running IN this studio dir must
# block the restore. A fake `jac` script gives the process that command line.
mkdir -p "$WORK/bin" "$WORK/elsewhere"
printf '#!/bin/bash\ntrap "kill \\$! 2>/dev/null; exit 0" TERM\nsleep 120 &\nwait\n' > "$WORK/bin/jac"
chmod +x "$WORK/bin/jac"
(cd "$JAC_STUDIO_DIR" && exec "$WORK/bin/jac" start --dev main.jac) &
HERE_PID=$!
PIDS+=("$HERE_PID")
sleep 0.5
if ERR="$(bash "$SCRIPTS_DIR/restore_graph.sh" 2>&1 >/dev/null)"; then
  fail "restore ran while 'jac start --dev main.jac' was live in the studio dir"
fi
grep -q "running" <<<"$ERR" || fail "restore failed for the wrong reason: $ERR"
kill "$HERE_PID" 2>/dev/null || true; wait "$HERE_PID" 2>/dev/null || true

# 3b. A server in ANOTHER checkout (e.g. the live dev server) must not block it.
(cd "$WORK/elsewhere" && exec "$WORK/bin/jac" start --dev main.jac) &
PIDS+=($!)
sleep 0.5
bash "$SCRIPTS_DIR/restore_graph.sh" >/dev/null || fail "restore_graph.sh errored"

# 4. Verify contents came back.
GOT="$(cat "$DATA/sentinel.txt" 2>/dev/null || true)"
[[ "$GOT" == "$SENTINEL" ]] || fail "sentinel mismatch (got '$GOT')"
[[ "$(cat "$DATA/nested/deep.txt" 2>/dev/null)" == "nested-ok" ]] \
  || fail "nested file not restored"
ROWS="$("$PY" -c '
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
assert c.execute("pragma integrity_check").fetchone()[0] == "ok"
print(c.execute("select count(*) from t").fetchone()[0])
' "$DB")" || fail "restored DB unreadable / failed integrity_check"
[[ "$ROWS" == "501" ]] || fail "restored DB has $ROWS rows, want 501 (WAL row lost?)"
[[ "$(cat "$RT/projects/p1/dataset/train.jsonl" 2>/dev/null)" == '{"rt": "ok"}' ]] \
  || fail "runtime project data not restored"
[[ -f "$RT/audit/audit.jsonl" ]] || fail "runtime audit trail not restored"

# 5. Pre-restore safety copies of both trees should exist.
ls -d "$JAC_STUDIO_DIR/.jac/data.pre-restore-"* >/dev/null 2>&1 \
  || fail "pre-restore safety copy of .jac/data not created"
ls -d "$RT.pre-restore-"* >/dev/null 2>&1 \
  || fail "pre-restore safety copy of the runtime data root not created"

# 6. A legacy (graph-only, data/ only) tarball still restores and leaves the
# runtime data root alone.
LEGACY="$WORK/legacy.tar.gz"
tar -czf "$LEGACY" -C "$JAC_STUDIO_DIR/.jac" data
bash "$SCRIPTS_DIR/restore_graph.sh" "$LEGACY" >/dev/null || fail "legacy restore errored"
[[ "$(cat "$RT/projects/p1/dataset/train.jsonl" 2>/dev/null)" == '{"rt": "ok"}' ]] \
  || fail "legacy restore disturbed the runtime data root"

echo "PASS: backup -> wipe -> restore round-trip verified (graph + sqlite + runtime data)"
