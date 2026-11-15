#!/usr/bin/env bash
# Minimal harness for the Price Watch exercise.
#
# This script proves only that the happy path of each requirement is wired:
# one call per requirement, one coarse assertion each.
#
# What it deliberately does NOT check - that part is yours (spec/SPEC.md):
#   - that a repeated observation is really idempotent
#   - the exact statistics
#   - the shape of the alert message
#   - that a failing record stays in the queue
#   - that a duplicated message is tolerated
#
# Extend this file or add your own beside it. Do not weaken what is here.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STACK="${STACK:-price-watch}"
SKU="MLA-TEST-1"

[ -f .emulator.env ] && . ./.emulator.env

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; }

stack_output() {
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null | tail -1
}

API_ID=$(stack_output RestApiId)
TABLE=$(stack_output TableName)
QUEUE_URL=$(stack_output QueueUrl)

if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
  echo "cannot read stack outputs - is the stack deployed? (make deploy)" >&2
  exit 1
fi

# test-invoke-method wants a resource id. The API lists resources by template
# path ("/products/{sku}"), not by the path you are requesting, and the list
# can come back empty right after creation, so retry.
resolve() {
  local want="$1" id=""
  for _ in $(seq 1 20); do
    id=$(aws apigateway get-resources --rest-api-id "$API_ID" --output json 2>/dev/null \
      | python3 -c '
import json, sys
want = sys.argv[1]
for item in json.load(sys.stdin).get("items", []):
    if item.get("path") == want:
        print(item["id"])
        break
' "$want")
    [ -n "$id" ] && { printf '%s' "$id"; return 0; }
    sleep 0.5
  done
  return 1
}

# invoke METHOD ROUTE [CONCRETE_PATH] [BODY] -> prints "<status>\t<body>"
invoke() {
  local method="$1" route="$2" concrete="${3:-$2}" body="${4:-}" rid
  rid=$(resolve "$route") || { printf 'ERR\tresource %s not found' "$route"; return 0; }
  local args=(--rest-api-id "$API_ID" --resource-id "$rid" --http-method "$method")
  [ -n "$body" ] && args+=(--body "$body")
  [ "$concrete" != "/observations" ] && args+=(--path-with-query-string "$concrete")
  aws apigateway test-invoke-method "${args[@]}" --output json 2>&1 | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    print("ERR\t" + raw.strip().replace("\n", " ")[:300])
    raise SystemExit
print(str(data.get("status")) + "\t" + str(data.get("body", "")))
'
}

status_of() { printf '%s' "$1" | cut -f1; }
body_of()   { printf '%s' "$1" | cut -f2-; }

observe() { # observe PRICE TIMESTAMP
  invoke POST /observations /observations \
    "$(printf '{"sku":"%s","precio":%s,"moneda":"COP","url":"https://example.com/p","capturadoEn":"%s"}' \
       "$SKU" "$1" "$2")"
}

echo "== R1 receive an observation"
R1=$(observe 100 "2026-11-14T20:00:00Z")
case "$(status_of "$R1")" in
  200|201) ok "POST /observations answered 2xx" ;;
  *) bad "POST /observations answered 2xx" "status=$(status_of "$R1") body=$(body_of "$R1")" ;;
esac
STORED=$(aws dynamodb query --table-name "$TABLE" --output json 2>/dev/null \
  --key-condition-expression 'pk = :p' \
  --expression-attribute-values "{\":p\":{\"S\":\"SKU#$SKU\"}}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Count","ERR"))' 2>/dev/null)
if [ "${STORED:-0}" -ge 1 ] 2>/dev/null; then
  ok "the observation reached the table"
else
  bad "the observation reached the table" "count=${STORED:-?}"
fi

echo "== R2 answer statistics"
R2=$(invoke GET "/products/{sku}" "/products/$SKU")
if [ "$(status_of "$R2")" = "200" ] && [ -n "$(body_of "$R2")" ]; then
  ok "GET /products/{sku} answered 200 with a body"
else
  bad "GET /products/{sku} answered 200 with a body" \
      "status=$(status_of "$R2") body=$(body_of "$R2")"
fi

echo "== R3 send an alert"
R3=$(invoke PUT "/products/{sku}" "/products/$SKU" '{"precioObjetivo":90}')
case "$(status_of "$R3")" in
  200|201|204) ok "PUT /products/{sku} answered 2xx" ;;
  *) bad "PUT /products/{sku} answered 2xx" "status=$(status_of "$R3") body=$(body_of "$R3")" ;;
esac
observe 89.9 "2026-11-14T23:00:00Z" >/dev/null
QUEUED=""
for _ in $(seq 1 20); do
  RAW=$(aws sqs receive-message --queue-url "$QUEUE_URL" --max-number-of-messages 1 \
        --visibility-timeout 0 --output json 2>/dev/null || true)
  if printf '%s' "$RAW" | grep -q '"Messages"'; then QUEUED="yes"; break; fi
  sleep 0.5
done
if [ -n "$QUEUED" ]; then
  ok "an alert landed in the queue"
else
  bad "an alert landed in the queue" "queue empty"
fi

echo "== R4 consume asynchronously"
sleep 8
INVOKED=$(aws logs tail "/aws/lambda/$(stack_output NotifierFunctionName)" 2>/dev/null \
  | grep -c 'batch_received' || true)
if [ "${INVOKED:-0}" -ge 1 ]; then
  ok "the notifier was invoked by the queue"
else
  bad "the notifier was invoked by the queue" "no batch_received line in its log"
fi

printf '\n----------------------------------------\n'
printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
printf 'Happy path only. The assertions that matter are yours: spec/SPEC.md\n'
[ "$FAIL" -eq 0 ] || exit 1
