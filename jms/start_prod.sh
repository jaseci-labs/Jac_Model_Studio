#!/bin/bash
# Production serve for Jac ML Studio (multi-tenant shared host).
# NOT for local dev — use ./start.sh (--dev) instead.
#
# Required env:
#   JWT_SECRET          — long random string (never use the jac default)
# Optional env:
#   JAC_STUDIO_WORKSPACE / JAC_STUDIO_DATA_ROOT
#   SPHERON_MAX_CONCURRENT / SPHERON_DAILY_BUDGET_USD / SPHERON_MAX_HOURLY
#   JAC_MAX_CONCURRENT_JOBS / JAC_TRASH_DAYS
set -euo pipefail
cd "$(dirname "$0")"

if [[ -z "${JWT_SECRET:-}" ]]; then
  echo "ERROR: JWT_SECRET must be set for production" >&2
  exit 1
fi

_STUDIO_DIR="$(pwd)"
_WORKSPACE_DEFAULT="$(dirname "$_STUDIO_DIR")"
export JAC_STUDIO_WORKSPACE="${JAC_STUDIO_WORKSPACE:-$_WORKSPACE_DEFAULT}"
export JAC_STUDIO_DATA_ROOT="${JAC_STUDIO_DATA_ROOT:-$JAC_STUDIO_WORKSPACE}"

# Open-file ceiling. Prod runs without --dev so there is no project file watcher,
# but a resident MLX model load still opens many safetensors shards + tokenizer
# files, and a service manager (launchd/systemd) can hand this process a soft
# limit as low as 256. Raise it before exec so the ceiling covers the whole run.
# See start.sh for the full measurement and the --dev watcher story.
# `-S` raises only the soft limit; bare `ulimit -n N` would clamp hard to N too.
if ! ulimit -S -n 65536 2>/dev/null; then
  ulimit -S -n "$(ulimit -Hn)" 2>/dev/null || true
fi
echo "[start_prod.sh] open-file limit: soft=$(ulimit -Sn) hard=$(ulimit -Hn)"

# Bind API on loopback; put Caddy/nginx in front for TLS (see deploy/Caddyfile).
API_PORT="${JAC_API_PORT:-8001}"
UI_PORT="${JAC_UI_PORT:-8000}"

exec jac start main.jac -p "$UI_PORT" -a "$API_PORT" < /dev/null
