# save as: smoketest_08_beam.sh
#!/usr/bin/env bash
set -euo pipefail

ok(){ echo "OK: $*"; }
fail(){ echo "FAIL: $*"; exit 1; }

svc=beam
outdir=/workspace/beam/_smoketest_out

echo "=== Beam: DirectRunner create → transform → write → verify ==="

# 0) sanity: service + beam import
docker compose ps "$svc" >/dev/null 2>&1 || fail "beam service not found in compose"

docker compose exec -T "$svc" bash -lc \
  'python - <<PY
import apache_beam as beam; print(beam.__version__)
PY' >/dev/null \
  || fail "apache_beam not importable"
ok "apache_beam import ok"

# 1) run a tiny pipeline
docker compose exec -T "$svc" bash -lc \
  "python - <<'PY'
import os, shutil
import apache_beam as beam
from apache_beam.options.pipeline_options import PipelineOptions

outdir = '$outdir'
shutil.rmtree(outdir, ignore_errors=True)

with beam.Pipeline(options=PipelineOptions(['--runner=DirectRunner'])) as p:
    ( p
      | 'make' >> beam.Create(['a','b','c','a'])
      | 'count' >> beam.combiners.Count.PerElement()
      | 'fmt' >> beam.Map(lambda kv: f\"{kv[0]}:{kv[1]}\")
      | 'write' >> beam.io.WriteToText(os.path.join(outdir,'result'), num_shards=1)
    )

print('pipeline ok')
PY" \
  || fail "Beam pipeline failed"
ok "Beam pipeline ran"

# 2) verify results
docker compose exec -T "$svc" bash -lc \
  "shopt -s nullglob; f=( $outdir/result-*-of-* ); [ -f \"\${f[0]}\" ] && cat \"\${f[0]}\"" \
  | tee /tmp/beam_out.txt >/dev/null

grep -q '^a:2$' /tmp/beam_out.txt || fail "expected 'a:2' in output"
grep -q '^b:1$' /tmp/beam_out.txt || fail "expected 'b:1' in output"
grep -q '^c:1$' /tmp/beam_out.txt || fail "expected 'c:1' in output"
ok "verification matched expected counts"

echo
echo "RESULT: ✅ Beam smoketest passed"
