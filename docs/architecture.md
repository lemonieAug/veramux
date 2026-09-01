# Architecture

Veramux is in a **hybrid DSH-native migration**. DSH is the runtime and
agent infrastructure; Veramux remains the deterministic engineering-policy
and workflow controller during Phase 1.

```
user
  -> Veramux CLI/config resolution
  -> workspace lock + Veramux journal (source of truth)
  -> context adapters (memory / graph / research)
  -> DSH headless profile, native tool presentation
  -> Claude Code subagent (only writer)
  -> deterministic validation + deterministic risk
  -> Codex subagent in dedicated read-only CODEX_HOME, when review is needed
  -> bounded Claude correction loop
  -> Veramux final state / journal
```

## Ownership

DSH provides profile composition, headless execution, relay provider model
runtime, and official Claude Code/Codex subagent primitives. Veramux owns
their integration policy, workspace locking, journal, resume checkpoints,
validation, risk classification, review routing, correction limits, redaction,
and the DeepSeek-primary/OpenAI-fallback policy.

The `legacy` engine remains the default. The opt-in `dsh` engine requires the
supported DSH runtime and records its selection in the Veramux journal. Both
engines use the same native-only DSH invocation seam; neither transfers
deterministic policy into an LLM or a DSH workflow.

## Boundaries

Claude Code is the only implementation writer. Codex is an independent reviewer running
with a dedicated `CODEX_HOME` and read-only sandbox. Context gathering is
read-only with respect to the project workspace: it may query a graph that an
operator prepared explicitly, but it never installs Graphify or builds graph
artifacts during an orchestration run. Before context starts, Veramux records
a run-owned baseline of Git-visible files; reviewer diffs compare that baseline
with the post-lead workspace so pre-existing dirty user changes are excluded.
Validation and risk remain deterministic. DSH sessions do not replace the workspace lock, and
the Veramux journal remains authoritative for resume.

## Web UI

DSH Web is the host UI and can load the local `veramux-dsh-plugin` bundle.
Its single capability, `veramux_run(workspace, task)`, starts the existing
`agent --engine dsh --tool-mode native` CLI in a managed subprocess. Veramux
remains the source of truth for workflow state and reads its run-owned final
artifact before returning a result to the Harness.

The Web profile never receives Claude Code or Codex as free tools. Those
remain private to the `lead` and `reviewer` profiles, respectively. The
plugin does not initialize Graphify or write project configuration; it only
canonicalizes the workspace and delegates to the deterministic controller.
