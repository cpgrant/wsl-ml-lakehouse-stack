#!/usr/bin/env bash
set -euo pipefail
need=$(docker compose exec -T pydev python -c 'import importlib,sys; print(0 if importlib.util.find_spec("pyspark") else 1)' | tr -d '\r')
if [[ "$need" == "1" ]]; then
  echo "Installing pyspark==3.5.3 and delta-spark==3.2.0 in pydev..."
  docker compose exec -T pydev pip install pyspark==3.5.3 delta-spark==3.2.0
else
  echo "pyspark already present."
fi
docker compose exec -T pydev python - <<'PY'
from pyspark.sql import SparkSession
spark = SparkSession.builder.appName("probe").getOrCreate()
print("spark.version:", spark.version)
print("count:", spark.range(10).count())
spark.stop()
PY
