import type {
  LoreArc,
  LoreBlock,
  LoreBoard,
  LoreDetail,
  LorePopout,
  LoreRails,
  LoreTitle,
} from '../types'

export type Ran = { exitCode: number; stdout: string; isStdoutTruncated: boolean } | null

const SNAPSHOT_VERSION = '1'
// Markdown and Code each take at most 10,000 characters.
const BLOCK_ROOM = 9_800
const MAX_BLOCKS = 10

function parse(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}

function record(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {}
}

function list(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

function text(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function succeeded(ran: Ran): unknown {
  return ran?.exitCode === 0 ? parse(ran.stdout) : undefined
}

export function activeStoreOf(ran: Ran): string | null {
  if (!ran) return null
  const answer = record(parse(ran.stdout))
  return answer.active === true && typeof answer.store === 'string' && answer.store !== ''
    ? answer.store
    : null
}

export type Snapshot = Record<string, unknown>

export function snapshotOf(raw: string | null): Snapshot | null {
  if (raw === null) return null
  const snapshot = parse(raw)
  return snapshot === undefined ? null : record(snapshot)
}

export function refreshedSnapshotOf(ran: Ran): Snapshot | null {
  const snapshot = succeeded(ran)
  return snapshot === undefined ? null : record(snapshot)
}

export function isDue(snapshot: Snapshot | null, nowMs: number): boolean {
  const nextUpdate = snapshot?.next_update
  return !snapshot || typeof nextUpdate !== 'number' || nowMs / 1000 >= nextUpdate
}

export function boardOf(snapshot: Snapshot | null): LoreBoard {
  if (!snapshot) return { arcs: [], generation: -1, error: "Can't read the board." }
  if (String(snapshot.schema_version) !== SNAPSHOT_VERSION) {
    return { arcs: [], generation: -1, error: "This window doesn't know this board's format." }
  }
  const streams = list(snapshot.coordination_streams).map(record)
  const arcs: LoreArc[] = list(snapshot.coordination_arcs)
    .map(record)
    .filter(arc => arc.status === 'active' && typeof arc.arc === 'string')
    .map(arc => ({
      slug: text(arc.arc),
      streams: streams
        .filter(row => row.arc === arc.arc)
        .map(row => ({
          id: text(row.stream_id),
          step: text(row.step),
          status: text(row.status),
          verdict: text(row.verdict),
          workItem: typeof row.work_item === 'string' && row.work_item !== '' ? row.work_item : null,
        })),
    }))
  const generation = typeof snapshot.generation === 'number' ? snapshot.generation : -1
  return { arcs, generation, error: null }
}

export function titlesOf(ran: Ran): LoreTitle[] | null {
  const listed = succeeded(ran)
  if (listed === undefined) return null
  return list(listed)
    .map(record)
    .filter(arc => typeof arc.slug === 'string')
    .map(arc => ({ slug: text(arc.slug), title: text(arc.title) || text(arc.slug) }))
}

const encoder = new TextEncoder()
const decoder = new TextDecoder()

// The board verb reports where the status words start as a byte offset into
// the UTF-8 line; the drawing slices a JS string, which counts UTF-16 units.
function stringIndex(line: string, byteOffset: number): number {
  if (byteOffset < 0) return -1
  return decoder.decode(encoder.encode(line).slice(0, byteOffset)).length
}

export function railsOf(slug: string, width: number, generation: number, ran: Ran): LoreRails {
  if (ran?.exitCode === 3) return { slug, generation, width, rows: [], isOld: true }
  return {
    slug,
    generation,
    width,
    isOld: false,
    rows: list(record(succeeded(ran)).rows)
      .map(record)
      .map(row => ({
        id: text(row.stream_id),
        lines: list(row.lines)
          .map(record)
          .map(line => {
            const at = typeof line.metadata_at === 'number' ? line.metadata_at : -1
            return { text: text(line.text), wordsAt: stringIndex(text(line.text), at) }
          }),
      })),
  }
}

export function detailOf(slug: string, generation: number, ran: Ran): LoreDetail {
  const shown = succeeded(ran)
  if (shown === undefined) {
    return { slug, generation, path: '', brief: [], decisions: [], files: [], error: "Can't read this arc." }
  }
  const arc = record(shown)
  return {
    slug,
    generation,
    path: text(arc.path),
    brief: list(arc.brief)
      .map(record)
      .map(field => ({ label: text(field.label), text: text(field.text) })),
    decisions: list(arc.decisions)
      .map(record)
      .map(decision => ({ text: text(decision.text), heading: text(decision.heading) })),
    files: list(arc.files)
      .map(record)
      .filter(file => typeof file.path === 'string')
      .map(file => ({ path: text(file.path), size: typeof file.size === 'number' ? file.size : 0 })),
    error: null,
  }
}

const FENCE = /^\s*(```|~~~)/

// Splits a body into blocks under the element limit at line ends. A Markdown
// block cut inside a code fence closes it and the next block reopens it, so
// each block renders on its own. Past MAX_BLOCKS the last block ends with
// `continues`.
export function pages(kind: LoreBlock['kind'], body: string, continues: string): LoreBlock[] {
  const blocks: LoreBlock[] = []
  const lines = body.split('\n')
  let current: string | null = null
  let fence: string | null = null
  for (let i = 0; i < lines.length; i += 1) {
    let line = lines[i] ?? ''
    if (line.length > BLOCK_ROOM) {
      lines.splice(i + 1, 0, line.slice(BLOCK_ROOM))
      line = line.slice(0, BLOCK_ROOM)
    }
    if (current !== null && current.length + line.length + 1 > BLOCK_ROOM) {
      const isFenced = kind === 'markdown' && fence !== null
      blocks.push({ kind, text: isFenced ? `${current}\n${fence}` : current })
      if (blocks.length === MAX_BLOCKS) {
        const last = blocks[MAX_BLOCKS - 1]
        if (last) last.text = last.text.slice(0, BLOCK_ROOM - continues.length) + continues
        return blocks
      }
      current = isFenced ? (fence ?? '') : null
    }
    current = current === null ? line : `${current}\n${line}`
    const marker = kind === 'markdown' ? FENCE.exec(line)?.[1] : undefined
    if (marker) fence = fence === null ? marker : null
  }
  blocks.push({ kind, text: current ?? '' })
  return blocks
}

export function documentOf(title: string, source: string, body: string | null): LorePopout {
  if (body === null) return { title, source, blocks: [{ kind: 'markdown', text: "Can't read this file here." }] }
  const kind = /\.(md|markdown)$/i.test(title) ? 'markdown' : 'code'
  return { title, source, blocks: pages(kind, body, `\n\n… continues in ${source}`) }
}

export function workItemOf(slug: string, ran: Ran): LorePopout {
  const source = `lore work show ${slug}`
  if (ran?.isStdoutTruncated) {
    return { title: slug, source, blocks: [{ kind: 'markdown', text: 'This work item is too large to show here.' }] }
  }
  const shown = succeeded(ran)
  if (shown === undefined) {
    return { title: slug, source, blocks: [{ kind: 'markdown', text: "Can't read this work item." }] }
  }
  const item = record(shown)
  const plan = text(item.plan_content).trim()
  const notes = text(item.notes_content).trim()
  const continues = `\n\n… continues: ${source}`
  const blocks: LoreBlock[] = [
    ...(plan ? pages('markdown', plan, continues) : []),
    ...(notes ? pages('markdown', notes, continues) : []),
  ]
  if (blocks.length === 0) blocks.push({ kind: 'markdown', text: 'No plan or notes yet.' })
  return { title: text(item.title) || slug, source, blocks }
}

// An arc a Bash command touched through lore: its ledger path, or an arc verb
// naming it.
const COMMAND_MENTION = /(?:_work\/_arcs\/|lore arc (?:show|member (?:add|rm)|set|close|archive) )([a-z0-9][a-z0-9-]*)/g

// The one arc a result names for this session: `lore arc open`'s own line.
// Other output lists arcs (`lore arc list --json` prints every arc's path), so
// it binds nothing.
const OPENED = /\[arc\] Opened: ([a-z0-9][a-z0-9-]*)/g

function slugs(text: string, pattern: RegExp): string[] {
  const found: string[] = []
  for (const match of text.matchAll(pattern)) {
    if (match[1]) found.push(match[1])
  }
  return found
}

export function mentions(command: string, result: string): string[] {
  return [...slugs(command, COMMAND_MENTION), ...slugs(result, OPENED)]
}

export function boundArc(arcs: LoreArc[], seen: string[], pin: string | null): LoreArc | null {
  if (pin) {
    const chosen = arcs.find(arc => arc.slug === pin)
    if (chosen) return chosen
  }
  for (let i = seen.length - 1; i >= 0; i -= 1) {
    const chosen = arcs.find(arc => arc.slug === seen[i])
    if (chosen) return chosen
  }
  return null
}
