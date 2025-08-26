#!/usr/bin/env bash
set -euo pipefail

ok(){ echo "OK: $1"; }
fail(){ echo "FAIL: $1"; exit 1; }

echo "=== Spark: master/worker UIs + PySpark local job ==="

# 1) Spark master UI reachable inside spark-master
docker compose exec -T spark-master bash -lc 'curl -fsS http://localhost:8080 >/dev/null' \
  && ok "Spark master UI (8080) reachable inside container"

# 2) Spark worker UI reachable inside spark-worker
docker compose exec -T spark-worker bash -lc 'curl -fsS http://localhost:8081 >/dev/null' \
  && ok "Spark worker UI (8081) reachable inside container"

# 3) Run a tiny PySpark job inside pydev
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
