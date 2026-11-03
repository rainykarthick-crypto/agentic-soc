# Architecture

How the agent decides, what it is allowed to do, and where the pieces sit.

- [Components](#components)
- [The investigation loop](#the-investigation-loop)
- [Tools and risk](#tools-and-risk)
- [The safety engine](#the-safety-engine)
- [Memory](#memory)
- [API](#api)
- [The console](#the-console)
- [Ports and networks](#ports-and-networks)

---

## Components

| Component | Container | Responsibility |
|---|---|---|
| Agent | `soc-agent` | FastAPI service. Runs the ReAct loop, calls tools through the safety gate, serves the API |
| Console | `soc-dashboard` | Static page plus an nginx reverse proxy for `/api` |
| Model | *external* or `soc-ollama` | Chat completion for the reasoning step |

The agent is the only component that talks to a model. The console never does; it
reads JSON from the agent.

## The investigation loop

An investigation is a bounded ReAct loop: **at most 10 steps**.

```
POST /investigate { alert }
        |
        v
  store trigger, set state = investigating
        |
        v
  +--> think      : build prompt (trigger + recalled episodes + tool list)
  |    |
  |    +--> act   : model returns JSON { thought, action, params }
  |    |
  |    +--> gate  : assess_action(tool, params, blast_radius, reversible)
  |    |
  |    +--> run   : only if the gate returns auto_execute
  |    |
  |    +--> log   : append event, record rollback entry
  |    |
  +----+---------- repeat while step < 10
        |
        v
  store episode, set state = idle
```

Every step appends one or more events to the investigation log. The console renders
them; you can also read them directly at `GET /log`.

Event types emitted: `INVESTIGATION_START`, `STEP_n_REASONING`, `STEP_n_THOUGHT`,
`STEP_n_SAFETY`, `STEP_n_RESULT`, `STEP_n_ERROR`, `MAX_STEPS_REACHED`,
`INVESTIGATION_COMPLETE`.

If a step raises, the run aborts and the state is **not** reset - see
[OPERATIONS.md](OPERATIONS.md#troubleshooting).

## Tools and risk

Each tool declares three things: a description for the model, a **blast radius**
(1-10), and whether it is **reversible**. The registry ships eight tools:

| Tool | Radius | Reversible | What it does |
|---|---|---|---|
| `get_recent_alerts` | 1 | yes | fetch alerts from the SIEM |
| `get_alert_detail` | 1 | yes | full detail for one alert |
| `query_asset_inventory` | 1 | yes | IP to hostname/role/owner |
| `generate_incident_report` | 1 | yes | structured report |
| `run_vulnerability_scan` | 3 | yes | scan a target for CVEs |
| `create_detection_rule` | 5 | yes | add a SIEM rule |
| `unblock_ip` | 6 | yes | remove a block |
| `block_ip` | 7 | yes | block an IP at the network level |

Blast radius is the *only* input to the safety decision, alongside reversibility.

## The safety engine

`assess_action()` returns one of three decisions. Every tool call passes through it;
there is no bypass path in the code.

| Condition | Decision | Effect |
|---|---|---|
| Tool is on the prohibited list | `blocked` | never runs |
| Irreversible **and** radius >= 7 | `blocked` | never runs |
| Radius >= 7 | `requires_approval` | queued; needs a human "Approve" |
| Anything else | `auto_execute` | runs immediately |

The prohibited list is a constitutional constraint, checked before anything else:

```
disable_logging, delete_audit_trail, modify_audit_trail, exfiltrate_data
```

Approvals are surfaced in the console as cards showing the tool, its parameters,
the radius and reversibility, with Approve and Reject buttons.

## Memory

Completed investigations are stored as episodes. When a new alert arrives, the
agent recalls episodes whose trigger text overlaps, and includes them in the prompt
- so a repeated incident benefits from what was learned last time.

Episodes are written to `/app/memory/episodes.json`, which is a mounted volume, so
they survive restarts. The approval queue and the rollback ledger are in-process
lists and do not.

## API

All endpoints are unauthenticated and bound to loopback. See
[SECURITY.md](SECURITY.md).

| Method | Path | Returns |
|---|---|---|
| `POST` | `/investigate` | `{status, investigation_id}` - starts a run in the background |
| `GET` | `/status` | `{state, current_task}` where state is `idle` or `investigating` |
| `GET` | `/log?limit=N` | `{log: [{id, timestamp, event, message, data}]}` |
| `GET` | `/approvals` | `{pending: [{approval_id, tool, params, blast_radius, reversible, requested_at, status}]}` |
| `POST` | `/approvals/{id}/approve` | `{status, action}` |
| `POST` | `/approvals/{id}/reject` | `{status, action}` |
| `GET` | `/rollback-ledger` | `{ledger: [{timestamp, tool, params, result_summary, rollback_cmd}]}` |
| `GET` | `/memory` | `{episodes: [...]}` |
| `GET` | `/tools` | `{tools: [{name, description, blast_radius, reversible}]}` |
| `GET` | `/health` | `{status, model, timestamp}` |

## The console

```
browser --> :3010 /           -> index.html          (static)
        --> :3010 /api/status -> soc-agent:8000/status   (nginx proxy)
```

One page, no build step, no external assets: the charts are hand-written SVG and the
script is plain JavaScript. The proxy exists so the browser talks to its own origin -
no CORS, and the agent never needs a published port.

The console polls every two seconds and renders: agent state, a three-series
activity timeline, an event-mix donut, a colour-coded live stream, the tool registry
with radius meters, pending approvals, the rollback ledger, and agent memory.

## Ports and networks

| Port | Bound to | What |
|---|---|---|
| `3010` | `127.0.0.1` | console |
| `8020` | `127.0.0.1` | agent API |
| `11435` | `127.0.0.1` | bundled model server, only with `--profile llm` |

One bridge network, `soc`. Nothing is published beyond loopback. The agent container
runs read-only with `cap_drop: ALL`; the console needs a small set of capabilities
because nginx drops privileges and chowns its temp directories.
