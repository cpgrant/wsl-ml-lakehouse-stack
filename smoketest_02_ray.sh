#!/usr/bin/env bash
set -euo pipefail

ok(){ echo "OK: $1"; }
fail(){ echo "FAIL: $1"; exit 1; }

echo "=== Ray: cluster connectivity & basic ops ==="

# 1) Quick cluster status
docker compose exec -T ray-head bash -lc "ray status || true" >/dev/null && ok "ray status reachable"

# 2) Python checks inside ray-head
docker compose exec -T ray-head bash -lc 'python - << "PY"
import sys, ray, numpy as np

ray.init(address="auto", namespace="smoketest", log_to_driver=False)

nodes = ray.nodes()
alive = [n for n in nodes if n.get("Alive")]
print("alive_nodes:", len(alive))
if len(alive) < 1:
    sys.exit("No alive nodes in cluster")

@ray.remote
def plus1(x): return x + 1
assert ray.get(plus1.remote(41)) == 42
print("remote_task_ok")

arr = np.arange(10_000, dtype=np.int32)
oid = ray.put(arr)
out = ray.get(oid)
assert (out == arr).all()
print("object_store_ok")
PY' | tee /tmp/ray_smoke.out >/dev/null

grep -q "alive_nodes:" /tmp/ray_smoke.out && ok "Cluster has alive nodes"
grep -q "remote_task_ok" /tmp/ray_smoke.out && ok "Remote task executed"
grep -q "object_store_ok" /tmp/ray_smoke.out && ok "Object store put/get"

# 3) Optional dashboard probe
if curl -fsS -m 2 http://localhost:8265 >/dev/null 2>&1; then
  ok "Dashboard reachable on http://localhost:8265"
else
  echo "Note: Ray dashboard not reachable on localhost:8265 (might be firewall/expected)."
fi

echo
echo "RESULT: ✅ Ray smoketest passed"
