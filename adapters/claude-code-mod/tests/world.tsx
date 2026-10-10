import { mock } from 'claude-code/testing'
import type { Engine, MockClock } from 'claude-code/testing'
import type { On, PaneOpenArgs, SessionMessage } from 'claude-code'

export const STORE = '/store'
export const SESSION = 's-1'
export const SURFACES = ['terminal', 'desktop'] as const

export const ARC_LIST = [
  { slug: 'alpha', title: 'Alpha arc', status: 'active' },
  { slug: 'beta', title: 'Beta arc', status: 'active' },
  { slug: 'gamma', title: 'Gamma arc', status: 'closed' },
]

export function snapshot(nextUpdate = 2_000_000_000) {
  return {
    schema_version: '1',
    generation: 7,
    next_update: nextUpdate,
    coordination_arcs: [
      { arc: 'alpha', status: 'active' },
      { arc: 'beta', status: 'active' },
      { arc: 'gamma', status: 'closed' },
    ],
    coordination_streams: [
      { arc: 'alpha', stream_id: '1', step: 'Read the board', status: 'done', verdict: 'full', work_item: 'alpha-one' },
      { arc: 'alpha', stream_id: '2', step: 'Draw the window', status: 'in-flight', verdict: '', work_item: 'alpha-two' },
      { arc: 'alpha', stream_id: '3', step: 'Ask the owner', status: 'blocked-on-input', verdict: '', work_item: null },
      { arc: 'alpha', stream_id: '4', step: 'Ship it', status: 'in-flight', verdict: '', work_item: null },
      { arc: 'beta', stream_id: '1', step: 'Only step', status: 'pending', verdict: '', work_item: null },
    ],
  }
}

export const ARC_SHOW = {
  slug: 'alpha',
  path: '_work/_arcs/alpha',
  brief: [
    { label: 'Landed', text: 'The board reads truthfully.' },
    { label: 'Surprises', text: '- None yet.' },
  ],
  decisions: [
    { text: 'Keep the chip to one row. It sits above the prompt in every bound session.', heading: 'Decisions so far' },
    { text: 'Read lore only through its commands.', heading: 'Decisions so far' },
  ],
  files: [
    { path: 'coordination.md', size: 2048, mtime: '2026-10-04T00:00:00Z' },
    { path: 'drafts/long.md', size: 25000, mtime: '2026-10-04T00:00:00Z' },
  ],
}

export const LONG_DOCUMENT = Array.from({ length: 500 }, (_, i) => `Line ${i} ${'x'.repeat(40)}`).join('\n')

const encoder = new TextEncoder()

// What `lore coordinate board --json` prints for alpha at a width.
export function boardJson(width: number) {
  const row = (id: string, rail: string, step: string, status: string) => {
    const lead = `${rail}  ${id}  ${step}`
    const text = lead + ' '.repeat(Math.max(1, width - lead.length - status.length)) + status
    return { stream_id: id, lines: [{ text, metadata_at: encoder.encode(text).length - encoder.encode(status).length }] }
  }
  return {
    arc: 'alpha',
    width,
    rows: [
      row('1', ' ✓─╮', 'Read the board', 'done'),
      row('2', ' │ ●', 'Draw the window', 'running'),
      row('3', ' ▲ │', 'Ask the owner', 'waiting on you'),
      row('4', ' ●─╯', 'Ship it', 'running'),
    ],
  }
}

export type Fixture = {
  active?: boolean
  isLoreMissing?: boolean
  boardExit?: number
  nextUpdate?: number
  history?: SessionMessage[]
  store?: Record<string, unknown>
}

export type World = {
  clock: MockClock
  runs: string[]
  reads: string[]
  commands: string[]
  opened: PaneOpenArgs[]
  closed: string[]
  store: Map<string, unknown>
  files: Record<string, string>
}

function ran(stdout: string, exitCode = 0) {
  return { value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
}

export function world(on: On, fixture: Fixture = {}): World {
  const clock = mock.clock(on, { now: 1_000_000 })
  const seen: World = {
    clock,
    runs: [],
    reads: [],
    commands: [],
    opened: [],
    closed: [],
    store: new Map(Object.entries(fixture.store ?? {})),
    files: {},
  }
  const files: Record<string, string> = {
    [`${STORE}/_coordination/display.json`]: JSON.stringify(snapshot(fixture.nextUpdate)),
    [`${STORE}/_work/_arcs/alpha/coordination.md`]: '# Ledger\n\nThe steps so far.',
    [`${STORE}/_work/_arcs/alpha/drafts/long.md`]: LONG_DOCUMENT,
  }

  seen.files = files
  const shown = new Set<string>()

  on('store.get', (_$, e) => ({ value: seen.store.get(e.key) }))
  on('store.set', (_$, e) => {
    seen.store.set(e.key, e.value)
    return { value: undefined }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: SESSION }))
  on('session.messages', () => ({ value: fixture.history ?? [] }))
  on('command.register', (_$, e) => {
    seen.commands.push(e.name)
    return { value: { command: e.name } }
  })
  on('ui.open', (_$, e) => {
    seen.opened.push(e)
    shown.add(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.close', (_$, e) => {
    seen.closed.push(e.id)
    shown.delete(e.id)
    return { value: undefined }
  })
  on('ui.panes', () => ({
    value: [...shown].map(id => ({ id, title: 'lore', isShown: true, isFocused: false, isPlaced: true })),
  }))
  on('ui.render', ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box key="engine" />
  })
  on('fs.read', (_$, e) => {
    seen.reads.push(e.path)
    const body = files[e.path]
    if (body === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: body }
  })
  on('process.run', (_$, e) => {
    const args = e.argv.slice(1).join(' ')
    seen.runs.push(args)
    if (fixture.isLoreMissing) throw new Error('spawn lore ENOENT')
    if (args.startsWith('active ')) {
      const isActive = fixture.active ?? true
      const reason = isActive ? 'ok' : 'harness-disabled'
      return ran(JSON.stringify({ active: isActive, harness: 'claude-code', store: STORE, reason }), isActive ? 0 : 1)
    }
    if (args === 'arc list --json') return ran(JSON.stringify(ARC_LIST))
    if (args === 'coordinate read --refresh --json') return ran(JSON.stringify(snapshot()))
    if (args.startsWith('coordinate board --arc alpha --width ')) {
      if (fixture.boardExit === 3) return ran('', 3)
      return ran(JSON.stringify(boardJson(Number(e.argv[6]))))
    }
    if (args === 'arc show alpha --json') return ran(JSON.stringify(ARC_SHOW))
    if (args === 'work show alpha-two --json') {
      return ran(JSON.stringify({ slug: 'alpha-two', title: 'Draw the window', plan_content: '# Plan\n\nDraw it.', notes_content: 'Drawn once.' }))
    }
    return ran('', 1)
  })
  return seen
}

export async function start($: Engine, clock: MockClock) {
  await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
  await clock.settle()
}

export function bash(command: string, text = ''): SessionMessage {
  return {
    role: 'assistant',
    text: '',
    toolUses: [{ tool_use_id: 'toolu_' + command.length, tool: 'Bash', input: { command }, text }],
  }
}

export const BAND = {
  component: 'AbovePrompt',
  props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 100, scroll: { offset: 0, bodyRows: 10 }, view: {} },
} as const

export function pane(requestId: string, bodyColumns: number) {
  return {
    component: 'Pane',
    requestId,
    props: { title: 'lore', isFocused: false, bodyColumns, placement: 'dock', scroll: { offset: 0, bodyRows: 60 }, view: {} },
  } as const
}
