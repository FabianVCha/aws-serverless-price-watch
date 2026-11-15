#!/usr/bin/env bash
# Package both functions, upload them to the artifact bucket and create or
# update the CloudFormation stack.
#
# Why not `aws cloudformation deploy`: this script polls the stack itself, so
# every step is visible and nothing hides behind a waiter.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STACK="${STACK:-price-watch}"
BUCKET="${BUCKET:-price-watch-artifacts}"

if [ ! -f .emulator.env ]; then
  echo "missing .emulator.env - run 'make up' first" >&2
  exit 1
fi
# shellcheck disable=SC1091
. ./.emulator.env

mkdir -p .build

# No `zip` on this machine, so build the archives with the python standard
# library. The archive root must hold index.mjs, not the folder.
zip_dir() {
  python3 - "$1" "$2" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _dirs, files in os.walk(src):
        for name in files:
            path = os.path.join(root, name)
            z.write(path, os.path.relpath(path, src))
print(f"packed {src} -> {out}")
PY
}

zip_dir src/api .build/api.zip
zip_dir src/notifier .build/notifier.zip

# The S3 key carries a hash of the package. CloudFormation only updates a
# Lambda when the template changes, so a stable key would silently keep the
# old code deployed after an edit.
API_KEY="api-$(sha256sum .build/api.zip | cut -c1-12).zip"
NOTIFIER_KEY="notifier-$(sha256sum .build/notifier.zip | cut -c1-12).zip"

echo "== artifact bucket =="
if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  aws s3 mb "s3://$BUCKET" >/dev/null
  echo "created s3://$BUCKET"
fi
aws s3 cp --only-show-errors .build/api.zip "s3://$BUCKET/$API_KEY"
aws s3 cp --only-show-errors .build/notifier.zip "s3://$BUCKET/$NOTIFIER_KEY"
echo "uploaded $API_KEY and $NOTIFIER_KEY"

COMMON=(
  --stack-name "$STACK"
  --template-body "file://$ROOT/template.yaml"
  --capabilities CAPABILITY_NAMED_IAM
  --parameters "ParameterKey=ArtifactBucket,ParameterValue=$BUCKET"
               "ParameterKey=ApiCodeKey,ParameterValue=$API_KEY"
               "ParameterKey=NotifierCodeKey,ParameterValue=$NOTIFIER_KEY"
)

POLL=1
if aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then
  if [ "${RECREATE:-1}" = "1" ]; then
    # The emulator cannot update a stack that owns an event source mapping:
    # UpdateStack tries to create a second mapping with the same queue and
    # function and the whole stack rolls back. Delete and create instead,
    # which also matches how the emulator is meant to be used (ephemeral
    # state). On real AWS leave RECREATE=0 and the update path below is used.
    echo "== recreating stack (RECREATE=1) =="
    aws cloudformation delete-stack --stack-name "$STACK" >/dev/null
    for _ in $(seq 1 120); do
      gone=$(aws cloudformation describe-stacks --stack-name "$STACK" \
             --query 'Stacks[0].StackStatus' --output text 2>/dev/null | tail -1 || true)
      [ -z "$gone" ] || [ "$gone" = "None" ] || [ "$gone" = "DELETE_COMPLETE" ] && break
      sleep 1
    done
    # The stack disappears from describe-stacks before its resources finish
    # deleting. Creating the stack again too early fails with "Table is being
    # deleted", so wait until no resource of this stack is left behind.
    remaining() {
      local n=0
      if aws dynamodb list-tables --query 'TableNames[]' --output text 2>/dev/null | grep -q 'price-watch'; then n=$((n + 1)); fi
      if aws sqs list-queues --query 'QueueUrls[]' --output text 2>/dev/null | grep -q 'price-watch'; then n=$((n + 1)); fi
      printf '%s' "$n"
    }
    for _ in $(seq 1 60); do
      [ "$(remaining)" = "0" ] && break
      sleep 1
    done
    aws cloudformation create-stack "${COMMON[@]}" >/dev/null
  else
    echo "== update-stack =="
    if ! out=$(aws cloudformation update-stack "${COMMON[@]}" 2>&1); then
      case "$out" in
        *"No updates are to be performed"*)
          echo "no changes to apply"
          POLL=0
          ;;
        *)
          echo "$out" >&2
          exit 1
          ;;
      esac
    fi
  fi
else
  echo "== create-stack =="
  aws cloudformation create-stack "${COMMON[@]}" >/dev/null
fi

status=""
if [ "$POLL" = "1" ]; then
  for _ in $(seq 1 120); do
    status=$(aws cloudformation describe-stacks --stack-name "$STACK" \
             --query 'Stacks[0].StackStatus' --output text 2>/dev/null | tail -1 || true)
    case "$status" in
      CREATE_COMPLETE|UPDATE_COMPLETE) break ;;
      CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_FAILED|UPDATE_ROLLBACK_COMPLETE|UPDATE_FAILED|UPDATE_ROLLBACK_FAILED)
        echo "stack ended in $status" >&2
        echo "--- failed resources ---" >&2
        aws cloudformation describe-stack-events --stack-name "$STACK" --output json 2>/dev/null \
          | python3 -c '
import json, sys
events = json.load(sys.stdin).get("StackEvents", [])
for ev in events:
    if "FAILED" in ev.get("ResourceStatus", ""):
        print(ev.get("LogicalResourceId"), "-", ev.get("ResourceStatusReason", "")[:300])
' >&2 || true
        exit 1
        ;;
    esac
    sleep 2
  done

  if [ "$status" != "CREATE_COMPLETE" ] && [ "$status" != "UPDATE_COMPLETE" ]; then
    echo "stack did not settle (last status: ${status:-unknown})" >&2
    exit 1
  fi
  echo "stack $status"
else
  echo "stack unchanged, still deployed"
fi

aws cloudformation describe-stacks --stack-name "$STACK" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text
