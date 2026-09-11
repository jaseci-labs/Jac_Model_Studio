#!/bin/bash
# Boot check: API answers (authenticated) and UI serves. Run while the
# browser-target server is up in local mode (`jac start --dev main.jac` with
# JAC_LOCAL_USER=1, as start.sh sets). Exits non-zero on any failure.
set -euo pipefail
API="${JAC_API:-http://localhost:8001}"
UI="${JAC_UI:-http://localhost:8000}"

TOK=$(curl -sf -X POST "$API/function/local_session" -H "Content-Type: application/json" -d '{}' \
  | python3 -c "import sys,json; t=json.load(sys.stdin)['data']['result']; assert t, 'no token (not local mode?)'; print(t)")

call() {  # call <endpoint> <json-body> -> prints result JSON, fails on !ok
  curl -sf -X POST "$API/function/$1" -H "Authorization: Bearer $TOK" \
    -H "Content-Type: application/json" -d "$2" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['ok'], d; print(json.dumps(d['data']['result'])[:160])"
}

for ep in list_models dataset_stats dataset_files ui_layout jms_ui_layout active_jobs list_cloud_runs list_clusters; do
  echo -n "api $ep: "; call "$ep" '{}'
done
echo -n "api list_projects: "; call list_projects '{"workspace": ""}'
echo -n "ui $UI: "; curl -sf -o /dev/null "$UI" && echo OK
echo "smoke passed"
