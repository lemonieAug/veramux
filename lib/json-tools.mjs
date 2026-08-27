#!/usr/bin/env node
// Small, deliberately narrow JSON helpers for bash callers. Node is already
// a hard dependency of DeepSeek Harness itself, so this avoids adding jq or
// any other JSON tooling dependency (see README "Segurança"/architecture
// notes). This is NOT a general JSON framework: two subcommands only.
import { readFileSync, appendFileSync, writeFileSync, renameSync, mkdirSync, existsSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { dirname } from 'node:path'

const [, , cmd, ...args] = process.argv

function readStdin() {
  const chunks = []
  return new Promise((resolve, reject) => {
    process.stdin.on('data', (c) => chunks.push(c))
    process.stdin.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    process.stdin.on('error', reject)
  })
}

function fail(msg) {
  process.stderr.write(`json-tools: ${msg}\n`)
  process.exit(2)
}

// build-validation-result: reads TSV lines "status<TAB>command" from stdin,
// status one of: passed|failed|skipped. Emits the structured result the
// validation runner and the review packages both consume.
async function buildValidationResult() {
  const input = await readStdin()
  const result = { commands: [], passed: [], failed: [], skipped: [] }
  for (const line of input.split('\n')) {
    if (!line.trim()) continue
    const idx = line.indexOf('\t')
    if (idx < 0) fail(`malformed line (expected "status<TAB>command"): ${line}`)
    const status = line.slice(0, idx)
    const command = line.slice(idx + 1)
    if (!['passed', 'failed', 'skipped'].includes(status)) fail(`unknown status: ${status}`)
    result.commands.push(command)
    result[status].push(command)
  }
  process.stdout.write(JSON.stringify(result))
}

// build-project-profile: reads tagged TSV lines from stdin (P2.3) and
// assembles the validation-profile JSON object. Line shapes:
//   language<TAB>value
//   framework<TAB>value
//   package_manager<TAB>value
//   validation<TAB>label<TAB>command
//   detected_at<TAB>iso8601
//   source_file<TAB>path
async function buildProjectProfile() {
  const input = await readStdin()
  const profile = {
    languages: [], package_manager: null, frameworks: [],
    validation: {}, high_risk_paths: [], detected_at: null,
    source_files_that_justify_detection: [],
  }
  for (const line of input.split('\n')) {
    if (!line.trim()) continue
    const parts = line.split('\t')
    const tag = parts[0]
    if (tag === 'language' && parts[1] && !profile.languages.includes(parts[1])) {
      profile.languages.push(parts[1])
    } else if (tag === 'framework' && parts[1] && !profile.frameworks.includes(parts[1])) {
      profile.frameworks.push(parts[1])
    } else if (tag === 'package_manager' && parts[1]) {
      profile.package_manager = parts[1]
    } else if (tag === 'validation' && parts[1] && parts[2] !== undefined) {
      profile.validation[parts[1]] = parts[2]
    } else if (tag === 'detected_at' && parts[1]) {
      profile.detected_at = parts[1]
    } else if (tag === 'source_file' && parts[1]) {
      profile.source_files_that_justify_detection.push(parts[1])
    }
  }
  process.stdout.write(JSON.stringify(profile))
}

// project-id <root-path>: stable, filesystem-safe project identifier for
// the run journal (P2.4/P2.5) — a sanitized basename plus an 8-hex-char
// hash of the full resolved path, so two differently-named checkouts of
// the same repo never collide and the id stays readable. Uses Node's
// built-in crypto instead of shelling out to sha1sum/shasum, which aren't
// guaranteed present on every platform this stack runs on (Node already is).
function projectId(rootPath) {
  const hash = createHash('sha1').update(rootPath).digest('hex').slice(0, 8)
  const base = (rootPath.split(/[\\/]/).filter(Boolean).pop() || 'project')
    .replace(/[^A-Za-z0-9_-]/g, '_')
  process.stdout.write(`${base}-${hash}`)
}

// append-event <events.jsonl path> <event_name> [key=value ...]: appends one
// structured JSON line (P2.6). Values are coerced: "true"/"false" -> boolean,
// an integer-looking string -> number, everything else -> string. Always
// includes schema_version and a timestamp. A single O_APPEND write keeps
// concurrent appenders from interleaving partial lines (each line is small
// and written in one syscall).
function appendEvent(eventsPath, eventName, kvArgs) {
  const record = {
    schema_version: 1,
    timestamp: new Date().toISOString(),
    event: eventName,
  }
  for (const kv of kvArgs) {
    const idx = kv.indexOf('=')
    if (idx < 0) continue
    const key = kv.slice(0, idx)
    const raw = kv.slice(idx + 1)
    if (raw === 'true') record[key] = true
    else if (raw === 'false') record[key] = false
    else if (raw !== '' && /^-?\d+(\.\d+)?$/.test(raw)) record[key] = Number(raw)
    else record[key] = raw
  }
  appendFileSync(eventsPath, JSON.stringify(record) + '\n')
}

// Coerces "true"/"false" -> boolean and integer-looking strings -> number;
// everything else stays a string. Shared by append-event/run-create/run-update.
function coerceValue(raw) {
  if (raw === 'true') return true
  if (raw === 'false') return false
  if (raw === 'null') return null
  if (raw !== '' && /^-?\d+$/.test(raw)) return Number(raw)
  return raw
}

function parseKvArgs(kvArgs) {
  const out = {}
  for (const kv of kvArgs) {
    const idx = kv.indexOf('=')
    if (idx < 0) continue
    out[kv.slice(0, idx)] = coerceValue(kv.slice(idx + 1))
  }
  return out
}

// Same-directory temp-file-then-rename: rename is atomic on the same
// filesystem on POSIX and NTFS alike, so a reader never observes a
// partially-written run.json (P2.5: "evite arquivo parcialmente escrito").
function writeAtomic(path, content) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
  const tmp = `${path}.tmp-${process.pid}-${Date.now()}`
  writeFileSync(tmp, content, { mode: 0o600 })
  renameSync(tmp, path)
}

