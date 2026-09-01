# Veramux DSH plugin

DeepSeek Harness is the host platform, runtime, sessions, workspace picker, plugin lifecycle, and Web UI. Veramux is an opinionated orchestration plugin that exposes one model-facing capability, `veramux_run`.

`veramux_run(workspace, task)` canonicalizes the workspace, then starts the existing Veramux CLI as `agent --engine dsh --tool-mode native <workspace> <task>`. The CLI remains the owner of context gathering, policy and risk, the external dirty-worktree baseline, single-writer sequencing, deterministic validation, correction rounds, the reviewer contract, workspace locking, cancellation journal, and final artifact.

The Web profile receives no Claude Code or Codex tool. The private `lead` profile owns `subagent_claude_code`; the private `reviewer` profile owns the read-only Codex provider. The plugin never initializes Graphify and never writes `.claude/`, `CLAUDE.md`, or `graphify-out/` in the target workspace.

The tool uses DSH's subprocess capability with an argv array and the tool execution `AbortSignal`. Cancellation invokes DSH's managed process-tree termination sequence and waits for tree exit. A normal result is read from the Veramux run-owned `final.json`, not from a lead response.

## Install locally in Web

From the Veramux checkout:

```sh
pnpm --dir packages/dsh-plugin install --frozen-lockfile
dsh plugin --profile web add ./packages/dsh-plugin
dsh --profile web --dump-config
dsh --profile web
```

The profile manager adds only this bundle layer and preserves existing Web profile rows. For a non-persistent proof before installation, use an overlay that inserts `veramux-dsh-plugin` with the same config row as `cordis.patch.yml`; local package resolution still requires the checkout to be linked in the profile.

For tests, set `VERAMUX_AGENT_PATH` to a fixture executable. Production defaults to `agent`, resolved by DSH's subprocess provider rather than assuming it is already on PATH.
