#!/usr/bin/env bash
# Call a route of the deployed API without dealing with API Gateway resource
# ids, JMESPath or shell differences.
#
#   ./scripts/invoke.sh POST /observations '{"sku":"MLA-1","precio":100}'
#   ./scripts/invoke.sh GET  '/products/{sku}' /products/MLA-1
#   ./scripts/invoke.sh PUT  '/products/{sku}' /products/MLA-1 '{"precioObjetivo":90}'
#   ./scripts/invoke.sh GET  /observations            # any registered path
#
# Usage: invoke.sh METHOD ROUTE [CONCRETE_PATH] [BODY]
#   ROUTE          the template path, e.g. /products/{sku}
#   CONCRETE_PATH  what the request carries, e.g. /products/MLA-1
#                  (only for routes with a parameter; a third argument that
#                  does not start with / is taken as the body)
#   BODY           JSON text
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STACK="${STACK:-price-watch}"

if [ $# -lt 2 ]; then
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

METHOD=$1
ROUTE=$2

# Third argument is the concrete path when it looks like a path, otherwise it is
# the body. Without this, `invoke.sh POST /observations '{"sku":"X"}'` would send
# the JSON as the request path.
if [ $# -ge 3 ] && [ "${3#/}" != "$3" ]; then
  CONCRETE=$3
  BODY=${4:-}
else
  CONCRETE=$ROUTE
  BODY=${3:-}
fi

if [ ! -f .emulator.env ]; then
  echo "missing .emulator.env - run 'make up' first" >&2
  exit 1
fi
# shellcheck disable=SC1091
. ./.emulator.env

API_ID=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='RestApiId'].OutputValue" --output text 2>/dev/null | tail -1)
if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
  echo "stack $STACK not deployed - run 'make deploy'" >&2
  exit 1
fi

RESOURCE_ID=""
for _ in $(seq 1 20); do
  RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --output json 2>/dev/null \
    | python3 -c '
import json, sys
want = sys.argv[1]
for item in json.load(sys.stdin).get("items", []):
    if item.get("path") == want:
        print(item["id"])
        break
' "$ROUTE")
  [ -n "$RESOURCE_ID" ] && break
  sleep 0.3
done

if [ -z "$RESOURCE_ID" ]; then
  echo "no resource with path $ROUTE in this API. Registered paths:" >&2
  aws apigateway get-resources --rest-api-id "$API_ID" \
    --query 'items[].path' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/  /' >&2
  exit 1
fi

ARGS=(--rest-api-id "$API_ID" --resource-id "$RESOURCE_ID" --http-method "$METHOD")
[ -n "$BODY" ] && ARGS+=(--body "$BODY")
# ALWAYS pass the path, even for routes without parameters. Without it the
# emulator drops the body into event.path and leaves event.body null, which
# looks like a broken handler.
ARGS+=(--path-with-query-string "$CONCRETE")

aws apigateway test-invoke-method "${ARGS[@]}" --output json 2>&1 | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    print(raw.strip()[:2000])
    raise SystemExit(1)
status = data.get("status")
body = data.get("body", "")
print(f"status: {status}")
try:
    print("body:   " + json.dumps(json.loads(body), indent=2, ensure_ascii=False))
except Exception:
    if body:
        print("body:   " + str(body))
log = data.get("log") or ""
errors = [line for line in log.splitlines() if "Error" in line or "error" in line]
if errors:
    print("log:    " + " | ".join(errors[:3]))
'
