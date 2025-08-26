# Project: wsl-ml-stack
# Usage: put these files in a new folder (e.g., wsl-ml-stack/) and run `make up`


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

