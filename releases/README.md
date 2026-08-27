# Release manifests (P3.16)

Each `releases/<version>.yaml` records a **known-good, validated** combination
of the whole stack — every component version, the host runtimes it was tested
on, the capability-probe verdicts, and the benchmark outcome.

## Create one (on the machine where the stack actually works — the VPS)

```sh
agent doctor                       # must be clean
agent benchmark --offline          # note pass/fail
agent release create 1.0.0 --benchmark-offline pass
```

This reads the LIVE inventory. It never fabricates a live-benchmark result —
pass `--benchmark-live pass` only after you actually ran `agent benchmark --live`.

## Reproduce it on a fresh VPS

```sh
git clone <this repo> && cd veramux
scripts/install.sh --release 1.0.0     # pins dsh to the manifest version, then runs configure.sh
# authenticate Claude Code and Codex (see README "Authentication")
agent doctor
agent release verify 1.0.0             # confirms this machine matches
```

`--release` currently overrides only the `dsh` version pin; the subagent
bundles follow `versions.yaml` and claude-mem / Graphify / Agent-Reach are
installed via their own channels (the installer prints the steps). The
authoritative check is `agent release verify`, which compares the current
machine against the manifest — every component version, the critical
capability verdicts, and the offline benchmark — and prints
`RELEASE_VERIFIED` or `RELEASE_MISMATCH` with the specific drift.

TODO (VPS): teach `scripts/configure.sh` to take the bundle versions from
the release manifest too, so `--release` pins the whole stack, not just dsh.

No manifest is committed here yet: the dev checkout does not have `dsh`,
Graphify, or Agent-Reach installed, so a manifest generated here would be
mostly `MISSING`. Generate `1.0.0.yaml` on the VPS and commit it from there.
