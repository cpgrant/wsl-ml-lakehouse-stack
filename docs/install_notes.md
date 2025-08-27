Got it 👍 — here’s a **recreated full Install Guide** with crawler support integrated, clean and self-contained:

---

# Install Guide — WSL2 on Windows 11

This guide takes you from a clean Windows 11 + WSL2 setup to a running **ML Lakehouse Stack** with:
**Ray, Spark, Kafka, MinIO, Airflow, dbt, Beam, Terraform, Jupyter/PySpark, and a demo Crawler.**

It also includes smoke tests, troubleshooting, and day-2 ops.

> **Tested on:** Windows 11 + WSL2 (Ubuntu 22.04), Docker Desktop WSL backend, Compose v2
> **Default ports:** MinIO 9000/9001, Ray 8265, Spark 7077/8080/8081, Airflow 8085, Kafka 29092, Jupyter 8888

---

## 0) Requirements

* **Windows 11** (22H2 or newer) with **WSL2** enabled
* **Ubuntu** distro in WSL (recommend **Ubuntu 22.04 LTS**)
* **Docker Desktop** for Windows ≥ 4.34 with **WSL2 backend**

  * Settings → **General** → enable *Use the WSL 2 based engine*
  * Settings → **Resources → WSL Integration** → enable your Ubuntu distro
  * (Optional GPU) Settings → **Resources** → enable **GPU support**
* **NVIDIA GPU (optional)**

  * Install latest Windows driver (R535+)
  * Verify in PowerShell: `nvidia-smi`
  * In WSL: `nvidia-smi` should also work
  * In Docker:

    ```bash
    docker run --rm --gpus all nvidia/cuda:12.4.1-base nvidia-smi
    ```
* **Allow firewall prompts** when Windows Security asks → allow for **Private networks**
* **Disk space**: \~10–15 GB recommended for images + data

> **Performance tip**: Clone/run the repo **inside** the Linux filesystem (`/home/<user>/…`) instead of `/mnt/c/...` for faster I/O.

---

## 1) First-time system prep (inside WSL Ubuntu)

Install base tools:

```bash
sudo apt update && sudo apt install -y git curl ca-certificates jq
```

Clone the repository:

```bash
mkdir -p ~/dockerprojects && cd ~/dockerprojects
git clone <YOUR_REPO_URL> wsl-ml-lakehouse-stack
cd wsl-ml-lakehouse-stack
```

Copy example environment and edit:

```bash
cp .env.example .env

cat >> .env <<'ENV'
COMPOSE_PROJECT_NAME=wsl-ml-lakehouse-stack
TZ=Europe/Copenhagen
AWS_REGION=eu-north-1
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=minioadmin
MINIO_BUCKET=crawl
# Optional Jupyter token
JUPYTER_TOKEN=letmein123
ENV

# Ensure LF endings
sed -i 's/\r$//' .env
```

**Important**: `.env` must be plain `KEY=VALUE`.
No quotes, no `$(id -u)`, no CRLF.

---

## 2) Start the stack

```bash
docker compose pull
docker compose down --remove-orphans || true
docker compose up -d --remove-orphans
docker compose ps   # wait for (healthy)
```

---

## 3) Reach the UIs

