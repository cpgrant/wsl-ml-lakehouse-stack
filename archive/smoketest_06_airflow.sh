#!/usr/bin/env bash
set -euo pipefail

ok(){ echo "OK: $1"; }
warn(){ echo "WARN: $1"; }
fail(){ echo "FAIL: $1"; exit 1; }

echo "=== Airflow: CLI, DB, Scheduler, Web ==="

# 1) CLI reachable
docker compose exec -T airflow airflow version >/dev/null && ok "airflow version"

# 2) DB reachable (psql ping from airflow-db)
docker compose exec -T airflow-db pg_isready -U airflow -d airflow >/dev/null && ok "Postgres (airflow-db) ready"

# 3) Basic CLI DB call (lists DAGS; proves ORM/DB connection works)
docker compose exec -T airflow airflow dags list >/dev/null && ok "airflow dags list (DB ok)"

# 4) Scheduler heartbeat check (CLI)
docker compose exec -T airflow airflow jobs check --job-type SchedulerJob >/dev/null && ok "Scheduler heartbeat ok"

# 5) Optional web health (2.9+ exposes /health). Don’t fail if not present.
if curl -fsS http://localhost:8085/health >/dev/null 2>&1; then
  ok "Webserver /health reachable on :8085"
else
  warn "Webserver /health not reachable (may be fine depending on image/ports)"
fi

echo
echo "RESULT: ✅ Airflow smoketest passed"
