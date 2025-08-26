#!/usr/bin/env bash
set -euo pipefail

ok(){ echo "OK: $1"; }
fail(){ echo -e "FAIL: $1"; exit 1; }

echo "=== Kafka: topic create → produce → consume ==="

# Use the same address Kafka advertises internally
BOOT="kafka:9092"
TOPIC="smoketest"

# 1) Readiness: retry listing topics until broker responds
if ! docker compose exec -T kafka bash -lc '
set -e
BOOT="'"$BOOT"'"
for i in {1..20}; do
  /opt/bitnami/kafka/bin/kafka-topics.sh --list --bootstrap-server "$BOOT" >/dev/null 2>&1 && exit 0
  sleep 1
done
exit 1
'; then
  # Show quick diag
  docker compose exec -T kafka bash -lc '
echo "---- diag: broker process ----"
ps aux | grep -i kafka | grep -v grep || true
echo "---- diag: listeners env ----"
env | grep -E "KAFKA_CFG_LISTENERS|ADVERTISED|PROCESS_ROLES|NODE_ID" || true
echo "---- diag: controller quorum ----"
/opt/bitnami/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server '"$BOOT"' describe 2>/dev/null || true
'
  fail "Broker not ready at $BOOT"
fi
ok "Broker responded at $BOOT"

# 2) Ensure topic exists (idempotent)
docker compose exec -T kafka bash -lc '
BOOT="'"$BOOT"'"; TOPIC="'"$TOPIC"'"
/opt/bitnami/kafka/bin/kafka-topics.sh --create --if-not-exists --topic "$TOPIC" \
  --bootstrap-server "$BOOT" --replication-factor 1 --partitions 1 >/dev/null
/opt/bitnami/kafka/bin/kafka-topics.sh --describe --bootstrap-server "$BOOT" --topic "$TOPIC"
' || fail "Topic create/describe failed"
ok "Topic available: $TOPIC"

# 3) Roundtrip: start a consumer, then produce one message
if docker compose exec -T kafka bash -lc '
set -e
BOOT="'"$BOOT"'"; TOPIC="'"$TOPIC"'"
TMP="$(mktemp)"
# Start consumer in background to capture exactly one message
( /opt/bitnami/kafka/bin/kafka-console-consumer.sh \
    --bootstrap-server "$BOOT" --topic "$TOPIC" \
    --from-beginning --timeout-ms 5000 --max-messages 1 >"$TMP" 2>&1 ) &
CONS_PID=$!
sleep 1
# Produce one message
printf "%s\n" "hello-smoke" | /opt/bitnami/kafka/bin/kafka-console-producer.sh \
    --bootstrap-server "$BOOT" --topic "$TOPIC" >/dev/null 2>&1 || true
wait $CONS_PID || true
echo "---- consumer output ----"
cat "$TMP" || true
grep -q "hello-smoke" "$TMP"
'; then
  ok "Produced and consumed a message"
else
  # If it failed, show extra diagnostics
  docker compose exec -T kafka bash -lc '
BOOT="'"$BOOT"'"; TOPIC="'"$TOPIC"'"
echo "---- diag: topics list ----"
/opt/bitnami/kafka/bin/kafka-topics.sh --list --bootstrap-server "$BOOT" || true
echo "---- diag: end offsets ----"
/opt/bitnami/kafka/bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
  --broker-list "$BOOT" --topic "$TOPIC" 2>/dev/null || true
'
  fail "Kafka roundtrip failed (see diagnostics above)"
fi

echo
echo "RESULT: ✅ Kafka smoketest passed"
