#!/usr/bin/env python3
import os, io, re, time, hashlib, gzip, asyncio, contextlib
from collections import deque, defaultdict
from urllib.parse import urlparse, urljoin, urlunparse, urldefrag
from urllib import robotparser

import aiohttp
from bs4 import BeautifulSoup
import aioboto3
from botocore.config import Config
import ujson as json

# ----------------- Env -----------------
SEEDS = [s.strip() for s in os.getenv("SEEDS", "https://www.deepaimind.com/").split(",") if s.strip()]
ALLOWED = set(d.strip().lower() for d in os.getenv("ALLOWED_DOMAINS", "deepaimind.com").split(",") if d.strip())

MAX_PAGES   = int(os.getenv("MAX_PAGES", "800"))
MAX_DEPTH   = int(os.getenv("MAX_DEPTH", "3"))
CONCURRENCY = int(os.getenv("CONCURRENCY", "10"))
MIN_DELAY   = float(os.getenv("MIN_DELAY_SECONDS", "0.5"))
MAX_ENQUEUE = int(os.getenv("MAX_ENQUEUE", "50000"))
REQUEST_TIMEOUT = int(os.getenv("REQUEST_TIMEOUT", "25"))

UA = os.getenv("UA", "WSL-ML-STACK-Crawler/1.0 (+https://deepaimind.com)")
INCLUDE_FILETYPES = set(x.strip().lower() for x in os.getenv("INCLUDE_FILETYPES", "html,htm,pdf,docx").split(","))

DATE = time.strftime("%Y%m%d")
OUT_S3_URI = os.getenv("OUT_S3_URI", f"s3://crawl/raw/{DATE}/deepaimind/run_{int(time.time())}.jsonl").replace("%Y%m%d", DATE)
BIN_S3_PREFIX = os.getenv("BIN_S3_PREFIX", f"s3://crawl/bin/{DATE}/deepaimind").replace("%Y%m%d", DATE)

S3_ENDPOINT = os.getenv("S3_ENDPOINT_URL", "http://minio:9000")
AWS_REGION  = os.getenv("AWS_DEFAULT_REGION", "us-east-1")
AWS_ACCESS_KEY_ID     = os.getenv("AWS_ACCESS_KEY_ID")
AWS_SECRET_ACCESS_KEY = os.getenv("AWS_SECRET_ACCESS_KEY")

MAX_BODY_BYTES = int(os.getenv("MAX_BODY_BYTES", "5242880"))   # 5 MB
MAX_TEXT_CHARS = int(os.getenv("MAX_TEXT_CHARS", "250000"))

# Toggle sitemap seeding via env
ENABLE_SITEMAP = os.getenv("ENABLE_SITEMAP_SEEDING", "1").lower() not in ("0", "false", "no")

SITEMAP_LOC_RE = re.compile(r"<loc>(.*?)</loc>", flags=re.I)

# Optional extractors (only used if installed)
try:
    from pdfminer.high_level import extract_text as _pdf_extract_text
except Exception:
    _pdf_extract_text = None

try:
    import docx as _docx
except Exception:
    _docx = None

# ----------------- Helpers -----------------
def s3_parse(uri: str):
    assert uri.startswith("s3://"), f"Bad S3 URI: {uri}"
    _, rest = uri.split("://", 1)
    bucket, key = rest.split("/", 1)
    return bucket, key

def in_scope(url: str) -> bool:
    host = (urlparse(url).hostname or "").lower()
    return any(host == d or host.endswith(f".{d}") for d in ALLOWED)

def norm(url: str) -> str:
    u = urlparse(url)
    scheme = (u.scheme or "https").lower()
    host = (u.hostname or "").lower()
    path = u.path or "/"
    if path != "/" and path.endswith("/"):
        path = path.rstrip("/")
    clean, _ = urldefrag(urlunparse((scheme, host, path, "", "", "")))
    return clean

