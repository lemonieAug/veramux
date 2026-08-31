# Programmatic orchestration

Tool modes are a stable Veramux configuration surface:

| Requested mode | Phase 1 behavior |
| --- | --- |
| `native` | Supported. The DSH process receives `DSH_TOOLS_MODE=native`. |
| `auto` | Resolves deterministically to `native`. |
| `programmatic` | Known but blocked before any DSH, provider or subagent call. |

The installed upstream primitive is `code` in DSH `0.1.1-rc.2`; a future
compatible primitive could be `ptc`. Primitive availability and Veramux
authorization are deliberately separate facts.

**Code Mode availability is not equivalent to Code Mode being authorized by
Veramux policy.** The current worker-thread CodeRuntime is containment, not
an operating-system security boundary, and cannot preserve Veramux's
single-writer policy in the real workspace.

The desired future boundary is:

```
Programmatic Orchestrator
  -> isolated OS boundary
  -> read-only or disposable workspace view
```

Minimum requirements: container or VM isolation, read-only workspace,
ephemeral filesystem where feasible, no Docker socket, SSH agent, Git remote
write credentials, Claude/Codex credentials, or ambient secrets; minimal
relay credentials only; and denied/restricted network where feasible.
