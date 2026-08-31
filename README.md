# veramux

A personal agentic engineering stack: one entry point, `agent`, that puts
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`)
in charge of running Claude Code as the implementer and Codex as an
independent, mechanism-enforced read-only reviewer against your own
projects.

P0 was the minimum end-to-end loop; P1 added automatic context gathering
(memory, code-structure graph, external research — all optional, all
degrading gracefully) and risk-adaptive review depth. P2 was operational
hardening — a durable run journal, structured events, a small run-state
machine, timeouts/retries/cancellation, workspace locking, git-state
safety, recovery/resume. P3 (this version, **V1**) makes it maintainable
for the long haul: a component inventory + compatibility manifest,
capability probes, a discover → plan → stage → snapshot → apply →
verify → keep-or-rollback upgrade cycle that never touches a critical
component silently, deterministic quality/cost benchmarks, optimization
profiles, backup/restore, and a reproducible release manifest — all with
**zero** added LLM calls to a normal run. See
[Operational hardening (P2)](#operational-hardening-p2) and
[Maintenance and controlled upgrades (P3 / V1)](#maintenance-and-controlled-upgrades-p3--v1)
below. A dashboard, multi-user/SaaS, Kubernetes, a remote database, a
custom UI, a generic plugin system, a required local model, and a custom
embeddings/vector-DB stack remain explicitly out of scope — see
[Future scope (post-V1)](#future-scope-post-v1) at the bottom.

## Architecture

```
User
  |
run journal created (run_id, lock acquired) -- P2.4/P2.5/P2.12
  |
DeepSeek Harness (orchestrator: dsh)
  |
Context gathering (memory / graph / grep / external research -- all optional)
  |
Claude Code (lead, real write/edit access, subscription-authenticated)
  |
