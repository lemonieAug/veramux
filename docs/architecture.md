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

<<<<<<< HEAD
Claude Code is the only implementation writer. Codex is an independent reviewer running
with a dedicated `CODEX_HOME` and read-only sandbox. Context gathering is
read-only with respect to the project workspace: it may query a graph that an
operator prepared explicitly, but it never installs Graphify or builds graph
artifacts during an orchestration run. Before context starts, Veramux records
a run-owned baseline of Git-visible files; reviewer diffs compare that baseline
with the post-lead workspace so pre-existing dirty user changes are excluded.
Validation and risk remain deterministic. DSH sessions do not replace the workspace lock, and
=======
Claude Code is the only writer. Codex is an independent reviewer running
with a dedicated `CODEX_HOME` and read-only sandbox. The orchestrator gathers
context and coordinates; it does not acquire write tools. Validation and risk
remain deterministic. DSH sessions do not replace the workspace lock, and
>>>>>>> f94c88fb5794dbde19e2366420f103952b0a86fb
the Veramux journal remains authoritative for resume.

## Web UI

DSH Web is architecture-ready for future integration. Veramux has no Web UI
in this phase and no UI is a source of workflow state.
