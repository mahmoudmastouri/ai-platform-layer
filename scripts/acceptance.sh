#!/usr/bin/env bash
# Post-deploy acceptance checks for the platform layer. Run on CT 210 as root:
#
#   ssh root@192.168.1.60 'bash -s -- all' < scripts/acceptance.sh
#   ssh root@192.168.1.60 'bash -s -- faults' < scripts/acceptance.sh
#
# Needs bash, curl, awk, grep, sed and docker. Nothing is printed from compose/.env
# except variable names. Each check prints PASS or FAIL, and the exit code is the
# number of failures.
#
# Phases:  health  langfuse  gateway  faults  stats  all  full
#   all   = health, langfuse, gateway, stats (no stub needed)
#   full  = all plus faults, with one combined cost total
# `faults` and `full` need the stub: docker compose --profile faults up -d fault-stub
#
# Environment:
#   COMPOSE_DIR   directory holding compose/.env. Default: read from the label on
#                 the ai-platform-litellm container.
set -uo pipefail

phase="${1:-all}"
fails=0
cost_total=0

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
info() { echo "      $*"; }

# --- environment ------------------------------------------------------------
if [ -z "${COMPOSE_DIR:-}" ]; then
  COMPOSE_DIR="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' ai-platform-litellm 2>/dev/null)"
fi
env_file="$COMPOSE_DIR/.env"
[ -r "$env_file" ] || { echo "cannot read $env_file (set COMPOSE_DIR)" >&2; exit 99; }
while IFS= read -r line; do
  case "$line" in [A-Za-z_]*=*) export "${line%%=*}=${line#*=}" ;; esac
done < "$env_file"

bind="$BIND_ADDRESS"
lf="http://$bind:${LANGFUSE_WEB_PORT:-3000}"
gw="http://$bind:${LITELLM_PORT:-4000}"
s3="http://$bind:${SEAWEEDFS_S3_PORT:-8333}"
empty=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

s3get() { curl -fsS --aws-sigv4 "aws:amz:us-east-1:s3" --user "$SEAWEEDFS_S3_ACCESS_KEY:$SEAWEEDFS_S3_SECRET_KEY" -H "x-amz-content-sha256: $empty" "$@"; }
header() { grep -i "^$1:" "$tmp/h" | tail -n 1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r'; }

# chat <group> [max-token-field]  -> writes $tmp/h and $tmp/b, sets code, secs
chat() {
  local group="$1" field="${2:-max_tokens}" t0 t1
  t0="$(date +%s.%N)"
  code="$(curl -sS -o "$tmp/b" -D "$tmp/h" -w '%{http_code}' --max-time 150 -X POST "$gw/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$group\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: pong\"}],\"$field\":${3:-16}}")"
  t1="$(date +%s.%N)"
  secs="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')"
  cost="$(header x-litellm-response-cost)"; cost="${cost:-0}"
  cost_total="$(awk -v a="$cost_total" -v b="$cost" 'BEGIN{printf "%.6f", a+b}')"
}

# --- health -----------------------------------------------------------------
check_health() {
  echo "== all services healthy within 5 minutes"
  local services="ai-platform-seaweedfs ai-platform-qdrant ai-platform-postgres ai-platform-clickhouse ai-platform-valkey ai-platform-langfuse-web ai-platform-langfuse-worker ai-platform-litellm"
  local deadline=$((SECONDS + 300)) bad
  while :; do
    bad=""
    for c in $services; do
      st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealth{{end}}' "$c" 2>/dev/null || echo missing)"
      [ "$st" = healthy ] || bad="$bad $c=$st"
    done
    [ -z "$bad" ] && break
    [ "$SECONDS" -ge "$deadline" ] && break
    sleep 5
  done
  if [ -z "$bad" ]; then pass "8 services healthy after ${SECONDS}s"; else fail "not healthy after 300s:$bad"; fi
  st="$(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' ai-platform-seaweedfs-init 2>&1)"
  case "$st" in "exited exit=0") pass "seaweedfs-init completed ($st)" ;; *) fail "seaweedfs-init: $st" ;; esac
  docker ps -a --filter label=com.docker.compose.project=ai-platform-stack --format '      {{.Names}}  {{.Status}}'
}

# --- langfuse ---------------------------------------------------------------
check_langfuse() {
  echo "== Langfuse"
  if curl -fsS --max-time 10 "$lf/api/public/health" > "$tmp/b"; then pass "GET /api/public/health: $(cat "$tmp/b")"; else fail "Langfuse health"; fi

  local before after tid eid ts
  before="$(s3get "$s3/langfuse-events?list-type=2" | grep -o '<KeyCount>[0-9]*' | sed 's/<KeyCount>//')"
  tid="$(cat /proc/sys/kernel/random/uuid)"; eid="$(cat /proc/sys/kernel/random/uuid)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  code="$(curl -sS -o "$tmp/b" -w '%{http_code}' -u "$LANGFUSE_INIT_PROJECT_PUBLIC_KEY:$LANGFUSE_INIT_PROJECT_SECRET_KEY" \
    -X POST "$lf/api/public/ingestion" -H 'Content-Type: application/json' \
    -d "{\"batch\":[{\"id\":\"$eid\",\"type\":\"trace-create\",\"timestamp\":\"$ts\",\"body\":{\"id\":\"$tid\",\"name\":\"acceptance-check\",\"timestamp\":\"$ts\"}}]}")"
  if [ "$code" = 207 ] || [ "$code" = 200 ]; then pass "ingestion accepted trace $tid (HTTP $code)"; else fail "ingestion HTTP $code: $(head -c 300 "$tmp/b")"; fi

  local start=$SECONDS got=0
  while [ $((SECONDS - start)) -lt 60 ]; do
    code="$(curl -sS -o "$tmp/b" -w '%{http_code}' -u "$LANGFUSE_INIT_PROJECT_PUBLIC_KEY:$LANGFUSE_INIT_PROJECT_SECRET_KEY" "$lf/api/public/traces/$tid")"
    [ "$code" = 200 ] && { got=1; break; }
    sleep 3
  done
  if [ "$got" = 1 ]; then pass "trace returned by the public API after $((SECONDS - start))s"; else fail "trace not returned within 60s (last HTTP $code)"; fi

  after="$(s3get "$s3/langfuse-events?list-type=2" | grep -o '<KeyCount>[0-9]*' | sed 's/<KeyCount>//')"
  info "langfuse-events objects: before=${before:-?} after=${after:-?}"
  if [ "${after:-0}" -ge 1 ] 2>/dev/null; then pass "at least one object in langfuse-events"; else fail "no object in langfuse-events"; fi
}

