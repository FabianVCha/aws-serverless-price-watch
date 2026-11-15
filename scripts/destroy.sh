#!/usr/bin/env bash
# Delete the stack and, unless KEEP_BUCKET=1, the artifact bucket.
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

if ! aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then
  echo "stack $STACK does not exist"
else
  echo "== delete-stack =="
  aws cloudformation delete-stack --stack-name "$STACK" >/dev/null
  for _ in $(seq 1 120); do
    status=$(aws cloudformation describe-stacks --stack-name "$STACK" \
             --query 'Stacks[0].StackStatus' --output text 2>/dev/null | tail -1 || true)
    [ -z "$status" ] || [ "$status" = "DELETE_COMPLETE" ] && break
    sleep 2
  done
  echo "stack deleted"
fi

if [ "${KEEP_BUCKET:-0}" != "1" ] && aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  aws s3 rm "s3://$BUCKET" --recursive >/dev/null
  aws s3 rb "s3://$BUCKET" >/dev/null
  echo "bucket s3://$BUCKET removed"
fi
