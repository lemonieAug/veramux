#!/usr/bin/env node
// Small, deliberately narrow JSON helpers for bash callers. Node is already
// a hard dependency of DeepSeek Harness itself, so this avoids adding jq or
// any other JSON tooling dependency (see README "Segurança"/architecture
// notes). This is NOT a general JSON framework: two subcommands only.
import { readFileSync } from 'node:fs'

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
  if (typeof value === 'string' || typeof value === 'number') {
    process.stdout.write(String(value))
  }
}

const FILE_ARG_COMMANDS = new Set([
  'validate-review', 'blocking-findings', 'review-verdict', 'findings-count', 'findings-text', 'validation-summary',
])

async function main() {
  if (cmd === 'build-validation-result') return buildValidationResult()
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
  fail(`unknown subcommand: ${cmd}. Expected one of: build-validation-result, get-field, ${[...FILE_ARG_COMMANDS].join(', ')}`)
}

main()
