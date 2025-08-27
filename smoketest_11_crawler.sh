#!/usr/bin/env bash
set -euo pipefail

echo "=== Crawler: fetch → emit → verify ==="

TS=$(date +%Y%m%d/%H%M%S)            # e.g., 20250827/113115
OUT="s3://crawl/raw/${TS}/smoketest.jsonl"

# Crawl quotes.toscrape.com (quick but multi-page)
docker compose run --rm \
  -e SEEDS="https://quotes.toscrape.com" \
  -e ALLOWED_DOMAINS="quotes.toscrape.com" \
  -e MAX_PAGES=5 \
  -e MAX_DEPTH=1 \
  -e CONCURRENCY=3 \
  -e OUT_S3_URI="$OUT" \
  crawler

# Verify file exists and has >=3 lines
docker compose exec minio sh -lc "
  mc alias set local http://minio:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null &&
  OBJ=\"local/${OUT#s3://}\" &&
  mc stat \"\$OBJ\" >/dev/null 2>&1 &&
  LINES=\$(mc cat \"\$OBJ\" | wc -l) &&
  if [ \"\$LINES\" -ge 3 ]; then
    echo \"OK: Crawler emitted \$LINES lines -> ${OUT}\"
    mc cat \"\$OBJ\" | head -n 3
  else
    echo \"FAIL: Crawler wrote only \$LINES lines (<3) -> ${OUT}\"; exit 1
  fi
"
