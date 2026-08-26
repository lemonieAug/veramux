# Upstream Findings: DeepSeek Harness, Claude Code, Codex

Discovery phase for the P0 milestone. DeepSeek Harness ("DSH") is real and very
recent (developer preview, first tag `dsh-v0.1.1-rc.2`, commit from
2026-08-21). It postdates the assistant's training data, so this document is
based on directly inspecting the cloned upstream repository
(`github.com/deepseek-ai/deepseek-harness`, commit `b150a551`), not on prior
knowledge. Re-verify against the actually installed version before relying on
any of this — see `versions.yaml`.

## What DSH actually is

An open-source, plugin-based agent harness ("everything is a plugin"), built
on a framework called Cordis. The CLI binary is `dsh`. It ships a Web UI
(`dsh web`, `http://127.0.0.1:3080`) and a **headless CLI mode**
(`dsh --profile headless "task"`) that runs one fresh session, prints the
final assistant text to stdout, and exits 0/1 based on completion. There is no
separate "orchestrator mode" flag — every `dsh` session is driven by a
configured chat-completions model (a "brain") that reasons and calls tools;
DeepSeek is the natively wired default (`DEEPSEEK_API_KEY`), but any
OpenAI-compatible endpoint can be configured.

Node `^22.19.0 || >=24.0.0`, package manager `pnpm@11.7.0` (from `package.json`).

## Claude Code and Codex are official, opt-in "subagent" Bundles

Confirmed at `packages/subagent/subagent-claude-code` and
`packages/subagent/subagent-codex`, and documented in
`.agents/notes/implemented/simplification/2026-08-12-production-dsh-excludes-product-subagent-providers.md`.

- **Not installed by default.** `@deepseek-ai/dsh-base` deliberately excludes
  both. Each is a separate installable "Profile Bundle":
  ```sh
  dsh plugin --profile <name> add @deepseek-ai/dsh-subagent-claude-code
  dsh plugin --profile <name> add @deepseek-ai/dsh-subagent-codex
  ```
  Installing brings in the pinned product runtime (Claude: official
  `@anthropic-ai/claude-agent-sdk@0.3.220`, which selects its own bundled
  Claude Code 2.1.220 CLI platform payload; Codex: official
  `@openai/codex@0.147.0` wrapper + native platform payload). Restart the
  profile after installing.
- **Each call is one fresh, isolated, one-shot text-in/text-out run.** No
  session continuation, no shared context with the parent. The child's `cwd`
  is the parent DSH session's cwd. Child tokens never enter the parent's
  context — this is exactly the "independent, small-context reviewer" shape
  P0.6/P0.7 need, for free.
- **No tool filtering, no output-schema enforcement at the DSH layer for
  these two providers** ("Known Limitations" in both READMEs). Whatever
  structure we want out of Codex's review, we must ask for in the prompt and
  parse ourselves — DSH will not validate it for us. This confirms the
  spec's fallback plan (small custom JSON parser with one retry) is
  necessary, not optional.
- **Real read/write/edit tool access for the *child* process comes from the
  product itself** (Claude Code's own native tools, Codex's own native
  tools), not from anything DSH grants. DSH does not hand Claude/Codex a
  curated tool catalog.

### Authentication and billing risk (critical for P0.10/P0.11)

- Both providers **omit any DSH-side settings override** and let the product
  read its own native, already-authenticated state (Claude: normal user/
  project/local Claude settings including native account state; Codex:
  native `CODEX_HOME`/config, i.e. whatever `codex login` set up). Neither
  provider logs in, creates an account, or rewrites settings.