// run-create <run.json path> key=value ...: initial P2.5 run.json. Any
// field not explicitly passed gets its documented default. Never accepts an
// "api_key"/"token"/"secret"/"password"-named field — those are rejected
// loudly rather than silently written to disk (run journals must never hold
// credentials; see P2 security notes).
const SECRET_LIKE_KEY = /(api[_-]?key|token|secret|password|credential)/i
function runCreate(path, kvArgs) {
  const fields = parseKvArgs(kvArgs)
  for (const key of Object.keys(fields)) {
    if (SECRET_LIKE_KEY.test(key)) fail(`refusing to write secret-shaped field "${key}" into a run journal`)
  }
  const now = new Date().toISOString()
  const record = {
    schema_version: 1,
    run_id: fields.run_id ?? null,
    project: fields.project ?? null,
    workspace: fields.workspace ?? null,
    task_summary: fields.task_summary ?? '',
    state: fields.state ?? 'CREATED',
    started_at: fields.started_at ?? now,
    updated_at: now,
    base_git_head: fields.base_git_head ?? null,
    current_git_head: fields.current_git_head ?? null,
    dirty_at_start: fields.dirty_at_start ?? false,
    risk: fields.risk ?? null,
    correction_round: fields.correction_round ?? 0,
    last_completed_phase: fields.last_completed_phase ?? null,
  }
  writeAtomic(path, JSON.stringify(record, null, 2))
}

// run-update <run.json path> key=value ...: read-modify-write, atomic.
// Always refreshes updated_at unless the caller explicitly overrides it.
function runUpdate(path, kvArgs) {
  const fields = parseKvArgs(kvArgs)
  for (const key of Object.keys(fields)) {
    if (SECRET_LIKE_KEY.test(key)) fail(`refusing to write secret-shaped field "${key}" into a run journal`)
  }
  if (!existsSync(path)) fail(`no such run journal: ${path}`)
  const record = JSON.parse(readFileSync(path, 'utf8'))
  Object.assign(record, fields)
  if (!('updated_at' in fields)) record.updated_at = new Date().toISOString()
  writeAtomic(path, JSON.stringify(record, null, 2))
}

// build-object key=value ...: generic flat JSON object builder (same
// coercion rules as append-event). Used for the P2.7 failure-result shape
// and anywhere else a small flat object is all that's needed.
function buildObject(kvArgs) {
  process.stdout.write(JSON.stringify(parseKvArgs(kvArgs)))
}

