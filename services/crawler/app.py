import os, time, json, asyncio, urllib.parse, contextlib
from collections import deque
import aiohttp
from bs4 import BeautifulSoup
import aioboto3
from botocore.config import Config
from urllib.parse import urlparse, urlunparse

SEEDS = os.getenv("SEEDS", "https://quotes.toscrape.com").split()
ALLOWED = set(os.getenv("ALLOWED_DOMAINS", "quotes.toscrape.com").split())
MAX_PAGES = int(os.getenv("MAX_PAGES", "20"))
MAX_DEPTH = int(os.getenv("MAX_DEPTH", "2"))
CONCURRENCY = int(os.getenv("CONCURRENCY", "10"))
UA = os.getenv("UA", "WSL-ML-STACK-Crawler/1.0")
OUT = os.getenv("OUT_S3_URI", "s3://crawl/raw/%Y%m%d/run.jsonl").replace("%Y%m%d", time.strftime("%Y%m%d"))
MIN_DELAY = float(os.getenv("MIN_DELAY_SECONDS", "0.2"))
MAX_ENQUEUE = int(os.getenv("MAX_ENQUEUE", "10000"))

S3_ENDPOINT = os.getenv("S3_ENDPOINT_URL", "http://minio:9000")
AWS_REGION = os.getenv("AWS_DEFAULT_REGION", "us-east-1")
AWS_ACCESS_KEY_ID = os.getenv("AWS_ACCESS_KEY_ID")
AWS_SECRET_ACCESS_KEY = os.getenv("AWS_SECRET_ACCESS_KEY")

def allowed(url: str) -> bool:
    host = urllib.parse.urlparse(url).hostname or ""
    return any(host == d or host.endswith(f".{d}") for d in ALLOWED)

def parse_title(html: str) -> str:
    soup = BeautifulSoup(html, "html.parser")
    return (soup.title.string.strip() if soup.title and soup.title.string else "")

def s3_parse(uri: str):
    assert uri.startswith("s3://")
    _, rest = uri.split("://", 1)
    bucket, key = rest.split("/", 1)
    return bucket, key


def norm(url: str) -> str:
    u = urlparse(url)
    # force https host casing + strip default port + strip fragment + collapse trailing slash
    path = u.path or "/"
    if path != "/" and path.endswith("/"):
        path = path.rstrip("/")
    return urlunparse((u.scheme.lower(), (u.hostname or "").lower(), path, "", "", ""))





async def fetch(session: aiohttp.ClientSession, url: str):
    try:
        async with session.get(url, timeout=aiohttp.ClientTimeout(total=20)) as r:
            r.raise_for_status()
            text = await r.text()
            return text, str(r.url)
    except Exception as e:
        print(f"skip {url} -> {e}")
        return None, url

async def crawl():
    seen = set()
    q = deque((norm(u), 0) for u in SEEDS)
    sem = asyncio.Semaphore(CONCURRENCY)
    results = []
    fetched = 0
    headers = {"User-Agent": UA}

    async with aiohttp.ClientSession(headers=headers) as session:
        async def handle(url, depth):
            nonlocal fetched
            nu = norm(url)
            if nu in seen or depth > MAX_DEPTH or not allowed(nu):
                return
            seen.add(nu)

            async with sem:
                # tiny polite delay
                await asyncio.sleep(MIN_DELAY)
                html_and_final = await fetch(session, nu)

            if not html_and_final or not html_and_final[0]:
                return

            html, final_url = html_and_final
            fetched += 1
            # emit basic record
            results.append(json.dumps({
                "url": norm(final_url),
                "title": parse_title(html),
                "depth": depth,
                "ts": int(time.time())
}))


            # discover links (enqueue normalized URLs)
            if depth < MAX_DEPTH:
                soup = BeautifulSoup(html, "html.parser")
                for a in soup.find_all("a", href=True):
                    nxt = urllib.parse.urljoin(final_url, a["href"])
                    if not nxt.startswith("http"):
                        continue
                    nn = norm(nxt)
                    # avoid growing the queue unbounded and skip URLs we've already seen
                    if len(q) < MAX_ENQUEUE and nn not in seen:
                        q.append((nn, depth + 1))



        while q and len(seen) < MAX_PAGES:
            batch = []
            while q and len(batch) < CONCURRENCY and len(seen) + len(batch) < MAX_PAGES:
                url, depth = q.popleft()
                batch.append(asyncio.create_task(handle(url, depth)))
            if batch:
                await asyncio.gather(*batch)

    bucket, key = s3_parse(OUT)
    cfg = Config(s3={"addressing_style": "path"})
    async with aioboto3.Session().client(
        "s3",
        endpoint_url=S3_ENDPOINT,
        region_name=AWS_REGION,
        aws_access_key_id=AWS_ACCESS_KEY_ID,
        aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
        config=cfg,
    ) as s3:
        body = ("\n".join(results) + ("\n" if results else "")).encode("utf-8")
        await s3.put_object(Bucket=bucket, Key=key, Body=body)

    print(f"Fetched={fetched} Emitted={len(results)} -> s3://{bucket}/{key}")

if __name__ == "__main__":
    with contextlib.suppress(KeyboardInterrupt):
        asyncio.run(crawl())

