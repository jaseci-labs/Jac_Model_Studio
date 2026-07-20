#!/bin/bash
# Multi-tenant auth isolation smoke test. Requires a running studio API.
# Usage: JAC_API=http://localhost:8001 ./smoke_auth.sh
set -euo pipefail
API="${JAC_API:-http://localhost:8001}"
TS="$(date +%s)"
A="alice-$TS@example.com"
B="bob-$TS@example.com"
PW="test-pass-123"

echo "=== unauthenticated list_chats should 401 ==="
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/function/list_chats" \
  -H "Content-Type: application/json" -d '{}')
if [[ "$code" != "401" ]]; then
  echo "FAIL: expected 401, got $code" >&2
  exit 1
fi
echo "OK ($code)"

register() {
  local email="$1"
  curl -sf -X POST "$API/user/register" -H "Content-Type: application/json" -d "{
    \"identities\": [{\"type\": \"email\", \"value\": \"$email\"}],
    \"credential\": {\"type\": \"password\", \"password\": \"$PW\"}
  }" >/dev/null
}

login() {
  local email="$1"
  curl -sf -X POST "$API/user/login" -H "Content-Type: application/json" -d "{
    \"identity\": {\"type\": \"email\", \"value\": \"$email\"},
    \"credential\": {\"type\": \"password\", \"password\": \"$PW\"}
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['token'])"
}

echo "=== register + login alice & bob ==="
register "$A"
register "$B"
TOK_A=$(login "$A")
TOK_B=$(login "$B")
echo "OK"

echo "=== alice creates chat ==="
CHAT=$(curl -sf -X POST "$API/function/create_chat" \
  -H "Authorization: Bearer $TOK_A" -H "Content-Type: application/json" \
  -d '{"title": "alice secret", "workspace": "01"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "chat_id=$CHAT"

echo "=== bob cannot read alice messages ==="
bob_msgs=$(curl -sf -X POST "$API/function/get_messages" \
  -H "Authorization: Bearer $TOK_B" -H "Content-Type: application/json" \
  -d "{\"chat_id\": \"$CHAT\"}")
if [[ "$bob_msgs" != "[]" ]]; then
  echo "FAIL: bob saw alice messages: $bob_msgs" >&2
  exit 1
fi
echo "OK (empty)"

echo "=== bob cannot delete alice chat ==="
del_ok=$(curl -sf -X POST "$API/function/delete_chat" \
  -H "Authorization: Bearer $TOK_B" -H "Content-Type: application/json" \
  -d "{\"chat_id\": \"$CHAT\"}")
if [[ "$del_ok" != "false" ]]; then
  echo "FAIL: bob delete returned $del_ok" >&2
  exit 1
fi
echo "OK (false)"

echo "=== alice still has the chat ==="
alice_chats=$(curl -sf -X POST "$API/function/list_chats" \
  -H "Authorization: Bearer $TOK_A" -H "Content-Type: application/json" -d '{}')
echo "$alice_chats" | python3 -c "
import sys,json
chats=json.load(sys.stdin)
ids=[c['id'] for c in chats]
assert '$CHAT' in ids, chats
print('OK')
"

echo "=== unauthenticated create_gpu_instance should 401 ==="
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/function/create_gpu_instance" \
  -H "Content-Type: application/json" -d '{"offer_id": 1}')
if [[ "$code" != "401" ]]; then
  echo "FAIL: expected 401, got $code" >&2
  exit 1
fi
echo "OK ($code)"

echo "smoke_auth passed"
