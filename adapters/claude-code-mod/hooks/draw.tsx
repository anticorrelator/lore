import type { ElementTable, RenderElement } from 'claude-code'

import type {
  LoreArc,
  LoreDecision,
  LoreDetail,
  LoreFile,
  LorePopout,
  LoreRails,
  LoreSize,
  LoreStream,
  LoreTitle,
} from '../types'

export type Actions = {
  toggleWindow: () => Promise<void>
  minimize: () => Promise<void>
  dismiss: () => Promise<void>
  toggleSize: () => Promise<void>
  pick: (isPicking: boolean) => Promise<void>
  pin: (slug: string) => Promise<void>
  toggleDecision: (key: string) => Promise<void>
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

const GLYPH_COLOR: Record<string, string> = {
  'in-flight': 'cyan',
  'blocked-on-input': 'yellow',
}

const CONTROL_COLUMNS = 7
const TEXT_MIN = 12

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

export function tally(arc: LoreArc): { running: number; waiting: number } {
  let running = 0
  let waiting = 0
  for (const stream of arc.streams) {
    if (stream.status === 'in-flight') running += 1
    if (stream.status === 'blocked-on-input') waiting += 1
  }
  return { running, waiting }
}

export function titleOf(titles: LoreTitle[], slug: string): string {
  return titles.find(title => title.slug === slug)?.title ?? slug
}

function cut(text: string, room: number): string {
  if (text.length <= room) return text
  if (room <= 1) return '…'
  return text.slice(0, room - 1) + '…'
}

function firstSentence(text: string): string {
  return /^[\s\S]*?[.!?](?=\s|$)/.exec(text)?.[0] ?? text
}

function kilobytes(size: number): string {
  return size < 1024 ? `${size} B` : `${Math.round(size / 1024)} KB`
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
  const { running, waiting } = tally(arc)
  const long = [` · ● ${running} running`, waiting > 0 ? ` · ◆ ${waiting} waiting on you` : '']
  const short = [` ● ${running}`, waiting > 0 ? ` ◆ ${waiting}` : '']
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
  size: LoreSize
  isPicking: boolean
  rails: LoreRails | null
  detail: LoreDetail | null
  openDecisions: string[]
  width: number
  isTerminal: boolean
}

export function drawWindow(ui: ElementTable, data: WindowData, actions: Actions): RenderElement {
  const { Box, Text, Button } = ui
  const { arc, isPicking } = data
  const heading = arc && !isPicking ? titleOf(data.titles, arc.slug) : 'lore'
  const frame = (...body: RenderElement[]) => (
    <Box flexDirection="column" borderStyle="round" paddingX={1}>
      <Box justifyContent="space-between">
        <Text bold color="cyan" wrap="truncate-end">
          {heading}
        </Text>
        <Box flexShrink={0}>
          <Button key="minimize" label="▾" hotkey="m" onPress={actions.minimize} />
          <Button key="size" label={data.size === 'compact' ? '□' : '▫'} hotkey="e" onPress={actions.toggleSize} />
          <Button key="close" label="×" hotkey="x" role="dismiss" onPress={actions.dismiss} />
        </Box>
      </Box>
      {body}
    </Box>
  )

  if (data.arcs === null) return frame(<Text dimColor>Reading the board…</Text>)
  if (data.error) return frame(<Text color="red">{data.error}</Text>)
  if (!arc || isPicking) return frame(picker(ui, data.arcs, data.titles, arc !== null, data.width, actions))

  const switcher = (
    <Box key="switch" marginTop={1}>
      <Button key="switch" plain dimColor hotkey="s" label="switch arc" onPress={() => actions.pick(true)} />
    </Box>
  )
  if (data.size === 'compact') {
    return frame(counts(ui, arc, data.isTerminal), glyphStrip(ui, arc, data.isTerminal), switcher)
  }
  return frame(
    streams(ui, arc, data.rails, data.width, data.isTerminal, actions),
    sections(ui, data.detail, arc, data.openDecisions, actions),
    switcher,
  )
}

function picker(
  ui: ElementTable,
  arcs: LoreArc[],
  titles: LoreTitle[],
  isBound: boolean,
  width: number,
  actions: Actions,
): RenderElement {
  const { Box, Text, Button } = ui
  return (
    <Box key="picker" flexDirection="column" marginTop={1}>
      <Text dimColor>{isBound ? 'Show another arc here:' : 'Pin an arc to this session:'}</Text>
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
      {isBound ? <Button key="back" label="back" hotkey="b" onPress={() => actions.pick(false)} /> : null}
    </Box>
  )
}

function counts(ui: ElementTable, arc: LoreArc, isTerminal: boolean): RenderElement {
  const { Box, Text } = ui
  const { running, waiting } = tally(arc)
  return (
    <Box key="counts" flexDirection="column" marginTop={1}>
      <Text dimColor>● {running} running</Text>
      {waiting > 0 ? <Text {...(isTerminal ? { color: 'yellow' } : {})}>◆ {waiting} waiting on you</Text> : null}
    </Box>
  )
}

function glyphStrip(ui: ElementTable, arc: LoreArc, isTerminal: boolean): RenderElement {
  const { Box, Text } = ui
  if (arc.streams.length === 0) {
    return (
      <Box key="strip" marginTop={1}>
        <Text dimColor>No streams yet.</Text>
      </Box>
    )
  }
  return (
    <Box key="strip" flexWrap="wrap" marginTop={1}>
      {arc.streams.map(stream => {
        const color = isTerminal ? GLYPH_COLOR[stream.status] : undefined
        return <Text {...(color ? { color } : { dimColor: stream.status === 'done' })}>{glyph(stream)} </Text>
      })}
    </Box>
  )
}

function railText(ui: ElementTable, text: string, wordsAt: number): RenderElement {
  const { Box, Text } = ui
  if (wordsAt < 0) return <Text wrap="truncate-end">{text}</Text>
  const status = text.slice(wordsAt)
  return (
    <Box>
      <Text wrap="truncate-end">{text.slice(0, wordsAt)}</Text>
      <Text {...(status.includes('waiting on you') ? { color: 'yellow' } : { dimColor: true })}>{status}</Text>
    </Box>
  )
}

function streams(
  ui: ElementTable,
  arc: LoreArc,
  rails: LoreRails | null,
  width: number,
  isTerminal: boolean,
  actions: Actions,
): RenderElement {
  const { Box, Text, Button, Code } = ui
  const byId = new Map(arc.streams.map(stream => [stream.id, stream]))
  const drawn = rails && rails.slug === arc.slug && !rails.isOld && rails.rows.length > 0 ? rails : null
  const open = (stream: LoreStream) => () => actions.openWorkItem(stream.workItem ?? '')

  if (!drawn) {
    return (
      <Box key="streams" flexDirection="column" marginTop={1}>
        <Text bold>Streams</Text>
        {arc.streams.length === 0 ? <Text dimColor>No streams yet.</Text> : null}
        {arc.streams.map(stream =>
          stream.workItem ? (
            <Button key={'stream:' + stream.id} plain label={plainLine(stream, width)} onPress={open(stream)} />
          ) : (
            <Text wrap="truncate-end">{plainLine(stream, width)}</Text>
          ),
        )}
        {rails?.slug === arc.slug && rails.isOld ? <Text dimColor>run lore rebuild for the graph</Text> : null}
      </Box>
    )
  }

  if (!isTerminal) {
    const openable = arc.streams.filter(stream => stream.workItem !== null)
    return (
      <Box key="streams" flexDirection="column" marginTop={1}>
        <Text bold>Streams</Text>
        <Code source={drawn.rows.flatMap(row => row.lines.map(line => line.text)).join('\n')} wrap="truncate-end" />
        {openable.length > 0 ? <Text dimColor>Open a step's work item:</Text> : null}
        {openable.map(stream => (
          <Button
            key={'stream:' + stream.id}
            plain
            label={cut(`${stream.id}  ${stream.step}`, width)}
            onPress={open(stream)}
          />
        ))}
      </Box>
    )
  }

  return (
    <Box key="streams" flexDirection="column" marginTop={1}>
      <Text bold>Streams</Text>
      {drawn.rows.flatMap(row => {
        const stream = byId.get(row.id)
        return row.lines.map((line, i) =>
          i === 0 && stream?.workItem ? (
            <Button key={'stream:' + row.id} plain label={line.text} onPress={open(stream)} />
          ) : (
            railText(ui, line.text, line.wordsAt)
          ),
        )
      })}
    </Box>
  )
}

type DecisionGroup = { heading: string; items: { key: string; text: string }[] }

function decisionGroups(decisions: LoreDecision[]): DecisionGroup[] {
  const groups: DecisionGroup[] = []
  decisions.forEach((decision, i) => {
    let group = groups.find(g => g.heading === decision.heading)
    if (!group) {
      group = { heading: decision.heading, items: [] }
      groups.push(group)
    }
    group.items.push({ key: 'decision:' + i, text: decision.text })
  })
  return groups
}

function sections(
  ui: ElementTable,
  detail: LoreDetail | null,
  arc: LoreArc,
  open: string[],
  actions: Actions,
): RenderElement {
  const { Box, Text, Button, Markdown } = ui
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
  return (
    <Box key="sections" flexDirection="column">
      {detail.brief.length > 0 ? (
        <Box key="brief" flexDirection="column" marginTop={1}>
          <Text bold>Brief</Text>
          {detail.brief.map(field => (
            <Box key={'brief:' + field.label} flexDirection="column">
              <Text color="cyan">{field.label}</Text>
              <Markdown text={cut(field.text, 9_800)} />
            </Box>
          ))}
        </Box>
      ) : null}
      {detail.decisions.length > 0 ? (
        <Box key="decisions" flexDirection="column" marginTop={1}>
          <Text bold>Decisions</Text>
          {decisionGroups(detail.decisions).map(group => (
            <Box key={'group:' + group.heading} flexDirection="column">
              {group.heading ? <Text color="cyan">{group.heading}</Text> : null}
              {group.items.map(item => {
                const first = firstSentence(item.text)
                const isOpen = open.includes(item.key)
                return (
                  <Box key={item.key}>
                    {first === item.text ? (
                      <Text dimColor>•</Text>
                    ) : (
                      <Button
                        key={'toggle:' + item.key}
                        plain
                        label={isOpen ? '▾' : '▸'}
                        onPress={() => actions.toggleDecision(item.key)}
                      />
                    )}
                    <Text> {isOpen ? item.text : first}</Text>
                  </Box>
                )
              })}
            </Box>
          ))}
        </Box>
      ) : null}
      {detail.files.length > 0 ? (
        <Box key="documents" flexDirection="column" marginTop={1}>
          <Text bold>Documents</Text>
          {detail.files.map(file => (
            <Button
              key={'doc:' + file.path}
              plain
              label={`${file.path}  ${kilobytes(file.size)}`}
              onPress={() => actions.openDocument(file)}
            />
          ))}
        </Box>
      ) : null}
    </Box>
  )
}

export function drawPopout(ui: ElementTable, shown: LorePopout | null, actions: Actions): RenderElement {
  const { Box, Text, Button, Markdown, Code } = ui
  return (
    <Box flexDirection="column" borderStyle="round" paddingX={1}>
      <Box justifyContent="space-between">
        <Text bold wrap="truncate-end">
          {shown?.title ?? 'lore'}
        </Text>
        <Button key="close" label="×" hotkey="x" role="dismiss" onPress={actions.closePopout} />
      </Box>
      {shown?.source ? <Text dimColor wrap="truncate-middle">{shown.source}</Text> : null}
      {(shown?.blocks ?? []).map((block, i) =>
        block.kind === 'markdown' ? <Markdown key={'page:' + i} text={block.text} /> : <Code source={block.text} />,
      )}
    </Box>
  )
}
