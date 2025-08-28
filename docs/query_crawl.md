---

# Querying DeepAIMind Crawl Outputs

This guide shows common, useful queries over the crawler outputs written to **MinIO**:

* Count by **kind** (html/pdf/docx/other)
* List **PDF files** (and optionally download them)
* Total **bytes/MB** (overall and by kind)
* Quick QA: statuses, depth, recent pages
* (Optional) Delta Lake queries with Spark

Assumptions: you ran the crawler with outputs like:

* JSONL rows: `s3://crawl/raw/<YYYYMMDD>/deepaimind/run_*.jsonl`
* Raw bytes:  `s3://crawl/bin/<YYYYMMDD>/deepaimind/<shard>/<sha>.<ext>`
* Manifest:   `s3://crawl/raw/<YYYYMMDD>/deepaimind/manifest_*.json`

> The MinIO Console is available at `http://localhost:9001` (use your `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`).

---

## 0) Get today’s latest run (paths)

```bash
# Host: store the latest JSONL and manifest paths in variables
LATEST_JSONL=$(docker compose exec -T minio sh -lc '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  mc find local/crawl/raw/$(date +%Y%m%d)/deepaimind --name "run_*.jsonl" | sort | tail -n1
'); echo "LATEST_JSONL=$LATEST_JSONL"

LATEST_MANIFEST=$(docker compose exec -T minio sh -lc '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  mc find local/crawl/raw/$(date +%Y%m%d)/deepaimind --name "manifest_*.json" | sort | tail -n1
'); echo "LATEST_MANIFEST=$LATEST_MANIFEST"
```

Peek at them:

```bash
docker compose exec -T minio sh -lc "mc stat '$LATEST_JSONL'"
docker compose exec -T minio sh -lc "mc cat  '$LATEST_MANIFEST'"
```

Optionally copy to host:

```bash
docker compose exec -T minio sh -lc "mc cat '$LATEST_JSONL'"     > /tmp/deepaimind.jsonl
docker compose exec -T minio sh -lc "mc cat '$LATEST_MANIFEST'"  > /tmp/deepaimind_manifest.json
```

---

## 1) #kinds — count rows by kind (html/pdf/docx/other)

**From JSONL (host Python):**

```bash
docker compose exec -T minio sh -lc "mc cat '$LATEST_JSONL'" | python3 - <<'PY'
import sys, json, collections
c = collections.Counter()
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        obj=json.loads(line)
        c[obj.get("kind","unknown")] += 1
    except: pass
for k in sorted(c):
    print(f"{k}: {c[k]}")
PY
```

**From the manifest (host Python):**

```bash
python3 - <<'PY'
import json
d=json.load(open('/tmp/deepaimind_manifest.json'))
print(d['kinds'])
PY
```

---

## 2) #pdf files — list/count the PDFs we captured

**Count PDFs from JSONL:**

```bash
docker compose exec -T minio sh -lc "mc cat '$LATEST_JSONL'" | python3 - <<'PY'
import sys, json
print(sum(1 for ln in sys.stdin if ln.strip() and json.loads(ln).get("kind")=="pdf"))
PY
```

**List PDF URLs:**

```bash
docker compose exec -T minio sh -lc "mc cat '$LATEST_JSONL'" | python3 - <<'PY'
import sys, json
for ln in sys.stdin:
    if not ln.strip(): continue
    o=json.loads(ln)
    if o.get("kind")=="pdf":
        print(o.get("url"))
PY
```

**(Optional) Download PDFs to a local folder on host:**

