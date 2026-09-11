#!/bin/bash
# Restore the OSP graph + user DB (.jac/data/) and, when the tarball carries it,
# the runtime data root (JAC_STUDIO_DATA_ROOT, default <studio>/data) from a
# backup_graph.sh tarball. Old data/-only tarballs restore the graph and leave
# the runtime data root alone.
#
# Usage:
#   scripts/restore_graph.sh [tarball]
#     tarball  path to a graph-*.tar.gz; if omitted, the newest in the backup dir
#              ($JAC_BACKUP_DIR, default <studio>/backups) is used.
#
# The server MUST be stopped first (the graph is live state):
#   sudo systemctl stop studio
# "Running" = any `jac start` process (prod or --dev) whose working directory is
# THIS studio dir; servers of other checkouts don't block. JAC_RESTORE_FORCE=1
# overrides. Existing trees are moved aside to <tree>.pre-restore-<stamp> (not
# deleted) so a bad restore is itself reversible.
set -euo pipefail
STUDIO_DIR="${JAC_STUDIO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
JAC_DIR="$STUDIO_DIR/.jac"
DATA_DIR="$JAC_DIR/data"
RUNTIME_DIR="${JAC_STUDIO_DATA_ROOT:-$STUDIO_DIR/data}"
[[ "$RUNTIME_DIR" = /* ]] || RUNTIME_DIR="$STUDIO_DIR/$RUNTIME_DIR"
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

# Working directory of *pid* ("" if unknowable): /proc on Linux, lsof on macOS.
_cwd_of() {
  local pid="$1"
  if [[ -e "/proc/$pid/cwd" ]]; then
    readlink "/proc/$pid/cwd" 2>/dev/null || true
    return
  fi
  lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n1
}

# PIDs of `jac start ...` processes (start_prod.sh's `jac start main.jac -p ..`,
# start.sh's `jac start --dev main.jac`, ...) running in THIS studio dir.
live_server_pids() {
  local want pid cwd
  want="$(cd "$STUDIO_DIR" && pwd -P)"
  for pid in $(pgrep -f 'jac start' 2>/dev/null || true); do
    cwd="$(_cwd_of "$pid")"
    [[ -n "$cwd" ]] || continue
    cwd="$(cd "$cwd" 2>/dev/null && pwd -P || echo "$cwd")"
    [[ "$cwd" == "$want" ]] && echo "$pid"
  done
  return 0
}

# Refuse to clobber a live server unless forced.
if [[ "${JAC_RESTORE_FORCE:-}" != "1" ]]; then
  LIVE="$(live_server_pids)"
  if [[ -n "$LIVE" ]]; then
    echo "a 'jac start' server is running in $STUDIO_DIR (pid $(echo $LIVE)) — stop it first" >&2
    echo "(or set JAC_RESTORE_FORCE=1 to override)" >&2
    exit 1
  fi
fi

# Validate the archive shape before touching anything.
if ! tar -tzf "$TARBALL" | grep -q '^data/'; then
  echo "$TARBALL does not contain a data/ tree — not a graph backup?" >&2
  exit 1
fi

# Extract to a staging dir FIRST (same filesystem as .jac), so a failed/partial
# extract never leaves the live tree half-replaced.
mkdir -p "$JAC_DIR"
STAGE="$(mktemp -d "$JAC_DIR/.restore-XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
tar -xzf "$TARBALL" -C "$STAGE"
if [[ ! -d "$STAGE/data" ]]; then
  echo "restore failed: data/ missing after extract" >&2
  exit 1
fi

# Move *path* aside to <path>.pre-restore-<stamp> (unique even within a second).
aside() {
  local src="$1" dst="$1.pre-restore-$STAMP"
  [[ -e "$dst" ]] && dst="$dst-$$-$RANDOM"
  mv "$src" "$dst"
  echo "moved existing $(basename "$src") aside -> $dst"
}

[[ -e "$DATA_DIR" ]] && aside "$DATA_DIR"
mv "$STAGE/data" "$DATA_DIR"
echo "restored $TARBALL -> $DATA_DIR"

if [[ -d "$STAGE/runtime" ]]; then
  [[ -e "$RUNTIME_DIR" ]] && aside "$RUNTIME_DIR"
  mkdir -p "$(dirname "$RUNTIME_DIR")"
  mv "$STAGE/runtime" "$RUNTIME_DIR"
  echo "restored runtime data -> $RUNTIME_DIR"
fi
echo "start the server again:  sudo systemctl start studio"
