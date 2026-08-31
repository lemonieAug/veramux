# Security boundaries

Claude Code is the only workspace writer. Codex is an independent reviewer:
its profile uses a dedicated `CODEX_HOME`, read-only sandbox mode and disabled
native write/edit/shell rows. These are mechanical configuration boundaries,
not prompt-only conventions.

The DSH worker-thread CodeRuntime is **not** a security sandbox. It provides
a fresh worker, empty environment, resource/time limits and termination, but
worker-thread containment is not OS-level isolation. The installed runtime
can use Node built-ins and the authority of the process for filesystem,
process and network access. Its empty environment avoids inherited ambient
credentials, but it does not remove process authority; processes started by a
program may outlive worker termination.

Therefore Programmatic Mode is blocked in the main workspace. See
[Programmatic orchestration](programmatic-orchestration.md) for the required
future isolation boundary.
