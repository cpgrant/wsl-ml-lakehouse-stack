#!/bin/bash
set -e

echo "=== MinIO and Spark Smoketest ==="
# Copy smoketest.py to pydev and run
docker compose exec pydev ls -l /home/jovyan/work | grep -q smoketest.py || docker cp smoketest.py pydev:/home/jovyan/work/smoketest.py
docker compose exec pydev python /home/jovyan/work/smoketest.py

echo "=== Kafka Smoketest ==="
make kafka-topic
docker compose exec -T kafka kafka-console-producer.sh --topic events --bootstrap-server kafka:9092 <<< "Test message"
docker compose exec -T kafka kafka-console-consumer.sh --topic events --bootstrap-server kafka:9092 --from-beginning --max-messages 1

echo "=== Ray Smoketest ==="
docker compose ps | grep ray-head | grep -q "Up" || docker compose restart ray-head
sleep 5
docker compose exec pydev bash -c "pip install ray && python -c 'import ray; ray.init(address=\"ray://ray-head:10001\"); print(ray.get(ray.remote(lambda: \"Hello from Ray!\").remote()))'"

echo "=== Airflow Smoketest ==="
docker compose ps | grep airflow | grep -q "Up" || docker compose restart airflow
sleep 15
curl -s -u admin:admin http://localhost:8085/api/v1/health | grep -q "healthy" && echo "Airflow healthy"

echo "=== dbt Smoketest ==="
docker compose exec dbt bash -c "cd test_project || (dbt init test_project && echo 'spark:\n  target: dev\n  outputs:\n    dev:\n      type: spark\n      method: thrift\n      host: spark-master\n      port: 7077\n      schema: test' > /workspace/dbt/.dbt/profiles.yml && echo 'SELECT 1 AS id, \"hello\" AS message' > test_project/models/test.sql) && cd test_project && dbt run"

echo "=== Terraform Smoketest ==="
docker compose exec terraform bash -c "echo 'output \"test\" { value = \"Hello from Terraform!\" }' > test.tf && terraform init && terraform plan"

echo "=== Beam Smoketest ==="
docker compose exec beam python -c 'import apache_beam as beam; with beam.Pipeline() as p: (p | \"Create\" >> beam.Create([\"Hello\", \"World\"]) | \"Print\" >> beam.Map(print))'

echo "=== Jupyter Smoketest ==="
curl -s http://localhost:8888/api/status | grep -q "running" && echo "Jupyter running"

echo "=== Redis Smoketest ==="
docker compose exec airflow-redis redis-cli ping

echo "=== Postgres Smoketest ==="
docker compose exec airflow-db psql -U airflow -d airflow -c "SELECT 1;"

echo "All smoketests passed!"