```bash
mkdir -p /tmp/deepaimind_pdfs
docker compose exec -T minio sh -lc "mc cat '$LATEST_JSONL'" | python3 - <<'PY'
import sys, json, os, pathlib, urllib.parse, subprocess, textwrap
outdir="/tmp/deepaimind_pdfs"
pathlib.Path(outdir).mkdir(parents=True, exist_ok=True)
for ln in sys.stdin:
    if not ln.strip(): continue
    o=json.loads(ln)
    if o.get("kind")!="pdf": continue
    url=o.get("url")
    if not url: continue
    name=urllib.parse.urlparse(url).path.rsplit("/",1)[-1] or "file.pdf"
    # Use curl via the host to fetch (site is public)
    subprocess.run(["curl","-L","-o",os.path.join(outdir,name),url], check=False)
print("Saved to", outdir)
PY
```

> If you prefer to pull the **raw PDFs** from MinIO instead of re-downloading, use the `raw_s3_uri` field in JSONL and copy via `mc cp`. Example below in **§4**.

---

## 3) #bytes / megabytes — sizes overall & by kind

### 3a) Total size of today’s raw binaries (all kinds)

```bash
# Sum sizes under today's bin prefix (MinIO container; uses mc --json)
docker compose exec -T minio sh -lc '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  mc ls -r --json local/crawl/bin/$(date +%Y%m%d)/deepaimind
' | python3 - <<'PY'
import sys, json
total=0
for ln in sys.stdin:
    try:
        o=json.loads(ln)
        if o.get("type")=="file":
            total += int(o.get("size",0))
    except: pass
print("bytes:", total)
print("MB:", round(total/1024/1024,2))
PY
```

### 3b) Size by kind (html/pdf/docx) from **bin** objects

We’ll classify by file extension in the bin prefix:

```bash
docker compose exec -T minio sh -lc '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  mc ls -r --json local/crawl/bin/$(date +%Y%m%d)/deepaimind
' | python3 - <<'PY'
import sys, json, re, collections
by_ext=collections.Counter()
sizes=collections.Counter()
for ln in sys.stdin:
    try:
        o=json.loads(ln)
        if o.get("type")!="file": continue
        key=o["key"]  # e.g., bin/20250828/deepaimind/ab/abcd...html
        size=int(o.get("size",0))
        m=re.search(r"\.([a-z0-9]+)$", key.lower())
        ext=m.group(1) if m else "bin"
        by_ext[ext]+=1
        sizes[ext]+=size
    except: pass
for ext in sorted(by_ext):
    print(f"{ext}: {by_ext[ext]} files, {round(sizes[ext]/1024/1024,2)} MB")
PY
```

> If you only want **PDF bytes**, read just the `.pdf` line from the output above.

---

## 4) Copy raw files (e.g., PDFs) from MinIO to host

**List raw objects for today (first 20):**

```bash
docker compose exec -T minio sh -lc '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  mc ls -r local/crawl/bin/$(date +%Y%m%d)/deepaimind | head -n 20
'
```

**Copy only PDFs to a local folder:**

```bash
mkdir -p /tmp/deepaimind_raw_pdfs
# Find PDFs (host: we filter with Python since minio container lacks grep)
docker compose exec -T minio sh -lc '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  mc find local/crawl/bin/$(date +%Y%m%d)/deepaimind --name "*.pdf"
' | python3 - <<'PY'
import sys, subprocess, os
outdir="/tmp/deepaimind_raw_pdfs"
os.makedirs(outdir, exist_ok=True)
for line in sys.stdin:
    p=line.strip()
    if not p: continue
    subprocess.run(["docker","compose","exec","-T","minio","sh","-lc",f"mc cp '{p}' '/data/tmp.pdf'"], check=False)
    # Grab the file from the minio container to the host path
    # (Bind-mount alternative recommended for large jobs; this is a simple demo.)
PY
```

> For larger transfers, it’s cleaner to run `mc cp` directly on your **host** by using the MinIO **Client (mc)** installed locally, or by bind-mounting a host folder into the minio container.

---

## 5) QA / Diagnostics

**HTTP status distribution:**

