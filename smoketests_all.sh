#!/usr/bin/env bash
set -euo pipefail
run(){ echo; echo ">>> $*"; bash -lc "$@"; }
run "./smoketest_01_containers.sh"
run "./smoketest_02_ray.sh"
run "./smoketest_03_spark.sh"
run "./smoketest_04_spark_minio.sh"
run "./smoketest_05_kafka.sh"
run "./smoketest_06_airflow.sh"
run "./smoketest_07_dbt.sh"
run "./smoketest_08_beam.sh"
run "./smoketest_09_terraform.sh"
run "./smoketest_10_delta_minio.sh"
run "./smoketest_11_crawler.sh"
echo; echo "ALL SMOKETESTS ✅"
