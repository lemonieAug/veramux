/** Utilities for the Veramux DSH tool's process and journal integration. */
import { createHash } from 'node:crypto'
import { readFile, realpath, stat } from 'node:fs/promises'
import { basename, join } from 'node:path'

/** Canonicalize a workspace and reject paths that cannot be an orchestration target. */
export async function resolveWorkspace(workspace) {
  if (typeof workspace !== 'string' || workspace.trim() === '') throw new Error('workspace must be a non-empty path')
  let resolved
  try {
    resolved = await realpath(workspace)
  } catch {
    throw new Error(`workspace does not exist: ${workspace}`)
  }
  if (!(await stat(resolved)).isDirectory()) throw new Error(`workspace is not a directory: ${resolved}`)
  return resolved
}

/** Reject blank tasks before starting a run-owned workspace lock or journal. */
export function requireTask(task) {
  if (typeof task !== 'string' || task.trim() === '') throw new Error('task must be a non-empty string')
  return task
}

/** Fixed native-only invocation; user tool arguments never become command options. */
export function agentArgv(agentPath, workspace, task) {
  return [agentPath, '--engine', 'dsh', '--tool-mode', 'native', workspace, task]
}

/** Extract the run id emitted by the Veramux CLI, without treating its prose as the result. */
export function runIdFromOutput(output) {
  const match = /^run: ([0-9]{8}T[0-9]{6}Z-[0-9a-f]{6,})$/m.exec(output)
  return match?.[1]
}

/** Match Veramux's documented state path without relying on child-provided paths. */
export function finalPath(stateHome, workspace, runId) {
  const project = `${basename(workspace).replace(/[^A-Za-z0-9_-]/g, '_') || 'project'}-${createHash('sha1').update(workspace).digest('hex').slice(0, 8)}`
  return join(stateHome, 'runs', project, runId, 'final.json')
}

/** Read the authoritative final artifact only after the child process settled. */
export async function readFinalResult(stateHome, workspace, runId) {
  if (runId === undefined) return undefined
  try {
    const parsed = JSON.parse(await readFile(finalPath(stateHome, workspace, runId), 'utf8'))
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return undefined
    if (typeof parsed.status !== 'string' || typeof parsed.message !== 'string') return undefined
    return parsed
  } catch {
    return undefined
  }
}

/** Forward only Veramux's existing relay inputs and state/profile locations. */
export function childEnvironment(environment = process.env) {
  const names = [
    'DSH_HOME', 'AGENT_STATE_HOME', 'XDG_STATE_HOME',
    'VERAMUX_DEEPSEEK_API_KEY', 'VERAMUX_OPENAI_API_KEY',
    'VERAMUX_DEEPSEEK_MODEL', 'VERAMUX_OPENAI_MODEL',
  ]
  const forwarded = { DSH_TOOLS_MODE: 'native' }
  for (const name of names) {
    if (environment[name] !== undefined) forwarded[name] = environment[name]
  }
  return forwarded
}

/** Resolve the CLI's state root using the same precedence as lib/state_paths.sh. */
export function stateHome(environment = process.env) {
  if (environment.AGENT_STATE_HOME) return environment.AGENT_STATE_HOME
  if (environment.XDG_STATE_HOME) return join(environment.XDG_STATE_HOME, 'agent-stack')
  if (environment.HOME) return join(environment.HOME, '.local', 'state', 'agent-stack')
  throw new Error('cannot resolve Veramux state home: HOME is not set')
}