* **MinIO**: [http://localhost:9001](http://localhost:9001) (login: `minioadmin / minioadmin`)
* **Ray Dashboard**: [http://localhost:8265](http://localhost:8265)
* **Spark Master UI**: [http://localhost:8080](http://localhost:8080)
* **Spark Worker UI**: [http://localhost:8081](http://localhost:8081)
* **Airflow**: [http://localhost:8085](http://localhost:8085)

  ```bash
  docker compose exec airflow airflow users create \
    --username admin --firstname Admin --lastname User \
    --role Admin --email admin@example.com --password admin
  ```
* **Jupyter (pydev)**: [http://localhost:8888](http://localhost:8888)
  If token not set, get it:

  ```bash
  docker compose exec pydev jupyter server list
  ```

---

## 4) Run smoke tests

Run all:

```bash
./smoketests_all.sh
```

Run individual:

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
./smoketest_11_crawler.sh
```

You should see ✅ for each.

---

## 5) Quick demo: Kafka ➜ Delta on MinIO

**Terminal A — produce messages**

```bash
docker compose exec kafka /opt/bitnami/kafka/bin/kafka-console-producer.sh \
  --broker-list kafka:9092 --topic smoketest
# type a few lines then Ctrl+C
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

print("Streaming... Ctrl+C to stop")
query.awaitTermination()
PY
```

**Verify written data**

```bash
docker compose exec -T pydev python - <<'PY'
from pyspark.sql import SparkSession
spark = SparkSession.builder.getOrCreate()
df = spark.read.format("delta").load("s3a://smoketest-bucket/delta/streams/smoketest")
df.show(truncate=False)
PY
```

---

## 6) Crawler demo

The stack includes a minimal async **crawler** that writes JSONL docs (`url`, `title`, `depth`, `ts`) to MinIO.

### One-off run

```bash
docker compose build crawler
docker compose run --rm \
  -e SEEDS="https://quotes.toscrape.com" \
  -e ALLOWED_DOMAINS="quotes.toscrape.com" \
  -e MAX_PAGES=20 -e MAX_DEPTH=2 -e CONCURRENCY=5 \
  -e OUT_S3_URI="s3://crawl/raw/%Y%m%d/%H%M%S/run.jsonl" \
  crawler
```

### Verify output

```bash
docker compose exec minio sh -lc '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" &&
  mc ls -r local/crawl/raw | head &&
  mc cat local/crawl/raw/$(date +%Y%m%d)/*/run.jsonl | head
'
```

### Smoketest

```bash
./smoketest_11_crawler.sh
```

This fetches \~5 pages and checks at least 3 lines were written.

---

## 7) Troubleshooting

* **Crawler writes 0 docs** → ensure `ca-certificates` is installed in crawler image; rebuild:

  ```bash
  docker compose build --no-cache crawler
  ```
* **Container name conflicts** → `docker rm -f <name>`
* **.env parse errors** → ensure plain `KEY=VALUE`, remove CRLF
* **Ports in use** → `sudo lsof -i :8080` or `netstat -ano | findstr :8080`
* **Docker Desktop integration** → enable WSL integration in settings
* **Jupyter token confusion** → set `JUPYTER_TOKEN` in `.env`
* **Slow Spark jar downloads** → first run only; bake jars into image if needed
* **GPU not detected** → check `docker run --rm --gpus all nvidia/cuda:12.4.1-base nvidia-smi`
* **Windows Firewall** → allow Docker/WSL on private networks

---

## 8) Day-2 Ops

* **Update + restart**

  ```bash
  docker compose pull
  docker compose up -d --remove-orphans
  docker compose ps
  ```

* **Full smoketest**

  ```bash
  ./smoketests_all.sh
  ```

* **Clean shutdown**

  ```bash
  docker compose down -v --remove-orphans
  ```

* **Reset MinIO demo bucket (dangerous!)**

  ```bash
  docker compose exec minio bash -lc \
    'mc alias set local http://minio:9000 minioadmin minioadmin && \
     mc rb --force local/smoketest-bucket && \
     mc mb local/smoketest-bucket'
  ```

---

## 9) CI sanity (optional)

Minimal GitHub Actions:

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

---

## 10) Security notes

* Change default credentials (`.env`) if running long-term
* Restrict host-port exposure on shared networks
* Configure TLS/users/policies before treating MinIO as production S3

---

## 11) Uninstall / cleanup

```bash
docker compose down -v --remove-orphans
for n in spark-master spark-worker kafka minio airflow airflow-db airflow-redis pydev terraform ray-head ray-worker dbt beam; do
  docker rm -f "$n" 2>/dev/null || true
done
```

---

### Appendix: Tips

* Always use **LF** endings (`git config core.autocrlf input`)
* Keep repo under `/home/<user>` for Docker/WSL performance
* Update firewall rules if ports change
* To debug a single service, run docker compose up <service>

---

✅ This now fully documents the **crawler**, **smoketest 11**, and all other services.

