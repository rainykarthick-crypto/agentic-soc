#!/usr/bin/env bash
# =============================================================================
# Agentic SOC - verification (Linux / macOS)
# =============================================================================
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DASH="${DASH:-http://127.0.0.1:3010}"
AGENT="${AGENT:-http://127.0.0.1:8020}"

FAILED=0
pass() { printf '  \033[32mPASS\033[0m  %-38s %s\n' "$1" "$2"; }
fail() { printf '  \033[31mFAIL\033[0m  %-38s %s\n' "$1" "$2"; FAILED=$((FAILED+1)); }

running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

echo
echo "Agentic SOC - verification"
echo "===================================================================="

for c in soc-agent soc-dashboard; do
  if running "$c"; then pass "$c running" "up"; else fail "$c running" "not running"; fi
done

# Poll instead of judging on the first attempt: uvicorn with --reload needs a
# few seconds after a recreate.
wait_body() {
  local url="$1" tries=20 body=""
  for _ in $(seq 1 "$tries"); do
    body=$(curl -s --max-time 3 "$url" 2>/dev/null || true)
    [[ -n "$body" ]] && { printf '%s' "$body"; return 0; }
    sleep 1.5
  done
  return 1
}

health=$(wait_body "$AGENT/health" || true)
if [[ "$health" == *'"status":"ok"'* ]]; then
  model=$(printf '%s' "$health" | sed -n 's/.*"model":"\([^"]*\)".*/\1/p')
  pass "agent /health" "model=$model"
else
  fail "agent /health" "${health:-no response after 30s}"
fi

page=$(curl -s --max-time 8 "$DASH/" || true)
if [[ "$page" == *"Activity timeline"* ]]; then pass "console serves the dashboard" "index.html"
else fail "console serves the dashboard" "unexpected page"; fi

if [[ "$page" == *cdnjs* || "$page" == *unpkg* || "$page" == *jsdelivr* || "$page" == *googleapis* ]]; then
  fail "console has no external asset tags" "found a CDN reference"
else
  pass "console has no external asset tags" "self-contained"
fi

status=$(wait_body "$DASH/api/status" || true)
if [[ "$status" == *'"state"'* ]]; then pass "console proxies /api to the agent" "$status"
else fail "console proxies /api to the agent" "${status:-no response}"; fi

tools=$(curl -s --max-time 8 "$DASH/api/tools" || true)
n=$(printf '%s' "$tools" | grep -o '"name"' | wc -l | tr -d ' ')
if [[ "${n:-0}" -gt 0 ]]; then pass "tool registry reachable" "$n tools"
else fail "tool registry reachable" "$tools"; fi

if running soc-agent; then
  if docker exec soc-agent grep -q 'timeout=900.0' /app/main.py 2>/dev/null; then
    pass "LLM timeout patch applied" "timeout=900.0"
  else fail "LLM timeout patch applied" "not found"; fi

  if docker exec soc-agent grep -q 'os.environ.get' /app/main.py 2>/dev/null; then
    pass "Ollama URL is configurable" "reads OLLAMA_URL"
  else fail "Ollama URL is configurable" "not found"; fi
else
  fail "LLM timeout patch applied" "agent not running"
  fail "Ollama URL is configurable" "agent not running"
fi

ids=$(docker compose -f "$ROOT/docker-compose.yml" ps -q 2>/dev/null || true)
if [[ -n "$ids" ]]; then
  bad=""
  for id in $ids; do
    while read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$line" == *"->127.0.0.1:"* ]] || bad+="$line; "
    done < <(docker port "$id" 2>/dev/null || true)
  done
  if [[ -z "$bad" ]]; then pass "all published ports are loopback only" "ok"
  else fail "all published ports are loopback only" "$bad"; fi
else
  fail "all published ports are loopback only" "no running containers"
fi

echo
if [[ $FAILED -eq 0 ]]; then
  printf '\033[32mAll checks passed.\033[0m\n'; exit 0
else
  printf '\033[31m%d check(s) failed.\033[0m\n' "$FAILED"; exit 1
fi
