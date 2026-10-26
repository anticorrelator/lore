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

// Two open reviews as `lore followup list --json` lists them, plus a follow-up
// that is no review; review-a is the newer.
export function reviewList() {
  return [
    { id: 'retro-note', title: 'A retro note', status: 'open', source: 'retro', attachments: [], updated: '2026-10-05T00:00:00Z' },
    { id: 'review-b', title: 'Review: Older change (#8)', status: 'open', source: 'pr-review', attachments: [{ type: 'pr', ref: '#8' }], updated: '2026-10-01T00:00:00Z' },
    { id: 'review-a', title: 'Review: Newer change (#7)', status: 'open', source: 'pr-review', attachments: [{ type: 'pr', ref: '#7' }], updated: '2026-10-04T00:00:00Z' },
  ]
}

export type ReviewFixture = {
  proposed_comments: Record<string, unknown> | unknown[] | null
  lens_findings: Record<string, unknown> | null
}

export function reviewFixture(pr: number): ReviewFixture {
  return {
    proposed_comments: {
      pr,
      owner: 'o',
      repo: 'r',
      head_sha: 'abc',
      comments: [
        { path: 'a.py', line: 3, title: 'Guard drops the error', finding_ordinal: 1, body: 'The guard returns early. The error is lost.' },
        { path: 'b.py', line: 9, title: 'Name says less than it does', finding_ordinal: 2, body: 'Rename it.', selected: false },
      ],
      review_body: 'Two notes on the change.',
      review_body_selected: true,
      review_event: 'COMMENT',
    },
    lens_findings: null,
  }
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
  arc?: string
  mtimes?: Record<string, number>
  reviews?: Record<string, unknown>[]
  review?: Record<string, ReviewFixture>
  postExit?: number
  isLoreMissing?: boolean
  boardExit?: number
  nextUpdate?: number
  history?: SessionMessage[]
  store?: Record<string, unknown>
  // This plugin's panes already open at session start, and the dock's shown
  // pane, which may be another's (the engine's diff panel, say).
  panes?: string[]
  front?: string
}

export type World = {
  clock: MockClock
  runs: string[]
  stdins: string[]
  toasts: string[]
  fills: string[]
  listed: Record<string, unknown>[]
  review: Record<string, ReviewFixture>
  reads: string[]
  commands: string[]
  opened: PaneOpenArgs[]
  closed: string[]
  dock: { panes: string[]; front: string | null }
  store: Map<string, unknown>
  files: Record<string, string>
}

function ran(stdout: string, exitCode = 0, stderr = '') {
  return { value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false } }
}

function view(id: string, entry: Record<string, unknown> | undefined, held: ReviewFixture) {
  return { id, title: entry?.title ?? id, source: 'pr-review', status: 'open', attachments: entry?.attachments ?? [], finding_content: `# ${String(entry?.title ?? id)}\n\nThe whole report.`, ...held }
}

// The edit-review verb as the fixture holds it: the changes the panel asks
// for, made to the review it will read back.
function editReview(held: ReviewFixture, argv: readonly string[], stdin: string | undefined): boolean {
  const review = held.proposed_comments
  if (!review || Array.isArray(review)) return false
  const comments = review.comments as Record<string, unknown>[]
  const findings = (held.lens_findings?.findings ?? []) as Record<string, unknown>[]
  const at = (flag: string) => argv[argv.indexOf(flag) + 1] ?? ''
  const selected = argv.includes('--select') ? true : argv.includes('--deselect') ? false : undefined
  const body = argv.includes('--body-file') ? stdin : undefined
  const apply = (item: Record<string, unknown> | undefined) => {
    if (!item) return false
    if (selected !== undefined) item.selected = selected
    if (body !== undefined) item.body = body
    return true
  }
  if (argv.includes('--event')) review.review_event = at('--event')
  if (argv.includes('--comment')) return apply(comments[Number(at('--comment'))])
  if (argv.includes('--finding')) return apply(findings[Number(at('--finding'))])
  if (argv.includes('--all-comments')) comments.forEach(apply)
  if (argv.includes('--all-findings')) findings.forEach(apply)
  if (argv.includes('--general')) {
    if (selected !== undefined) review.review_body_selected = selected
    if (body !== undefined) review.review_body = body
  }
  return true
}