// inventory-build: reads TSV rows from stdin (P3.2) and assembles a JSON
// array of component objects. Row shape (7 tab-separated columns):
//   name  installed  source  tested  status  critical  capabilities(comma)
async function inventoryBuild() {
  const input = await readStdin()
  const components = []
  for (const line of input.split('\n')) {
    if (!line.trim()) continue
    const [name, installed, source, tested, status, critical, caps] = line.split('\t')
    const dash = (v) => (v === undefined || v === '' || v === '-' ? null : v)
    components.push({
      name: name || '',
      installed_version: dash(installed),
      source: dash(source),
      expected_version: dash(tested),
      status: status || 'UNKNOWN',
      critical: critical === 'true',
      capabilities: (dash(caps) || '').split(',').map((s) => s.trim()).filter(Boolean),
    })
  }
  process.stdout.write(JSON.stringify({ schema_version: 1, components }))
}

// update-check-build: TSV rows (P3.4) -> JSON.
//   name  installed  available  scheme  status  critical
async function updateCheckBuild() {
  const input = await readStdin()
  const dash = (v) => (v === undefined || v === '' || v === '-' ? null : v)
  const components = []
  for (const line of input.split('\n')) {
    if (!line.trim()) continue
    const [name, installed, available, scheme, status, critical] = line.split('\t')
    components.push({
      name: name || '',
      installed_version: dash(installed),
      available_version: dash(available),
      scheme: dash(scheme),
      status: status || 'unknown',
      critical: critical === 'true',
    })
  }
  const updates = components.filter((c) => c.status === 'update_available').map((c) => c.name)
  process.stdout.write(JSON.stringify({ schema_version: 1, checked_at: new Date().toISOString(), updates_available: updates, components }))
}

// plan-build: the "key: value" + "  - item" lines from update_plan_for
// (P3.5) -> one JSON object. List keys ("affected:", "post_update_
// capability_checks:") collect their following "  - " items.
async function planBuild() {
  const input = await readStdin()
  const obj = {}
  let listKey = null
  for (const rawLine of input.split('\n')) {
    if (!rawLine.trim()) continue
    if (rawLine.startsWith('  - ')) {
      if (listKey) obj[listKey].push(rawLine.slice(4).trim())
      continue
    }
    const m = /^([a-z_]+):\s?(.*)$/.exec(rawLine)
    if (!m) { listKey = null; continue }
    const [, key, val] = m
    if (val === '') { obj[key] = []; listKey = key }
    else {
      obj[key] = val === 'true' ? true : val === 'false' ? false : val
      listKey = null
    }
  }
  process.stdout.write(JSON.stringify(obj))
}

// benchmark-compare <baseline.json> <candidate.json> <maxCallsPct> <maxCtxPct>
// P3.13 regression detector. Exits 1 if a hard invariant broke or a
// threshold was exceeded.
function benchmarkCompare(baselinePath, candidatePath, maxCallsPct, maxCtxPct) {
  const b = JSON.parse(readFileSync(baselinePath, 'utf8'))
  const c = JSON.parse(readFileSync(candidatePath, 'utf8'))
  const byId = (r) => Object.fromEntries((r.results || []).map((x) => [x.fixture, x]))
  const B = byId(b), C = byId(c)
  const findings = []
  let hardFail = false

  for (const id of Object.keys(B)) {
    const bo = B[id], co = C[id]
    if (!co) { findings.push(`- ${id}: MISSING from candidate results`); hardFail = true; continue }

    if (bo.passed === true && co.passed !== true) {
      findings.push(`- ${id}: REGRESSION — baseline passed, candidate does not (${co.review_ok === false ? 'review routing' : co.risk_ok === false ? 'risk' : 'tools'} changed)`)
      hardFail = true
    }
    if (co.risk === 'high' && co.review_decision === 'skip') {
      findings.push(`- ${id}: INVARIANT BROKEN — HIGH risk routed to skip review`)
      hardFail = true
    }
    const bc = Number(bo.llm_calls_min || 0), cc = Number(co.llm_calls_min || 0)
    if (bc > 0 && cc > bc * (1 + maxCallsPct / 100)) {
      findings.push(`- ${id}: expected LLM calls ${bc} -> ${cc} (> +${maxCallsPct}%)`)
      hardFail = true
    }
    const bx = Number(bo.context_budget_chars || 0), cx = Number(co.context_budget_chars || 0)
    if (bx > 0 && cx > bx * (1 + maxCtxPct / 100)) {
      findings.push(`- ${id}: context budget ${bx} -> ${cx} chars (> +${maxCtxPct}%)`)
      hardFail = true
    }
    if (bx > 0 && cx < bx) {
      findings.push(`- ${id}: context budget ${bx} -> ${cx} chars (improvement — smaller)`)
    }
  }

  if (findings.length === 0) {
    process.stdout.write('benchmark compare: no regressions, no threshold breaches.\n')
  } else {
    process.stdout.write('benchmark compare findings:\n' + findings.join('\n') + '\n')
  }
  process.exit(hardFail ? 1 : 0)
}

