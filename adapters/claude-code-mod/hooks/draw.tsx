import type { ElementTable, RenderElement } from 'claude-code'

import type {
  LoreArc,
  LoreDecision,
  LoreDetail,
  LoreFile,
  LorePopout,
  LoreRails,
  LoreStream,
  LoreTitle,
} from '../types'

export type Actions = {
  toggleWindow: () => Promise<void>
  close: () => Promise<void>
  pin: (slug: string) => Promise<void>
  toggleOpen: (key: string) => Promise<void>
  openDocument: (file: LoreFile) => Promise<void>
  openWorkItem: (slug: string) => Promise<void>
  closePopout: () => Promise<void>
}

const GLYPH: Record<string, string> = {
  done: '✓',
  'in-flight': '●',
  pending: '○',
  'blocked-on-input': '▲',
  dropped: '✕',
}

const CONTROL_COLUMNS = 7
const TEXT_MIN = 12
// Brief labels are the coordinator's own words; past this they are cut, not
// given a wider column.
const LABEL_MAX = 15

function glyph(stream: LoreStream): string {
  if (stream.status.startsWith('blocked-on:')) return '◈'
  return GLYPH[stream.status] ?? '?'
}

function words(stream: LoreStream): string {
  switch (stream.status) {
    case 'done':
      if (stream.verdict === 'partial') return 'done · partial'
      if (stream.verdict === 'none') return 'done · nothing landed'
      return 'done'
    case 'in-flight':
      return 'running'
    case 'pending':
      return 'queued'
    case 'blocked-on-input':
      return 'waiting on you'
    case 'dropped':
      return 'dropped'
  }
  if (stream.status.startsWith('blocked-on:')) return 'waiting on ' + stream.status.slice(11).trim()
  return stream.status
}

export type Tally = { done: number; total: number; running: number; waiting: number }

export function tally(arc: LoreArc): Tally {
  const counted = { done: 0, total: 0, running: 0, waiting: 0 }
  for (const stream of arc.streams) {
    if (stream.status === 'dropped') continue
    counted.total += 1
    if (stream.status === 'done') counted.done += 1
    if (stream.status === 'in-flight') counted.running += 1
    if (stream.status === 'blocked-on-input') counted.waiting += 1
  }
  return counted
}

export function titleOf(titles: LoreTitle[], slug: string): string {
  return titles.find(title => title.slug === slug)?.title ?? slug
}

export function cut(text: string, room: number): string {
  if (text.length <= room) return text
  if (room <= 1) return '…'
  return text.slice(0, room - 1) + '…'
}

export function firstSentence(text: string): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  return /^.*?[.!?](?=\s|$)/.exec(flat)?.[0] ?? flat
}

// One stream as a line of text, for when the board verb can't draw the graph.
function plainLine(stream: LoreStream, width: number): string {
  const lead = `${glyph(stream)} ${stream.id.padStart(2)}  `
  const tail = `  ${words(stream)}`
  const room = width - lead.length - tail.length
  if (room < TEXT_MIN) return cut(lead + words(stream), width)
  return lead + cut(stream.step, room).padEnd(room) + tail
}

export function drawChip(
  ui: ElementTable,
  arc: LoreArc,
  title: string,
  isWindowOpen: boolean,
  bodyColumns: number,
  actions: Actions,
): RenderElement {
  const { Box, Text, Button } = ui
  const { done, total, running, waiting } = tally(arc)
  const long = [` · ${done}/${total} done · ● ${running} running`, waiting > 0 ? ` · ▲ ${waiting} waiting on you` : '']
  const short = [` ● ${running}`, waiting > 0 ? ` ▲ ${waiting}` : '']
  const spare = (parts: string[]) => bodyColumns - 2 - CONTROL_COLUMNS - parts.join('').length
  const parts = spare(long) >= TEXT_MIN ? long : short
  return (
    <Box key="chip">
      <Text color="cyan">▣ </Text>
      <Text>{cut(title, Math.max(4, spare(parts)))}</Text>
      <Text dimColor>{parts[0]}</Text>
      {waiting > 0 ? <Text color="yellow">{parts[1]}</Text> : null}
      <Text> </Text>
      <Button key="toggle" label={isWindowOpen ? '▾' : '▴'} hotkey="l" onPress={actions.toggleWindow} />
    </Box>
  )
}

export type WindowData = {
  arcs: LoreArc[] | null
  error: string | null
  arc: LoreArc | null
  titles: LoreTitle[]
  rails: LoreRails | null
  detail: LoreDetail | null
  open: string[]
  width: number
  isTerminal: boolean
}

export type Control = { key: string; label: string; isClose: boolean; onPress: () => Promise<void> }

