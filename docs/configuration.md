# Configuration

Project configuration is optional at `.agent/config.yaml`. Engine precedence
is CLI, then project config, then the default `legacy`.

```yaml
orchestration:
  engine: legacy
  tool_mode: native
```

To opt into the Phase 1 hybrid DSH engine:

```yaml
orchestration:
  engine: dsh
  tool_mode: native
```

Equivalent CLI use: `agent --engine dsh . "task"`. `auto` currently resolves
to `native`. `tool_mode: programmatic` and `agent --programmatic` are
rejected deterministically, for either engine; they do not fall back silently.
