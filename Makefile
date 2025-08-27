# Project: wsl-ml-stack
# Usage: put these files in a new folder (e.g., wsl-ml-stack/) and run `make up`

.PHONY: up ps logs stop down restart kafka-topic spark-shell ray-open airflow-open jupyter-open \
        crawler-build crawler-run crawler-run-pol minio-open backup restore



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

crawler-build:
	docker compose build crawler

crawler-run:
	docker compose run --rm crawler

crawler-run-pol:
	docker compose run --rm \
	  -e SEEDS="https://politiken.dk" \
	  -e ALLOWED_DOMAINS="politiken.dk" \
	  -e MAX_PAGES=50 -e MAX_DEPTH=1 \
	  crawler

minio-open:
	@echo "MinIO Console: http://localhost:9001  (login = $$MINIO_ROOT_USER / $$MINIO_ROOT_PASSWORD)"


# Create a timestamped backup tarball in ../backup, preserving the repo folder name
backup:
	@mkdir -p ../backup
	@repo=$$(basename "$$(pwd)"); ts=$$(date +%Y%m%d-%H%M%S); \
	tar -C .. -czf ../backup/$$repo-$$ts.tar.gz $$repo; \
	echo "Backup created: ../backup/$$repo-$$ts.tar.gz"


# Restore from a given tarball into the parent directory
# Usage: make restore BACKUP=../backup/wsl-ml-stack-20250827-153045.tar.gz
restore:
	@[ -n "$(BACKUP)" ] || (echo "Usage: make restore BACKUP=path/to/file.tar.gz" && exit 1)
	@tar -xvzf $(BACKUP) -C ..
	@echo "Restored from $(BACKUP)"    


backup-prune:
	@repo=$$(basename "$$(pwd)"); \
	ls -1t ../backup/$$repo-*.tar.gz | tail -n +11 | xargs -r rm -f; \
	echo "Pruned old backups, kept latest 10."