const REVIEW_SEVERITIES = new Set(['critical', 'high', 'medium', 'low'])
const REVIEW_CATEGORIES = new Set([
  'security', 'correctness', 'regression', 'performance', 'maintainability', 'tests', 'other',
])

// validate-review <file>: validates the P0.6 review contract shape. Prints
// the normalized JSON on stdout and exits 0 when valid. Exits 1 with a
// human-readable reason on stderr when invalid (including malformed JSON),
// so the caller can decide whether to retry once, per spec.
function validateReview(raw) {
  let parsed
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    process.stderr.write(`invalid JSON: ${e.message}\n`)
    process.exit(1)
  }
  const errors = []
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    errors.push('root must be a JSON object')
  } else {
    if (parsed.verdict !== 'approved' && parsed.verdict !== 'changes_requested') {
      errors.push(`verdict must be "approved" or "changes_requested", got: ${JSON.stringify(parsed.verdict)}`)
    }
    if (typeof parsed.summary !== 'string' || parsed.summary.length === 0) {
      errors.push('summary must be a non-empty string')
    }
    if (!Array.isArray(parsed.findings)) {
      errors.push('findings must be an array (use [] for none)')
    } else {
      parsed.findings.forEach((f, i) => {
        if (f === null || typeof f !== 'object') { errors.push(`findings[${i}] must be an object`); return }
        if (!REVIEW_SEVERITIES.has(f.severity)) errors.push(`findings[${i}].severity invalid: ${JSON.stringify(f.severity)}`)
        if (!REVIEW_CATEGORIES.has(f.category)) errors.push(`findings[${i}].category invalid: ${JSON.stringify(f.category)}`)
        if (f.file !== null && typeof f.file !== 'string') errors.push(`findings[${i}].file must be a string or null`)
        if (f.line !== undefined && f.line !== null && !Number.isInteger(f.line)) errors.push(`findings[${i}].line must be an integer or null`)
        if (typeof f.problem !== 'string' || !f.problem) errors.push(`findings[${i}].problem must be a non-empty string`)
        if (typeof f.reason !== 'string' || !f.reason) errors.push(`findings[${i}].reason must be a non-empty string`)
        if (typeof f.recommendation !== 'string' || !f.recommendation) errors.push(`findings[${i}].recommendation must be a non-empty string`)
      })
    }
    if (parsed.verdict === 'approved' && Array.isArray(parsed.findings)) {
      const blocking = parsed.findings.filter((f) => f && (f.severity === 'critical' || f.severity === 'high'))
      if (blocking.length > 0) {
        errors.push(`verdict is "approved" but ${blocking.length} finding(s) are critical/high severity`)
      }
    }
  }
  if (errors.length > 0) {
    process.stderr.write(errors.map((e) => `- ${e}`).join('\n') + '\n')
    process.exit(1)
  }
  process.stdout.write(JSON.stringify(parsed))
}

// blocking-findings <file>: prints JSON array of findings whose severity is
// critical or high — the ones that must go back to Claude per P0.7/P0.9.
function blockingFindings(raw) {
  const parsed = JSON.parse(raw)
  const blocking = (parsed.findings || []).filter((f) => f.severity === 'critical' || f.severity === 'high')
  process.stdout.write(JSON.stringify(blocking))
}

// review-verdict <file>: prints just the verdict string.
function reviewVerdict(raw) {
  process.stdout.write(JSON.parse(raw).verdict)
}

// findings-count <file>: prints how many findings are in the given array
// (used on the output of blocking-findings).
function findingsCount(raw) {
  process.stdout.write(String(JSON.parse(raw).length))
}

