/** DSH Web tool that delegates deterministic engineering runs to the Veramux CLI. */
import { defineTool } from '@deepseek-ai/dsh-tools'
import z from '@deepseek-ai/schemastery'
import { agentArgv, childEnvironment, readFinalResult, requireTask, resolveWorkspace, runIdFromOutput, stateHome } from './runtime.js'

export const name = 'veramux-dsh-plugin'
export const inject = ['tools', 'subprocess']

/** Deployment values for the trusted local Veramux CLI integration. */
export const Config = z.object({
  agentPath: z.string().default('agent'),
  graceMs: z.number().step(1).min(1).default(10_000),
  outputMaxBytes: z.number().step(1).min(1).default(1_048_576),
  outputSpillMaxBytes: z.number().step(1).min(1).default(4_194_304),
})

function renderedResult(value) {
  const details = value.run_id === undefined ? '' : ` (run ${value.run_id})`
  return [{ type: 'text', text: `${value.status}: ${value.message}${details}` }]
}

/** Register the only Web-visible Veramux capability. */
export function apply(ctx, config) {
  ctx.effect(() => ctx.tools.register(defineTool({
    name: 'veramux_run',
    description: 'Run Veramux’s deterministic engineering pipeline for a workspace and task. Veramux alone selects the private Claude Code lead and Codex reviewer profiles, validation, risk policy, baseline, and correction rounds.',
    parameters: {
      workspace: { type: 'string', required: true, description: 'Existing workspace directory to operate on.' },
      task: { type: 'string', required: true, description: 'Non-empty engineering task for Veramux.' },
    },
    output: {
      schema: {
        type: 'object', additionalProperties: false, properties: {
          status: { type: 'string', required: true, enum: ['completed', 'failed', 'cancelled'] },
          message: { type: 'string', required: true },
          exit_code: { type: 'number' },
          run_id: { type: 'string' },
        },
      },
      render: (_args, value) => renderedResult(value),
    },
    async execute(args, exec) {
      const workspace = await resolveWorkspace(args.workspace)
      const task = requireTask(args.task)
      const executable = await ctx.subprocess.resolveExecutable(config.agentPath, childEnvironment(), exec.signal)
      const handle = ctx.subprocess.spawn({
        argv: agentArgv(executable, workspace, task),
        cwd: workspace,
        stdio: {
          stdin: 'ignore',
          stdout: { maxBytes: config.outputMaxBytes, spill: { maxBytes: config.outputSpillMaxBytes } },
          stderr: { maxBytes: config.outputMaxBytes, spill: { maxBytes: config.outputSpillMaxBytes } },
        },
        graceMs: config.graceMs,
        signal: exec.signal,
        env: childEnvironment(),
      })
      const outcome = await handle.done
      await handle.waitForExit()
      const stdout = handle.collected.stdout?.readFrom(0).text ?? ''
      const stderr = handle.collected.stderr?.readFrom(0).text ?? ''
      const runId = runIdFromOutput(`${stdout}\n${stderr}`)
      if (exec.signal.aborted) {
        return { status: 'cancelled', message: 'Veramux run cancelled', ...(runId === undefined ? {} : { run_id: runId }) }
      }
      const final = await readFinalResult(stateHome(), workspace, runId)
      if (final !== undefined) {
        return {
          status: final.status === 'completed' ? 'completed' : final.status === 'cancelled' ? 'cancelled' : 'failed',
          message: final.message,
          ...(outcome.exitCode === null ? {} : { exit_code: outcome.exitCode }),
          ...(runId === undefined ? {} : { run_id: runId }),
        }
      }
      return {
        status: outcome.exitCode === 0 ? 'completed' : 'failed',
        message: outcome.exitCode === 0 ? 'Veramux completed without a final artifact' : 'Veramux exited without a final artifact',
        ...(outcome.exitCode === null ? {} : { exit_code: outcome.exitCode }),
        ...(runId === undefined ? {} : { run_id: runId }),
      }
    },
    presentCall: args => ({ card: 'generic', title: 'Run Veramux', kind: 'execute', rawInput: args.task, locations: [{ path: args.workspace }] }),
  }), 'veramux: tool'))
}
