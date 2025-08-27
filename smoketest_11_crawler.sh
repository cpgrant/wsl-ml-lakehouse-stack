#!/usr/bin/env bash
set -euo pipefail

echo "=== Crawler: fetch → emit → verify ==="

# Run crawler once against quotes.toscrape.com
docker compose run --rm \
  -e SEEDS="https://quotes.toscrape.com" \
  -e ALLOWED_DOMAINS="quotes.toscrape.com" \
  -e MAX_PAGES=5 \
  -e MAX_DEPTH=1 \
  -e CONCURRENCY=2 \
  -e OUT_S3_URI="s3://crawl/raw/%Y%m%d/smoketest.jsonl" \
  crawler

# Verify that file exists and has >0 lines
docker compose exec minio sh -lc '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null &&
  LINES=$(mc cat local/crawl/raw/$(date +%Y%m%d)/smoketest.jsonl | wc -l) &&
  if [ "$LINES" -gt 0 ]; then
    echo "OK: Crawler emitted $LINES lines"
    head -n 3 <(mc cat local/crawl/raw/$(date +%Y%m%d)/smoketest.jsonl)
    exit 0
  else
    echo "FAIL: Crawler wrote 0 lines"
    exit 1
  fi
'