// findings-text <file>: human-readable rendering of a findings array, for
// feeding back into the lead-correction prompt template.
function findingsText(raw) {
  const findings = JSON.parse(raw)
  const lines = findings.map((f) =>
    `- [${f.severity}] ${f.file ?? '?'}:${f.line ?? '?'} ${f.problem}\n  reason: ${f.reason}\n  recommendation: ${f.recommendation}`,
  )
  process.stdout.write(lines.join('\n\n'))
}

// validation-summary <file>: one-line human-readable rollup of a
// build-validation-result JSON document.
function validationSummary(raw) {
  const r = JSON.parse(raw)
  if (r.commands.length === 0) {
    process.stdout.write('no validation commands were run')
    return
  }
  process.stdout.write(
    `${r.passed.length} passed, ${r.failed.length} failed, ${r.skipped.length} skipped ` +
    `(commands: ${r.commands.join('; ')})` +
    (r.failed.length > 0 ? `\nfailed: ${r.failed.join('; ')}` : ''),
  )
}

// get-field <file> <dot.path>: prints a string/number field from a JSON
// document (e.g. claude-mem's {"context": "...", "count": N} responses).
// Prints nothing (exit 0) when the path is missing or not a string/number —
// callers treat an empty result as "nothing to inject", not an error.
function getField(raw, dotPath) {
  let value
  try {
    value = JSON.parse(raw)
  } catch {
    return
  }
  for (const part of dotPath.split('.')) {
    if (value === null || typeof value !== 'object') { value = undefined; break }
    value = value[part]
  }
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
    process.stdout.write(String(value))
  }
}

const FILE_ARG_COMMANDS = new Set([
  'validate-review', 'blocking-findings', 'review-verdict', 'findings-count', 'findings-text', 'validation-summary',
])

async function main() {
  if (cmd === 'build-validation-result') return buildValidationResult()
  if (cmd === 'build-project-profile') return buildProjectProfile()
  if (cmd === 'project-id') {
    if (!args[0]) fail('project-id requires a root-path argument')
    return projectId(args[0])
  }
  if (cmd === 'append-event') {
    const [eventsPath, eventName, ...kvArgs] = args
    if (!eventsPath || !eventName) fail('append-event requires <events.jsonl path> <event_name> [key=value ...]')
    return appendEvent(eventsPath, eventName, kvArgs)
  }
  if (cmd === 'run-create') {
    const [path, ...kvArgs] = args
    if (!path) fail('run-create requires <run.json path> [key=value ...]')
    return runCreate(path, kvArgs)
  }
  if (cmd === 'run-update') {
    const [path, ...kvArgs] = args
    if (!path) fail('run-update requires <run.json path> [key=value ...]')
    return runUpdate(path, kvArgs)
  }
  if (cmd === 'build-object') return buildObject(args)
  if (cmd === 'inventory-build') return inventoryBuild()
  if (cmd === 'update-check-build') return updateCheckBuild()
  if (cmd === 'plan-build') return planBuild()
  if (cmd === 'benchmark-compare') {
    const [bl, cd, mc, mx] = args
    if (!bl || !cd) fail('benchmark-compare requires <baseline.json> <candidate.json> [maxCallsPct] [maxCtxPct]')
    return benchmarkCompare(bl, cd, Number(mc || 20), Number(mx || 25))
  }
  if (cmd === 'get-field') {
    const dotPath = args[0]
    if (!dotPath) fail('get-field requires a dot.path argument')
    const raw = await readStdin()
    return getField(raw, dotPath)
  }
  if (FILE_ARG_COMMANDS.has(cmd)) {
    const raw = args[0] ? readFileSync(args[0], 'utf8') : await readStdin()
    if (cmd === 'validate-review') return validateReview(raw)
    if (cmd === 'blocking-findings') return blockingFindings(raw)
    if (cmd === 'review-verdict') return reviewVerdict(raw)
    if (cmd === 'findings-count') return findingsCount(raw)
    if (cmd === 'findings-text') return findingsText(raw)
    return validationSummary(raw)
  }
  fail(`unknown subcommand: ${cmd}. Expected one of: build-validation-result, build-project-profile, get-field, ${[...FILE_ARG_COMMANDS].join(', ')}`)
}

main()
