#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[video-bench] $*"
}

GUNICORN_BIND="${GUNICORN_BIND:-127.0.0.1:8000}"
GUNICORN_WORKERS="${GUNICORN_WORKERS:-2}"
GUNICORN_THREADS="${GUNICORN_THREADS:-2}"
GUNICORN_TIMEOUT="${GUNICORN_TIMEOUT:-120}"

for script in /docker-entrypoint.d/*.sh; do
  if [ -x "$script" ]; then
    log "running entrypoint hook ${script}"
    "$script"
  fi
done

log "checking Django configuration"
python manage.py check

log "starting Django via gunicorn on ${GUNICORN_BIND}"
gunicorn video_bench_backend.wsgi:application \
  --bind "$GUNICORN_BIND" \
  --workers "$GUNICORN_WORKERS" \
  --threads "$GUNICORN_THREADS" \
  --timeout "$GUNICORN_TIMEOUT" \
  --access-logfile "-" \
  --error-logfile "-" &
WEB_PID=$!

log "starting nginx"
nginx -g "daemon off;" &
NGINX_PID=$!

terminate() {
  local code="${1:-0}"
  log "shutting down (code ${code})"
  for pid in "${NGINX_PID:-}" "${WEB_PID:-}"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  wait || true
  exit "$code"
}

trap 'terminate 0' SIGTERM SIGINT

if wait -n "$NGINX_PID" "$WEB_PID"; then
  exit_code=0
else
  exit_code=$?
fi

terminate "$exit_code"
