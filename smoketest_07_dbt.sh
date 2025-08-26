#!/usr/bin/env bash
set -euo pipefail

ok(){ echo "OK: $*"; }
fail(){ echo "FAIL: $*"; exit 1; }

svc=dbt
proj_dir=/workspace/dbt/smoketest
profiles_dir=/workspace/dbt/.dbt
db_path=/workspace/dbt/smoketest.duckdb

echo "=== dbt: adapter install → project run → verify in DuckDB ==="

# 0) basic sanity
docker compose ps "$svc" >/dev/null 2>&1 || fail "dbt service not found in compose"
docker compose exec -T "$svc" dbt --version >/dev/null 2>&1 || fail "dbt CLI not available"
ok "dbt CLI present"

# 1) install duckdb adapter (compatible with dbt-core 1.8)
docker compose exec -T "$svc" bash -lc \
  'python -m pip install --no-cache-dir -q "dbt-duckdb==1.8.*" && dbt --version >/dev/null' \
  || fail "failed to install dbt-duckdb"
ok "dbt-duckdb installed"

# 2) prepare fresh project + profiles
docker compose exec -T "$svc" bash -lc "rm -rf $proj_dir $profiles_dir $db_path && mkdir -p $proj_dir/models $profiles_dir" || true

docker compose exec -T "$svc" bash -lc "cat > $proj_dir/dbt_project.yml <<'YML'
name: 'smoketest'
version: '1.0.0'
config-version: 2
profile: 'smoketest'
models:
  smoketest:
    +materialized: table
YML"

docker compose exec -T "$svc" bash -lc "cat > $proj_dir/models/example.sql <<'SQL'
select 1 as id, 'ok' as status
SQL"

docker compose exec -T "$svc" bash -lc "cat > $profiles_dir/profiles.yml <<'YML'
smoketest:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: $db_path
      threads: 1
YML"

ok "dbt project + profiles created"

# 3) debug connectivity
docker compose exec -T "$svc" bash -lc "DBT_PROFILES_DIR=$profiles_dir dbt debug --project-dir $proj_dir -q" \
  || fail "dbt debug failed"
ok "dbt debug ok"

# 4) run the model
docker compose exec -T "$svc" bash -lc "DBT_PROFILES_DIR=$profiles_dir dbt run --project-dir $proj_dir -q" \
  || fail "dbt run failed"
ok "dbt run succeeded"

# 5) verify data landed in DuckDB
docker compose exec -T "$svc" bash -lc \
  "python - <<'PY'
import duckdb
con=duckdb.connect('$db_path')
n=con.sql('select count(*) from smoketest.example').fetchone()[0]
print(n)
assert n==1, f'expected 1 row, got {n}'
PY" || fail "verification query failed"

ok "verification query returned 1 row"

echo
echo "RESULT: ✅ dbt smoketest passed"
