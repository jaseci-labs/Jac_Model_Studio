#!/bin/bash
# Boot check: API answers and UI serves. Run while start.sh is up.
set -e
echo -n "api /api/models: "
curl -sf http://127.0.0.1:8400/api/models | head -c 120 && echo " ... OK"
echo -n "api /api/prompts: "
curl -sf http://127.0.0.1:8400/api/prompts >/dev/null && echo "OK"
echo -n "ui :3000: "
curl -sf -o /dev/null http://localhost:3000 && echo "OK"
echo "smoke passed"
