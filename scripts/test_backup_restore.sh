#!/bin/bash
# Verify the backup -> restore round-trip actually recovers the graph data.
# Runs entirely in a throwaway temp studio dir (JAC_STUDIO_DIR override) — never
# touches the real .jac/data. Exit 0 = round-trip verified.
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d -t studio-backup-test-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export JAC_STUDIO_DIR="$WORK/studio"
export JAC_BACKUP_DIR="$WORK/backups"
mkdir -p "$JAC_STUDIO_DIR/.jac/data" "$JAC_BACKUP_DIR"

# Seed a sentinel that must survive the round-trip.
SENTINEL="graph-state-$(date -u +%s)-$$"
echo "$SENTINEL" > "$JAC_STUDIO_DIR/.jac/data/sentinel.txt"
mkdir -p "$JAC_STUDIO_DIR/.jac/data/nested"
echo "nested-ok" > "$JAC_STUDIO_DIR/.jac/data/nested/deep.txt"

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. Back up.
bash "$SCRIPTS_DIR/backup_graph.sh" >/dev/null || fail "backup_graph.sh errored"
TARBALL="$(ls -1t "$JAC_BACKUP_DIR"/graph-*.tar.gz 2>/dev/null | head -n1 || true)"
[[ -n "$TARBALL" && -f "$TARBALL" ]] || fail "no backup tarball produced"

# 2. Simulate corruption of the live graph (data dir still present, contents bad).
echo "CORRUPTED" > "$JAC_STUDIO_DIR/.jac/data/sentinel.txt"
rm -f "$JAC_STUDIO_DIR/.jac/data/nested/deep.txt"

# 3. Restore (no live server in the temp dir, so no force needed).
bash "$SCRIPTS_DIR/restore_graph.sh" >/dev/null || fail "restore_graph.sh errored"

# 4. Verify contents came back byte-for-byte.
GOT="$(cat "$JAC_STUDIO_DIR/.jac/data/sentinel.txt" 2>/dev/null || true)"
[[ "$GOT" == "$SENTINEL" ]] || fail "sentinel mismatch (got '$GOT')"
[[ "$(cat "$JAC_STUDIO_DIR/.jac/data/nested/deep.txt" 2>/dev/null)" == "nested-ok" ]] \
  || fail "nested file not restored"

# 5. The pre-restore safety copy of the (empty) tree should exist.
ls -d "$JAC_STUDIO_DIR/.jac/data.pre-restore-"* >/dev/null 2>&1 \
  || fail "pre-restore safety copy not created"

echo "PASS: backup -> wipe -> restore round-trip verified"
