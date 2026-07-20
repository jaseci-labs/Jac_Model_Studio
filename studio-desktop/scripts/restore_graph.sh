#!/bin/bash
# Restore the OSP graph + user DB (.jac/data/) from a backup_graph.sh tarball.
#
# Usage:
#   scripts/restore_graph.sh [tarball]
#     tarball  path to a graph-*.tar.gz; if omitted, the newest in the backup dir
#              ($JAC_BACKUP_DIR, default <studio>/backups) is used.
#
# The server MUST be stopped first (the graph is live state):
#   sudo systemctl stop jac-studio
# The current data dir is moved aside to .jac/data.pre-restore-<stamp> (not
# deleted) so a bad restore is itself reversible.
set -euo pipefail
STUDIO_DIR="${JAC_STUDIO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
JAC_DIR="$STUDIO_DIR/.jac"
DATA_DIR="$JAC_DIR/data"
DEST="${JAC_BACKUP_DIR:-$STUDIO_DIR/backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

TARBALL="${1:-}"
if [[ -z "$TARBALL" ]]; then
  TARBALL="$(ls -1t "$DEST"/graph-*.tar.gz 2>/dev/null | head -n1 || true)"
fi
if [[ -z "$TARBALL" || ! -f "$TARBALL" ]]; then
  echo "no backup tarball found (looked in $DEST); pass one explicitly" >&2
  exit 1
fi

# Refuse to clobber a live server unless forced.
if pgrep -f "jac start main.jac" >/dev/null 2>&1 && [[ "${JAC_RESTORE_FORCE:-}" != "1" ]]; then
  echo "a 'jac start main.jac' process is running — stop it first" >&2
  echo "(or set JAC_RESTORE_FORCE=1 to override)" >&2
  exit 1
fi

# Validate the archive shape before touching anything.
if ! tar -tzf "$TARBALL" | grep -q '^data/'; then
  echo "$TARBALL does not contain a data/ tree — not a graph backup?" >&2
  exit 1
fi

mkdir -p "$JAC_DIR"
if [[ -d "$DATA_DIR" ]]; then
  mv "$DATA_DIR" "$JAC_DIR/data.pre-restore-$STAMP"
  echo "moved existing data aside -> $JAC_DIR/data.pre-restore-$STAMP"
fi

tar -xzf "$TARBALL" -C "$JAC_DIR"
if [[ ! -d "$DATA_DIR" ]]; then
  echo "restore failed: $DATA_DIR missing after extract" >&2
  exit 1
fi
echo "restored $TARBALL -> $DATA_DIR"
echo "start the server again:  sudo systemctl start jac-studio"
