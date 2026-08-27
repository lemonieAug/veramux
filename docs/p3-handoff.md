# P3 Continuation State (V1 — maintenance / controlled upgrades / rollback / benchmarks)

Last updated: 2026-08-27
Current phase: ALL 15 PHASES IMPLEMENTED — final full regression + report
Baseline: commit `59ddee2` ("feat: P2 complete added fields")
Uncommitted P3 work on the tree (not committed — user hasn't asked)

## BASELINE_GREEN (P3.1)

Recorded 2026-08-27 at commit `59ddee2` on this dev box (Windows 11 / Git Bash):

- **Unit suite**: `bash tests/unit/run.sh` → 25 suites, 505 assertions, **all pass**, exit 0.
- **doctor**: `bash scripts/doctor.sh` → exit 0, "7 issue(s) found, 1 blocking" — every issue is
  **environment-only, not a regression**:
  - `dsh not found` (blocking) — DeepSeek Harness is not installed on this dev box. Expected:
    this machine develops/tests P3 with mocks + fake candidates per the P3 safety rule; the real
    stack lives on the VPS.
  - lead/reviewer profiles missing — same cause (no dsh).
  - `OPENAI_API_KEY` set in shell — doctor safety warning only; never consumed by the stack.
  - claude-mem worker not responding — auto-starts on next Claude Code session; also the
    claude-mem observer is 401-ing (OpenRouter key), unrelated to this stack.
- **Integration suite** (`tests/integration/run.sh`): opt-in, needs real dsh + Claude/Codex quota —
  not runnable here.

A baseline is only `BASELINE_GREEN` when the **deterministic** suite is fully green AND doctor's
non-environment checks are clean. Both hold at `59ddee2`.

## Environment inventory (this dev box, 2026-08-27)

| Tool | Installed | Source | Notes |
|---|---|---|---|
| node | 22.23.2 | system | versions.yaml min 22.19.0 ✓ |
| npm | 10.9.8 | bundled w/ node | |
| pnpm | 11.7.0 | system | == tested |
| bun | 1.4.0 | system | |
| python | 3.13.1 | system | |
| uv | 0.12.5 | system | |
| pipx | absent | | not required (uv covers isolated py installs) |
| git | 2.49.0 | system | |
| claude (host CLI) | 2.1.246 | Anthropic installer | non-authoritative signal (stack uses the dsh bundle) |
| codex (host CLI) | 0.149.1 | OpenAI installer | non-authoritative signal |
| claude-mem | 13.16.0 | npm (`claude-mem`) | registry has 13.16.1 → patch update available |
| dsh | absent | npm `@deepseek-ai/dsh` | registry 0.1.1-rc.2 == tested |
| graphify | absent | PyPI `graphifyy` | registry 0.9.50 == P1 tested |
| agent-reach | absent | npm `agent-reach` @ 0.3.4 | P1 doc referenced repo v1.5.0 — **discrepancy to verify** |
| gh | absent | | optional (GitHub research only) |

## Update-discovery sources confirmed working (deterministic, zero LLM)

- **npm**: `npm view <pkg> version` and `npm view <pkg> versions --json`
- **PyPI**: `curl -s https://pypi.org/pypi/<pkg>/json` → `.info.version` / `.releases`
- **component-specific**: `agent-reach check-update`, host `claude`/`codex` self-report — to wire in PHASE 4

## Completed

- **PHASE 1** — regression gate (`BASELINE_GREEN` above) + P3 upstream discovery
  (`docs/upstream-findings.md` §"P3 discovery").
- **PHASE 2** — `compat.yaml` (P3.3 manifest, 12 components, capabilities + migration/rollback notes),
  `lib/compat.sh` (TESTED/SUPPORTED/NEWER_UNTESTED/OLDER/MISSING), `lib/inventory.sh` (P3.2
  deterministic version detection per component → TSV + JSON via `json-tools.mjs inventory-build`).
  Tests: `test_compat.sh` (33), `test_inventory.sh` (17).
- **PHASE 3** — `lib/capability_probe.sh` (P3.3): per-capability deterministic probes returning
  pass/fail/unknown; `capability_verdict` → OK/INCOMPATIBLE/UNVERIFIED; `inventory_collect --probe`
  overlays INCOMPATIBLE. Only `fail` (verifiably absent) makes a component INCOMPATIBLE — "not
  installed" / "needs live call" is `unknown`, never a silent pass. Test: `test_capability_probe.sh` (12).
  Fixed an MSYS path-mangling bug: never put a leading-slash path literal in a `node -e` string on
  Git Bash — pass paths via argv.

- **PHASE 4** — `lib/update_discovery.sh` + `agent update check` + `agent inventory`.
  `_update_registry_query` is the single network seam (npm dist-tag aware — dsh + bundles follow
  the `next` channel; test fixture `tests/fixtures/update-registry/fixture`). Status vocab:
  up_to_date / update_available / ahead / unknown / not_installed / not_applicable.
  `json-tools.mjs update-check-build`. Test: `test_update_discovery.sh` (17). **Bundle-version fix:**
  claude-code/codex now track the *bundle* package version (mirrors dsh scheme), not the transitive
  SDK/wrapper version (that's `inventory_detail_version` + the existing `version_drift_installed_*`).
- **PHASE 5** — `lib/update_plan.sh` + `agent update plan [component]`. Deterministic risk
  (`update_risk`): dsh/claude-code/codex = always HIGH; claude-mem major = HIGH, minor = MEDIUM,
  patch = LOW; graphify/agent-reach minor = MEDIUM; unknown bump = HIGH; staging-not-isolatable
  escalates one tier. Plan shows exact apply command, affected configs/skills, post-update
  capability checks, rollback, migration notes. `json-tools.mjs plan-build`. Test: `test_update_plan.sh` (28).

Test seams added: `AGENT_COMPAT_FILE`, `AGENT_UPDATE_REGISTRY_FIXTURE`, `AGENT_UPDATE_OFFLINE=1`,
`AGENT_INVENTORY_FIXTURE` (fixture scripts under `tests/fixtures/update-registry/`).

- **PHASE 6** — `lib/snapshot.sh` (P3.8: config-state snapshot under `state_snapshots_dir`; JSON
  secret-keys nulled in copies, secret-bearing files recorded by sha256 only in
  `secrets-manifest.jsonl`; `AGENT_STACK_ROOT` seam), `lib/update_stage.sh` (P3.6: isolated
  install into `state_staging_dir`, verify binary/version/subcommands, auto-cleanup;
  `staged_ok|staged_failed|staging_not_available`; bundles = not_available without real dsh),
  `lib/migration_detect.sh` (P3.7: `severity: none|reversible|irreversible|unknown` + concerns;
  claude-mem major = irreversible). Tests: `test_snapshot.sh` (18), `test_update_stage.sh` (7),
  `test_migration_detect.sh` (15).
- **PHASE 7** — `lib/update_verify.sh` (P3.10: `update_verify_component` = version + capability
  probes; `update_verify_regression` = doctor + full unit suite, seam `AGENT_VERIFY_REGRESSION_CMD`),
  `lib/update_apply.sh` (P3.9: plan → snapshot → stage → install EXPLICIT candidate → verify
  component → verify regression; result `UPDATE_SUCCESS` / `UPDATE_FAILED_ROLLBACK_AVAILABLE:<snap>` /
  `UPDATE_FAILED_ROLLBACK_PARTIAL:<snap>`; refuses non-interactive without `--yes`; refuses system
  components; seam `AGENT_APPLY_INSTALL_FIXTURE`). Test: `test_update_apply.sh` (13, incl. adversarial
  broken-binary / wrong-version / regression).
- **PHASE 8** — `lib/rollback.sh` (P3.11: restore config tree from snapshot — NEVER overwrites a
  secret-bearing file; reinstall recorded versions; verify; `ROLLBACK_COMPLETE` /
  `ROLLBACK_PARTIAL` — partial when a reinstall fails, verification fails, or the forward update
  was an irreversible migration; seam `AGENT_ROLLBACK_INSTALL_FIXTURE`). Test: `test_rollback.sh` (10,
  incl. adversarial rollback-also-fails / irreversible-migration).

CLI: `agent update check|plan|apply|rollback` all live now; `agent inventory [--json]`.
New state dirs: `snapshots/ staging/ backups/ benchmark/` under `$AGENT_STATE_HOME`.

- **PHASE 9** — `lib/benchmark.sh` + `policies/benchmark.yaml` + 8 fixtures
  `tests/benchmark/fixtures/` (categories A-H). Offline mode: deterministic checks of risk /
  review routing / tool routing / context-budget footprint vs each fixture's expected_*.
  `benchmark_compare` (`json-tools.mjs benchmark-compare`) = the P3.13 regression detector.
  `agent benchmark --offline|--live|compare`. Test: `test_benchmark_suite.sh` (27).
- **PHASE 10** — `policies/profiles.yaml` + `lib/profiles.sh` (economy/balanced/strict).
  `agent --profile X` (global flag), `agent profile`. Guarded hooks in `lib/context.sh` (budgets +
  external on/off) and `lib/risk.sh` (`risk_requires_codex`/`risk_requires_verification`) — no-op
  when profiles.sh isn't sourced, so P1 suites unaffected. **HIGH review never weakened.**
  Test: `test_profiles.sh` (24).
- **PHASE 11** — `lib/memexp.sh` + `tests/benchmark/memory/` (10 facts / 10 queries).
  `agent memexp report|baseline|facts|queries|score|compare`. Deterministic recall scorer;
  NEVER edits `~/.claude-mem/settings.json`, only recommends. Test: `test_memexp.sh` (12).
- **PHASE 12** — `lib/backup.sh` (`agent backup` → portable tar.gz of stack config, reuses
  snapshot's secret handling; `agent restore` → validate → show → preserve current secrets →
  restore → doctor). Test: `test_backup.sh` (10).
- **PHASE 13** — `lib/release.sh` (`agent release create|show|list|verify`; manifest =
  per-component versions + host runtimes + capability verdicts + benchmark outcome, never
  fabricated). `scripts/install.sh --release <v>`. `releases/README.md`. Test: `test_release.sh` (13).
- **PHASE 14** — `test_adversarial_updates.sh` (10): scenarios A (dsh loses Codex backend),
  B (loses Code Mode), C (Graphify skill misplaced), D (claude-mem schema/major migration
  detected up front), E (Agent-Reach doctor surface changed). F/G/H are in test_update_apply.sh
  + test_rollback.sh.
- **PHASE 15** — README §"Maintenance and controlled upgrades (P3 / V1)", `agent --help` updated,
  `docs/upstream-findings.md` §"P3 discovery" (from PHASE 1), future-scope section updated.

## New CLI surface (P3)

`agent inventory [--json]`, `agent update check|plan|apply|rollback`,
`agent benchmark --offline|--live|compare`, `agent backup|restore`,
`agent release list|show|create|verify`, `agent memexp ...`, `agent --profile X`, `agent profile`.

## Test seams (all fixture scripts under tests/fixtures/update-registry/ or inline)

`AGENT_COMPAT_FILE`, `AGENT_UPDATE_REGISTRY_FIXTURE`, `AGENT_UPDATE_OFFLINE`, `AGENT_INVENTORY_FIXTURE`,
`AGENT_STAGE_INSTALL_FIXTURE`, `AGENT_APPLY_INSTALL_FIXTURE`, `AGENT_ROLLBACK_INSTALL_FIXTURE`,
`AGENT_VERIFY_REGRESSION_CMD`, `AGENT_STACK_ROOT`, `AGENT_RELEASES_DIR`, `AGENT_BENCHMARK_FIXTURES`,
`AGENT_MEMEXP_FIXTURES`, `DSH_HOME`, `AGENT_STATE_HOME`.

## Known environment limitations (unchanged)

`dsh` / Graphify / Agent-Reach not installed on this dev box — all P3 machinery tested against
mocks + fixtures + fake candidates per the P3 safety rule. A real release manifest and real
`agent update apply` against upstreams must be exercised on the VPS.

## Architecture decisions (P3)

- Reuse `lib/version_drift.sh` (`version_drift_compare`, `version_drift_status`) — do **not** write a
  second semver comparator.
- Reuse `lib/state_paths.sh` for where snapshots/backups/benchmark results live
  (`$AGENT_STATE_HOME` root; new subdirs `snapshots/`, `backups/`, `benchmark/`, `releases/`).
- `compat.yaml` is the new compatibility manifest; `versions.yaml` stays as the simple pin list
  (compat.yaml references it, doesn't replace it).
- All `agent update *` except a future `--live` benchmark: **zero** LLM calls, and `check`/`plan`/
  `backup`/`restore` perform **zero mutations** to installed components.
- Real upstream updates are never run to test P3 — mocks at the package-manager boundary + fake
  candidate tarballs + local fixtures only.

## Commands to continue

```bash
bash tests/unit/run.sh                 # BASELINE_GREEN check (~15 min on this box)
bash scripts/doctor.sh                 # environment
git log --oneline -5
```

## Next action

PHASE 2: `lib/inventory.sh` (deterministic component inventory JSON) + `compat.yaml` +
`lib/compat.sh` (TESTED/SUPPORTED/NEWER_UNTESTED/INCOMPATIBLE) + `tests/unit/test_inventory.sh`
+ `tests/unit/test_compat.sh`.
