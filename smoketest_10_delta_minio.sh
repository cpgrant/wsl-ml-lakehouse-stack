# save as: smoketest_10_delta_minio.sh
#!/usr/bin/env bash
set -euo pipefail

ok(){ echo "OK: $*"; }
fail(){ echo "FAIL: $*"; exit 1; }

echo "=== Delta Lake on MinIO (S3A) roundtrip ==="

BUCKET="${MINIO_BUCKET:-smoketest-bucket}"

# Get root creds from minio container (or use your service creds if you have them)
AK="$(docker compose exec -T minio sh -lc 'printf "%s" "${MINIO_ROOT_USER:-${MINIO_ACCESS_KEY}}"' | tr -d '\r')"
SK="$(docker compose exec -T minio sh -lc 'printf "%s" "${MINIO_ROOT_PASSWORD:-${MINIO_SECRET_KEY}}"' | tr -d '\r')"

# Ensure bucket exists (no-op if it already does)
docker compose run --rm --no-deps -e MINIO_BUCKET="$BUCKET" minio-init >/dev/null 2>&1 || true

# Run a tiny Delta write/read using explicit JAR packages (Delta + S3A)
docker compose exec -T pydev python - <<PY
import time
from pyspark.sql import SparkSession

AK="${AK}"
SK="${SK}"
BUCKET="${BUCKET}"
path = f"s3a://{BUCKET}/delta/smoke_{int(time.time())}"

packages = ",".join([
    "io.delta:delta-spark_2.12:3.2.0",
    "org.apache.hadoop:hadoop-aws:3.3.4",
    "com.amazonaws:aws-java-sdk-bundle:1.12.698",
])

spark = (
    SparkSession.builder
    .appName("delta-smoke")
    .config("spark.jars.packages", packages)
    # Enable Delta SQL features explicitly (since we're not using the helper)
    .config("spark.sql.extensions", "io.delta.sql.DeltaSparkSessionExtension")
    .config("spark.sql.catalog.spark_catalog", "org.apache.spark.sql.delta.catalog.DeltaCatalog")
    # MinIO/S3A wiring
    .config("spark.hadoop.fs.s3a.access.key", AK)
    .config("spark.hadoop.fs.s3a.secret.key", SK)
    .config("spark.hadoop.fs.s3a.endpoint", "http://minio:9000")
    .config("spark.hadoop.fs.s3a.path.style.access", "true")
    .config("spark.hadoop.fs.s3a.connection.ssl.enabled", "false")
    .config("spark.hadoop.fs.s3a.impl", "org.apache.hadoop.fs.s3a.S3AFileSystem")
    .getOrCreate()
)

df = spark.range(0, 5)
df.write.format("delta").mode("overwrite").save(path)

cnt = spark.read.format("delta").load(path).count()
assert cnt == 5, f"expected 5, got {cnt}"
print("delta->minio roundtrip ok:", path)

spark.stop()
PY

ok "Delta write/read via S3A"
echo
echo "RESULT: ✅ Delta Lake smoketest passed"