export function world(on: On, fixture: Fixture = {}): World {
  const clock = mock.clock(on, { now: 1_000_000 })
  const seen: World = {
    clock,
    runs: [],
    stdins: [],
    toasts: [],
    fills: [],
    listed: fixture.reviews ?? [],
    review: fixture.review ?? { 'review-a': reviewFixture(7), 'review-b': reviewFixture(8) },
    reads: [],
    commands: [],
    opened: [],
    closed: [],
    dock: { panes: [...(fixture.panes ?? [])], front: fixture.front ?? fixture.panes?.at(-1) ?? null },
    store: new Map(Object.entries(fixture.store ?? {})),
    files: {},
  }
  const files: Record<string, string> = {
    [`${STORE}/_coordination/display.json`]: JSON.stringify(snapshot(fixture.nextUpdate)),
    [`${STORE}/_work/_arcs/alpha/coordination.md`]: '# Ledger\n\nThe steps so far.',
    [`${STORE}/_work/_arcs/alpha/drafts/long.md`]: LONG_DOCUMENT,
  }

  seen.files = files
  // The dock as the engine keeps it: one pane shown, the rest tabs behind it.
  // A new pane comes to the front; opening an open one only retitles it unless
  // it asks for the keyboard, which raises it.
  const dock = seen.dock

  on('store.get', (_$, e) => ({ value: seen.store.get(e.key) }))
  on('store.set', (_$, e) => {
    seen.store.set(e.key, e.value)
    return { value: undefined }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: SESSION }))
  on('session.messages', () => ({ value: fixture.history ?? [] }))
  on('ui.toast', (_$, e) => {
    seen.toasts.push(e.text)
    return { value: undefined }
  })
  on('prompt.fill', (_$, e) => {
    seen.fills.push(e.text)
    return { isFilled: true }
  })
  on('command.register', (_$, e) => {
    seen.commands.push(e.name)
    return { value: { command: e.name } }
  })
  on('ui.open', (_$, e) => {
    seen.opened.push(e)
    if (!dock.panes.includes(e.id)) {
      dock.panes.push(e.id)
      dock.front = e.id
    } else if (e.focus) {
      dock.front = e.id
    }
    return { value: { isPlaced: true } }
  })
  on('ui.close', (_$, e) => {
    seen.closed.push(e.id)
    dock.panes = dock.panes.filter(id => id !== e.id)
    if (dock.front === e.id) dock.front = dock.panes.at(-1) ?? null
    return { value: undefined }
  })
  on('ui.panes', () => ({
    value: dock.panes.map(id => ({ id, title: 'lore', isShown: dock.front === id, isFocused: false, isPlaced: true })),
  }))
  on('ui.render', ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box key="engine" />
  })
  on('fs.stat', (_$, e) => {
    const mtimeMs = fixture.mtimes?.[e.path]
    if (mtimeMs === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: { kind: 'file', size: 0, mtimeMs, isLink: false } }
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
    if (e.init?.stdin !== undefined) seen.stdins.push(e.init.stdin)
    if (fixture.isLoreMissing) throw new Error('spawn lore ENOENT')
    if (args.startsWith('active ')) {
      const isActive = fixture.active ?? true
      const reason = isActive ? 'ok' : 'harness-disabled'
      return ran(JSON.stringify({ active: isActive, harness: 'claude-code', store: STORE, reason, arc: fixture.arc ?? null }), isActive ? 0 : 1)
    }
    if (args === 'arc list --json') return ran(JSON.stringify(ARC_LIST))
    if (args === 'followup list --json') return ran(JSON.stringify(seen.listed))
    const followup = /^followup (?:view --json|edit-review|post-review|update) ([a-z0-9-]+)/.exec(args)?.[1] ?? /--followup-id ([a-z0-9-]+)/.exec(args)?.[1]
    const held = followup ? seen.review[followup] : undefined
    const settled = () => {
      seen.listed = seen.listed.filter(entry => entry.id !== followup)
    }
    if (followup && held) {
      if (args.startsWith('followup view --json ')) return ran(JSON.stringify(view(followup, seen.listed.find(entry => entry.id === followup), held)))
      if (args.startsWith('followup edit-review ')) {
        if (!editReview(held, e.argv, e.init?.stdin)) return ran(JSON.stringify({ error: 'no comment at position 9' }), 1)
        return ran(JSON.stringify({ id: followup, ...held }))
      }
      if (args === `followup post-review ${followup} --dry-run`) return ran('[post-proposed-review] DRY RUN\nEvent: COMMENT\nInline comments: 1')
      if (args === `followup post-review ${followup}`) {
        if (fixture.postExit) return ran('', fixture.postExit, '[post-proposed-review] ERROR: head moved and two comments are lost')
        return ran('[post-proposed-review] Posted: https://github.com/o/r/pull/7#pullrequestreview-1\n[post-proposed-review] Outcomes persisted to sidecar')
      }
      if (args === `followup update ${followup} --status reviewed`) {
        settled()
        return ran('{}')
      }
      if (args.startsWith('followup dismiss ')) {
        settled()
        return ran(`[followup] Dismissed: ${followup}`)
      }
      if (args.startsWith('followup promote ')) {
        settled()
        return ran(`[followup] Promoted: ${followup} → work item 'Fix the guard' (fix-the-guard)`)
      }
    }
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
