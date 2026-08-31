# DSH integration

Phase 1 targets DSH `0.1.1-rc.2` without automatic upgrades. The installed
headless bundle supplies the `tools` host row and the worker-thread code
runtime. Veramux uses official headless profiles and the Claude Code/Codex
subagent primitives; it does not invent an npm bundle or workflow package.

`tools.config.mode` is host/deployment configuration. The agent preset's
`@deepseek-ai/dsh-agent-tool-presentation` is session/preset configuration.
They are distinct layers. The `dsh --dump-config` command is used only for
structural composition checks: it does not evaluate `!!js` environment
expressions and cannot prove runtime interpolation.

For every real Veramux workflow invocation, regardless of selected engine,
the integration seam exports
`DSH_TOOLS_MODE=native`. This prevents an inherited `code` or `both` setting
from enabling Code Mode in the actual workspace. The opt-in `dsh` engine adds
supported-runtime gating and journal correlation; Veramux retains timeout,
fallback, validation, risk, locking and journaling.

DSH has workflow/delegation primitives, but they are not yet the source of
truth for Veramux state. A future migration requires parity tests for journal,
lock, resume, validation, risk, review and rollback first.
