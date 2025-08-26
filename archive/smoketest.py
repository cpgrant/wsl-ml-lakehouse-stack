import os
from pyspark.sql import SparkSession

access_key = os.environ.get("AWS_ACCESS_KEY_ID")
secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY")
endpoint = os.environ.get("AWS_S3_ENDPOINT", "http://minio:9000")

print(f"Access Key: {access_key}")
print(f"Endpoint: {endpoint}")

spark = (SparkSession.builder
         .appName("SmokeTest")
         .config("spark.sql.extensions", "io.delta.sql.DeltaSparkSessionExtension")
         .config("spark.sql.catalog.spark_catalog", "org.apache.spark.sql.delta.catalog.DeltaCatalog")
         .config("spark.jars.packages", "io.delta:delta-spark_2.12:3.2.0,org.apache.hadoop:hadoop-aws:3.3.4")
         .config("spark.hadoop.fs.s3a.endpoint", endpoint)
         .config("spark.hadoop.fs.s3a.path.style.access", "true")
         .config("spark.hadoop.fs.s3a.connection.ssl.enabled", "false")
         .config("spark.hadoop.fs.s3a.access.key", access_key)
         .config("spark.hadoop.fs.s3a.secret.key", secret_key)
         .config("spark.hadoop.fs.s3a.impl", "org.apache.hadoop.fs.s3a.S3AFileSystem")
         .getOrCreate())

# Test Delta
delta_path = "s3a://data/delta/smoketest"
spark.range(5).write.format("delta").mode("overwrite").save(delta_path)
spark.read.format("delta").load(delta_path).show()

# Test Parquet
pq_path = "s3a://data/parquet/smoketest"
spark.range(3).write.mode("overwrite").parquet(pq_path)
spark.read.parquet(pq_path).show()

print("Success!")
spark.stop()
