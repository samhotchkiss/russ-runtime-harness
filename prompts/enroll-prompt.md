# Enroll-external prompt template

The app's **Settings → Externals → Add external** flow renders this template with
the placeholders filled, and the owner pastes the result into their local agent
(Claude CLI, Codex, …). The agent self-configures and registers. The
`{{ENROLL_TOKEN}}` is single-use and short-lived.

---

You are connecting this machine to Russell as a runtime. Do the following:

1. Get the harness: clone `{{HARNESS_REPO}}` (or `cd` into it if you already have
   it). The harness lives in `runtime-harness/`.
2. Determine **what you are** and **which models you can run**:
   - your kind: `claude-cli`, `codex`, or another short identifier;
   - the models you actually have access to, from `haiku`, `sonnet`, `opus`
     (list only what you can run).
3. Self-register by running:
   ```bash
   export RUSS_BASE_URL={{BASE_URL}}
   export RUSS_ENROLL_TOKEN={{ENROLL_TOKEN}}
   export RUSS_RUNTIME_KIND=<claude-cli|codex|…>     # what you are
   export RUSS_OFFERED_MODELS=<e.g. haiku,sonnet,opus>  # what you can run
   export RUSS_RUNTIME_NAME=<a label, e.g. sam-laptop>  # optional
   runtime-harness/bin/enroll.sh
   ```
   This registers you and writes your long-lived credential to `~/.russ/runtime.env`.
4. Start the harness:
   ```bash
   source ~/.russ/runtime.env
   caffeinate -dimsu runtime-harness/bin/heartbeat-daemon.sh &
   ```
   Then start a **Haiku** Claude Code session in `runtime-harness/` — it runs
   `CLAUDE.md` and becomes the dispatcher, pulling needs and spawning one
   identity-adopting sub-agent per need.

Report back the runtime id from step 3 and confirm the dispatcher is looping.

---

**Placeholders:** `{{BASE_URL}}` = tenant URL · `{{ENROLL_TOKEN}}` = single-use
enrollment token · `{{HARNESS_REPO}}` = harness git URL.
