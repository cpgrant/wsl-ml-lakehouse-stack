#!/usr/bin/env bash
set -euo pipefail

ok(){ echo "OK: $1"; }
skip(){ echo "SKIP: $1"; exit 0; }
fail(){ echo "FAIL: $1"; exit 1; }

echo "=== Spark ⇄ MinIO (S3A) Parquet roundtrip ==="

# Bucket to use; prefer your compose var if set
BUCKET="${MINIO_BUCKET:-smoketest-bucket}"

# Prefer service-user creds if provided; otherwise fall back to root (if allowed)
AK="${MINIO_SA_ACCESS:-}"
SK="${MINIO_SA_SECRET:-}"
if [[ -z "$AK" || -z "$SK" ]]; then
  AK="$(docker compose exec -T minio sh -lc 'printf "%s" "${MINIO_ROOT_USER:-${MINIO_ACCESS_KEY}}"' | tr -d "\r" || true)"
  SK="$(docker compose exec -T minio sh -lc 'printf "%s" "${MINIO_ROOT_PASSWORD:-${MINIO_SECRET_KEY}}"' | tr -d "\r" || true)"
fi
if [[ -z "$AK" || -z "$SK" ]]; then
  skip "No S3 credentials available; export MINIO_SA_ACCESS/MINIO_SA_SECRET or set root creds."
fi

# Ensure boto3 is available and create the bucket if missing
if ! docker compose exec -T pydev python -c "import boto3" >/dev/null 2>&1; then
  docker compose exec -T pydev pip install --quiet boto3
fi

docker compose exec -T pydev python - <<PY
import os, sys, boto3, botocore
ak="${AK}"; sk="${SK}"; endpoint="http://minio:9000"; bucket="${BUCKET}"

s3 = boto3.client("s3",
    endpoint_url=endpoint,
    aws_access_key_id=ak,
    aws_secret_access_key=sk,
    region_name=os.getenv("AWS_REGION","us-east-1"),
    config=boto3.session.Config(signature_version="s3v4"),
)

def ensure_bucket(b):
    try:
        s3.head_bucket(Bucket=b)
        print(f"bucket exists: {b}")
    except botocore.exceptions.ClientError as e:
        code = int(e.response.get("ResponseMetadata",{}).get("HTTPStatusCode", 0))
        if code == 404:
            # MinIO ignores LocationConstraint for single region; create plain
            s3.create_bucket(Bucket=b)
            print(f"bucket created: {b}")
        else:
            raise

ensure_bucket(bucket)
PY

# Run Spark job with S3A jars pulled on-demand
docker compose exec -T pydev python - <<PY
from pyspark.sql import SparkSession

ak="${AK}"
sk="${SK}"
bucket="${BUCKET}"

spark = (SparkSession.builder
    .appName("s3a-roundtrip")
    .config("spark.jars.packages", "org.apache.hadoop:hadoop-aws:3.3.4,com.amazonaws:aws-java-sdk-bundle:1.12.698")
    .config("spark.hadoop.fs.s3a.access.key", ak)
    .config("spark.hadoop.fs.s3a.secret.key", sk)
    .config("spark.hadoop.fs.s3a.endpoint", "http://minio:9000")
    .config("spark.hadoop.fs.s3a.path.style.access", "true")
    .config("spark.hadoop.fs.s3a.connection.ssl.enabled", "false")
    .config("spark.hadoop.fs.s3a.impl", "org.apache.hadoop.fs.s3a.S3AFileSystem")
    .getOrCreate())

df = spark.createDataFrame([(1,"a"),(2,"b")],["id","val"])
path = f"s3a://{bucket}/spark/parquet"
df.write.mode("overwrite").parquet(path)

cnt = spark.read.parquet(path).count()
assert cnt == 2, f"Expected 2 rows, got {cnt}"
print("spark->minio roundtrip ok")

spark.stop()
PY

ok "Parquet write/read via S3A"
echo
echo "RESULT: ✅ Spark ⇄ MinIO smoketest passed"