- Both providers **scrub credential-shaped ambient environment variables**
  before spawning the child process. An `ANTHROPIC_API_KEY` or
  `OPENAI_API_KEY` sitting in the shell that runs `dsh` is **not** passed
  through automatically — it only reaches the child if **we** put it in the
  provider's own `env:` config block in our `cordis.patch.yml`. This is the
  actual control point for the "don't silently bill the API key" requirement:
  our profile configs must never set `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` in
  a subagent provider's `env`, and `doctor` should treat that config
  pattern, if found, as a hard failure requiring deliberate confirmation.
  Ambient env vars are a separate, softer risk (they can affect a host
  `claude`/`codex` CLI run outside `dsh`, or get pasted into config later) —
  worth a warning, not a silent block.
- Claude Code's permission modes (`dontAsk` default, `acceptEdits`, `auto`,
  `plan`, `bypassPermissions`) and Codex's (`never` default, `approve-for-me`,
  `dangerously-bypass-approvals-and-sandbox`) are the only per-call policy
  knobs. Everything else (model, tools, sandbox, account) is native/host
  config.

### Consequence for "Codex must be read-only, enforced not just prompted"

DSH has no tool-filtering hook for subagent providers, so read-only
enforcement has to happen at the **product** layer, the way the spec's
"defense in depth" principle demands:
- Give the Codex reviewer provider its own `CODEX_HOME` (via the provider's
  `env` override) pointing at a dedicated config directory whose
  `config.toml` pins `sandbox_mode = "read-only"` (or equivalent read-only
  sandbox setting). Combine with DSH's own `permissionMode: never` (no
  approval prompts, so a write attempt fails closed instead of hanging).
