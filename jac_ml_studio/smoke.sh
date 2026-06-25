#!/bin/bash
# Boot check: API answers and UI serves. Run while start.sh is up.
set -e
echo -n "api /function/list_models: "
curl -sf -X POST http://localhost:8001/function/list_models \
  -H "Content-Type: application/json" -d '{}' | head -c 120 && echo " ... OK"
echo -n "api /function/dataset_stats: "
curl -sf -X POST http://localhost:8001/function/dataset_stats \
  -H "Content-Type: application/json" -d '{}' >/dev/null && echo "OK"
echo -n "ui :8000: "
curl -sf -o /dev/null http://localhost:8000 && echo "OK"
echo "smoke passed"
