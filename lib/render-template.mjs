#!/usr/bin/env node
// Renders a harness/prompts/*.md template by replacing {{KEY}} placeholders.
// Usage: render-template.mjs <template-file> KEY=<value-file> [KEY=<value-file> ...]
// Values are always read from files (never argv) so arbitrarily large diffs
// or findings text never hit an argv length limit before they reach dsh.
import { readFileSync } from 'node:fs'

const [, , templatePath, ...pairs] = process.argv
if (!templatePath) {
  process.stderr.write('usage: render-template.mjs <template-file> KEY=<value-file> ...\n')
  process.exit(2)
}

let text = readFileSync(templatePath, 'utf8')
for (const pair of pairs) {
  const idx = pair.indexOf('=')
  if (idx < 0) {
    process.stderr.write(`malformed argument (expected KEY=path): ${pair}\n`)
    process.exit(2)
  }
  const key = pair.slice(0, idx)
  const valuePath = pair.slice(idx + 1)
  const value = readFileSync(valuePath, 'utf8')
  text = text.split(`{{${key}}}`).join(value)
}
process.stdout.write(text)