# --- gateway ----------------------------------------------------------------
check_gateway() {
  echo "== Gateway"
  code="$(curl -sS -o "$tmp/b" -w '%{http_code}' "$gw/v1/models")"
  [ "$code" = 401 ] && pass "GET /v1/models without key: 401" || fail "GET /v1/models without key: HTTP $code"

  code="$(curl -sS -o "$tmp/b" -w '%{http_code}' -H "Authorization: Bearer $LITELLM_MASTER_KEY" "$gw/v1/models")"
  local ids missing=""
  ids="$(grep -o '"id":"[^"]*"' "$tmp/b" | sed 's/"id":"//;s/"$//' | sort | tr '\n' ' ')"
  for g in generator judge embedder generator-fault-timeout generator-fault-5xx generator-fallback-openai generator-fallback-openrouter; do
    case " $ids" in *" $g "*) ;; *) missing="$missing $g" ;; esac
  done
  if [ "$code" = 200 ] && [ -z "$missing" ]; then pass "GET /v1/models with key lists all groups: $ids"; else fail "models HTTP $code, missing:$missing (got: $ids)"; fi

  chat generator
  mg="$(header x-litellm-model-group)"
  if [ "$code" = 200 ] && [ -n "$mg" ]; then pass "generator: 200, x-litellm-model-group=$mg, ${secs}s, cost \$$cost"; else fail "generator: HTTP $code group='$mg' $(head -c 300 "$tmp/b")"; fi

  code="$(curl -sS -o "$tmp/b" -D "$tmp/h" -w '%{http_code}' -X POST "$gw/v1/embeddings" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
    -d '{"model":"embedder","input":"acceptance check"}')"
  cost="$(header x-litellm-response-cost)"; cost="${cost:-0}"
  cost_total="$(awk -v a="$cost_total" -v b="$cost" 'BEGIN{printf "%.6f", a+b}')"
  dims="$(grep -o '"embedding":\[[^]]*\]' "$tmp/b" | head -n 1 | sed 's/"embedding":\[//;s/\]//' | tr ',' '\n' | grep -c .)"
  if [ "$code" = 200 ] && [ "$dims" = 1536 ]; then pass "embedder: 200, $dims dimensions, cost \$$cost"; else fail "embedder: HTTP $code, dims=$dims"; fi

  # Each deployment behind the fallback chain and the judge, called directly once.
  for g in generator-fallback-openai generator-fallback-openrouter; do
    chat "$g"
    if [ "$code" = 200 ]; then pass "$g: 200, ${secs}s, cost \$$cost"; else fail "$g: HTTP $code $(head -c 300 "$tmp/b")"; fi
  done
  chat judge max_completion_tokens 200
  if [ "$code" = 200 ]; then pass "judge: 200, ${secs}s, cost \$$cost"; else fail "judge: HTTP $code $(head -c 300 "$tmp/b")"; fi
}

check_faults() {
  echo "== Gateway fault injection (needs --profile faults)"
  local st
  st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' ai-platform-fault-stub 2>&1)"
  [ "$st" = healthy ] && pass "fault-stub healthy" || { fail "fault-stub is $st, start it with: docker compose --profile faults up -d fault-stub"; return; }
  for g in generator-fault-5xx generator-fault-timeout; do
    chat "$g"
    af="$(header x-litellm-attempted-fallbacks)"; mg="$(header x-litellm-model-group)"
    if [ "$code" = 200 ] && [ "${af:-0}" -ge 1 ] 2>/dev/null; then
      pass "$g: 200, attempted-fallbacks=$af, answered by group=$mg, elapsed ${secs}s, cost \$$cost"
    else
      fail "$g: HTTP $code attempted-fallbacks='${af}' group='$mg' elapsed ${secs}s $(head -c 300 "$tmp/b")"
    fi
  done
}

check_cost() {
  echo "== Cost of test calls"
  info "total x-litellm-response-cost: \$$cost_total"
  if awk -v c="$cost_total" 'BEGIN{exit !(c < 0.05)}'; then pass "total cost \$$cost_total is under \$0.05"; else fail "total cost \$$cost_total is not under \$0.05"; fi
}

check_stats() {
  echo "== Resource use (run after 5 minutes idle)"
  docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}'
  echo; free -h
}

case "$phase" in
  health) check_health ;;
  langfuse) check_langfuse ;;
  gateway) check_gateway; check_cost ;;
  faults) check_faults; check_cost ;;
  stats) check_stats ;;
  all) check_health; check_langfuse; check_gateway; check_cost; check_stats ;;
  full) check_health; check_langfuse; check_gateway; check_faults; check_cost; check_stats ;;
  *) echo "unknown phase: $phase" >&2; exit 99 ;;
esac

echo; echo "failures: $fails"
exit "$fails"
