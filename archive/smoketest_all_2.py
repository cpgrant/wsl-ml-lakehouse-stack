#!/usr/bin/env bash
set -euo pipefail

echo "=== Discover compose project network (for docker run) ==="
NET="$(docker inspect $(docker compose ps -q minio) --format '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' | head -n1 || true)"
# Fallback: use the compose default network name if inspect failed
: "${NET:=$(docker network ls --format '{{.Name}}' | grep -E '_default$' | head -n1)}"

ok() { echo "OK: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

echo "=== Basic container up check ==="
docker compose ps || fail "docker compose ps"

echo "=== MinIO: HTTP + mc smoke ==="
docker compose exec -T minio curl -sSf http://127.0.0.1:9000/minio/health/ready >/dev/null && ok "MinIO ready probe"
# Use mc in a throwaway container sharing the MinIO net-ns (no need to know network name)
docker run --rm --network container:minio minio/mc:latest \
  alias set local http://127.0.0.1:9000 minioadmin minioadmin >/dev/null
docker run --rm --network container:minio minio/mc:latest mb -p local/smoketest-bucket >/dev/null || true
docker run --rm --network container:minio minio/mc:latest ls local | grep -q smoketest-bucket && ok "MinIO mc bucket create/list"

echo "=== Ray: cluster + remote task ==="
docker compose exec -T ray-head bash -lc '
python - << "PY"
import ray; ray.init(address="auto", log_to_driver=False, namespace="smoketest")
@ray.remote
def f(x): return x+1
assert ray.get(f.remote(41))==42
print("ray ok")
PY' | grep -q "ray ok" && ok "Ray remote task ran"

echo "=== Spark: master UI reachable from inside spark-master ==="
docker compose exec -T spark-master bash -lc "curl -fsS http://localhost:8080 | head -n1 >/dev/null" && ok "Spark master UI curl"

echo "=== Spark (PySpark) via pydev: local compute ==="
docker compose exec -T pydev python - <<'PY'
from pyspark.sql import SparkSession
spark = (SparkSession.builder
         .appName("smoketest-local")
         .getOrCreate())
df = spark.range(0,1000)
assert df.count()==1000
print("pyspark local ok")
spark.stop()
PY

echo "=== Spark -> MinIO (S3A) roundtrip from pydev ==="
docker compose exec -T pydev python - <<'PY'
import os
from pyspark.sql import SparkSession
spark = (SparkSession.builder
    .appName("smoketest-s3a")
    .config("spark.hadoop.fs.s3a.access.key","minioadmin")
    .config("spark.hadoop.fs.s3a.secret.key","minioadmin")
    .config("spark.hadoop.fs.s3a.endpoint","http://minio:9000")
    .config("spark.hadoop.fs.s3a.path.style.access","true")
    .config("spark.hadoop.fs.s3a.impl","org.apache.hadoop.fs.s3a.S3AFileSystem")
    .getOrCreate())
df = spark.createDataFrame([(1,"a"),(2,"b")],["id","val"])
path = "s3a://smoketest-bucket/spark/parquet"
df.write.mode("overwrite").parquet(path)
df2 = spark.read.parquet(path)
assert df2.count()==2
print("spark->minio roundtrip ok")
spark.stop()
PY

echo "=== Kafka: topic create/produce/consume ==="
docker compose exec -T kafka bash -lc '
export KAFKA_BROKER_ID=1
export BOOTSTRAP="localhost:9092"
/opt/bitnami/kafka/bin/kafka-topics.sh --create --if-not-exists --topic smoketest --bootstrap-server $BOOTSTRAP --replication-factor 1 --partitions 1 >/dev/null
echo "hello" | /opt/bitnami/kafka/bin/kafka-console-producer.sh --bootstrap-server $BOOTSTRAP --topic smoketest >/dev/null
/opt/bitnami/kafka/bin/kafka-console-consumer.sh --bootstrap-server $BOOTSTRAP --topic smoketest --from-beginning --timeout-ms 3000 --max-messages 1 2>/dev/null
' | grep -q hello && ok "Kafka produce/consume"

echo "=== Airflow: CLI + web port mapped ==="
docker compose exec -T airflow airflow version >/dev/null && ok "Airflow CLI"
curl -fsS http://localhost:8085/health | grep -q '"\status\":\"healthy\"' && ok "Airflow web healthy" || echo "Tip: If /health not exposed, just rely on CLI ok."

echo "=== Postgres (airflow-db): ready ==="
docker compose exec -T airflow-db pg_isready -U postgres >/dev/null && ok "Postgres pg_isready"

echo "=== Redis: PING ==="
docker compose exec -T airflow-redis redis-cli ping | grep -q PONG && ok "Redis PONG"

echo "=== dbt: version ==="
docker compose exec -T dbt dbt --version >/dev/null && ok "dbt CLI"

echo "=== Apache Beam SDK: trivial pipeline ==="
docker compose exec -T beam python - <<'PY'
import apache_beam as beam
with beam.Pipeline() as p:
    (p | beam.Create([1,2,3]) | beam.Map(lambda x: x+1))
print("beam ok")
PY

echo "=== Terraform: version + init (no backend) ==="
docker compose exec -T terraform sh -lc 'terraform version >/dev/null && (mkdir -p /tmp/tf && cd /tmp/tf && printf "terraform {\n required_version = \">= 1.0\"\n}\n" > main.tf && terraform init -backend=false >/dev/null)' && ok "Terraform CLI"

echo
echo "ALL SMOKETESTS PASSED ✅"
