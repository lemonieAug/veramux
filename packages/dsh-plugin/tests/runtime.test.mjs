import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { agentArgv, childEnvironment, finalPath, readFinalResult, requireTask, resolveWorkspace, runIdFromOutput } from '../src/runtime.js'

test('canonicalizes existing workspace directories', async () => {
  const root = await mkdtemp(join(tmpdir(), 'veramux-plugin-'))
  assert.equal(await resolveWorkspace(root), await resolveWorkspace(`${root}/.`))
  await assert.rejects(resolveWorkspace(join(root, 'missing')), /does not exist/)
  const file = join(root, 'file')
  await writeFile(file, '')
  await assert.rejects(resolveWorkspace(file), /not a directory/)
})

test('rejects blank tasks and fixes the native-only argv', () => {
  assert.throws(() => requireTask('  \n'), /non-empty/)
  assert.deepEqual(agentArgv('/opt/veramux/agent', '/tmp/a;touch-pwned', '--tool-mode programmatic'), [
    '/opt/veramux/agent', '--engine', 'dsh', '--tool-mode', 'native', '/tmp/a;touch-pwned', '--tool-mode programmatic',
  ])
})

test('reads only the deterministic final artifact', async () => {
  const state = await mkdtemp(join(tmpdir(), 'veramux-state-'))
  const workspace = '/tmp/workspace'
  const runId = '20260831T120000Z-abcdef'
  const path = finalPath(state, workspace, runId)
  await mkdir(join(path, '..'), { recursive: true })
  await writeFile(path, JSON.stringify({ status: 'completed', run_id: runId, message: 'approved (round 1)' }))
  assert.deepEqual(await readFinalResult(state, workspace, runId), { status: 'completed', run_id: runId, message: 'approved (round 1)' })
  assert.equal(runIdFromOutput('lead text\nrun: 20260831T120000Z-abcdef\n'), runId)
})

test('forwards only the existing relay and location inputs', () => {
  const env = childEnvironment({ HOME: '/home/test', VERAMUX_DEEPSEEK_API_KEY: 'secret', OPENAI_API_KEY: 'must-not-pass', DSH_HOME: '/dsh' })
  assert.equal(env.DSH_TOOLS_MODE, 'native')
  assert.equal(env.VERAMUX_DEEPSEEK_API_KEY, 'secret')
  assert.equal(env.OPENAI_API_KEY, undefined)
  assert.equal(env.DSH_HOME, '/dsh')
})