Tests / Lint / Typecheck (the project's own commands)
  |
Risk classification (low / medium / high -- deterministic, no LLM call)
  |
Codex (independent reviewer, mechanism-enforced read-only; skipped for low risk)
  |
Claude Code (correction, up to policies/orchestration.yaml: max_correction_rounds)
  |
Final validation
  |
Final result (approved | blocked, never silently masked) -- journal COMPLETED/FAILED
```

Every arrow above is wrapped with a wall-clock timeout, a structured event,
and (for the two dsh calls) a bounded retry on transient failure only —
see [Operational hardening (P2)](#operational-hardening-p2). An
interrupted run (Ctrl+C, a VPS reboot, a killed process) leaves a durable
record instead of silent, mysterious state:

```
INTERRUPTED
  |
run journal (what phase were we in? was that phase's call actually
             in flight, or just about to start?)
  |
git state check (has HEAD moved since this run started?)
  |
safe checkpoint (CONTEXT_READY / IMPLEMENTATION_DONE / VALIDATION_DONE /
                 REVIEW_DONE / CORRECTION_DONE)
  |
a NEW, self-contained one-shot call to Claude/Codex if one is needed
  |
CONTINUE (agent resume <run-id>)
```

DeepSeek Harness (`dsh`) is real, but very new (developer preview,
`0.1.1-rc.2` as of writing) and its own docs don't cover everything by
example. Every claim in this README about how `dsh` behaves was verified by
cloning `deepseek-ai/deepseek-harness` and reading the actual source and
tests — the full trail is in
[`docs/upstream-findings.md`](docs/upstream-findings.md). Read that file
before changing anything under `harness/`.

### What's ours vs. what's upstream

| Piece | Owner |
|---|---|
| Running Claude Code (process, auth, permissions, platform CLI) | `@deepseek-ai/dsh-subagent-claude-code` (official DSH bundle) |
| Running Codex (process, JSON-RPC protocol, auth, permissions) | `@deepseek-ai/dsh-subagent-codex` (official DSH bundle) |
| Profile/plugin lifecycle, config layering, hot reload | `dsh plugin`, `cordis.patch.yml` (official) |
| Config introspection | `dsh --profile <name> --dump-config` (official) |
| One-shot headless execution, exit codes | `dsh --profile headless` (official) |
| The `lead`/`reviewer` DSH profiles (who gets which one tool, what persona) | ours: [`harness/profiles/`](harness/profiles/) |
| The deterministic implement→validate→review→correct loop, round limit | ours: [`lib/orchestrate.sh`](lib/orchestrate.sh) |
| Validation command detection/runner | ours: [`lib/validation.sh`](lib/validation.sh) |
| Review JSON contract parsing/validation | ours: [`lib/json-tools.mjs`](lib/json-tools.mjs) |
| Secret/sensitive-file redaction before anything reaches the reviewer | ours: [`lib/redact.sh`](lib/redact.sh) |
| `agent doctor` | ours: [`scripts/doctor.sh`](scripts/doctor.sh) |
| Code-structure graph (query/explain/path, local AST, no vector DB) | `graphify` CLI (Graphify-Labs/graphify — official, optional) |
| Persistent cross-session memory, progressive-disclosure search | claude-mem's worker HTTP API (thedotmack/claude-mem — official, optional) |
| Web/search/GitHub fetch primitives | Jina Reader/search + `gh` CLI (the same backends Agent-Reach itself selects — official, optional) |
| Context package assembly, budgets, mutual-exclusivity dedup | ours: [`lib/context.sh`](lib/context.sh) |
| Risk classification (low/medium/high), adaptive review depth | ours: [`lib/risk.sh`](lib/risk.sh) |
| Project-level overrides (`.agent/config.yaml`) | ours: [`lib/project_config.sh`](lib/project_config.sh) |

Two DSH profiles do all the real work:

- **`lead`** — boots `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-headless` +
  `@deepseek-ai/dsh-subagent-claude-code`, with every native tool (bash, fs,
  editor, generic subagents, ...) disabled except one:
  `subagent_claude_code`. Its own driving model (DeepSeek by default) has
  exactly one job — call that tool with the task text it's given and return
  the answer verbatim. All real editing happens inside the real Claude Code
  CLI's own session (bundled by the official SDK), using **your Claude Code
  subscription login**, not this profile's own tools.
- **`reviewer`** — same shape, with `subagent_codex` instead, running under
  a **dedicated `CODEX_HOME`** whose `config.toml` pins
  `sandbox_mode = "read-only"`. Codex authenticates as your normal
  `codex login` (the auth file is symlinked in), but the sandbox refuses
  writes regardless of what the reviewer prompt says — this is enforced by
  Codex's own sandbox, not just an instruction.

See [`docs/upstream-findings.md`](docs/upstream-findings.md) for exactly why
the loop itself (round limits, JSON contract, redaction) lives in
[`lib/orchestrate.sh`](lib/orchestrate.sh) as plain bash instead of inside a
single long-lived `dsh` conversation: those are hard, deterministic rules,
and DSH's own subagent providers are one-shot, text-in/text-out, with no
tool-filtering or structured-output support to lean on for them.

### Why context/research is a bash pipeline, not a Claude Code skill

Graphify, claude-mem, and Agent-Reach are all designed to be installed as
skills/plugins the coding agent itself uses autonomously inside its own
session. An earlier design note in
[`docs/upstream-findings.md`](docs/upstream-findings.md) argued for exactly
that — install the three as skills, let Claude decide when to use them, and
keep our own code to risk classification and review depth. That question
was put to the person running this stack, who chose the other path:
[`lib/context.sh`](lib/context.sh), [`lib/graph.sh`](lib/graph.sh),
[`lib/memory.sh`](lib/memory.sh), and [`lib/research.sh`](lib/research.sh)
call Graphify's CLI, claude-mem's worker HTTP API, and Jina Reader/`gh`
directly from bash, assemble a small bounded context package **before**
the lead ever runs, and hand it to Claude as background material. Both
designs are legitimate; this repo implements the explicit-pipeline one.
Graphify's CLI (`graphify query/explain/path` against `graphify-out/
graph.json`) and claude-mem's worker (`POST /api/context/semantic`) both
have real, stable, bash-callable interfaces for this — see
`docs/upstream-findings.md` for the exact endpoints/commands. Agent-Reach
itself exposes no fetch/search command of its own by design ("a capability
layer, not a wrapper"), so the research path calls the same underlying
tools it would tell an agent to call (Jina Reader, `gh`) directly, and
Agent-Reach's own value here is mainly as an installer/health-checker for
the fuller channel set if you want it (`agent-reach doctor`).

## Prerequisites

- A Linux VPS (this is the assumed target — see [`versions.yaml`](versions.yaml)).
- Node.js `>= 22.19.0`, pnpm `11.7.0` (`dsh plugin` shells out to pnpm).
- git.
- A Claude Code subscription (for the lead).
- A ChatGPT plan Codex is authorized against (for the reviewer).
- A DeepSeek API key for the relay's primary provider. An OpenAI API key is
  optional and enables the relay fallback; neither key authenticates the
  Claude Code or Codex child process.
- Optional, all independently skippable (the run degrades gracefully
  without any of them — see [Context tools](#context-tools)): `graphify`
  (`uv tool install graphifyy`), claude-mem (`npx claude-mem install`,
  needs Node ≥ 20.12 and installs Bun + `uv` itself), `curl` (for the
  built-in web/search research path), `gh` CLI (for GitHub-specific
  research).

## Install

```sh
git clone <this-repo-url> veramux
cd veramux
./scripts/install.sh
agent doctor
```

`scripts/install.sh` is idempotent — safe to re-run. It:

1. Checks Node/pnpm and installs the pinned `dsh` version
   ([`versions.yaml`](versions.yaml)) via `npm install -g` if missing.
2. Runs [`scripts/configure.sh`](scripts/configure.sh), which creates the
   `lead` and `reviewer` DSH profiles under `$DSH_HOME/profiles/` using the
   official `dsh plugin --profile <name> add ...` command (we never
   hand-author a profile's `package.json`/bundle list) and copies our
   `cordis.patch.yml` templates into them.
3. Prints exactly what to do for authentication (next section) — it never
   logs in on your behalf and never stores a password or token itself.

No `sudo` is used. If a system-level dependency is genuinely missing (e.g.
Node itself), the script tells you the exact command to run and stops
instead of guessing.

## Authentication

**Claude Code (subscription, not API billing):**

```sh
npm install -g @anthropic-ai/claude-code   # if you don't already have it
claude                                      # log in once, interactively
```

This login is shared with the private Claude Code CLI the `lead` profile's
bundled Agent SDK selects internally — you do not need to log in twice, and
the bundled copy is not a separate account.

**Codex (ChatGPT plan, not API billing):**

```sh
npm install -g @openai/codex   # if you don't already have it
codex login
```

`scripts/configure.sh` symlinks `~/.codex/auth.json` into the reviewer's
dedicated, read-only-sandboxed `CODEX_HOME` — re-run it (or just
`scripts/install.sh` again) after logging in if you configured before
logging in.

**Relay providers — DeepSeek primary, OpenAI fallback:**

```sh
export VERAMUX_DEEPSEEK_API_KEY=...      # primary; or put it in $DSH_HOME/.env
export VERAMUX_DEEPSEEK_MODEL=deepseek-chat  # optional default

export VERAMUX_OPENAI_API_KEY=...        # optional fallback only
export VERAMUX_OPENAI_MODEL=gpt-5-mini   # optional fallback default
```

Every relay call starts at DeepSeek. OpenAI is tried only after DeepSeek's
retry budget ends with `RATE_LIMIT`, `QUOTA`, `PROVIDER_UNAVAILABLE`, or
`TIMEOUT`, or when DeepSeek is not configured and OpenAI is. Configuration,
authentication, malformed/internal output, validation/review, cancellation,
policy/security, and unknown failures do not trigger fallback. The two
`apiKeyEnv` references are independent and the unselected ambient key is
removed before `dsh` starts. Never put `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`
into a Claude/Codex child-provider config.

`agent doctor` reports all supported states: both providers (normal with
fallback), DeepSeek only (normal without fallback), OpenAI only (degraded),
or neither (blocked).

## `agent doctor`

```sh
agent doctor            # environment + harness checks only
agent doctor /path/repo # also checks that project's git/ecosystem/validation setup
```

Sample output:

```
Core
  ✓ git (2.43.0)
  ✓ Node (22.19.0)
  ✓ pnpm (11.7.0)
  ✓ DeepSeek Harness (dsh 0.1.1-rc.2)

Claude
  - no host 'claude' CLI on PATH — not required, but you need it to log in
  ✓ found local Claude Code config/credential state (heuristic only)

Codex
  - no host 'codex' CLI on PATH — not required, but you need it to log in
  ✓ found ~/.codex/auth.json (heuristic only)

Harness profiles
  ✓ lead profile exists
  ✓ lead profile has the Claude Code subagent bundle
  ✓ reviewer profile exists
  ✓ reviewer profile has the Codex subagent bundle
  ✓ reviewer profile disables native write/edit/shell tool rows (mechanism-level read-only)
  ✓ reviewer profile pins a dedicated CODEX_HOME
  ✓ reviewer CODEX_HOME pins sandbox_mode = read-only

Safety
  ✓ no ANTHROPIC_API_KEY/OPENAI_API_KEY in this shell's environment
  ✓ no hardcoded ANTHROPIC_API_KEY/OPENAI_API_KEY in installed profile configs

doctor: all checks passed.
```

Exit codes: `0` clean, `1` non-blocking issues found, `2` at least one
blocking issue (missing core tool, reviewer not actually read-only, a
credential forwarded into a profile config without
`policies/safety.yaml: allow_explicit_api_key_billing: true`).

The Claude/Codex authentication checks are explicitly labeled
**heuristic** — neither CLI exposes a scriptable "am I on a subscription or
an API key" status command as far as we could confirm, so doctor checks for
the presence of known credential-state files and says so plainly rather
than pretending to know more than it does.

## Running it

```sh
agent                          # workspace = cwd, prompts for a task
agent .                        # same, explicit
agent /path/to/repo            # another project
agent /path/to/repo "task"     # non-interactive
```

If no task is given, `agent` prompts on a terminal or reads one line from
stdin when piped. This is a deliberate reading of the spec, not something
upstream defines: the source instructions describe `agent /path` opening
the harness on a project but don't show a task argument anywhere, so we
picked the interpretation that matches the rest of the spec (a single
automated run producing one final result) rather than an open-ended chat
session — documented here instead of guessed silently.

### What actually happens (P0.7, extended in P1)

0. [`lib/context.sh`](lib/context.sh) builds a small background-context
   block: claude-mem's semantic search (if its worker is up and the task
   is specific enough), a Graphify query against the project's knowledge
   graph (built automatically on first use, local AST only), or — only
   when there's no graph — a few `git grep` snippets seeded from the
   task's own keywords. External research (Jina Reader/search) is added
   only when the task actually looks like it needs it (a URL, "latest
   version", "official docs", etc. — [`lib/research.sh`](lib/research.sh)).
   Every source is independently optional and capped
   ([`policies/context.yaml`](policies/context.yaml)); none of this ever
   blocks the run.
1. The task, wrapped in [`harness/prompts/lead.md`](harness/prompts/lead.md)'s
   instructions (minimal changes, investigate first, no `git commit`/`push`,
   report honestly) plus that background context, goes to the `lead`
   profile. Claude Code implements it with real write/edit/shell access in
   your project's working directory — the context is a head start, not a
   ceiling; current source always wins over anything stale in it.
2. `git status`/`git diff` are collected (including brand-new untracked
   files — plain `git diff HEAD` alone misses those).
3. [`lib/risk.sh`](lib/risk.sh) classifies the change **low / medium /
   high** from changed paths and diff content
   ([`policies/risk.yaml`](policies/risk.yaml)) — no LLM call. A one-line
   auth change stays `high` regardless of diff size. `low` (docs,
   formatting, and similar) skips Codex entirely unless a project override
   forces review; the run ends here for those.
4. The project's own test/lint/typecheck commands run
   ([`lib/validation.sh`](lib/validation.sh) — see below).
5. A **small, independent** review package — objective, risk
   classification, redacted diff, affected file list, validation summary,
   and (only for `high` risk) a compact architecture snippet; never the
   lead's reasoning or conversation — goes to the `reviewer` profile.
6. Codex's answer must be exactly the JSON contract in
   [`policies/review.yaml`](policies/review.yaml); one retry is allowed on a
   malformed response, then it's reported as a failure, not swallowed.
7. `approved`, or `changes_requested` with no critical/high finding, ends
   the run (for `high` risk, ending on "nothing blocking" without the word
   "approved" is logged distinctly, not silently equated with an explicit
   approval). A critical/high finding goes back to the lead as a
   correction task (findings + validation summary only — not the whole
   review conversation), validation re-runs, and review happens again.
8. This repeats up to `max_correction_rounds` (2, in
   [`policies/orchestration.yaml`](policies/orchestration.yaml)). Still
   blocked after that: the run ends with a nonzero exit and says exactly
   what's still wrong. It never reports a blocked run as a success.

`agent` never runs `git commit`, `git push`, a deploy command, or touches
production infrastructure on its own.

## How validation works

[`lib/validation.sh`](lib/validation.sh) detects, in priority order —
test, lint, typecheck, build — without inventing a command the project
doesn't already declare:

- **Node**: `package.json` scripts (`test`, `lint`, `typecheck`, `build`).
  npm's placeholder `"Error: no test specified"` doesn't count as a real
  test. `build` only runs when nothing else validates the change, or when
  explicitly forced — it's usually the slowest signal and often redundant
  with test/typecheck.
- **Python**: `pytest` when a `tests/`/`test/` directory or pytest config
  exists, `ruff check .` when Ruff is configured, `mypy .` when configured.
- **Fallback**: known `Makefile` targets (`test`, `lint`, `typecheck`,
  `build`).

Every command that runs is echoed before execution — a project's own
script is project code, and it's shown, not hidden. The result is
structured as `{ commands, passed, failed, skipped }`
([`lib/json-tools.mjs`](lib/json-tools.mjs) `build-validation-result`) and
that's what both the reviewer package and the correction prompt see.

## Context tools

All three are optional and independently detected — nothing here is
required for the P0 loop to work, and each one's absence just means that
part of the context package stays empty (see `docs/upstream-findings.md`
for the "why bash pipeline, not a skill" decision).

- **Graphify** (code-structure graph): `uv tool install graphifyy` (or
  `pipx install graphifyy`). Nothing else to do — `agent` registers the
  project-scoped skill and builds a code-only graph (local tree-sitter AST,
  no API key, no LLM) automatically the first time it's useful for a given
  project. Queries go through the real `graphify query "<question>" --graph
  graphify-out/graph.json` CLI.
- **claude-mem** (persistent cross-session memory): `npx claude-mem
  install` — a real, heavier dependency (Bun + `uv`, a background worker,
  a global Claude Code plugin), so it's not auto-installed; run it
  yourself when you want memory. Once its worker is up,
  [`lib/memory.sh`](lib/memory.sh) calls its `POST /api/context/semantic`
  endpoint directly (the same relevance gate and progressive-disclosure
  design claude-mem's own MCP tools use — we don't reimplement it, just
  tune the injection volume down via `~/.claude-mem/settings.json`).
- **External research** (web/search/GitHub): works out of the box with
  just `curl` (Jina Reader for page fetch and search — free, no API key)
  and, optionally, the `gh` CLI for GitHub-specific lookups. Only runs when
  [`lib/research.sh`](lib/research.sh)'s `research_needed` heuristic thinks
  the task actually depends on external information (a URL, "latest
  version", "official docs", "changelog", etc.) — never for things the
  repository itself already answers. [Agent-Reach](https://github.com/Panniantong/Agent-Reach)
  is not required; if you want its fuller channel set (YouTube, RSS, and
  more) install it yourself and check `agent-reach doctor` — we deliberately
  do not run its installer automatically (its own recommended install flow
  is "tell an agent to fetch and run a remote install.md," which is a
  choice you should make yourself, not something this script does for you).

Budgets for every source (`max_chars`, `max_results`, etc.) live in
[`policies/context.yaml`](policies/context.yaml).

## Risk classification and adaptive review

[`lib/risk.sh`](lib/risk.sh) classifies every change as `low`, `medium`, or
`high` from [`policies/risk.yaml`](policies/risk.yaml) — changed-path
patterns and diff-content keywords, no LLM call:

- **`low`** — every changed path matches a low-risk pattern (`*.md`,
  `docs/**`, `LICENSE`, ...). Codex is skipped by default.
- **`medium`** — anything else. Normal Codex review.
- **`high`** — a changed path or diff line matches a sensitive pattern
  (auth, secrets, payments, migrations, dependency manifests, Dockerfiles,
  CI workflows, `sudo`/`exec`/`child_process`/destructive SQL, ...).
  Always reviewed; ending the loop on "nothing blocking" without an
  explicit "approved" is logged as a distinct outcome rather than treated
  as equivalent to one.

A high-risk path pattern always wins over "the diff is tiny" — a one-line
change to `src/auth/session.js` is `high`.

## Project overrides

Optional, per project, at `<project>/.agent/config.yaml`. Absent by
default; nothing changes if you never create one.

```yaml
review:
  high_risk_paths:      # additive only — widens `high`, never narrows it
    - "src/auth/**"
    - "prisma/**"
  always_review: true    # force Codex even on an otherwise-skipped low-risk change

research:
  enabled: false          # or memory: / graph: {enabled: false}

validation:
  test: "make unit-test"  # overrides auto-detection for this label
```

Precedence: built-in defaults (`policies/*.yaml`) → this project file. There
is no CLI/runtime override flag yet. See
[`lib/project_config.sh`](lib/project_config.sh).

## Benchmark

Every run prints `run artifacts: <dir>`. Summarize one run's context/review
footprint:

```sh
scripts/benchmark.sh <run_dir>
```

Prints one line of JSON: context package size and composition (memory/
graph/grep-fallback/external present or not), risk tier, reviewer
invocation and correction-round counts, and the final validation summary.
See the honest limitation on what this can and can't measure in
[Known limitations](#known-limitations).

## Operational hardening (P2)

P2's goal: run `agent .` daily and trust it. This section covers what got
added and how to use it. None of it adds an LLM call to a normal run — see
[Token/LLM-call impact](#tokenllm-call-impact-p2) at the end of this
section.

### Project detection and the validation profile (P2.2/P2.3)

At the start of every run the stack builds a small **validation profile**
for the workspace — deterministically, from evidence on disk only (a
manifest or lockfile's presence, never "what's installed on this box" or a
content heuristic):

- **languages** — node/python/make (P0) plus go, rust, php, java, docker, just
- **package manager** — chosen from the project's *own* lockfile
  (`pnpm-lock.yaml` -> pnpm, `yarn.lock` -> yarn, `bun.lock*` -> bun, else npm);
  genuine ambiguity (two lockfiles) warns and falls back to npm. Override
  with `validation.package_manager` in `.agent/config.yaml`.
- **validation commands** — `test` / `lint` / `typecheck` / `build`, already
  prefixed for the resolved package manager (e.g. `pnpm test`, `yarn lint`)
- **frameworks** — only when a single manifest field answers it (next, nuxt)
- **source_files_that_justify_detection** — the exact files that drove each call

It is persisted to `<run-dir>/project-profile.json` (mode 600), cached
project-level for reuse across runs, and its metadata (never file contents)
is recorded as the `project.detected` event. `agent show <run-id>`
surfaces it.

### Run lifecycle and the run journal

Every real task gets a `run_id` (`<UTC timestamp>-<6 hex chars>`, e.g.
`20260826T204512Z-a1b2c3`) and a small state machine:

```
CREATED -> CONTEXT -> IMPLEMENTING -> VALIDATING -> REVIEWING
  -> (CORRECTING -> VALIDATING -> REVIEWING)*  -> COMPLETED
  any non-terminal state -> FAILED | CANCELLED | INTERRUPTED
```

State is persisted durably under an XDG-style state directory — **never
inside your project's own repo**:

```
${XDG_STATE_HOME:-~/.local/state}/agent-stack/
  runs/<project-id>/<run-id>/
    run.json          # schema_version, state, timestamps, git heads, risk...
    events.jsonl       # one structured JSON line per operational event
    task.txt           # the full task text (mode 600) — run.json only
                        # keeps a truncated one-line task_summary
    validation.json, review-N.json, final.json, ...
  locks/<project-id>.lock.d/
```

Override the root with `AGENT_STATE_HOME` (mainly for tests). `run.json`
never contains API keys, tokens, or hidden model reasoning — writing a
field whose name looks credential-shaped is refused outright (see
`lib/json-tools.mjs`). Every write is atomic (temp file + rename), so a
reader never sees a half-written journal.

### Observability: structured events, not chain-of-thought

`events.jsonl` answers "what happened" without ever recording a model's
internal reasoning: `run.created`, `project.detected` (languages, package
manager, framework names, validation-command count — never file contents),
`context.started/completed` (with
character counts and which sources were used — memory/graph/external —
never the content itself), `lead.started/completed/failed`,
`validation.started/completed`, `review.started/completed/failed`,
`correction.started/completed/failed`, `provider.primary_selected`,
`provider.attempt`, `provider.fallback_triggered/skipped`,
`provider.responded`, `run.resumed`,
`run.state_changed`. Every line carries `schema_version` and a timestamp.

```sh
agent logs <run-id>          # human-readable
agent logs <run-id> --json   # raw structured lines
```

### Failure taxonomy (P2.7)

`CONFIGURATION | AUTHENTICATION | QUOTA | RATE_LIMIT |
PROVIDER_UNAVAILABLE | TIMEOUT | CANCELLED | TOOL_FAILURE |
VALIDATION_FAILURE | REVIEW_FAILURE | MALFORMED_OUTPUT |
WORKSPACE_CONFLICT | GIT_CONFLICT | INTERNAL` — classified deterministically
(exit codes, our own timeout/cancel signals, validation/review outcomes)
first; a small curated text-pattern table is the documented last resort for
provider-side categories (auth/quota/rate-limit) that DSH's one-shot
text-in/text-out contract doesn't expose a structured diagnostic for to an
external caller (see `docs/upstream-findings.md`). **No LLM ever classifies
a failure.** A failed run's `final.json` looks like:

```json
{"status":"failed","category":"QUOTA","phase":"review","retryable":false,
 "message":"Codex quota unavailable","run_id":"..."}
```

### Timeouts, retries, cancellation

DSH's own subagent providers document **no wall-clock timeout** as a known
limitation — imposing one is genuinely ours (`policies/runtime.yaml`:
`claude` 900s, `codex` 600s, `timeout_grace_seconds: 10`). We reuse GNU
coreutils `timeout --signal=TERM --kill-after=...` (falling back to an
equivalent bash SIGTERM→grace→SIGKILL loop if it's missing) instead of
writing a process supervisor: `dsh`'s own CLI already wires `SIGTERM` to a
full graceful shutdown that terminates its whole managed subprocess tree
(confirmed in its source — see `docs/upstream-findings.md`), so sending it
SIGTERM is real, tree-scoped cleanup, not a guess.

Retries are rare and specific (`policies/runtime.yaml`: `retry.
transient_max_attempts: 2`, `retry.malformed_review_max_attempts: 1`) —
only `RATE_LIMIT`, `PROVIDER_UNAVAILABLE`, `TIMEOUT`, and one retry of a
malformed reviewer JSON response are auto-retried. After those retries,
the relay fallback allowlist also permits `QUOTA`. Authentication,
validation/review outcomes, configuration, cancellation, policy/security,
and unknown errors never retry or fall back.

If both relay providers fail, `final.json` remains failed and carries the
sanitized `primary_error` and `fallback_error` categories. `events.jsonl`
retains each attempt and `provider.responded` names the provider that actually
answered; no API-key value is journaled. A later call always starts at
DeepSeek again.

```sh
agent cancel <run-id>
```

signals the in-flight call (if any) and marks the run `CANCELLED` — a
raced `0` exit code from the child never overrides this, because the
cancel *request* itself (not the child's exit code) is what
`lib/orchestrate.sh` checks after every call.

### Recovery / resume (P2.10)

**Resume never continues the same internal Claude/Codex session** — every
subagent call is one-shot by design (upstream fact, not a limitation we
introduced). Resume means: read our own journal, check the git HEAD hasn't
moved unaccountably, find the last *safe checkpoint*
(`CONTEXT_READY`/`IMPLEMENTATION_DONE`/`VALIDATION_DONE`/`REVIEW_DONE`/
`CORRECTION_DONE`), and issue a **new, self-contained** one-shot call only
if one is actually needed.

```sh
agent resume <run-id>            # refuses on a git conflict or an uncertain state
agent resume <run-id> --force    # proceed anyway (never runs reset/clean/checkout)
```

| Interrupted during... | Resume does |
|---|---|
| context gathering, or before Claude started | restarts cleanly from implementation |
| Claude was actively editing (mid-`IMPLEMENTING`/`CORRECTING`) | **UNCERTAIN** — refuses without `--force`; nothing was overwritten or guessed |
| validation (implementation finished) | re-runs validation only |
| after validation, before Codex was called | calls the reviewer directly, skips re-validating |
| Codex returned findings, before correction | sends them straight to Claude, skips re-reviewing |

"Uncertain" is detected precisely, not guessed: `events.jsonl` shows
whether that phase's own call logged a `.completed`/`.failed` after its
last `.started` — if not, that call was genuinely interrupted mid-flight.
A moved git HEAD (a commit/checkout/rebase since the run started) is
always reported, never silently overwritten — **no automatic
`reset --hard`, `clean -fd`, or `checkout --` is ever performed**, forced
or not.

### Workspace locking (P2.12)

One `mkdir`-atomic lock per project (keyed by the git repo root, or the
resolved path outside a repo) stops two runs from writing into the same
workspace by accident. A lock records `run_id`, `pid`, `hostname`, and
`created_at`; it's only ever auto-reclaimed when it's provably stale (same
host, dead PID) — a lock from a **different host** is never auto-broken
(can't verify a foreign PID namespace).

```sh
agent status         # shows lock state
agent unlock [/path]  # explicit, human-driven override; always reports what it removed
```

### Enhanced doctor and version drift (P2.14/P2.15)

`agent doctor` gained **Run storage**, **Locks**, and **Versions**
sections — state-directory writability, corrupt-journal detection, stale
locks, and drift between `versions.yaml`'s pins and what's *actually*
resolved inside each DSH profile's own `node_modules` (not a host
`claude`/`codex` CLI on `PATH`, which those two Bundles never use — see
`docs/upstream-findings.md`). Reports `SUPPORTED` / `NEWER_UNTESTED` /
`OLDER_UNSUPPORTED` / `MISSING` — never blocks on drift, never
auto-updates (`policies/runtime.yaml`: `versions.auto_update: false`,
always). Doctor still makes zero LLM calls.

### Operational CLI

```sh
agent status [/path]           # project, active run, lock, provider presence
agent runs [/path]             # run_id / state / risk / timestamps
agent show <run-id>            # sanitized summary (never dumps raw task text)
agent logs <run-id> [--json]
agent resume <run-id> [--force]
agent cancel <run-id>
agent unlock [/path]
agent cleanup [/path]          # apply retention (see below)
```

### Retention (P2.17)

`policies/runtime.yaml`: `runs.retention_days: 30`,
`runs.retention_max_per_project: 100`. `agent cleanup` removes only
**terminal** runs (`COMPLETED`/`FAILED`/`CANCELLED`) past those limits — an
active run or one still `INTERRUPTED` (and therefore resumable) is never
touched, and nothing inside your project's own repo is ever touched either.

### Token/LLM-call impact (P2)

**Zero.** Every mechanism above — the journal, events, failure
classification, timeouts, retries, locking, git-safety checks, doctor,
version drift — is local and deterministic. A normal run makes exactly the
same Claude/Codex calls P1 made; P2 adds reliability around those calls,
not more of them.

## Maintenance and controlled upgrades (P3 / V1)

P3 turns the stack into something you can run for months. Nothing critical
(DeepSeek Harness, Claude Code, Codex, claude-mem, Graphify, Agent-Reach)
ever updates silently. Every `agent update` verb except a deliberate
`benchmark --live` makes **zero LLM calls**; `check`, `plan`, `inventory`,
`backup`, and `release` make **zero changes** to the machine.

### Inventory and compatibility

`compat.yaml` records, per component: the tested version, where it comes
from, whether it is CRITICAL to the Claude/Codex flow, the capabilities the
stack depends on, and known migration/rollback concerns. `versions.yaml`
stays the plain pin list.

```sh
agent inventory            # installed vs tested version + capability status per component
```

Status is `TESTED` / `SUPPORTED` (same major.minor) / `NEWER_UNTESTED` /
`OLDER` / `MISSING`, and — with capability probes — `INCOMPATIBLE` when a
required capability is *verifiably* absent (a probe that simply can't run
without the real component is `unknown`, never a silent pass). Version
tells you risk; a capability probe tells you whether it still works.

### The upgrade cycle

```
agent update check            # what has a newer version (deterministic, no LLM)
      ↓
agent update plan <component>  # exact command, affected configs/skills, risk,
                              # rollback strategy, migration concerns
      ↓
agent update apply <component> [--to <version>] [--yes]
      │   snapshot config  →  stage the candidate in isolation  →
      │   install the EXPLICIT version  →  verify the component  →
      │   verify no P0/P1/P2/P3 regression
      ↓
UPDATE_SUCCESS                         (snapshot kept for rollback)
   or UPDATE_FAILED_ROLLBACK_AVAILABLE:<snap>
   or UPDATE_FAILED_ROLLBACK_PARTIAL:<snap>   (an irreversible data migration ran)
      ↓
agent update rollback [<snapshot-id>]  # restore config + reinstall pinned versions + verify
```

Risk is **deterministic**, not model-judged: any dsh / Claude / Codex
update is HIGH; a claude-mem major is HIGH (possible irreversible storage
migration); Graphify/Agent-Reach minors are MEDIUM; an unparseable version
jump is HIGH; a candidate that can't be verified in isolation escalates one
tier. `agent update apply` refuses to run non-interactively without
`--yes`, refuses system components (upgrade Node/git via the OS), and — for
a CRITICAL component — **stops the chain** rather than continuing blindly if
verification fails.

### Snapshots, rollback, and secrets

A snapshot captures only configuration — this repo's `policies/` +
manifests, the DSH profile *config* (never `node_modules`), non-secret
claude-mem settings, skill files, and a version inventory. A file that
holds a secret is recorded as a path + sha256 in `secrets-manifest.jsonl`,
never copied. Rollback restores config and reinstalls the recorded
versions, but **never overwrites a file that currently holds a secret** and
is honest when it can't be complete: `ROLLBACK_PARTIAL` when a reinstall
fails, verification fails, or the forward update was an irreversible
migration.

### Benchmarks and regression detection

```sh
agent benchmark --offline          # 8 fixtures (categories A-H), deterministic, ZERO quota
agent benchmark --live             # runs each fixture through real Claude/Codex (explicit opt-in)
agent benchmark compare <a> <b>    # flags regressions between two result files
```

Offline mode checks the parts the stack itself owns — risk classification,
review routing, context-tool routing, and a config-driven context-budget
footprint — against each fixture's expected characteristics. `compare`
(thresholds in `policies/benchmark.yaml`) fails on: a fixture the baseline
passed but the candidate doesn't, HIGH risk routed to skip review, an
expected-LLM-call increase over the threshold, or a context-budget blow-up.
A candidate that *shrinks* context is reported as an improvement.

### Optimization profiles

```sh
agent --profile economy  "task"    # smaller budgets, no auto web research, MEDIUM review per policy
agent --profile balanced "task"    # default — the P1 calibration
agent --profile strict   "task"    # bigger budgets, MEDIUM always reviewed + verified
```

`.agent/config.yaml` can set a project default (`profile: strict`); an
explicit `--profile` overrides it. **No profile ever weakens a HIGH-risk
security review** — economy and strict both always send HIGH to Codex with
verification.

### Backup, release manifest, reproducible install

```sh
agent backup [--out <path>]         # portable stack-config archive (no secrets, no projects)
agent restore <archive> [--yes]     # validate → show → preserve current secrets → restore → doctor
agent release create <version>      # snapshot the whole stack into releases/<version>.yaml
agent release verify [<version>]    # does THIS machine match that known-good combination?
```

A release manifest records every component version, the host runtimes it
was tested on, the capability verdicts, and the benchmark outcome (it never
fabricates a live-benchmark result). On a fresh VPS:

```sh
git clone <repo> && cd veramux
scripts/install.sh --release 1.0.0   # pins dsh to the manifest's version;
                                     # configure.sh + the printed steps handle the rest
# authenticate Claude Code and Codex (see "Authentication" above)
agent doctor
agent release verify 1.0.0           # RELEASE_VERIFIED or RELEASE_MISMATCH with the exact drift
```

`--release` currently overrides only the `dsh` pin from the manifest; the
subagent bundles follow `versions.yaml` and claude-mem / Graphify /
Agent-Reach are installed through their own channels as the installer
instructs. `agent release verify` is what actually confirms the whole
machine matches — it compares every component version, the critical
capability verdicts, and the offline benchmark, and names any mismatch.

### claude-mem cost experiment (P3.15 — opt-in)

`agent memexp report` records the current claude-mem compressor config
(secrets redacted) and lays out cheaper directions to evaluate with a fixed
10-fact / 10-query recall A/B (`agent memexp compare`). It **never** edits
`~/.claude-mem/settings.json`, enables a gateway, or buys API access —
switching providers stays a manual decision.

## Security

- **Codex is read-only at the mechanism level, not just by prompt.** The
  `reviewer` DSH profile disables every native write/edit/shell tool row
  from `dsh-base` (`tool-fs`, `tool-bash`, `tool-str-replace-editor`, ...),
  so even the profile's own driving model has nothing to write with. The
  actual Codex child process runs under a dedicated `CODEX_HOME` whose
  `config.toml` pins `sandbox_mode = "read-only"`, so Codex's own native
  tool use is refused by its own sandbox regardless of the prompt. Verified
  by [`tests/unit/test_reviewer_readonly.sh`](tests/unit/test_reviewer_readonly.sh)
  and by `agent doctor`.
- **API-key billing detection, not just a warning.** DSH's Claude Code and
  Codex subagent providers strip credential-shaped environment variables
  from the child process before it starts — an ambient `ANTHROPIC_API_KEY`
  or `OPENAI_API_KEY` does **not** reach either subagent unless a
  `cordis.patch.yml` explicitly forwards it. Our profiles never do that.
  `agent doctor` scans every installed profile config for exactly this
  pattern and fails loudly (`policies/safety.yaml: allow_explicit_api_key_billing`
  must be flipped to `true` deliberately to accept it), and separately warns
  if `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` are set in your shell (a softer,
  informational risk — it affects a host CLI run outside this stack, not
  the subagents themselves). No secret value is ever printed.
- **DeepSeek is the relay primary; OpenAI is an optional paid fallback.**
  OpenAI is never selected merely because an unknown/local error occurred.
  The dedicated relay keys are not interchangeable, and the Codex child keeps
  using its own `CODEX_HOME`/`codex login` authentication. Child
  Claude/Codex tokens never enter the relay model's own context.
- **Secrets never reach the reviewer.** [`lib/redact.sh`](lib/redact.sh)
  strips the diff content of any path matching
  [`policies/safety.yaml: ignore_patterns`](policies/safety.yaml) (`.env`,
  `*.pem`, `*.key`, `credentials*`, `secrets*`, `id_rsa`, `.ssh/*`, ...)
  before it's ever put in a prompt — the filename is still visible so Codex
  knows something changed, the content isn't. This does not depend on
  `.gitignore`.
- **No destructive commands, ever, on our own initiative.**
  `git push`/`--force`, `git reset --hard`, `npm publish`, etc. are listed
  in `policies/safety.yaml: forbidden_commands` and the lead prompt
  explicitly forbids `git commit`/`git push`/deploy commands.
- **Context tools never see the reviewer's secrets, and vice versa.**
  Memory/graph/research context goes to the *lead* only, built before any
  diff exists; the reviewer gets the (already redacted) diff and, only for
  `high` risk, a small architecture snippet — never raw memory, raw
  research output, or the lead's session. claude-mem is a real external
  system (a local worker + a cloud-sync option it owns) — it captures tool
  usage from Claude Code sessions in general, so treat `<private>` tags
  (its own opt-out mechanism, see its docs) as the way to keep something
  out of it, the same way you'd treat any other local dev tool with a
  persistence layer. External research never sends local file contents
  anywhere — it only fetches public URLs/search results.

## Troubleshooting

- **`dsh not found`** — run `./scripts/install.sh`, or
  `npm install -g @deepseek-ai/dsh@<version from versions.yaml>` yourself.
- **`lead profile missing` / `reviewer profile missing`** — run
  `./scripts/configure.sh`.
- **doctor says a profile config forwards a credential** — you (or a patch
  you applied) put `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` into a subagent
  provider's `env:` block. Remove it, or set
  `allow_explicit_api_key_billing: true` in `policies/safety.yaml` if that
  was genuinely intentional.
- **the reviewer call fails immediately** — usually `codex login` hasn't
  been run, or was run after `scripts/configure.sh` (re-run
  `scripts/configure.sh` to re-link `~/.codex/auth.json`).
- **`not a git repository`** — `agent` needs git to collect a diff to
  validate and review; initialize the target repo first.
- **a review comes back `blocked`** — that's the loop working as intended:
  a critical/high finding survived `max_correction_rounds`. Read the
  finding, fix it yourself or hand `agent` a follow-up task.
- **reviewer JSON keeps failing validation** — check
  `policies/review.yaml` and `harness/prompts/reviewer.md` are still in
  sync with `lib/json-tools.mjs`'s `validate-review`; the schema comment in
  `policies/review.yaml` is documentation only, the code is authoritative.
- **a change that should skip review doesn't** — check `agent`'s "risk
  classification:" line. If it says `medium`/`high` for something you
  expected `low`, a changed path matched `policies/risk.yaml` (or a
  project `.agent/config.yaml` override) — that's usually working as
  intended (a one-line auth change is deliberately never `low`).
- **no context shows up in the lead's task** — `agent doctor` reports
  Graphify/claude-mem presence and worker health under "Context (P1)"; a
  missing tool or a down worker means that section is legitimately empty,
  not a bug. Both are optional.
- **external research never fires** — check the task actually matches
  `research_needed`'s heuristic (a URL, "latest version", "official docs",
  etc.); it's deliberately conservative so the repo's own contents are
  preferred over a network call.
- **`another run is already active in this workspace`** — check
  `agent status`; if the reported PID/host is dead, the next `agent`/
  `agent resume` auto-reclaims it (same host only). To force it now, run
  `agent unlock [/path]`.
- **a run seems stuck / a VPS rebooted mid-run** — `agent status` and
  `agent show <run-id>` tell you the last safe checkpoint; `agent resume
  <run-id>` continues from there (`--force` only for an UNCERTAIN state or
  a moved git HEAD you've verified is fine — never runs `reset --hard`/
  `clean -fd`/`checkout --`).
- **doctor reports NEWER_UNTESTED/OLDER_UNSUPPORTED under "Versions"** —
  the Claude Agent SDK or Codex wrapper actually bundled in a profile's
  `node_modules` differs from `versions.yaml`'s pin. This never blocks a
  run by itself; re-run the discovery steps in `docs/upstream-findings.md`
  before trusting the new combination for anything sensitive.
- **old runs piling up** — `agent cleanup [/path]` applies
  `policies/runtime.yaml`'s `runs.retention_days`/`retention_max_per_project`;
  active/interrupted runs are never removed by it.

## Compatible versions

See [`versions.yaml`](versions.yaml) — DeepSeek Harness `0.1.1-rc.2`, Claude
Agent SDK `0.3.220` / Claude Code `2.1.220` (via the official bundle), Codex
wrapper `0.147.0` (via the official bundle), Node `>= 22.19.0`, pnpm
`11.7.0`, Graphify (`graphifyy` on PyPI) `0.9.50`, claude-mem `13.16.1`,
Agent-Reach `1.5.0` (reference only — not required, see
[Context tools](#context-tools)). DSH and the three P1 tools are all fast-
moving; re-run the discovery steps in `docs/upstream-findings.md` before
bumping any of these. `policies/runtime.yaml` holds the P2 operational
numbers (timeouts, retry attempts, retention, `versions.auto_update:
false`) — see [Operational hardening (P2)](#operational-hardening-p2).

## Known limitations

- The task text is passed as a CLI argument to `dsh --profile ... "task"`;
  an extremely large diff plus prompt could theoretically hit the OS
  argv-length limit. Not observed in practice for typical changes.
- Claude/Codex authentication checks in `agent doctor` are heuristics
  (presence of known credential-state files), not a definitive
  subscription-vs-API-key confirmation — neither CLI exposes one that we
  could find.
- One subagent call is one fresh, isolated, one-shot exchange (an upstream
  DSH limitation, not ours) — no incremental/streaming feedback from Claude
  or Codex mid-call.
- Tested primarily against Node and Python projects, with a `Makefile`
  fallback; no other ecosystem is detected.
- `dsh` itself is a developer preview; expect breaking changes upstream
  between releases.
- **The benchmark ([`scripts/benchmark.sh`](scripts/benchmark.sh)) cannot
  report literal "files Claude read" or token counts inside its session** —
  DSH's subagent contract never exposes a child's tool-call trace to the
  parent. It reports what the orchestrator actually controls: context
  package composition/size, risk tier, and reviewer/correction round
  counts. That's enough to show the P0-vs-P1 shape of the change, not a
  precise token-accounting tool.
- claude-mem's `SessionStart` auto-injection fires on every `lead`
  invocation (each is a fresh DSH subagent session) — there's no
  documented per-call opt-out short of disabling the plugin entirely, so
  "skip memory for a trivial task" is handled by keeping the injected
  volume small (`policies/context.yaml`), not by suppressing it
  conditionally.
- No "budget escalation" beyond one context package per run: if it isn't
  enough, Claude Code's own unrestricted native tools (it always has full
  read/write access regardless of what we pre-inject) are the real
  fallback, not a second orchestrator-driven re-fetch round.
- `.agent/config.yaml` has no schema validation yet — a malformed override
  is silently ignored for the keys it doesn't match rather than rejected.
- **Failure classification for provider-side categories (auth/quota/
  rate-limit/provider-unavailable) is best-effort text-pattern matching**
  on the `dsh` process's own stdout/stderr, not a structured diagnostic —
  DSH's driving model relays a subagent tool's error as its own final
  text rather than exposing the subagent's own diagnostic fields to an
  external caller (see `docs/upstream-findings.md` P2 section). Exit
  codes, our own timeout/cancel signals, and validation/review outcomes
  are fully deterministic; this subset is honestly heuristic. Because this
  classification gates relay fallback, its allowlist is closed: an
  unrecognized error becomes `INTERNAL` and does not switch providers.
- **"Uncertain" resume can't distinguish "Claude finished writing but the
  process died before logging completion" from "Claude was still
  writing"** — both look identical from outside (no completion event
  logged), so both are conservatively treated as uncertain rather than
  risking a false "safe to continue".
- Workspace locking is local-machine only (an `mkdir`-atomic lock, no
  distributed coordination) — by design, for a single-VPS personal stack.
- Resume never performs `git reset --hard`, `git clean -fd`, or
  `git checkout --`, even with `--force` — a git conflict or an uncertain
  state it can't resolve safely is reported, not auto-fixed.

## Future scope (post-V1)

Now covered by P3: controlled component upgrades, rollback, quality/cost benchmarks, optimization profiles, backup/restore, and a reproducible release manifest.

Still explicitly deferred: a dashboard, multi-user/SaaS support, Kubernetes, a
remote database, a custom UI, a generic plugin/provider system, a required
local model, a custom embeddings/vector-DB stack, budget-escalation rounds
beyond one context package per run, `.agent/config.yaml` schema
validation, a mandatory remote tracing platform, third-party telemetry, a
distributed job queue/scheduler, and an optional git-worktree isolation
mode (investigated in P2 discovery, not built — the default remains
operating directly in the given workspace).