// The heading row every lore pane opens with: a title, a dim summary to its
// right and the close mark. The pane's own frame is the only border.
export function heading(
  ui: ElementTable,
  title: string,
  summary: RenderElement | null,
  control: Control,
  isTerminal: boolean,
): RenderElement {
  const { Box, Text, Button } = ui
  return (
    <Box key="heading" justifyContent="space-between">
      <Text weight="bold" size="heading" {...(isTerminal ? { color: 'cyan' } : {})} wrap="truncate-end">
        {title}
      </Text>
      <Box flexShrink={0} gap={1}>
        {summary}
        <Button
          key={control.key}
          plain
          dimColor
          label={control.label}
          {...(control.isClose ? { role: 'dismiss' as const } : {})}
          onPress={control.onPress}
        />
      </Box>
    </Box>
  )
}

export function drawWindow(ui: ElementTable, data: WindowData, actions: Actions): RenderElement {
  const { Box, Text } = ui
  const { arc } = data
  const title = arc ? titleOf(data.titles, arc.slug) : 'Arc'
  const frame = (summary: RenderElement | null, ...body: RenderElement[]) => (
    <Box flexDirection="column" paddingX={1}>
      {heading(ui, title, summary, { key: 'close', label: '×', isClose: true, onPress: actions.close }, data.isTerminal)}
      {body}
    </Box>
  )

  if (data.arcs === null) return frame(null, <Text dimColor>Reading the board…</Text>)
  if (data.error) return frame(null, <Text color="red">{data.error}</Text>)
  if (!arc) return frame(null, picker(ui, data.arcs, data.titles, data.width, actions))

  return frame(
    summaryOf(ui, arc, data.isTerminal),
    streams(ui, arc, data.rails, data.width, data.isTerminal, actions),
    sections(ui, data.detail, arc, data.open, data.width, actions),
  )
}

function summaryOf(ui: ElementTable, arc: LoreArc, isTerminal: boolean): RenderElement {
  const { Box, Text } = ui
  const { done, total, running, waiting } = tally(arc)
  return (
    <Box key="summary">
      <Text dimColor>
        {done}/{total} done{running > 0 ? ` · ${running} running` : ''}
      </Text>
      {waiting > 0 ? <Text {...(isTerminal ? { color: 'yellow' } : {})}> · ▲ {waiting}</Text> : null}
    </Box>
  )
}

function picker(ui: ElementTable, arcs: LoreArc[], titles: LoreTitle[], width: number, actions: Actions): RenderElement {
  const { Box, Text, Button } = ui
  return (
    <Box key="picker" flexDirection="column" marginTop={1}>
      <Text dimColor>No arc is bound to this session. Pin one:</Text>
      {arcs.length === 0 ? <Text dimColor>No active arcs.</Text> : null}
      {arcs.map((arc, i) => (
        <Button
          key={'pin:' + arc.slug}
          plain
          {...(i < 9 ? { hotkey: String(i + 1) } : {})}
          label={cut(titleOf(titles, arc.slug), width - 3)}
          onPress={() => actions.pin(arc.slug)}
        />
      ))}
    </Box>
  )
}

function statusColor(status: string, isTerminal: boolean): { color: string } | { dimColor: true } {
  if (status.includes('waiting on you')) return isTerminal ? { color: 'yellow' } : { color: 'warning' }
  return { dimColor: true }
}

// One rail line: the graph and step in the surface's monospace face, so the
// rails line up off the terminal too, and the status words in their colour.
function railLine(ui: ElementTable, text: string, wordsAt: number, isTerminal: boolean): RenderElement[] {
  const { Text } = ui
  if (wordsAt < 0) return [<Text mono>{text}</Text>]
  const status = text.slice(wordsAt)
  return [<Text mono>{text.slice(0, wordsAt)}</Text>, <Text mono {...statusColor(status, isTerminal)}>{status}</Text>]
}

function streams(
  ui: ElementTable,
  arc: LoreArc,
  rails: LoreRails | null,
  width: number,
  isTerminal: boolean,
  actions: Actions,
): RenderElement {
  const { Box, Text, Button } = ui
  const byId = new Map(arc.streams.map(stream => [stream.id, stream]))
  const drawn = rails && rails.slug === arc.slug && !rails.isOld && rails.rows.length > 0 ? rails : null
  const open = (stream: LoreStream) => () => actions.openWorkItem(stream.workItem ?? '')

  if (arc.streams.length === 0) {
    return (
      <Box key="streams" marginTop={1}>
        <Text dimColor>No streams yet.</Text>
      </Box>
    )
  }

  if (!drawn) {
    return (
      <Box key="streams" flexDirection="column" marginTop={1}>
        {arc.streams.map(stream => {
          const line = plainLine(stream, width)
          const at = line.lastIndexOf(words(stream))
          const parts = railLine(ui, line, at, isTerminal)
          return stream.workItem ? (
            <Button key={'stream:' + stream.id} plain onPress={open(stream)}>
              {parts}
            </Button>
          ) : (
            <Box key={'line:' + stream.id}>{parts}</Box>
          )
        })}
        {rails?.slug === arc.slug && rails.isOld ? <Text dimColor>run lore rebuild for the graph</Text> : null}
      </Box>
    )
  }

  return (
    <Box key="streams" flexDirection="column" marginTop={1}>
      {drawn.rows.flatMap(row => {
        const stream = byId.get(row.id)
        return row.lines.map((line, i) => {
          const parts = railLine(ui, line.text, line.wordsAt, isTerminal)
          return i === 0 && stream?.workItem ? (
            <Button key={'stream:' + row.id} plain onPress={open(stream)}>
              {parts}
            </Button>
          ) : (
            <Box key={`line:${row.id}:${i}`}>{parts}</Box>
          )
        })
      })}
    </Box>
  )
}

