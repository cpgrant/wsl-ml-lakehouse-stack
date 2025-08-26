# WSL ML Lakehouse Stack

A one-command local lakehouse: MinIO (S3), Spark 3.5, Ray 2.x, Kafka, Airflow 2.9, dbt Core, Apache Beam, Terraform, and a Jupyter PySpark notebook.

## Prereqs
- Docker Desktop (with WSL2 backend)
- Git + GitHub CLI (optional)
- Bash

## Quickstart
```bash
cp .env.example .env             # then edit as needed
docker compose pull
docker compose up -d
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