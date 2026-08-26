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
