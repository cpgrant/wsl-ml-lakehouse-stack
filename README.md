
---

````markdown
# WSL ML Lakehouse Stack

A one-command **local ML lakehouse** running entirely on Docker + WSL2.  
Includes: **MinIO (S3), Spark 3.5, Ray 2.x, Kafka, Airflow 2.9, dbt Core, Apache Beam, Terraform, a Jupyter PySpark notebook — and a simple async web crawler** for demo data ingestion.

> ✅ Tested on Windows 11 + WSL2 (Ubuntu 22.04, Docker Desktop WSL backend).  
> Default ports: MinIO `9000/9001`, Ray `8265`, Spark `7077/8080/8081`, Airflow `8085`, Kafka `29092`, Jupyter `8888`.

---

## Quickstart

```bash
# Clone and prepare
git clone <YOUR_REPO_URL> wsl-ml-lakehouse-stack
cd wsl-ml-lakehouse-stack
cp .env.example .env   # edit values as needed

# Start everything
docker compose pull
docker compose up -d

# Run smoke tests
./smoketests_all.sh
````

You should see ✅ for all components.

---

## Smoke Tests

Run individually:

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

The **crawler smoketest** fetches a few pages from
[`https://quotes.toscrape.com`](https://quotes.toscrape.com) and writes JSON lines to MinIO at:

```
s3://crawl/raw/<date>/<timestamp>/smoketest.jsonl
```

---

## Documentation

* Full install and troubleshooting guide: [docs/install_notes.md](./docs/install_notes.md)
* Day-2 ops, GPU support, and CI sanity checks also covered there.

---

## Security Notes

* **Change default credentials** (`minioadmin`, `admin/admin`) before using outside local dev.
* Avoid exposing host ports on shared networks without TLS and auth.

---

## License

[MIT](./LICENSE)

```

---



```
