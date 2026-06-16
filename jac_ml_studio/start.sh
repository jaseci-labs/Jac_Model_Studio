#!/bin/bash
# Jac ML Studio: FastAPI model server (:8400) + Next.js UI (:3000). Ctrl-C stops both.
set -e
cd "$(dirname "$0")"

export JAC_STUDIO_DATA_ROOT="${JAC_STUDIO_DATA_ROOT:-/Volumes/ExtremePro/JaseciLabs/DataGeneration}"

server/.venv/bin/uvicorn app:app --app-dir server --host 127.0.0.1 --port 8400 &
SERVER_PID=$!

(cd ui && npm run dev) &
UI_PID=$!

trap 'kill $SERVER_PID $UI_PID 2>/dev/null' INT TERM EXIT
wait
