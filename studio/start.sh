#!/bin/bash
# Jac ML Studio (pure Jac): one process serves the API (:8001) + Vite UI (:8000).
# Ctrl-C stops it. The old FastAPI+Next app (server/, ui/) was replaced by studio/.
set -e
cd "$(dirname "$0")"

export JAC_STUDIO_DATA_ROOT="${JAC_STUDIO_DATA_ROOT:-/Volumes/ExtremePro/JaseciLabs/DataGeneration}"

exec jac start --dev main.jac