type Entry = { key: string; label: string; text: string }

// A list of collapsible entries: each one line until pressed, then its whole
// text. The Brief and the decisions both read this way, so the window stays a
// page of headlines until the person asks for more.
function entries(ui: ElementTable, items: Entry[], open: string[], width: number, actions: Actions): RenderElement[] {
  const { Box, Text, Button, Markdown } = ui
  const labelWidth = Math.min(LABEL_MAX, Math.max(0, ...items.map(item => item.label.length)))
  return items.map(item => {
    const first = firstSentence(item.text)
    const isOpen = open.includes(item.key)
    const label = item.label ? cut(item.label, labelWidth).padEnd(labelWidth) + '  ' : ''
    const room = Math.max(TEXT_MIN, width - 2 - label.length)
    const isWhole = first === item.text.replace(/\s+/g, ' ').trim() && first.length <= room
    const row = (
      <Button key={'toggle:' + item.key} plain onPress={() => actions.toggleOpen(item.key)}>
        <Text dimColor>{isWhole ? '•' : isOpen ? '▾' : '▸'} </Text>
        {label ? <Text color="cyan">{label}</Text> : null}
        <Text>{isOpen ? '' : cut(first, room)}</Text>
      </Button>
    )
    return (
      <Box key={item.key} flexDirection="column">
        {row}
        {isOpen ? (
          <Box paddingLeft={2}>
            <Markdown text={cut(item.text, 9_800)} />
          </Box>
        ) : null}
      </Box>
    )
  })
}

function decisionEntries(decisions: LoreDecision[]): Entry[] {
  const headings = new Set(decisions.map(decision => decision.heading))
  return decisions.map((decision, i) => ({
    key: 'decision:' + i,
    label: headings.size > 1 ? decision.heading : '',
    text: decision.text,
  }))
}

function sectionTitle(ui: ElementTable, text: string): RenderElement {
  const { Text } = ui
  return (
    <Text weight="semibold" dimColor>
      {text}
    </Text>
  )
}

function sections(
  ui: ElementTable,
  detail: LoreDetail | null,
  arc: LoreArc,
  open: string[],
  width: number,
  actions: Actions,
): RenderElement {
  const { Box, Text, Button } = ui
  if (!detail || detail.slug !== arc.slug) {
    return (
      <Box key="sections" marginTop={1}>
        <Text dimColor>Reading the arc…</Text>
      </Box>
    )
  }
  if (detail.error) {
    return (
      <Box key="sections" marginTop={1}>
        <Text color="red">{detail.error}</Text>
      </Box>
    )
  }
  const brief = detail.brief.map(field => ({ key: 'brief:' + field.label, label: field.label, text: field.text }))
  return (
    <Box key="sections" flexDirection="column">
      {brief.length > 0 ? (
        <Box key="brief" flexDirection="column" marginTop={1}>
          {sectionTitle(ui, 'Brief')}
          {entries(ui, brief, open, width, actions)}
        </Box>
      ) : null}
      {detail.decisions.length > 0 ? (
        <Box key="decisions" flexDirection="column" marginTop={1}>
          {sectionTitle(ui, 'Decisions')}
          {entries(ui, decisionEntries(detail.decisions), open, width, actions)}
        </Box>
      ) : null}
      {detail.files.length > 0 ? (
        <Box key="documents" flexDirection="column" marginTop={1}>
          {sectionTitle(ui, 'Documents')}
          <Box flexWrap="wrap" columnGap={2}>
            {detail.files.map(file => (
              <Button key={'doc:' + file.path} plain dimColor label={file.path} onPress={() => actions.openDocument(file)} />
            ))}
          </Box>
        </Box>
      ) : null}
    </Box>
  )
}

export function drawPopout(ui: ElementTable, shown: LorePopout | null, isTerminal: boolean, back: () => Promise<void>): RenderElement {
  const { Box, Text, Markdown, Code } = ui
  return (
    <Box flexDirection="column" paddingX={1}>
      {heading(
        ui,
        shown?.title ?? 'lore',
        null,
        { key: 'back', label: '← back', isClose: false, onPress: back },
        isTerminal,
      )}
      {shown?.source ? (
        <Text dimColor wrap="truncate-middle">
          {shown.source}
        </Text>
      ) : null}
      {(shown?.blocks ?? []).map((block, i) =>
        block.kind === 'markdown' ? <Markdown key={'page:' + i} text={block.text} /> : <Code source={block.text} />,
      )}
    </Box>
  )
}
