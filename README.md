# WSL ML Lakehouse Stack

Docker Compose stack for a local lakehouse lab:
- **MinIO** (S3), **Spark 3.5**, **Ray 2.x**, **Kafka 3.7 (KRaft)**,
- **Airflow 2.9 (CeleryExecutor)**, **dbt Core**, **Apache Beam**, **Terraform**,
- plus **Jupyter (PySpark)** and a **full smoketest suite**.

## Quickstart
```bash
cp .env.example .env
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