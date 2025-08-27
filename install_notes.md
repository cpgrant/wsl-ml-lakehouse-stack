# Install Guide — WSL2 on Windows 11

This document walks you from a clean Windows 11 + WSL2 setup to a running **ML Lakehouse Stack** (Ray, Spark, Kafka, MinIO, Airflow, dbt, Beam, Terraform, Jupyter/PySpark). It also includes smoke tests, common fixes, and day‑2 ops.

> **Tested on:** Windows 11 + WSL2 (Ubuntu 22.04), Docker Desktop WSL backend, Compose v2 (GNU/Linux 6.6.87.2-microsoft-standard-WSL2 x86_64).  
> **Default ports:** MinIO 9000/9001, Ray 8265, Spark 7077/8080/8081, Airflow 8085, Kafka 29092, Jupyter 8888.

---

## 0) Requirements

- **Windows 11** (22H2 or newer) with **WSL2** enabled.
- **Ubuntu** distro in WSL (recommend **Ubuntu 22.04 LTS**).
- **Docker Desktop** for Windows ≥ 4.34 with **WSL2 backend**.
  - Settings → **General**: enable *Use the WSL 2 based engine*.
  - Settings → **Resources → WSL Integration**: enable your Ubuntu distro.
  - (Optional GPU) Settings → **Resources**: enable **GPU** support if you have an NVIDIA GPU.
- **NVIDIA GPU (optional)**: Install the latest Windows NVIDIA driver (R535+). Verify in **PowerShell**:
  - `nvidia-smi`
  - In WSL: `nvidia-smi` should also work when GPU passthrough is available. In Docker: `docker run --rm --gpus all nvidia/cuda:12.4.1-base nvidia-smi`.
- **Allow firewall prompts**: When Windows Security prompts for Docker/WSL networking, allow on **Private networks**.
- **Disk space**: ~10–15 GB free recommended for images + data.

> **Performance tip:** Clone and run the repo **inside** the Linux filesystem (e.g., `/home/<user>/...`) rather than under `C:\` (`/mnt/c/...`) for faster I/O with Docker/WSL.

---

## 1) First‑time system prep (inside WSL Ubuntu)

```bash
sudo apt update && sudo apt install -y git curl ca-certificates jq
```

Clone the repository to a Linux path, e.g.:

```bash
mkdir -p ~/dockerprojects && cd ~/dockerprojects
git clone <YOUR_REPO_URL> wsl-ml-lakehouse-stack
cd wsl-ml-lakehouse-stack
```

Copy the example environment and **edit values** (no quotes, no command substitution):

```bash
cp .env.example .env
# Append/ensure these (adjust as needed)
cat >> .env <<'ENV'
COMPOSE_PROJECT_NAME=wsl-ml-lakehouse-stack
TZ=Europe/Copenhagen
AWS_REGION=eu-north-1
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=minioadmin
MINIO_BUCKET=lakehouse
# Optional: set a fixed Jupyter token so you don't hunt logs
JUPYTER_TOKEN=letmein123
ENV

# Ensure LF line endings (avoid CRLF)
sed -i 's/\r$//' .env
```

**Important:** `.env` must be plain `KEY=VALUE` pairs. **Do not** use `"$(id -u)"`, quotes, or shell expressions.

---

## 2) Start the stack

```bash
docker compose pull
# If you previously tried to run parts of the stack:
docker compose down --remove-orphans || true

docker compose up -d --remove-orphans

docker compose ps   # wait for (healthy) where defined
```

If you see any warnings about missing env vars, add them to `.env` and re‑run `docker compose up -d`.

---

## 3) Reach the UIs

- **MinIO**: http://localhost:9001  
  Login: `minioadmin / minioadmin`
- **Ray Dashboard**: http://localhost:8265
- **Spark Master UI**: http://localhost:8080
- **Spark Worker UI**: http://localhost:8081
- **Airflow Web**: http://localhost:8085  
  Create an admin, if not already created:
  ```bash
  docker compose exec airflow airflow users create \
    --username admin --firstname Admin --lastname User \
    --role Admin --email admin@example.com --password admin
  ```
- **Jupyter (pydev)**: http://localhost:8888  
  If you didn’t set `JUPYTER_TOKEN`, discover it:
  ```bash
  docker compose exec pydev jupyter server list
  ```

---

## 4) Run smoke tests (recommended)

All at once:

```bash
./smoketests_all.sh
```

Individually (examples):

```bash
./smoketest_01_containers.sh
./smoketest_02_ray.sh
./smoketest_03_spark.sh
./smoketest_04_spark_minio.sh
./smoketest_05_kafka.sh
./smoketest_06_airflow.sh
./smoketest_07_dbt.sh
./smoketest_08_beam.sh
./smoketest_09_terraform.sh
./smoketest_10_delta_minio.sh
```

You should see ✅ for each.

---

## 5) Quick demo: Kafka ➜ Delta on MinIO

**Terminal A — produce a few messages**

```bash
docker compose exec kafka /opt/bitnami/kafka/bin/kafka-console-producer.sh \
  --broker-list kafka:9092 --topic smoketest
# type a couple lines, then Ctrl+C
hello
world
```

**Terminal B — Spark Structured Streaming to Delta**

```bash
docker compose exec -T pydev python - <<'PY'
from pyspark.sql import SparkSession

spark = (SparkSession.builder
  .appName("kafka-to-delta")
  .config("spark.jars.packages",
          "org.apache.spark:spark-sql-kafka-0-10_2.12:3.5.3,"
          "io.delta:delta-spark_2.12:3.2.0,"
          "org.apache.hadoop:hadoop-aws:3.3.4,"
          "com.amazonaws:aws-java-sdk-bundle:1.12.698")
  .getOrCreate())

