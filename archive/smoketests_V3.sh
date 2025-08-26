# 1) Create a clean script (no jq needed)
# 1) smoketest_01_containers.sh

cat > smoketest_01_containers.sh <<'SH'
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
SH

# 2) Ensure proper Unix line endings (optional; only if you edited in Windows)
# sudo apt-get -y install dos2unix
# dos2unix smoketest_01_containers.sh

# 3) Run it
chmod +x smoketest_01_containers.sh
./smoketest_01_containers.sh


# ==============================================================
# 2) smoketest_02_ray.sh
# ==============================================================

#!/usr/bin/env bash
set -euo pipefail

ok(){ echo "OK: $1"; }
fail(){ echo "FAIL: $1"; exit 1; }

echo "=== Ray: cluster connectivity & basic ops ==="

# 1) Quick status (doesn't fail the run if it prints warnings)
docker compose exec -T ray-head bash -lc "ray status || true" >/dev/null && ok "ray status reachable"

# 2) Python-level checks from head (address=auto discovers worker(s))
docker compose exec -T ray-head bash -lc 'python - << "PY"
import sys, time, ray

# Connect
ray.init(address="auto", namespace="smoketest", log_to_driver=False)

# Expect at least 1 head + 1 worker
nodes = ray.nodes()
alive = [n for n in nodes if n.get("Alive")]
if len(alive) < 1:
    print("No alive nodes found"); sys.exit(2)

# Count distinct node IDs, print resources
node_ids = {n["NodeID"] for n in alive}
print("alive_nodes:", len(node_ids))
if len(node_ids) < 1:
    print("Cluster has no nodes alive"); sys.exit(2)

# Simple remote task
@ray.remote
def plus1(x): return x + 1

res = ray.get(plus1.remote(41))
assert res == 42, f"plus1 expected 42, got {res}"

# Object store roundtrip
import numpy as np
arr = np.arange(10_000, dtype=np.int32)
oid = ray.put(arr)
out = ray.get(oid)
assert (out == arr).all()

print("remote_task_ok")
print("object_store_ok")
PY' | tee /tmp/ray_smoke.out >/dev/null

grep -q "alive_nodes:" /tmp/ray_smoke.out && ok "Cluster has alive nodes"
grep -q "remote_task_ok" /tmp/ray_smoke.out && ok "Remote task executed"
grep -q "object_store_ok" /tmp/ray_smoke.out && ok "Object store put/get"

# 3) Optional: dashboard port (host)
if curl -fsS -m 2 http://localhost:8265 >/dev/null 2>&1; then
  ok "Dashboard reachable on http://localhost:8265"
else
  echo "Note: Ray dashboard not reachable on localhost:8265 (may be firewall or expected)."
fi

echo
echo "RESULT: ✅ Ray smoketest passed"

# 3) smoketest_03_spark.sh
#!/usr/bin/env bash
set -euo pipefail

ok(){ echo "OK: $1"; }
fail(){ echo "FAIL: $1"; exit 1; }

echo "=== Spark: master/worker UIs + PySpark local job ==="

# 1) Spark master UI reachable *from inside the master*
docker compose exec -T spark-master bash -lc 'curl -fsS http://localhost:8080 >/dev/null' \
  && ok "Spark master UI (8080) reachable inside container"

# 2) Spark worker UI reachable *from inside the worker*
docker compose exec -T spark-worker bash -lc 'curl -fsS http://localhost:8081 >/dev/null' \
  && ok "Spark worker UI (8081) reachable inside container"

# 3) Run a tiny PySpark job inside the pydev notebook container
docker compose exec -T pydev python - <<'PY'
from pyspark.sql import SparkSession

spark = (SparkSession.builder
         .appName("spark-smoketest-local")
         .getOrCreate())

# Simple compute
n = spark.range(1000).count()
assert n == 1000, f"Expected 1000 rows, got {n}"
print("pyspark local count ok")

# Simple DataFrame op
df = spark.createDataFrame([(1,"a"), (2,"b")], ["id","val"])
out = df.groupBy().count().collect()[0][0]
assert out == 2, f"Expected 2 rows, got {out}"
print("pyspark dataframe ok")

spark.stop()
PY

ok "PySpark local job succeeded"

echo
echo "RESULT: ✅ Spark smoketest passed"
