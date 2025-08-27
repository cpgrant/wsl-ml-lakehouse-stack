---

# Next Steps: From “Hello World” to a Useful Crawler ✅

You’ve got the pipeline running end-to-end: **crawler → MinIO (S3) → JSONL**.
Example success: `Fetched=1 Emitted=1 -> s3://crawl/raw/20250827/run.jsonl`.

This guide takes you from a single-page demo to a reliable, schedulable, and reviewable crawler workload.

---

## 1) Crawl More Than One Page

Increase limits and depth (keep polite defaults):

```bash
docker compose run --rm \
  -e SEEDS="https://quotes.toscrape.com" \
  -e ALLOWED_DOMAINS="quotes.toscrape.com" \
  -e MAX_PAGES=100 \
  -e MAX_DEPTH=3 \
  -e CONCURRENCY=5 \
  -e MIN_DELAY_SECONDS=0.5 \
  crawler
```

**Verify row count** for today’s run:

```bash
docker compose exec minio sh -lc '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" &&
  wc -l <(mc cat local/crawl/raw/$(date +%Y%m%d)/run.jsonl)
'
```

> If `mc` isn’t present inside the `minio` container, run it as a sidecar:
>
> ```bash
> docker run --rm --network wsl-ml-stack_default minio/mc:latest \
>   alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
> ```
>
> Replace `wsl-ml-stack_default` with your actual Compose network (`docker network ls`).

---

## 2) Prevent Overwrites (Recommended)

Use date partitions + unique filenames so multiple runs don’t clobber each other.

### Option A — App handles uniqueness (simplest)

In `app.py`:

```python
import os, time

# Default path has date folder + epoch-based filename
OUT = os.getenv(
    "OUT_S3_URI",
    f"s3://crawl/raw/{time.strftime('%Y%m%d')}/run_{int(time.time())}.jsonl"
)
# Allow %Y%m%d substitution if user passes it in env
OUT = OUT.replace("%Y%m%d", time.strftime("%Y%m%d"))
```

Run with:

```bash
-e OUT_S3_URI="s3://crawl/raw/%Y%m%d/run_%s.jsonl"
```

### Option B — Env-only uniqueness

```bash
-e EPOCH=$(date +%s) \
-e OUT_S3_URI="s3://crawl/raw/%Y%m%d/run_${EPOCH}.jsonl"
```

### Hourly partition + unique filename

```bash
-e OUT_S3_URI="s3://crawl/raw/%Y%m%d/%H/run_$(date +%M%S).jsonl"
```

---

## 3) Be Polite & Resilient

Tune for target sites:

* **Throttle:** `-e MIN_DELAY_SECONDS=0.5` (increase if rate-limited)
* **Concurrency:** `-e CONCURRENCY=5` (raise slowly once stable)
* **Retries / timeouts:** expose and document these if not already

---

## 4) Run as a Toggleable Service

If you want the crawler managed with the rest of the stack:

* Keep the `crawler` service **uncommented** in `docker-compose.yml`, or
* Use an overlay:

```bash
docker compose -f docker-compose.yml -f docker-compose.crawler.yml up -d --build crawler
docker compose logs -f crawler
```

---

## 5) Schedule Runs (Airflow or Cron)

### Airflow (already in your stack)

Create `airflow/dags/crawl_daily.py`:

```python
from airflow import DAG
from airflow.utils.dates import days_ago
from airflow.operators.bash import BashOperator

with DAG(
    dag_id="crawl_daily",
    start_date=days_ago(1),
    schedule_interval="0 2 * * *",
    catchup=False,
) as dag:
    run_crawler = BashOperator(
        task_id="run_crawler",
        bash_command="""
        cd /workspace && \
        docker compose run --rm \
          -e SEEDS='https://yourdomain' \
          -e ALLOWED_DOMAINS='yourdomain' \
          -e MAX_PAGES=500 -e MAX_DEPTH=3 \
          -e CONCURRENCY=10 -e MIN_DELAY_SECONDS=0.5 \
          -e OUT_S3_URI="s3://crawl/raw/%Y%m%d/run_$(date +\\%H\\%M\\%S).jsonl" \
          crawler
        """
    )
```

### Cron (host/WSL)

```bash
0 2 * * * cd ~/dockerprojects/wsl-ml-stack && \
  docker compose run --rm \
    -e SEEDS="https://yourdomain" \
    -e ALLOWED_DOMAINS="yourdomain" \
    -e MAX_PAGES=500 -e MAX_DEPTH=3 -e CONCURRENCY=10 -e MIN_DELAY_SECONDS=0.5 \
    -e OUT_S3_URI="s3://crawl/raw/%Y%m%d/run_$(date +\%H\%M\%S).jsonl" \
    crawler >> crawl.log 2>&1
```

---

## 6) Secrets & Hygiene

* Keep credentials in `.env` (never in Dockerfile or source)
* Use `env_file:` in Compose, or CI/CD secrets in pipelines
* Ensure `.env` is **.gitignored**

---

## 7) Handy Debug Commands

**Tail latest rows:**

```bash
docker compose exec minio sh -lc '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" &&
  mc cat local/crawl/raw/$(date +%Y%m%d)/run.jsonl | head -n 20
'
```

**List today’s outputs:**

```bash
docker compose exec minio sh -lc '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" &&
  mc ls -r local/crawl/raw/$(date +%Y%m%d) | head
'
```

---

## 8) Makefile Targets (Nice-to-Have)

Add these to your `Makefile` to reduce copy-paste:

```makefile
crawl-demo:
	docker compose run --rm \
	  -e SEEDS="https://quotes.toscrape.com" \
	  -e ALLOWED_DOMAINS="quotes.toscrape.com" \
	  -e MAX_PAGES=100 -e MAX_DEPTH=3 \
	  -e CONCURRENCY=5 -e MIN_DELAY_SECONDS=0.5 \
	  -e OUT_S3_URI="s3://crawl/raw/%Y%m%d/run_$(shell date +%s).jsonl" \
	  crawler

s3-head:
	docker compose exec minio sh -lc '\
	  mc alias set local http://minio:9000 "$$MINIO_ROOT_USER" "$$MINIO_ROOT_PASSWORD" && \
	  mc cat local/crawl/raw/$$(date +%Y%m%d)/run.jsonl | head -n 20 \
	'

s3-ls-today:
	docker compose exec minio sh -lc '\
	  mc alias set local http://minio:9000 "$$MINIO_ROOT_USER" "$$MINIO_ROOT_PASSWORD" && \
	  mc ls -r local/crawl/raw/$$(date +%Y%m%d) | head \
	'
```

---

## 9) Enhance the Payload

Right now you emit `{url, title}` — great for smoke tests. Next:

* Add `description`, `links[]`, `canonical_url`, `meta.*`, `lang`, `fetch_time`
* Normalize URLs and deduplicate per session (and across runs if needed)
* Add per-run manifest (counts, duration, error summary)

---

## 10) Quality & Safety

* **Robots.txt** awareness and site TOS compliance
* Backoff on 429/5xx; jitter on retries
* Content-type filtering (HTML only unless configured)
* Hash content to avoid duplicates
* Structured logs + metrics (e.g., emitted rows, crawl rate, error rate)

---

## 11) Where to Go Next

* **Airflow lineage:** push run metadata to a Delta table (for dashboards)
* **Delta table schema:** evolve from `{url,title}` to rich schema
* **Downstream:** feed JSONL/Delta to Spark jobs (clean, dedupe, split), then to Ray for training/finetuning steps

---

Specify real target domain and desired fields and tailor selectors and defaults (depth, concurrency, politeness) for site and create a matching schema.