# S3A creds for MinIO
hconf = spark.sparkContext._jsc.hadoopConfiguration()
hconf.set("fs.s3a.endpoint", "http://minio:9000")
hconf.set("fs.s3a.access.key", "minioadmin")
hconf.set("fs.s3a.secret.key", "minioadmin")
hconf.set("fs.s3a.path.style.access", "true")
hconf.set("fs.s3a.impl", "org.apache.hadoop.fs.s3a.S3AFileSystem")

df = (spark.readStream.format("kafka")
      .option("kafka.bootstrap.servers", "kafka:9092")
      .option("subscribe", "smoketest")
      .load()
      .selectExpr("CAST(value AS STRING) AS msg"))

query = (df.writeStream
   .format("delta")
   .outputMode("append")
   .option("checkpointLocation","s3a://smoketest-bucket/delta/checkpoints/smoketest")
   .start("s3a://smoketest-bucket/delta/streams/smoketest"))

print("Streaming... press Ctrl+C to stop")
query.awaitTermination()
PY
```

**Verify written data (another shell):**

```bash
docker compose exec -T pydev python - <<'PY'
from pyspark.sql import SparkSession
spark = SparkSession.builder.getOrCreate()
df = spark.read.format("delta").load("s3a://smoketest-bucket/delta/streams/smoketest")
df.show(truncate=False)
PY
```

---

## 6) Troubleshooting

**A. Container name conflicts**  
Error: `The container name "/spark-master" is already in use...`
- Cause: hard‑coded `container_name:` or leftovers from prior runs.
- Fix:
  ```bash
  for n in spark-master spark-worker kafka minio airflow airflow-db airflow-redis pydev terraform ray-head ray-worker dbt beam; do
    docker rm -f "$n" 2>/dev/null && echo "Removed $n"
  done
  # Prefer removing any `container_name:` lines from docker-compose.yml
  ```

**B. `.env` parse error**  
Error mentions quotes or `$(id -u)`.
- Fix: ensure plain `KEY=VALUE` (no quotes/shell). Remove CRLF:
  ```bash
  sed -i 's/\r$//' .env
  ```

**C. Ports already in use**  
Examples: 8080/8081/8085/8265/8888/9000/9001/29092.
- Find blockers: `sudo lsof -i :8080` or `netstat -ano | findstr :8080` (in PowerShell).
- Stop the app using the port, or adjust mapped port in `docker-compose.yml`.

**D. Docker Desktop integration**  
If `docker compose` fails inside WSL:
- In Docker Desktop → **Resources → WSL Integration**: enable your Ubuntu distro.
- Run `wsl --list --verbose` and ensure version is `2`.

**E. Jupyter token confusion**  
- Set `JUPYTER_TOKEN` in `.env` or run `docker compose exec pydev jupyter server list`.

**F. Slow Spark dependency downloads**  
- The first Spark jobs download connector JARs. For offline environments, bake them into a custom image or pre‑mount a local Ivy cache.

**G. GPU not detected in containers (optional)**
- Verify Windows `nvidia-smi` works.
- Docker Desktop → Settings → **Resources**: enable GPU.
- Test: `docker run --rm --gpus all nvidia/cuda:12.4.1-base nvidia-smi`.
- Ray should then see GPUs (`ray status` resources) if your containers request them.

**H. Windows Firewall prompts**
- Allow Docker/WSL on **Private networks**. Declining may block UIs on `localhost`.

---

## 7) Day‑2 Ops

**Update images & restart**
```bash
docker compose pull
docker compose up -d --remove-orphans
docker compose ps
```

**Full smoketest**
```bash
./smoketests_all.sh
```

**Clean shutdown (remove everything, including volumes)**
```bash
docker compose down -v --remove-orphans
```

**Reset MinIO demo bucket (DANGER: deletes bucket)**
```bash
docker compose exec minio bash -lc \
  'mc alias set local http://minio:9000 minioadmin minioadmin && mc rb --force local/smoketest-bucket && mc mb local/smoketest-bucket'
```

---

## 8) CI sanity (optional but recommended)

Add a minimal GitHub Actions workflow to validate the compose file & bash syntax on PRs:

```yaml
name: sanity
on: [push, pull_request]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: docker compose -f docker-compose.yml config > /dev/null
      - run: bash -n smoketest_*.sh scripts/*.sh
```

Commit:
```bash
git add .env.example docker-compose.yml smoketest_*.sh .github/workflows/sanity.yml
git commit -m "WSL ML lakehouse: docs + smoketests + CI sanity"
git push
```

---

## 9) Security notes

- **Change default credentials** in `.env` for any long‑running deployment (MinIO, Airflow, etc.).
- Restrict host‑port exposure if running on shared networks.
- Treat MinIO as production‑grade S3 only after configuring TLS, users, and policies.

---

## 10) Uninstall / cleanup

```bash
# Stop and remove containers
docker compose down -v --remove-orphans
# (Optional) remove any stray containers by name
for n in spark-master spark-worker kafka minio airflow airflow-db airflow-redis pydev terraform ray-head ray-worker dbt beam; do
  docker rm -f "$n" 2>/dev/null || true
done
```

---

### Appendix: Tips

- Prefer **LF** line endings in the repo; if needed: `git config core.autocrlf input` on Windows before cloning in WSL contexts.
- Keep the repo under `/home/<user>/...` for best performance with Docker/WSL.
- If you change ports in `docker-compose.yml`, also update firewall rules and any docs/scripts referencing them.

