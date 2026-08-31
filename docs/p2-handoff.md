# P2 Continuation State

Last updated: 2026-08-27
Current phase: P2 essentially complete — final audit / regression
Last completed phase: PHASE 2 (project detection + validation profile) fully wired

## Completed (all phases)

- **P2.1 upstream discovery** — `docs/upstream-findings.md` §"P2 discovery" (timeouts, cancellation,
  session model, version signal all confirmed as genuinely ours to build).
- **P2.2 project detection** — `lib/project_detect.sh`: node/python/make (P0) + go/rust/php/java/docker/just;
  `project_detect_package_manager` / `project_pm_resolve` choose the PM from the project's own lockfile
  (never "what's installed"), ambiguity → npm + stderr warning, `.agent/config.yaml` override wins.
- **P2.3 validation profile** — `project_profile_build` assembles the reusable JSON object; the resolved
  PM feeds `validation_detect_commands` (live path). Now captured at run start:
  `<run_dir>/project-profile.json` (mode 600) + project-level cache
  (`state_project_profile_cache`) + `project.detected` structured event (metadata only).
  Surfaced by `agent show`.
- **P2.4 run lifecycle** — `lib/run_lifecycle.sh` (11 states, structural transition table),
  `lib/state_paths.sh` (state dir under `$AGENT_STATE_HOME` / XDG, never inside the target repo),
  `run_id_generate` (UTC ts + 6 hex).
- **P2.5 durable journal** — `lib/journal.sh`; atomic temp-file+rename in `lib/json-tools.mjs`;
  `run.json` + `events.jsonl`, task text only in `task.txt` (600), never duplicated.
- **P2.6 observability** — `append-event` with `schema_version: 1`, stable event names,
  paired `<phase>.started` / `.completed` / `.failed`, counts/metadata not payloads.
- **P2.7 failure taxonomy** — `lib/failures.sh`, 14 categories. Precedence: explicit hint →
  our exit-code conventions (124 timeout, 130 cancellation, 137 timeout escalation unless the
  cancel marker already won) → curated text patterns (last resort) → INTERNAL. No LLM.
- **P2.8 timeout / cancellation** — `lib/proc_timeout.sh`: GNU `timeout` (or bash fallback),
  SIGTERM to the `dsh` process (which owns its own subprocess-tree disposal), 124 = our deadline.
  PID tracked in `<run_dir>/active.pid` for `agent cancel`; always cleared.
- **P2.9 retry** — `lib/retry.sh` + `policies/runtime.yaml`. Retryable set is fixed and small:
  RATE_LIMIT, PROVIDER_UNAVAILABLE, TIMEOUT, MALFORMED_OUTPUT. Exponential backoff capped 30s.
  AUTH / QUOTA / VALIDATION / REVIEW / config / workspace-git conflicts are never retried.
- **P2.10 resume** — `lib/resume.sh`; `orchestrate.sh` split into re-enterable
  `_orchestrate_validate_and_review` / `_orchestrate_review_loop`. `resume_entry_decision` uses
  `journal_call_in_flight` to tell "phase transition happened, call never started" (safe retry)
  from "call was mid-flight" (UNCERTAIN → refuse without `--force`). Never continues a provider session.
- **P2.11 provider / quota** — every relay call starts with DeepSeek. After retries, only
  RATE_LIMIT, QUOTA, PROVIDER_UNAVAILABLE, TIMEOUT, or an unconfigured DeepSeek primary may
  switch to the separately credentialed OpenAI relay. Both failures remain `FAILED` and are
  recorded. This does not change Claude Code/Codex child authentication.
- **P2.12 workspace locking** — `lib/workspace_lock.sh`: `mkdir` lock dir + `info`
  (run_id/pid/hostname/created_at). Stale reclaim only same-host + dead PID; different host = never auto-break.
- **P2.13 git safety** — `lib/git_safety.sh`: snapshot HEAD + `git status` at start; detect/report only,
  never reset/clean/checkout. `git_safety_head_conflict` → resume refuses without `--force`.
- **P2.14 enhanced doctor** — `scripts/doctor.sh` new sections: run storage (writable + corrupt-journal
  scan), locks (stale detection), versions (drift).
- **P2.15 version drift** — `lib/version_drift.sh`: reads versions actually resolved in each DSH
  profile's `node_modules`; SUPPORTED / NEWER_UNTESTED / OLDER_UNSUPPORTED / MISSING / UNKNOWN.
  `policies/runtime.yaml` `versions.auto_update: false`.
- **P2.16 operational CLI** — `bin/agent`: `status` `runs` `show` `logs` `resume` `cancel` `unlock`
  `cleanup`. `lib/run_cli.sh`. None call an LLM.
- **P2.17 retention** — `lib/cleanup.sh`: `retention_days` / `retention_max_per_project`;
  never deletes a non-terminal (active or INTERRUPTED) run; never touches the target repo.
- **P2.18 tests** — ~15 P2 unit suites, all green.
- **P2.19 failure-injection** — `tests/unit/test_failure_injection.sh`: A lead failure, B hang→our
  timeout + orphan check, C Codex no quota, D resume-after-implementation, I second writer blocked,
  dirty-start; Scenario E (interrupt during implementation → UNCERTAIN) in `test_resume.sh`.
- **P2.20 documentation** — `README.md` §"Operational hardening (P2)"; `.env.example` (`AGENT_STATE_HOME`);
  `docs/upstream-findings.md` P2 section.

## Partial / not started

- None known. Only follow-up: nice-to-have `agent status` line for the cached project profile
  (currently only `agent show` surfaces it).

## Known environment limitations

- Windows + Git Bash: each `bash`/`node`/`git` spawn is slow; the full unit suite takes ~15 min.
  Apparent "hangs" under concurrent runs are process-spawn contention, not deadlocks.
- `tests/integration/run.sh` is opt-in (`RUN_LLM_INTEGRATION_TESTS=1`), needs a real `dsh` install
  plus authenticated Claude Code + Codex — not runnable in this environment.
- `dsh` is not installed here, so `agent doctor` reports provider-missing (expected).

## Important architectural decisions

- P2 adds **zero** extra LLM calls to a normal run — same Claude/Codex calls P1 made.
- Journals live under `${AGENT_STATE_HOME:-${XDG_STATE_HOME:-~/.local/state}/agent-stack}/runs/<project-id>/<run-id>/`,
  never inside the target project. `project-id` = sanitized basename + 8-hex sha1 of the resolved root path.
- Secret-shaped field names (`api_key`, `token`, `secret`, `password`, `credential`) are rejected
  by `json-tools.mjs` before any journal write.
- One dsh call site: `orchestrate_call_dsh_tracked` — layers timeout + retry + events + cancel-marker.

## Commands to continue

```bash
bash tests/unit/run.sh                      # full P0+P1+P2 unit suite (~15 min here)
bash tests/unit/test_failure_injection.sh   # P2.19 E2E scenarios
bash tests/unit/test_resume.sh              # P2.10
bash scripts/doctor.sh /path/to/project     # P2.14 sections
RUN_LLM_INTEGRATION_TESTS=1 bash tests/integration/run.sh   # only with real dsh + quota
```

## Next action

Run the full regression suite, confirm green, then P2 is done — nothing further planned.