- This is real enforcement (Codex's own sandbox refuses writes), backed by
  the reviewer prompt telling it not to try. Prompt alone is not sufficient
  per the spec, and this now matches the actual mechanism available.
- Claude Code has no equivalent role here in P0 (it is only ever the lead).

## Configuration model

- **Home**: `$DSH_HOME`, default `~/.dsh` (confirmed in
  `packages/util/home-paths/src/index.ts`). Holds `settings.yaml`,
  `.credentials.yaml` (write-only secret store, never exported to
  `process.env`), `.env`, `profiles/<name>/`, and a home-level
  `cordis.patch.yml` that applies to every profile.
- **Profile** = `$DSH_HOME/profiles/<name>/{package.json, cordis.patch.yml}`.
  `package.json` carries `dsh.profile.bundles` (ordered list of bundle
  package names) plus pnpm-managed `node_modules` for out-of-tree bundles.
  `cordis.patch.yml` is the profile's own patch layer (add/replace rows).
  Layer order (later wins per row): bundles in order → profile
  `cordis.patch.yml` → home `cordis.patch.yml` → `--patch` CLI overlays.
- Two profiles ship as templates and auto-init on first use: `web` (base +
  web-app) and `headless` (base + headless). Any other profile name — e.g.
  ours — must be created explicitly via `dsh plugin --profile <name> add ...`.
- `dsh --profile <name> --dump-config` / `--dump-default-config` print the
  fully composed Cordis tree without booting — this is our primary `doctor`
  introspection tool, far better than re-parsing YAML ourselves.
- Model/provider config: `$DSH_HOME/settings.yaml` (+ `.credentials.yaml` for
  secrets, or ordinary env vars / `.env` files as a lower-precedence layer).
  DeepSeek's own adapter reads `DEEPSEEK_API_KEY` directly. Anthropic/OpenAI
  can *also* be wired as ordinary top-level chat model providers through
  Settings → Models — **we must not do this for Claude/Codex**; that path is
  plain pay-per-token API billing with no relationship to the Claude Code /
  Codex Bundles or their subscription auth. Anywhere our docs mention
  "configure the model," it means DeepSeek (or another cheap/local
  OpenAI-compatible endpoint), never Anthropic/OpenAI directly.
- **Code Mode**: not a YAML key — it's the env var `DSH_TOOLS_MODE`, one of
  `native | code | both`, read at process start. Applies to the orchestrating
  session's own tool-calling style; irrelevant to the Claude/Codex subagent
  children (which always use their own product's native tools internally).
  We'll leave it at the default (`native`) for P0; nothing in the spec's P0
  scope needs Code Mode, and turning it on adds a moving part with no payoff
  yet.
- `DSH_PERMISSION_MODE` overrides the process-level fallback permission
  preset (default new-session preset is `workspace-write`: bash/fs mutation
  confined to the session workspace + temp dirs, reads/network unconfined).

## Revised orchestration design (deviation from a literal reading, flagged for confirmation)

The spec frames DSH as running one continuous "orchestrator" conversation
that itself calls Claude then Codex as tools and enforces the loop rules
(max 2 correction rounds, structured review contract, skip-review
heuristics, secret filtering). Having now seen how the pieces actually fit
together, doing *all* of that inside one DSH model-driven session is
possible but fragile: those are hard, deterministic rules, and enforcing
"stop after exactly 2 rounds" or "never forward a raw diff with a `.env`
in it" by hoping a chat model's tool-calling obeys a system prompt is
exactly the kind of thing principle #7 (simple, explicit, easy to maintain)
and the "não mascare falha como sucesso" requirement argue against.

**Proposed split** (still 100% on official DSH mechanisms for the parts that
matter):

- DSH still *is* the mechanism that reaches Claude Code and Codex — each
  one-shot call goes through `dsh --profile lead "..."` /
  `dsh --profile reviewer "..."`, using the official subagent Bundles,
  native auth, native permission modes, and DSH's own process/credential
  handling. We are not writing a Claude/Codex wrapper of our own.
- Each of those two profiles is configured with a **minimal system prompt
  and exactly one tool** (`subagent_claude_code` or `subagent_codex`), so the
  profile's own driving model (DeepSeek, cheap) has a trivial job: call that
  one tool with the given text and return its answer verbatim. This keeps
  DSH's role real (it is still doing the credentialed process orchestration,
  sandboxing, and product invocation) while not asking a model to be the
  enforcer of hard round-limits or JSON-schema validity.
- The deterministic parts the spec is strict about — collecting `git
  status`/`git diff`, running the validation runner, building the
  independent review package, redacting secrets, parsing/validating Codex's
  JSON contract, counting correction rounds, deciding when review is
  skippable — live in our own `bin/agent` + `lib/*.sh`, which shells out to
  `dsh --profile lead|reviewer "..."` for the two model calls and does
  everything else itself.

This is a genuine design choice, not a discovered fact, so it's called out
explicitly rather than silently baked in. If you'd rather have a single
long-lived DSH session own the whole loop via its own tool-calling (closer
to a literal reading of the spec's diagram), that's also buildable on the
same Bundles — it would just move the round-limit/contract-validation logic
into that session's system prompt plus a small enforcement tool instead of
into bash, and would be harder to unit test deterministically (P0.14 wants
things like "limite de correction rounds" and "JSON inválido do reviewer" to
be testable without burning LLM quota).

## What we will NOT build (already provided upstream)

- Claude Code process management, credential handling, permission prompting,
  platform CLI selection → `@deepseek-ai/dsh-subagent-claude-code`.
- Codex process management, JSON-RPC/app-server protocol, credential
  handling, permission mapping → `@deepseek-ai/dsh-subagent-codex`.
- Profile/plugin lifecycle, config layering, hot reload → `dsh plugin`,
  `cordis.patch.yml` layering.
- Config introspection → `dsh --profile <name> --dump-config`.
- Headless one-shot execution, exit-code semantics → `dsh --profile headless`.
- Secret storage for our own orchestrator model key → `$DSH_HOME/.credentials.yaml`.

## What we still have to build ourselves

- `bin/agent` CLI (path resolution, `doctor`, `--help`/`--version`).
- The deterministic Claude→validate→Codex→correct loop and its round limit.
- The validation command runner (Node/Python/Makefile detection).
- The review JSON contract parser/validator (one retry on invalid JSON).
- Secret/sensitive-file redaction for anything sent into the reviewer prompt.
- `doctor` checks (tool presence, auth heuristics, billing-risk detection,
  profile/bundle presence, project ecosystem detection).
- Two DSH profiles (`lead`, `reviewer`) plus their `cordis.patch.yml` and
  system prompts.

## P1 discovery: Graphify, claude-mem, Agent-Reach

Same method as P0: cloned the actual upstream repos and read their real
READMEs/docs rather than trusting a search summary (one search result for
Agent-Reach's install method was simply wrong — see below). All three are
real, active, single-maintainer-adjacent OSS projects, not community forks.

| Project | Repo | Version/commit inspected |
|---|---|---|
| Graphify | `Graphify-Labs/graphify` (PyPI: `graphifyy`, double-y) | `0.9.50`, commit `43d54ac`, 2026-08-25 |
| claude-mem | `thedotmack/claude-mem` | `13.16.1`, commit `866a0ca`, 2026-08-26 |
| Agent-Reach | `Panniantong/Agent-Reach` | `1.5.0`, commit `06c202b`, 2026-08-25 |

### The one finding that reshapes the whole P1 design

**All three are designed to be installed as skills/plugins that Claude Code
itself uses autonomously inside its own session — not services an external
orchestrator calls to pre-build a context bundle.**

- **Graphify**: `graphify install [--project]` writes a `SKILL.md` (e.g.
  `.claude/skills/graphify/SKILL.md`) plus, via `graphify claude install`, a
  `CLAUDE.md` section and a `PreToolUse` hook that nudges (or, in `--strict`
  mode, blocks) Claude's *own* first raw file read toward `graphify query`
  first. Claude decides when to consult the graph; we don't pre-compute
  that decision in bash.
- **claude-mem**: `npx claude-mem install` registers a Claude Code plugin —
  5 lifecycle hooks (`SessionStart`, `UserPromptSubmit`, `PreToolUse` on
  `Read`, `PostToolUse`, `Stop`) plus an MCP server exposing exactly the
  3-layer `search` → `timeline` → `get_observations` progressive-disclosure
  workflow the spec asks for — **already implemented upstream**, not
  something to rebuild. It auto-injects a capped set of recent observations
  at `SessionStart` and lets Claude call the MCP tools for anything deeper,
  autonomously.
- **Agent-Reach**: explicitly describes itself as "a capability layer, not
  another tool... it doesn't do the reading itself. Reading is the agent
  calling the upstream tool directly, no wrapper." Installation writes a
  `SKILL.md`; from then on Claude decides for itself when a task needs
  `curl`/`yt-dlp`/`gh`/etc., guided by that skill file.

Given P0's own established pattern — the lead's Claude Code subagent runs a
**real Claude Code CLI session with native settings authoritative** (no
`settingSources` override, per the Claude Code subagent provider) — a skill
or plugin installed globally or project-locally for Claude Code is picked
up automatically by every `lead` invocation, with zero orchestrator-side
plumbing. This is consistent with, not a workaround of, the P0 architecture.

**Consequence:** P1.5/P1.6/P1.7 ("Context router", "Context package",
budgets) as literally specified — a bash-assembled
`{task, memory, architecture, code, external}` JSON bundle — would
duplicate functionality these tools already provide natively, and would
require our orchestrator to somehow read Claude's mind about what it needs
before it even starts, which none of these tools' own interfaces support
(Graphify's MCP/CLI query surface and claude-mem's MCP tools are built to
be called *from inside* an agent session, not polled by an external
script). Reimplementing that pipeline ourselves would be exactly the kind
of 500-line framework the spec's own "regra contra overengineering"
warns against.

**Proposed split** (mirrors the P0 lead/orchestrator split): install the
three tools as Claude Code skills/plugins available to the `lead` session;
update `harness/prompts/lead.md` to state the preference order (memory →
graph → LSP/rg → direct read → external) as *guidance*, since Claude
already decides autonomously once the skills exist; tune each tool's own
native config to the spec's conservative numbers instead of inventing a
parallel budget system. What stays genuinely ours, because it's
deterministic control flow DSH/Claude/these tools don't provide and
P0 already established this pattern for: **risk classification and
adaptive Codex review depth** (P1.9/P1.10 — extends `lib/orchestrate.sh`'s
existing skip-review logic), **project-level overrides** (P1.12 — a small
YAML we parse ourselves, same style as `policies/*.yaml`), and the
**extended `agent doctor`** (P1.13).

This was flagged for confirmation the same way the P0 loop-ownership
question was, before building 17 sub-phases on top of it. **Decision:**
the person running this stack chose the literal reading of the spec
instead — build the bash-driven context pipeline (`lib/context.sh`,
`lib/graph.sh`, `lib/memory.sh`, `lib/research.sh`) that calls Graphify's
CLI, claude-mem's worker HTTP API, and Jina Reader/`gh` directly and
assembles the context package before the lead ever runs, rather than
relying on Claude's own autonomous skill use. This was practical because,
unlike a hypothetical case where an upstream tool had no externally
callable interface at all, both Graphify (`graphify query/explain/path`
against `graphify-out/graph.json`) and claude-mem (`POST /api/context/
semantic` on its worker) do have real, stable, bash-callable interfaces —
see their subsections below for the exact commands/endpoints. Graphify's
project skill is *also* still registered (`graphify install --project`),
so Claude retains autonomous access to it as a bonus; claude-mem and
Agent-Reach get no plugin/skill installation from us at all — we only call
what's already running (memory) or the same low-level tools Agent-Reach
itself would select (research). Risk classification, adaptive review, and
project overrides are unaffected by this choice — they were always ours.

### Graphify — what we'll actually use

- Install: `uv tool install graphifyy` (needs `uv` or `pipx`; Python
  3.10+). CLI command is `graphify` (note the package name has a double
  `y`, the CLI doesn't).
- Register the skill **per target project** (not globally, and not in this
  `veramux` repo): `graphify install --project` writes
  `.claude/skills/graphify/SKILL.md` under the *target* project. Making it
  always-on (nudge, not block) is a separate step:
  `graphify claude install --project` (writes a `CLAUDE.md` section +
  `PreToolUse` hook; soft nudge by default, `--strict` available but we
  will not enable strict mode in P1 — the spec explicitly says "não
  bloqueie completamente raw reads").
- Graph build is triggered by the skill itself (`/graphify .` inside a
  Claude session) or headlessly: `graphify extract . --code-only` — this
  variant needs **no API key at all** (tree-sitter AST only, fully local),
  which is why we can safely pre-build the graph ourselves in bash on
  first use ("gerar na primeira necessidade") without asking the user for
  any credential. A full extraction (docs/PDFs/images) needs a model and,
  run via the skill inside Claude's own session, uses Claude's own
  subscription — no separate key needed there either.
- Lifecycle: `graphify hook install` sets up git `post-commit`/
  `post-checkout` hooks that re-run **AST-only** extraction automatically
  (no LLM, no cost) and a merge driver so `graph.json` never gets conflict
  markers. This already satisfies "não regenere tudo a cada mensagem" —
  we don't need our own staleness heuristic.
- Real commands confirmed: `graphify query "<question>"`,
  `graphify path A B`, `graphify explain "<node>"` — exactly the spec's
  desired interface, not invented.
- Output lives in `graphify-out/` inside the *target* project; we'll tell
  users to gitignore `graphify-out/cost.json` (per upstream's own
  recommendation) and add `graph.json`/`graphify-out/` to `.claudeignore`
  if prompt-cache churn becomes a problem (documented upstream footgun).
- No vector DB, no separate embeddings — confirmed local-first, tree-sitter
  AST only for code (matches "priorize funcionamento local/determinístico
  via AST").

### claude-mem — what we'll actually use

- Install: `npx claude-mem install` (interactive: prompts for provider/
  model choice) — a **global** Claude Code plugin install (`~/.claude/
  plugins/marketplaces/thedotmack/`), not per-project. Needs Node ≥ 20.12,
  Bun ≥ 1.0 (auto-installed by the installer if missing), and `uv` for the
  Python-based Chroma vector search component. This is a real, nontrivial
  new dependency footprint beyond P0's Node/pnpm — documented as an
  explicit, opt-in install step, not silently bundled into
  `scripts/install.sh`.
- **Billing default is already correct for our stack**:
  `CLAUDE_MEM_CLAUDE_AUTH_METHOD` defaults to `subscription` (Claude Agent
  SDK path, same subscription auth as everything else in this repo);
  `api-key`/`gateway` are opt-in alternatives a user would have to choose
  explicitly. Default compression model is `claude-haiku-4-5-20251001`
  (cheap). Nothing to change here beyond confirming the default holds.
- Config lives in `~/.claude-mem/settings.json` (auto-created). The spec's
  conservative numbers map onto real settings, not invented ones:
  - `CLAUDE_MEM_CONTEXT_OBSERVATIONS` (default `50`) → we'll set a lower
    value close to the spec's "search_results/full budget" intent.
  - `CLAUDE_MEM_CONTEXT_SESSION_COUNT` (default `10`) → spec wants `5`.
  - `CLAUDE_MEM_CONTEXT_FULL_COUNT` (default `5`) → spec's
    "full_observations: 2" maps directly onto this.
  - `CLAUDE_MEM_CONTEXT_SHOW_LAST_SUMMARY` / `..._SHOW_LAST_MESSAGE`
    (default `false`/`false`) → spec's "desabilite... última mensagem;
    grandes summaries" is **already the shipped default**, nothing to do.
  - `CLAUDE_MEM_SKIP_TOOLS` already excludes noisy/trivial tool calls from
    ever becoming observations by default.
- The 3-layer `search`/`timeline`/`get_observations` MCP tool workflow
  *is* the spec's "progressive disclosure" requirement, already built —
  each `search` result costs ~50-100 tokens, full detail only for
  filtered IDs (~500-1000 tokens each), ~10x savings claimed by upstream.
  We are not re-implementing this; we are only tuning its injection
  volume down from the shipped (generous) defaults.
- One real architectural question we could not resolve from docs alone:
  since every `lead` invocation is a **fresh** DSH subagent session (P0),
  `SessionStart` fires on every single task, so the capped auto-injection
  happens every time regardless of task triviality — the spec's "memória
  pode ser ignorada quando task trivial" isn't a lever claude-mem exposes
  directly. Mitigation is keeping the injected volume small (the settings
  above) rather than trying to suppress injection conditionally, since
  there is no documented per-call opt-out short of disabling the plugin
  entirely.

### Agent-Reach — what we'll actually use

- **Correction to an earlier web-search summary**: one search result
  claimed `pip install agent-reach`. The actual README explicitly warns
  against this — that PyPI name is an unrelated package. The real install
  path is from the GitHub repo itself, and upstream's own recommended flow
  is telling the *agent* to fetch and follow
  `docs/install.md` from the repo, not running a human-typed pip command.
  We will not send an agent to autonomously fetch and execute a remote
  install script as part of *our* automated install — that's a supply-chain
  posture decision beyond what P0's "no sudo, no silent system changes"
  precedent covers, so `scripts/install.sh` will print the exact,
  human-run command instead (see below), matching how we already handle
  Claude/Codex login (tell the user the command, never do it for them).
- Safe-by-default is real and matches the spec closely:
  `agent-reach install --env=auto` (or `--safe`, a documented alias) is
  **read-only** — checks the environment, installs nothing, writes no
  config, unless `--system` is passed explicitly. `--dry-run` is also real.
- Zero-config channels confirmed: **Web** (Jina Reader), **YouTube**
  (yt-dlp), **RSS** (feedparser), **full-web search** (Exa via `mcporter`,
  free, no key), **GitHub** (public repos/search; login only needed for
  private repos or write actions) — this is the spec's "Web; Search;
  GitHub; YouTube; RSS" list, confirmed as upstream's own real zero-config
  set (plus two others upstream enables by default — V2EX and Xueqiu stock
  quotes — both public, read-only, low-risk; we won't suppress them since
  we aren't the ones enabling them, but we also won't extend the same
  treatment to any login-gated channel).
- Social/login-gated channels (Twitter/X, Reddit, Facebook, Instagram,
  Xiaohongshu, LinkedIn) are confirmed **never auto-configured** by
  upstream itself — the agent only sets one up if the user explicitly asks
  ("帮我配 XXX"). This is already upstream's default behavior, not
  something we need to build a guard for ourselves — we simply never
  instruct the lead to request one.
- `agent-reach doctor` is a real command, exactly as the spec names it —
  reports per-channel status and which backend is currently active.
- It really is "capability layer only" — a `SKILL.md` install, no daemon,
  no API our orchestrator calls. Credentials, when a user does configure a
  login-gated channel, live in `~/.agent-reach/config.yaml` at file mode
  `600`, local-only.

### What we will NOT build (already provided upstream, P1)

- Progressive-disclosure memory search (`search`/`timeline`/
  `get_observations`) → claude-mem's own MCP tools.
- Code structure graph, clustering, staleness/lifecycle handling, git-hook
  auto-rebuild → Graphify's own CLI/hooks.
- Multi-backend routing and health-checking for external research
  channels → Agent-Reach's own channel router + `agent-reach doctor`.
- A "context router" LLM — none of the three need one; each is consulted
  by Claude's own native reasoning once the skill exists, per their own
  design ("capability layer, not a wrapper").

### What we still have to build ourselves (P1)

- Risk classification (LOW/MEDIUM/HIGH) from changed paths/diff content —
  deterministic bash/rule-based, extending `lib/orchestrate.sh`.
- Adaptive Codex review depth wired to that classification (skip on LOW,
  normal on MEDIUM, deep + post-correction verification on HIGH).
- Project-level override file (`.agent/config.yaml`) and its precedence
  over our built-in defaults.
- Extended `agent doctor` sections for Graphify/claude-mem/Agent-Reach
  presence and health (cheap checks only — no LLM calls from doctor).
- A per-project setup step that installs/updates the three skills for a
  *target* project the first time `agent` touches it (distinct from
  installing *our own* dependencies in `scripts/install.sh`).
- A best-effort benchmark script — with an honest limitation documented:
  DSH's subagent contract (P0 finding, still true) never exposes a child's
  tool-call trace to the parent, so we cannot literally count "files
  Claude read" from the orchestrator's side. The benchmark can only report
  what we control (risk tier, reviewer invocations, validation runs,
  whether each skill was available/used per its own logs where one
  exists, e.g. Graphify's opt-in query log).

## Open items to verify once `dsh`/`claude`/`codex` are actually installed locally

- Exact `dsh-tool-subagent` config row needed to expose exactly one subagent
  tool with a fixed name on a copied Agent Preset (README shows the shape;
  need to confirm the preset-copy step against the real `--dump-config`
  output).
- Real heuristic for "is Claude Code using subscription vs API key" beyond
  "does a native credentials file exist" — Claude Code CLI does not appear
  to expose a scriptable `status`/`whoami`; doctor will say what it can
  verify and what it can't, rather than guessing.
- Codex's documented (community-reported) behavior of `OPENAI_API_KEY`
  silently overriding ChatGPT subscription login — flagged as high-severity
  in doctor; should be re-confirmed against the installed Codex CLI version's
  own docs since this is exactly the kind of thing that changes release to
  release.
