#!/usr/bin/env bash
set -euo pipefail

EXPECTED=(
  airflow
  airflow-db
  airflow-redis
  beam
  dbt
  kafka
  minio
  pydev
  ray-head
  ray-worker
  spark-master
  spark-worker
  terraform
)

echo "=== L0: Containers up ==="
docker compose ps || true
echo

failures=0
for svc in "${EXPECTED[@]}"; do
  cid="$(docker compose ps -q "$svc" 2>/dev/null || true)"
  if [[ -z "$cid" ]]; then
    echo "FAIL: service '$svc' not found"
    ((failures++))
    continue
  fi

  state="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || true)"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid" 2>/dev/null || true)"

  if [[ "$state" != "running" ]]; then
    echo "FAIL: $svc state='$state' (expected running)"
    ((failures++))
    continue
  fi

  if [[ -n "$health" && "$health" != "healthy" ]]; then
    echo "FAIL: $svc health='$health' (expected healthy)"
    ((failures++))
    continue
  fi

  if [[ -n "$health" ]]; then
    echo "OK: $svc is running (health=$health)"
  else
    echo "OK: $svc is running"
  fi
done

echo
if (( failures > 0 )); then
  echo "RESULT: ❌ $failures service(s) not healthy/up"
  exit 1
else
  echo "RESULT: ✅ all expected services are Up"
fi
