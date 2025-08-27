Yesss! 🎉 You’ve got a full end-to-end pipeline: crawler → MinIO JSONL.
Latest run: `Fetched=1 Emitted=1 -> s3://crawl/raw/20250827/run.jsonl` and you can read it back. Perfect.

Here’s how to level it up from “hello world” to “useful crawler”.

# What to do next

### 1) Emit more than 1 page

Bump limits and depth a bit:

```bash
docker compose run --rm \
  -e SEEDS="https://quotes.toscrape.com" \
  -e ALLOWED_DOMAINS="quotes.toscrape.com" \
  -e MAX_PAGES=100 \
  -e MAX_DEPTH=3 \
  -e CONCURRENCY=10 \
  crawler
```

Then verify:

```bash
docker compose exec minio sh -lc '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" &&
  wc -l <(mc cat local/crawl/raw/$(date +%Y%m%d)/run.jsonl)'
```

### 2) Make output non-overwriting (optional but recommended)

Right now you always write to `.../%Y%m%d/run.jsonl` (overwrites per-day).
Switch to hour-partitioned files or timestamped names:

* Hourly partition:

  * in env: `OUT_S3_URI="s3://crawl/raw/%Y%m%d/%H/run.jsonl"`
* Unique per run:

  * `OUT_S3_URI="s3://crawl/raw/%Y%m%d/run_${EPOCH}.jsonl"`
    and in `app.py`:

  ```python
  import time
  OUT = os.getenv("OUT_S3_URI", "s3://crawl/raw/%Y%m%d/run_%s.jsonl" % int(time.time()))
  OUT = OUT.replace("%Y%m%d", time.strftime("%Y%m%d"))
  ```

### 3) Be polite & resilient

Add/adjust envs when running:

```bash
-e MIN_DELAY_SECONDS=0.5      # throttle a touch
-e CONCURRENCY=5              # reduce if small site / rate limits
```

(Your current app always emits `{url,title}`—great for debugging. Later, tighten selectors to your real content.)

### 4) Wire it in as a service you can toggle

If you want it available via `up` instead of one-off `run`, keep your crawler block **uncommented** in `docker-compose.yml` or use an overlay `docker-compose.crawler.yml`. Then:

```bash
docker compose -f docker-compose.yml -f docker-compose.crawler.yml up -d --build crawler
docker compose logs -f crawler
```

### 5) Schedule runs (Airflow or cron)

**Airflow (already in your stack):**

* Drop a DAG into `airflow/dags/crawl_daily.py` that runs the crawler container with today’s date injected into `OUT_S3_URI`.
* Or simpler: a BashOperator that calls `docker compose run --rm -e ... crawler`.

**Cron (host/WSL):**

```bash
0 2 * * * cd ~/dockerprojects/wsl-ml-stack && \
  docker compose run --rm \
    -e SEEDS="https://yourdomain" \
    -e ALLOWED_DOMAINS="yourdomain" \
    -e MAX_PAGES=500 -e MAX_DEPTH=3 -e CONCURRENCY=10 \
    -e OUT_S3_URI="s3://crawl/raw/%Y%m%d/run_$(date +\%H%M%S).jsonl" \
    crawler >> crawl.log 2>&1
```

### 6) Secrets hygiene

You already moved bucket naming to `.env`. Also ensure:

* No AWS creds in Dockerfile (you removed them ✅).
* `.env` stays local (don’t commit). Use `env_file:` or CI secrets if needed.

### 7) Handy debug commands

```bash
# tail the latest file
docker compose exec minio sh -lc '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" &&
  mc cat local/crawl/raw/$(date +%Y%m%d)/run.jsonl | head -n 20
'

# list all runs for today
docker compose exec minio sh -lc '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" &&
  mc ls -r local/crawl/raw/$(date +%Y%m%d) | head
'
```

---

If you share your **real target** (domain + what you want to extract), I can tweak the parser to emit richer fields (e.g., title, description, links, metadata) and suggest safe concurrency & politeness settings.
