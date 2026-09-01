import assert from 'node:assert/strict'
import { mkdtemp, mkdir, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { apply } from '../src/index.js'
import { finalPath } from '../src/runtime.js'

function registeredTool(config, subprocess) {
  const tools = []
  apply({
    effect(callback) { return callback() },
    tools: { register(tool) { tools.push(tool); return () => {} } },
    subprocess,
  }, config)
  assert.equal(tools.length, 1)
  return tools[0]
}

test('bundle metadata and patch expose only veramux_run', async () => {
  const root = new URL('..', import.meta.url)
  const manifest = JSON.parse(await readFile(new URL('package.json', root), 'utf8'))
  const patch = await readFile(new URL('cordis.patch.yml', root), 'utf8')
  assert.equal(manifest.dsh.bundle.patch, './cordis.patch.yml')
  assert.match(patch, /name: veramux-dsh-plugin/)
  assert.doesNotMatch(patch, /claude|codex|programmatic/i)
})

test('registers veramux_run and propagates an authoritative successful final result', async () => {
  const workspace = await mkdtemp(join(tmpdir(), 'veramux-workspace-'))
  const state = await mkdtemp(join(tmpdir(), 'veramux-state-'))
  const runId = '20260831T120000Z-abcdef'
  const final = finalPath(state, workspace, runId)
  await mkdir(join(final, '..'), { recursive: true })
  await writeFile(final, JSON.stringify({ status: 'completed', run_id: runId, message: 'approved (round 1)' }))
  const calls = []
  const tool = registeredTool(
    { agentPath: '/fixtures/agent', graceMs: 500, outputMaxBytes: 1024, outputSpillMaxBytes: 2048 },
    {
      async resolveExecutable(command) { assert.equal(command, '/fixtures/agent'); return command },
      spawn(spec) {
        calls.push(spec)
        return {
          done: Promise.resolve({ exitCode: 0, signal: null }),
          waitForExit: async () => true,
          collected: {
            stdout: { readFrom: () => ({ text: `run: ${runId}\n`, nextOffset: 0, lossy: false }) },
            stderr: { readFrom: () => ({ text: '', nextOffset: 0, lossy: false }) },
          },
        }
      },
    },
  )
  const prior = process.env.AGENT_STATE_HOME
  process.env.AGENT_STATE_HOME = state
  try {
    const value = await tool.execute({ workspace, task: 'Fix issue; echo injected' }, { signal: new AbortController().signal })
    assert.deepEqual(value, { status: 'completed', message: 'approved (round 1)', exit_code: 0, run_id: runId })
  } finally {
    if (prior === undefined) delete process.env.AGENT_STATE_HOME
    else process.env.AGENT_STATE_HOME = prior
  }
  assert.deepEqual(calls[0].argv, ['/fixtures/agent', '--engine', 'dsh', '--tool-mode', 'native', workspace, 'Fix issue; echo injected'])
  assert.equal(calls[0].cwd, workspace)
  assert.equal(calls[0].env.DSH_TOOLS_MODE, 'native')
})

test('returns cancellation after the managed child settles', async () => {
  const workspace = await mkdtemp(join(tmpdir(), 'veramux-workspace-'))
  let waited = false
  const tool = registeredTool(
    { agentPath: '/fixtures/agent', graceMs: 500, outputMaxBytes: 1024, outputSpillMaxBytes: 2048 },
    {
      async resolveExecutable() { return '/fixtures/agent' },
      spawn() {
        return {
          done: Promise.resolve({ exitCode: null, signal: 'SIGTERM' }),
          waitForExit: async () => { waited = true; return true },
          collected: {
            stdout: { readFrom: () => ({ text: '', nextOffset: 0, lossy: false }) },
            stderr: { readFrom: () => ({ text: '', nextOffset: 0, lossy: false }) },
          },
        }
      },
    },
  )
  const controller = new AbortController()
  controller.abort()
  assert.deepEqual(await tool.execute({ workspace, task: 'cancel' }, { signal: controller.signal }), { status: 'cancelled', message: 'Veramux run cancelled' })
  assert.equal(waited, true)
})
