#!/usr/bin/env bash
# =============================================================================
# Agentic SOC - provision and run (Linux / macOS)
# =============================================================================
#   ./scripts/setup.sh                preflight, .env, clone, patch
#   ./scripts/setup.sh --build        also build images
#   ./scripts/setup.sh --up           also start
#   ./scripts/setup.sh --verify       also run checks
#   ./scripts/setup.sh --build --up --verify
# =============================================================================
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$ROOT/docker-compose.yml"
ENV_FILE="$ROOT/.env"
AGENT_DIR="$ROOT/vendor/Agentic-SOC/agent"

DO_BUILD=0; DO_UP=0; DO_VERIFY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)  DO_BUILD=1 ;;
    --up)     DO_UP=1 ;;
    --verify) DO_VERIFY=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

step() { printf '\n\033[36m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32m[ok]\033[0m   %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   \033[33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '   \033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1 preflight
step "1/5 Preflight"
command -v docker >/dev/null || die "docker not on PATH"
docker info >/dev/null 2>&1 || die "docker daemon not running"
docker compose version >/dev/null 2>&1 || die "docker compose v2 required"
command -v git >/dev/null || die "git required"
ok "$(docker --version)"

for p in 3010 8020; do
  if command -v ss >/dev/null && ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN; then
    warn "port $p already in use"
  fi
done

# ---------------------------------------------------------------------- 2 env
step "2/5 Environment"
if [[ -f "$ENV_FILE" ]]; then
  ok ".env already exists (left untouched)"
else
  cp "$ROOT/.env.example" "$ENV_FILE"
  ok ".env created from .env.example"
fi

# ------------------------------------------------------------------- 3 vendor
step "3/5 Agent source"
if [[ -f "$AGENT_DIR/main.py" ]]; then
  ok "agent already cloned"
else
  info "cloning Nnamdi10/Agentic-SOC ..."
  git clone --depth 1 --quiet https://github.com/Nnamdi10/Agentic-SOC.git "$ROOT/vendor/Agentic-SOC" \
    || die "clone failed"
  ok "agent cloned"
fi

# --------------------------------------------------------------- 4 patch code
step "4/5 Local patches"
# Applied to the checkout only. Upstream has no license file, so its source is
# not copied into this repository.
MAIN="$AGENT_DIR/main.py"
[[ -f "$MAIN" ]] || die "missing $MAIN after clone"

# \r? keeps this working on a checkout with CRLF endings, where "^import json$"
# would never match and the import would be silently skipped.
grep -qE '^import os\r?$' "$MAIN" || sed -i 's/^import json\r\?$/import json\nimport os/' "$MAIN"
sed -i 's|OLLAMA_URL = "http://ollama:11434/api/generate"|OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://ollama:11434/api/generate")|' "$MAIN"
sed -i 's/httpx\.AsyncClient(timeout=60\.0)/httpx.AsyncClient(timeout=900.0)/' "$MAIN"

grep -qE '^import os\r?$' "$MAIN" || die "import os patch did not apply"
grep -q 'timeout=900.0' "$MAIN" || die "timeout patch did not apply"
grep -q 'os.environ.get("OLLAMA_URL"' "$MAIN" || die "OLLAMA_URL patch did not apply"
ok "patched (os import, OLLAMA_URL env, 900s timeout)"

if command -v python3 >/dev/null; then
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$MAIN" \
    || die "patched main.py is not valid Python"
  ok "patched source parses"
fi

# -------------------------------------------------------------------- 5 build
step "5/5 Build, start, verify"

if [[ $DO_BUILD -eq 1 ]]; then
  docker compose -f "$COMPOSE" --env-file "$ENV_FILE" build || die "build failed"
  ok "images built"
else
  info "skipped build (pass --build)"
fi

if [[ $DO_UP -eq 1 ]]; then
  docker compose -f "$COMPOSE" --env-file "$ENV_FILE" up -d || die "compose up failed"
  sleep 5
  docker compose -f "$COMPOSE" --env-file "$ENV_FILE" ps
  ok "stack started"
else
  info "skipped start (pass --up)"
fi

if [[ $DO_VERIFY -eq 1 ]]; then
  bash "$ROOT/scripts/verify.sh" || warn "some checks failed"
else
  info "skipped verify (pass --verify)"
fi

printf '\nConsole: http://127.0.0.1:3010\nAgent:   http://127.0.0.1:8020/health\n'
