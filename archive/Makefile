# Project: wsl-ml-stack
# Usage: put these files in a new folder (e.g., wsl-ml-stack/) and run `make up`


# ────────────────────────────────────────────────────────────────────────────────
# Makefile
# ────────────────────────────────────────────────────────────────────────────────
SHELL := /bin/bash

up:
	docker compose up -d --build

ps:
	docker compose ps

logs:
	docker compose logs -f --tail=200

stop:
	docker compose stop

down:
	docker compose down -v

restart: down up

# Create a Kafka topic named 'events'
kafka-topic:
	docker compose exec -T kafka kafka-topics.sh --create --topic events --bootstrap-server kafka:9092 --if-not-exists

# Quick Spark shell with Delta & S3 (MinIO)
spark-shell:
	docker compose exec -it spark-master spark-shell \
	  --packages io.delta:delta-spark_2.12:3.2.0,org.apache.hadoop:hadoop-aws:3.3.4 \
	  --conf spark.hadoop.fs.s3a.endpoint=$$AWS_S3_ENDPOINT \
	  --conf spark.hadoop.fs.s3a.path.style.access=true

# Open Ray dashboard
ray-open:
	@echo "Ray Dashboard: http://localhost:8265"

# Airflow quick links
airflow-open:
	@echo "Airflow Web:   http://localhost:8085  (admin/admin)"

# Jupyter quick link
jupyter-open:
	@echo "Jupyter:       http://localhost:8888  (token in .env: $$JUPYTER_TOKEN)"

