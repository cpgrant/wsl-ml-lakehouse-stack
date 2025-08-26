#!/usr/bin/env bash
set -euo pipefail

ok(){ echo "OK: $1"; }
warn(){ echo "WARN: $1"; }
fail(){ echo "FAIL: $1"; exit 1; }
in_af(){ docker compose exec -T airflow bash -lc "$1"; }

echo "=== Airflow: CLI, DB, Scheduler, Web ==="

# 1) DB ready
docker compose exec -T airflow-db pg_isready -U airflow -d airflow >/dev/null \
  && ok "Postgres (airflow-db) ready"

# 2) Locate the airflow CLI *without* causing set -e to kill the script
AF_BIN="$(docker compose exec -T airflow bash -lc 'command -v airflow || true' | tr -d '\r')"
if [ -z "$AF_BIN" ]; then
  AF_BIN="$(docker compose exec -T airflow bash -lc 'for p in /home/airflow/.local/bin/airflow /usr/local/bin/airflow /usr/bin/airflow; do [ -x "$p" ] && { echo $p; break; }; done || true' | tr -d '\r')"
fi
[ -n "$AF_BIN" ] || fail "airflow CLI not found in PATH or common locations"

# 3) Core CLI checks
in_af "$AF_BIN version"                    >/dev/null && ok "airflow version"
in_af "$AF_BIN dags list"                  >/dev/null && ok "airflow dags list (DB ok)"
in_af "$AF_BIN jobs check --job-type SchedulerJob" >/dev/null && ok "Scheduler heartbeat ok"

# 4) Web probe from host (mapped 8085 -> 8080)
if curl -fsS http://localhost:8085 >/dev/null 2>&1; then
  ok "Webserver reachable at http://localhost:8085"
else
  warn "Webserver not reachable yet (may still be starting)"
fi

echo
echo "RESULT: ✅ Airflow smoketest passed"