def sha256(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()

def ext_of(url: str) -> str:
    m = re.search(r"\.([a-z0-9]{1,12})(?:\?|$)", (urlparse(url).path or "").lower())
    return m.group(1) if m else ""

def pick_kind(url: str, content_type: str) -> str:
    e = ext_of(url)
    if e in ("html","htm"): return "html"
    if e == "pdf": return "pdf"
    if e == "docx": return "docx"
    ct = (content_type or "").split(";")[0].strip().lower()
    if ct == "text/html": return "html"
    if ct == "application/pdf": return "pdf"
    if ct == "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx"
    return "other"

def html_extract(html: str, base_url: str) -> dict:
    soup = BeautifulSoup(html, "html.parser")
    title = (soup.title.string.strip() if soup.title and soup.title.string else "")[:400]
    desc = ""
    for meta in soup.find_all("meta"):
        name = (meta.get("name") or meta.get("property") or "").lower()
        if name in ("description","og:description","twitter:description"):
            desc = (meta.get("content") or "").strip()
            if desc: break
    canonical = ""
    link_tag = soup.find("link", rel=lambda v: v and "canonical" in v)
    if link_tag and link_tag.get("href"):
        canonical = norm(urljoin(base_url, link_tag["href"]))
    links = []
    for a in soup.find_all("a", href=True):
        u = urljoin(base_url, a["href"])
        if u.startswith("http"):
            links.append(norm(u))
    text = soup.get_text(" ", strip=True)
    if len(text) > MAX_TEXT_CHARS:
        text = text[:MAX_TEXT_CHARS]
    return {"title": title, "description": desc, "canonical_url": canonical, "links": links, "text": text}

def pdf_extract_text(pdf_bytes: bytes) -> str:
    if not _pdf_extract_text:
        return ""
    with io.BytesIO(pdf_bytes) as f:
        try:
            txt = _pdf_extract_text(f) or ""
        except Exception:
            return ""
    return txt[:MAX_TEXT_CHARS]

def docx_extract_text(docx_bytes: bytes) -> str:
    if not _docx:
        return ""
    with io.BytesIO(docx_bytes) as f:
        try:
            d = _docx.Document(f)
        except Exception:
            return ""
    txt = "\n".join(p.text for p in d.paragraphs)
    return txt[:MAX_TEXT_CHARS]

# robots.txt cache
_robot_cache: dict[str, robotparser.RobotFileParser | str] = {}
async def can_fetch(session: aiohttp.ClientSession, url: str) -> bool:
    p = urlparse(url)
    root = f"{p.scheme}://{p.netloc}"
    rp = _robot_cache.get(root)
    if rp is None:
        rp = robotparser.RobotFileParser()
        try:
            async with session.get(root + "/robots.txt", timeout=REQUEST_TIMEOUT) as r:
                if r.status == 200:
                    txt = await r.text()
                    rp.parse(txt.splitlines())
                else:
                    _robot_cache[root] = "NONE"
                    return True
        except Exception:
            _robot_cache[root] = "NONE"
            return True
        _robot_cache[root] = rp
    if _robot_cache[root] == "NONE":
        return True
    return _robot_cache[root].can_fetch(UA, url)

# ---------- Sitemap helpers ----------
async def _fetch_text_or_xml(http, url: str, timeout: int) -> str | None:
    try:
        r = await http.get(url, timeout=timeout, allow_redirects=True)
        if r.status != 200:
            return None
        ctype = (r.headers.get("content-type","")).lower()
        data = await r.read()
        if url.endswith(".gz") or "gzip" in (r.headers.get("content-encoding","")).lower():
            with gzip.GzipFile(fileobj=io.BytesIO(data)) as g:
                data = g.read()
        text = data.decode(r.charset or "utf-8", errors="replace")
        if ("xml" in ctype) or url.endswith(".xml") or url.endswith(".xml.gz"):
            return text
        return None
    except Exception:
        return None

async def seed_from_sitemaps(http, seeds: list[str], q, in_scope_fn, norm_fn, timeout: int):
    """
    Try common sitemap endpoints for each seed and enqueue <loc> URLs at depth 0.
    Follows sitemap index → child sitemaps one level.
    """
    checked: set[str] = set()
    for seed in seeds:
        base = seed.rstrip("/")
        for cand in (f"{base}/sitemap.xml", f"{base}/sitemap_index.xml"):
            if cand in checked:
                continue
            checked.add(cand)
            xml = await _fetch_text_or_xml(http, cand, timeout)
            if not xml:
                continue

            locs = SITEMAP_LOC_RE.findall(xml)
            child_sitemaps = []
            for u in locs:
                nu = norm_fn(u.strip())
                if nu.endswith(".xml") or nu.endswith(".xml.gz"):
                    child_sitemaps.append(nu)
                elif in_scope_fn(nu):
                    q.append((nu, 0))

            # one level of child sitemaps
            for sm in child_sitemaps[:50]:  # guardrail
                if sm in checked:
                    continue
                checked.add(sm)
                x = await _fetch_text_or_xml(http, sm, timeout)
                if not x:
                    continue
                for u in SITEMAP_LOC_RE.findall(x):
                    nu = norm_fn(u.strip())
                    if in_scope_fn(nu):
                        q.append((nu, 0))

# ----------------- Main -----------------
async def main():
    q = deque((norm(u), 0) for u in SEEDS)
    seen = set()
    emitted = set()
    host_last = defaultdict(lambda: 0.0)

    results = []
    fetched = 0
    sem = asyncio.Semaphore(CONCURRENCY)
    headers = {"User-Agent": UA}

    start_ts = time.time()
    kind_counts = {"html": 0, "pdf": 0, "docx": 0, "other": 0}

    # --- S3 (MinIO) setup ---
    cfg = Config(s3={"addressing_style": "path"})
    bucket_jsonl, key_jsonl = s3_parse(OUT_S3_URI)
    session_s3 = aioboto3.Session()

    # OPEN the async client here
    async with session_s3.client(
        "s3",
        endpoint_url=S3_ENDPOINT,
        region_name=AWS_REGION,
        aws_access_key_id=AWS_ACCESS_KEY_ID,
        aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
        config=cfg,
    ) as s3:

        async def s3_put_bytes(uri: str, body: bytes, content_type: str | None = None):
            b, k = s3_parse(uri)
            kwargs = {"Bucket": b, "Key": k, "Body": body}
            if content_type:
                kwargs["ContentType"] = content_type
            await s3.put_object(**kwargs)

        async with aiohttp.ClientSession(headers=headers, raise_for_status=False) as http:

            # Optional: seed queue from sitemap(s) before normal discovery
            if ENABLE_SITEMAP:
                with contextlib.suppress(Exception):
                    await seed_from_sitemaps(
                        http=http,
                        seeds=SEEDS,
                        q=q,
                        in_scope_fn=in_scope,
                        norm_fn=norm,
                        timeout=REQUEST_TIMEOUT,
                    )

            async def handle(url: str, depth: int):
                nonlocal fetched
                u = norm(url)
                if u in seen or depth > MAX_DEPTH or not in_scope(u):
                    return
                seen.add(u)

                if not await can_fetch(http, u):
                    return

                # polite per-host delay
                host = (urlparse(u).hostname or "").lower()
                gap = MIN_DELAY - (time.time() - host_last[host])
                if gap > 0:
                    await asyncio.sleep(gap)

                try:
                    async with sem:
                        r = await http.get(u, timeout=REQUEST_TIMEOUT, allow_redirects=True)
                    host_last[host] = time.time()
                except Exception:
                    return

                ctype = r.headers.get("content-type", "")
                body = await r.read()
                if body:
                    body = body[:MAX_BODY_BYTES]

                kind = pick_kind(u, ctype)
                ext = ext_of(u)

                # filter by requested types
                if kind == "html":
                    if "html" not in INCLUDE_FILETYPES and "htm" not in INCLUDE_FILETYPES:
                        return
                else:
                    if (ext and ext not in INCLUDE_FILETYPES) or (kind not in INCLUDE_FILETYPES):
                        return

                fetched += 1
                # increment kind counts for processed items
                kind_counts[kind] = kind_counts.get(kind, 0) + 1

                sha = sha256(body) if body else ""
                now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

                item = {
                    "url": u,
                    "status": r.status,
                    "kind": kind,
                    "content_type": ctype,
                    "sha256": sha,
                    "fetch_time": now,
                    "depth": depth,
                }

                if r.status == 200 and body:
                    if kind == "html":
                        html = body.decode(r.charset or "utf-8", errors="replace")
                        data = html_extract(html, str(r.url))
                        item.update(data)
                        if depth < MAX_DEPTH:
                            for link in data["links"]:
                                if len(q) < MAX_ENQUEUE and link not in seen and in_scope(link):
                                    q.append((link, depth + 1))
                    elif kind == "pdf":
                        with contextlib.suppress(Exception):
                            item["text"] = pdf_extract_text(body)
                    elif kind == "docx":
                        with contextlib.suppress(Exception):
                            item["text"] = docx_extract_text(body)

                # Upload RAW bytes (sharded by first 2 hex chars)
                if body and sha:
                    shard = sha[:2]
                    raw_ext = ext or {"html": "html", "pdf": "pdf", "docx": "docx"}.get(kind, "bin")
                    raw_uri = f"{BIN_S3_PREFIX}/{shard}/{sha}.{raw_ext}"
                    await s3_put_bytes(raw_uri, body, ctype)
                    item["raw_s3_uri"] = raw_uri

                key = (u, sha)
                if key not in emitted:
                    results.append(json.dumps(item, ensure_ascii=False))
                    emitted.add(key)

            # dispatcher
            while q and len(seen) < MAX_PAGES:
                batch = []
                while q and len(batch) < CONCURRENCY and len(seen) + len(batch) < MAX_PAGES:
                    u, d = q.popleft()
                    batch.append(asyncio.create_task(handle(u, d)))
                if batch:
                    await asyncio.gather(*batch, return_exceptions=True)

        # write JSONL at the end (still inside the S3 client context)
        body = ("\n".join(results) + ("\n" if results else "")).encode("utf-8")
        await s3.put_object(
            Bucket=bucket_jsonl, Key=key_jsonl, Body=body, ContentType="application/json"
        )

        # write manifest sidecar
        manifest = {
            "seed": SEEDS,
            "date": DATE,
            "out_jsonl": f"s3://{bucket_jsonl}/{key_jsonl}",
            "fetched": fetched,
            "emitted": len(results),
            "kinds": kind_counts,
            "duration_seconds": round(time.time() - start_ts, 3),
            "max_depth": MAX_DEPTH,
            "max_pages": MAX_PAGES,
        }
        manifest_key = key_jsonl.rsplit("/", 1)[0] + f"/manifest_{int(start_ts)}.json"
        await s3.put_object(
            Bucket=bucket_jsonl,
            Key=manifest_key,
            Body=(json.dumps(manifest, ensure_ascii=False) + "\n").encode("utf-8"),
            ContentType="application/json",
        )

    print(f"Fetched={fetched} Emitted={len(results)} -> s3://{bucket_jsonl}/{key_jsonl}")

if __name__ == "__main__":
    with contextlib.suppress(KeyboardInterrupt):
        asyncio.run(main())
