# WSL ML Stack (Spark + Ray + Airflow + Kafka + MinIO)

Local, containerized data stack with smoketests.

## Quickstart
```bash
cp .env.example .env   # edit values if you like
docker compose pull
docker compose up -d --remove-orphans
./smoketest_01_containers.sh
# optional: run others
./smoketest_02_ray.sh
./smoketest_03_spark.sh
./smoketest_04_spark_minio.sh
./smoketest_06_airflow.sh
./smoketest_07_dbt.sh
./smoketest_08_beam.sh
./smoketest_09_terraform.sh
./smoketest_10_delta_minio.sh