```bash
docker compose exec -T minio sh -lc "mc cat '$LATEST_JSONL'" | python3 - <<'PY'
import sys, json, collections
c=collections.Counter()
for ln in sys.stdin:
    if not ln.strip(): continue
    o=json.loads(ln)
    c[o.get("status")]+=1
for k in sorted(c):
    print(k, c[k])
PY
```

**Depth distribution:**

```bash
docker compose exec -T minio sh -lc "mc cat '$LATEST_JSONL'" | python3 - <<'PY'
import sys, json, collections
c=collections.Counter()
for ln in sys.stdin:
    if not ln.strip(): continue
    o=json.loads(ln)
    c[o.get("depth")]+=1
for k in sorted(c):
    print(f"depth {k}: {c[k]}")
PY
```

**Empty or missing titles (HTML):**

```bash
docker compose exec -T minio sh -lc "mc cat '$LATEST_JSONL'" | python3 - <<'PY'
import sys, json
for ln in sys.stdin:
    if not ln.strip(): continue
    o=json.loads(ln)
    if o.get("kind")=="html" and not (o.get("title") or "").strip():
        print(o.get("url"))
PY
```

**Most recent pages by fetch\_time:**

```bash
docker compose exec -T minio sh -lc "mc cat '$LATEST_JSONL'" | python3 - <<'PY'
import sys, json, datetime
rows=[]
for ln in sys.stdin:
    if not ln.strip(): continue
    o=json.loads(ln)
    rows.append((o.get("fetch_time"), o.get("url"), o.get("kind"), o.get("status")))
rows.sort(reverse=True)  # lexicographic works for ISO timestamps
for r in rows[:10]:
    print(r)
PY
```

---

## 6) (Optional) Query with Spark / Delta

If you ingested to Delta at `s3a://crawl/delta/deepaimind`, here are a few quick queries.

**Open PySpark shell with Delta:**

```bash
docker compose exec spark-master bash -lc '
  pyspark --packages io.delta:delta-spark_2.12:3.2.0,org.apache.hadoop:hadoop-aws:3.3.4 -q
'
```

In the PySpark prompt:

```python
from pyspark.sql import SparkSession, functions as F
spark = SparkSession.builder.getOrCreate()
df = spark.read.format("delta").load("s3a://crawl/delta/deepaimind")

# Count by kind
df.groupBy("kind").count().show()

# PDFs only (list URLs)
df.filter(df.kind=="pdf").select("url","content_type","fetch_time").orderBy(F.desc("fetch_time")).show(20, truncate=False)

# Status distribution
df.groupBy("status").count().orderBy("status").show()

# Depth distribution
df.groupBy("depth").count().orderBy("depth").show()

# Latest rows (by fetch_time)
df.orderBy(F.desc("fetch_time")).select("fetch_time","kind","status","url").show(20, truncate=False)
```

---

## 7) Make it repeatable (optional Makefile targets)

```makefile
# Show latest JSONL path
s3-jsonl-latest:
	@docker compose exec -T minio sh -lc ' \
	  mc alias set local http://minio:9000 "$$MINIO_ROOT_USER" "$$MINIO_ROOT_PASSWORD" >/dev/null; \
	  mc find local/crawl/raw/$$(date +%Y%m%d)/deepaimind --name "run_*.jsonl" | sort | tail -n1 \
	'

# Show manifest JSON
s3-manifest-latest:
	@docker compose exec -T minio sh -lc ' \
	  mc alias set local http://minio:9000 "$$MINIO_ROOT_USER" "$$MINIO_ROOT_PASSWORD" >/dev/null; \
	  mc find local/crawl/raw/$$(date +%Y%m%d)/deepaimind --name "manifest_*.json" | sort | tail -n1 \
	'
```

---

### Tips

* The **manifest** is the fastest place to check **fetched/emitted** and **kinds** for a run.
* Prefer **host Python** for parsing; the minio container is intentionally minimal.
* For large transfers, install `mc` on your **host** and configure the same alias (`mc alias set ...`) to copy directly to local folders without going through the container.


