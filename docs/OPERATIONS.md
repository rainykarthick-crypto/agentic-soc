# Operations

Running it, and what to do when something misbehaves.

- [Prerequisites](#prerequisites)
- [First run](#first-run)
- [Commands](#commands)
- [Models](#models)
- [Troubleshooting](#troubleshooting)
- [Data and teardown](#data-and-teardown)

---

## Prerequisites

- Docker with Compose v2
- `git` (the agent source is cloned, not vendored)
- An Ollama instance with a model, on the host or in the compose `llm` profile
- PowerShell 5.1+ on Windows, or bash on Linux/macOS

## First run

```powershell
cd agentic-soc
.\scripts\setup.ps1 -Build -Up -Verify
```

`setup` does five things:

1. Preflight: docker running, compose present, ports 3010/8020 free.
2. Create `.env` from `.env.example` if missing.
3. Clone `Nnamdi10/Agentic-SOC` into `vendor/`.
4. Patch the clone: `import os`, `OLLAMA_URL` from env, timeout 60s -> 900s.
5. Optionally build, start, verify.

Linux/macOS: `./scripts/setup.sh --build --up --verify`.

## Commands

| Task | Command |
|---|---|
| Status | `docker compose ps` |
| Logs (agent) | `docker logs -f soc-agent` |
| Logs (console) | `docker logs -f soc-dashboard` |
| Restart agent | `docker compose restart soc-agent` |
| Stop, keep data | `docker compose down` |
| Stop, drop volumes | `docker compose down -v` |
| Verify | `.\scripts\verify.ps1` |
| Re-run patches | `.\scripts\setup.ps1` (idempotent) |

## Models

The agent asks for a JSON object containing reasoning, a tool name and parameters.
At roughly 2 tokens/sec on a small CPU that reply takes 100-200 seconds - which is
why `setup` raises the timeout to 900s. With the original 60s the run died at step 1
with `httpx.ReadTimeout`.

Warm the model before an investigation so the first call is not also paying
load time (about a minute for a 2 GB model):

```powershell
$b = '{"model":"llama3.2:3b","prompt":"ok","stream":false,"keep_alive":"30m","options":{"num_predict":1}}'
Set-Content -Path .\w.json -Value $b
curl.exe -s -X POST -H "Content-Type: application/json" --data-binary "@w.json" http://127.0.0.1:11434/api/generate | Out-Null
Remove-Item .\w.json
```

Use the bundled model server instead:

```powershell
docker compose --profile llm up -d
docker exec soc-ollama ollama pull llama3.2:3b
# .env: OLLAMA_URL=http://ollama:11434/api/generate
docker compose up -d
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Console shows "api offline" | agent down, or nginx cannot resolve it | `docker ps`, `docker logs soc-agent` |
| Console loads but every panel is empty with `fetch failed` | `/api` proxy cannot reach the agent | confirm `soc-agent` is on the same network and healthy |
| Investigation stops at `Calling LLM...`, log shows `ReadTimeout` | model slower than the timeout | re-run `setup` (raises it to 900s), then rebuild `soc-agent` |
| Agent reports `investigating` forever | a failed run raises before the status reset | `docker compose restart soc-agent` |
| First investigation of the day fails, later ones succeed | cold model load (~60s) | warm it with the command above |
| `connection refused` from the agent | `OLLAMA_URL` points somewhere unreachable | from inside: `docker exec soc-agent python -c "import urllib.request;print(urllib.request.urlopen('http://host.docker.internal:11434/api/tags').status)"` |
| Port already allocated | something else on 3010 or 8020 | change the host side of the mapping in `docker-compose.yml` |
| Patches missing after a re-clone | `vendor/` was deleted and re-cloned | run `setup` again; it re-applies them |

## Data and teardown

| Volume | Holds |
|---|---|
| `soc-memory` | `episodes.json`, the recalled investigation history |
| `agentic-soc_ollama-models` | pulled models, only with `--profile llm` |

Back up the memory volume:

```powershell
docker run --rm -v agentic-soc_soc-memory:/d -v ${PWD}:/b alpine tar czf /b/soc-memory.tgz -C /d .
```

Full removal:

```powershell
docker compose down -v
Remove-Item -Recurse -Force .\vendor    # optional: drop the cloned agent
```
