#!/usr/bin/env bash
# Start, stop or inspect the local AWS emulator and write the env file that
# every other script sources.
#
#   scripts/emulator.sh up      start it (idempotent) and write .emulator.env
#   scripts/emulator.sh down    stop it
#   scripts/emulator.sh status  running or not
#   scripts/emulator.sh env     print the env file
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-9297}"
ENVFILE="$ROOT/.emulator.env"
PIDFILE="$ROOT/.emulator.pid"
LOGFILE="$ROOT/.emulator.log"
STATE_DIR="$HOME/.aws/emulator/$PORT"

is_running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

start() {
  if is_running; then
    echo "emulator already running (pid $(cat "$PIDFILE"), port $PORT)"
    return 0
  fi
  if ! command -v aws-emulator >/dev/null 2>&1; then
    echo "aws-emulator not found in PATH" >&2
    exit 1
  fi
  echo "starting aws-emulator on port $PORT"
  aws-emulator --telemetry off -p "$PORT" >"$LOGFILE" 2>&1 &
  echo $! >"$PIDFILE"

  local code=""
  for _ in $(seq 1 80); do
    if [ -f "$STATE_DIR/ca.pem" ]; then
      code=$(curl -s -o /dev/null -w '%{http_code}' \
             --cacert "$STATE_DIR/ca.pem" "https://127.0.0.1:$PORT/__admin/health" 2>/dev/null || true)
      [ "$code" = "200" ] && break
    fi
    sleep 0.25
  done
  if [ "$code" != "200" ]; then
    echo "emulator did not become healthy; see $LOGFILE" >&2
    exit 1
  fi

  cat >"$ENVFILE" <<EOF
export AWS_ENDPOINT_URL=https://127.0.0.1:$PORT
export AWS_SHARED_CREDENTIALS_FILE=$STATE_DIR/emulator_credentials
export AWS_CONFIG_FILE=$STATE_DIR/config
export AWS_CA_BUNDLE=$STATE_DIR/ca.pem
export AWS_EC2_METADATA_DISABLED=true
export AWS_DISABLE_HOST_PREFIX_INJECTION=true
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
EOF
  echo "healthy on https://127.0.0.1:$PORT (env written to .emulator.env)"
}

stop() {
  if is_running; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    for _ in $(seq 1 40); do
      is_running || break
      sleep 0.25
    done
    echo "emulator stopped"
  else
    echo "emulator was not running"
  fi
  rm -f "$PIDFILE"
}

case "${1:-status}" in
  up) start ;;
  down) stop ;;
  status)
    if is_running; then echo "running (pid $(cat "$PIDFILE"), port $PORT)"; else echo "stopped"; fi
    ;;
  env) cat "$ENVFILE" ;;
  *) echo "usage: $0 {up|down|status|env}" >&2; exit 2 ;;
esac
