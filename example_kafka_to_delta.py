# Project: wsl-ml-stack
# Usage: put these files in a new folder (e.g., wsl-ml-stack/) and run `make up`

# ────────────────────────────────────────────────────────────────────────────────
# airflow/dags/example_kafka_to_delta.py  (minimal demo DAG)
# ────────────────────────────────────────────────────────────────────────────────
# Place this file at airflow/dags/example_kafka_to_delta.py
from datetime import datetime
from airflow import DAG
from airflow.providers.apache.kafka.sensors.kafka import KafkaSensor
from airflow.providers.apache.spark.operators.spark_submit import SparkSubmitOperator

default_args = {"owner": "airflow"}

dag = DAG(
    dag_id="example_kafka_to_delta",
    default_args=default_args,
    start_date=datetime(2025, 1, 1),
    schedule_interval=None,
    catchup=False,
)

wait_for_kafka = KafkaSensor(
    task_id="wait_for_kafka",
    topics=["events"],
    kafka_config={"bootstrap.servers": "kafka:9092"},
    dag=dag,
)

spark_job = SparkSubmitOperator(
    task_id="spark_stream_to_delta",
    application="/workspace/jobs/stream_to_delta.py",
    conn_id="spark_default",
    packages="io.delta:delta-spark_2.12:3.2.0,org.apache.hadoop:hadoop-aws:3.3.4",
    conf={
        "spark.hadoop.fs.s3a.endpoint": "http://minio:9000",
        "spark.hadoop.fs.s3a.path.style.access": "true",
        "spark.sql.extensions": "io.delta.sql.DeltaSparkSessionExtension",
        "spark.sql.catalog.spark_catalog": "org.apache.spark.sql.delta.catalog.DeltaCatalog",
    },
    dag=dag,
)

wait_for_kafka >> spark_job

# ────────────────────────────────────────────────────────────────────────────────
# /workspace/jobs/stream_to_delta.py  (sample Spark Structured Streaming job)
# ────────────────────────────────────────────────────────────────────────────────
# Put this under the shared 'workspace' volume: jobs/stream_to_delta.py
from pyspark.sql import SparkSession
from pyspark.sql.functions import col, from_json
from pyspark.sql.types import StructType, StructField, StringType

spark = (
    SparkSession.builder.appName("KafkaToDelta")
    .config("spark.sql.extensions","io.delta.sql.DeltaSparkSessionExtension")
    .config("spark.sql.catalog.spark_catalog","org.apache.spark.sql.delta.catalog.DeltaCatalog")
    .getOrCreate()
)

schema = StructType([StructField("message", StringType(), True)])

df = (
    spark.readStream.format("kafka")
    .option("kafka.bootstrap.servers","kafka:9092")
    .option("subscribe","events")
    .option("startingOffsets","earliest")
    .load()
)

json_df = df.selectExpr("CAST(value AS STRING) as raw").select(from_json(col("raw"), schema).alias("js")).select("js.*")

# Write to Delta on MinIO S3 bucket
query = (
    json_df.writeStream
    .format("delta")
    .option("checkpointLocation","s3a://data/checkpoints/kafka_to_delta/")
    .option("path","s3a://data/delta/events/")
    .outputMode("append")
    .start()
)

query.awaitTermination()

# ────────────────────────────────────────────────────────────────────────────────
# /workspace/notebooks/quickstart.ipynb (create your own Jupyter notebook)
# ────────────────────────────────────────────────────────────────────────────────
# Example PySpark snippet you can paste into a Jupyter cell (pydev container):
#
# from pyspark.sql import SparkSession
# spark = (SparkSession.builder
#          .appName("DeltaQuickstart")
#          .config("spark.sql.extensions","io.delta.sql.DeltaSparkSessionExtension")
#          .config("spark.sql.catalog.spark_catalog","org.apache.spark.sql.delta.catalog.DeltaCatalog")
#          .config("spark.hadoop.fs.s3a.endpoint","http://minio:9000")
#          .config("spark.hadoop.fs.s3a.path.style.access","true")
#          .getOrCreate())
# spark.range(0,10).write.format("delta").mode("overwrite").save("s3a://data/delta/demo")
# spark.read.format("delta").load("s3a://data/delta/demo").show()
#
# # Parquet example:
# spark.range(0,10).write.mode("overwrite").parquet("s3a://data/parquet/demo")
# spark.read.parquet("s3a://data/parquet/demo").show()

# ────────────────────────────────────────────────────────────────────────────────
# Quickstart (WSL + Docker Desktop)
# ────────────────────────────────────────────────────────────────────────────────
# 1) Ensure Docker Desktop is running and WSL2 integration is enabled for Ubuntu.
# 2) Save the files above in a new folder: wsl-ml-stack/ (create airflow/dags/ dir).
# 3) Run: `make up`  → this launches everything.
# 4) Create a Kafka topic: `make kafka-topic`.
# 5) Open UIs:
#    - MinIO Console: http://localhost:9001  (login: from .env)
#    - Jupyter (PySpark): http://localhost:8888  (token in .env)
#    - Spark Master UI:   http://localhost:8080
#    - Airflow Web:       http://localhost:8085  (admin/admin)
#    - Ray Dashboard:     http://localhost:8265
# 6) Produce a Kafka message (from host):
#    docker compose exec -T kafka kafka-console-producer.sh --bootstrap-server kafka:9092 --topic events <<< '{"message":"hello"}'
# 7) Trigger the Airflow DAG `example_kafka_to_delta` (unpause & play) to stream from Kafka to Delta on MinIO.
# 8) Explore Delta/Parquet data from Jupyter or Spark shell (see Makefile targets).

# Notes
# - dbt: mount your dbt project into /workspace/dbt and run commands: 
#     docker compose exec -it dbt bash -lc "dbt --version && dbt debug"
#   (install appropriate adapters, e.g., dbt-postgres, dbt-snowflake, etc.)
# - Terraform: place IaC in /workspace/infra, then: 
#     docker compose exec -it terraform bash -lc "terraform init && terraform plan"
# - Beam: put Python pipelines in /workspace/beam and run: 
#     docker compose exec -it beam bash -lc "python your_pipeline.py --runner=DirectRunner"
# - Ray: inside pydev or ray-head, `python -c 'import ray; ray.init("ray://ray-head:10001"); print(ray.cluster_resources())'`
