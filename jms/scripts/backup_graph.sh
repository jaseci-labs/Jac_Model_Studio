#!/bin/bash
# Snapshot the OSP graph + user DB (.jac/data/) for disaster recovery.
# Run from cron, e.g. 0 3 * * * /opt/jac_ml_studio/studio-desktop/scripts/backup_graph.sh
set -euo pipefail
STUDIO_DIR="${JAC_STUDIO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DATA_DIR="$STUDIO_DIR/.jac/data"
DEST="${JAC_BACKUP_DIR:-$STUDIO_DIR/backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$DEST"
if [[ ! -d "$DATA_DIR" ]]; then
  echo "no data dir at $DATA_DIR" >&2
  exit 1
fi
tar -czf "$DEST/graph-$STAMP.tar.gz" -C "$STUDIO_DIR/.jac" data
echo "wrote $DEST/graph-$STAMP.tar.gz"
# keep last 14 backups
ls -1t "$DEST"/graph-*.tar.gz 2>/dev/null | tail -n +15 | xargs -r rm -f
