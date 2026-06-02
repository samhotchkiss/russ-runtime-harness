# Russell runtime harness

The **local side** of Russell's Phase-7 runtime contract: the always-on process
on your machine that pulls *needs* from Russell and dispatches each to a fresh
sub-agent that adopts the delivered identity. This directory is both the
**reference implementation** (Claude Code) and the **agent-agnostic contract** —
Codex or any other runtime implements the same wire protocol and the same laws.

## The shape (Shape A: warm dispatcher + bash plumbing)

```
                        ┌─────────────────────────────────────────┐
  heartbeat-daemon.sh ──┤ bash, always on: POST /api/runtimes/      │  keeps the
   (every 60s)          │ heartbeat — keeps ALL leases alive        │  lease alive
                        └─────────────────────────────────────────┘  off-model
                        ┌─────────────────────────────────────────┐
  dispatcher (Haiku) ───┤ loop: dispatch-tick.sh → for each need,  │  zero persona,
   CLAUDE.md            │ spawn a sub-agent (model from bundle)     │  zero Russell
                        └───────────────┬─────────────────────────┘  tools
                                        │ Task(model=opus|sonnet|haiku, background)
                        ┌───────────────▼─────────────────────────┐
  per-need sub-agent ───┤ IS the agent for one need: read bundle → │  identity +
   prompts/agent-       │ act via chat.post/react → complete_need  │  intelligence
   subagent.md          └─────────────────────────────────────────┘  live here only
```

Two processes, one model session. The **heartbeat daemon** and the **poller**
are dumb bash (cheap, reliable, always up). The **dispatcher** is one warm Haiku
Claude Code session that only routes. The **brain** is spawned per need, at the
model tier the agent asks for, and is thrown away after.

Why this and not headless `claude -p` per need: a per-need process is N cold
starts (no prompt-cache reuse, full re-send each time). One warm session reuses
cache across the idle loop *and* across needs, and spawns sub-agents cheaply —
far cheaper at any real volume.

### Routing scope (Phase 7 = external only)

The agent profile specifies a **model, not a client** — *Frank thinks with opus*,
nothing about laptops. In Phase 7 the only execution route is **external**: a
registered runtime (this harness) whose `offered_models` cover that model pulls
the need and runs it. Choosing **external vs direct-API per model**, with an
external-pickup wait before falling back to a server-side API executor, is
**Phase 8** — see #439. This harness is the external-route executor; it reads the
model from the bundle and runs it, and is unaffected by where Phase 8 later
decides a given model should run.

## The contract (any runtime must honour these)

1. **Register once.** `POST /api/runtimes` with either an owner session or a
   one-time `russ_enroll_…` bearer → `{runtime, credential}`. The
   `russ_runtime_…` credential is shown **once**; store it as
   `RUSS_RUNTIME_CREDENTIAL`. The runtime self-describes its `kind` and
   `offered_models` (advisory) at registration.
2. **Heartbeat on a timer.** `POST /api/runtimes/heartbeat` (Bearer credential)
   more often than the **5-minute** freshness window. This keeps every in-flight
   claim alive and must not depend on the model being free.
3. **Poll `next_need`.** `POST /api/mcp` (JSON-RPC, `tools/call` → `next_need`).
   One call claims **one need per agent bound to this runtime** and returns a
   bundle each: `need` + `identity` (incl. `model_policy`, `tool_policy`) +
   `tool_manifest` + prefetched `context`. `next_need` also heartbeats.
4. **One fresh agent per need.** Never act inline. Spawn a fresh sub-agent whose
   system identity **is** the bundle's profile, give it exactly the bundle's
   tools, let it act, then **`complete_need`** (ack).
5. **Attribution is via `need_id`.** Every action tool call carries
   `{need_id, idempotency_key, arguments}`. The runtime credential authenticates;
   the `need_id` selects which agent acts (server resolves need → agent → policy).
   There is **no per-agent token** — one credential multiplexes all bound agents.
6. **Idempotency on every mutating call**, keyed off the need id and **reused
   across reclaims**, so a retried post de-dups server-side.
7. **No local retries.** A crashed/timed-out sub-agent never acks; the lease
   expires and the **server** reclaims and re-offers. The local side keeps no
   durable state and runs no retry/backoff/dead-letter logic.

## Files

| File | Role |
|---|---|
| `lib/russ-mcp.sh` | shell client: `russ_next_need`, `russ_complete_need`, `russ_chat_post/react/read_context`, `russ_heartbeat` |
| `bin/heartbeat-daemon.sh` | always-on bash liveness loop |
| `bin/next-need-blocking.sh` | blocking poll: returns the instant a need lands, else empty after the window |
| `bin/dispatch-tick.sh` | one tick: persists bundles to files, prints a compact summary (keeps heavy context out of the dispatcher) |
| `CLAUDE.md` | the dispatcher's instructions (the warm Haiku session runs this) |
| `prompts/agent-subagent.md` | the identity-adoption brief each per-need sub-agent follows |
| `bin/enroll.sh` | self-register with a one-time enrollment token; writes the credential |
| `prompts/enroll-prompt.md` | the copy-paste bootstrap the app's "Add external" flow renders |

## Setup — the "Add external" flow

The intended path is **self-enrollment** (no hand-copying of long-lived secrets):

1. In the app: **Settings → Externals → Add external**. It mints a single-use,
   short-lived enrollment token and renders a copy-paste prompt
   (`prompts/enroll-prompt.md` with the token + tenant URL filled in).
2. Paste that prompt into your local agent (Claude CLI / Codex). The agent
   locates the harness, **detects its kind and available models**, and runs
   `bin/enroll.sh`, which `POST`s to `/api/runtimes` with the enrollment token and
   `{name, kind, offered_models}`, receives the long-lived `russ_runtime_…`
   credential, and writes it to `~/.russ/runtime.env`.
3. Start liveness + dispatcher:
   ```bash
   source ~/.russ/runtime.env
   caffeinate -dimsu runtime-harness/bin/heartbeat-daemon.sh &   # liveness, off-model
   # then start a Haiku Claude Code session in runtime-harness/ — it runs CLAUDE.md,
   # loops dispatch-tick.sh, and spawns one identity-adopting sub-agent per need.
   export RUSS_CONCURRENCY=4   # max sub-agents in flight (optional)
   ```

Requires `bash`, `curl`, and `jq`.

**Manual fallback:** an owner can still register directly and export the
credential by hand:
```bash
curl -fsS -X POST https://<tenant>.russ.team/api/runtimes \
  -H "Cookie: <owner session>" -H 'Content-Type: application/json' \
  -d '{"name":"sam-laptop","kind":"claude-cli","offered_models":["haiku","sonnet","opus"]}'   # → credential
export RUSS_BASE_URL=https://<tenant>.russ.team RUSS_RUNTIME_CREDENTIAL=russ_runtime_xxx
```

## Server/UI deltas this harness assumes

- **Settings → Externals UI.** Add-external mints the token, renders the prompt,
  and lists registered externals with kind, models, and live heartbeat.

## Two conventions to confirm (open)

These are harness-level decisions, not server changes — flagged for a ruling:

1. **`model_policy` shape.** The agent profile's `model_policy` is a free JSON
   blob (server does not yet constrain it). This harness reads
   **`model_policy.model ∈ {haiku, sonnet, opus}`** and falls back to
   `review→haiku, pinged→opus`. If we want the server to validate this key, that
   is a small follow-up; today it is convention-only.
2. **Default model by trigger.** The fallback above assumes review needs are
   cheap/often no-op (haiku) and pinged needs warrant the strong model (opus).
   Adjust per agent via `model_policy` once (1) is settled.
