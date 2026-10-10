import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { LoreArc, LoreFile, LorePopout, LoreSize } from '../types'
import type { Actions } from './draw'
import { drawChip, drawPopout, drawWindow, titleOf } from './draw'
import type { Ran, Snapshot } from './parse'
import {
  activeStoreOf,
  boardOf,
  boundArc,
  detailOf,
  documentOf,
  isDue,
  mentions,
  railsOf,
  refreshedSnapshotOf,
  snapshotOf,
  titlesOf,
  workItemOf,
} from './parse'

const WINDOW = 'lore-arcs'
const POLL_MS = 30_000
// One width for the life of the session: resizing the dock reflows the whole
// conversation, so the window is sized once and the person's own drag wins after.
const WINDOW_COLUMNS = 64
let isSized = false

const store = atom({ plugin: 'lore', key: 'store' } as const, null)
const board = atom({ plugin: 'lore', key: 'board' } as const, null)
const titles = atom({ plugin: 'lore', key: 'titles' } as const, [])
const candidates = atom({ plugin: 'lore', key: 'candidates' } as const, [])
const pinned = atom({ plugin: 'lore', key: 'pinned' } as const, null)
const isOpen = atom({ plugin: 'lore', key: 'isOpen' } as const, false)
const isDismissed = atom({ plugin: 'lore', key: 'isDismissed' } as const, false)
const isPicking = atom({ plugin: 'lore', key: 'isPicking' } as const, false)
const size = atom({ plugin: 'lore', key: 'size' } as const, 'compact')
const rails = atom({ plugin: 'lore', key: 'rails' } as const, null)
const detail = atom({ plugin: 'lore', key: 'detail' } as const, null)
const openDecisions = atom({ plugin: 'lore', key: 'openDecisions' } as const, [])
const popout = atom({ plugin: 'lore', key: 'popout' } as const, null)

// The window body's width at its last drawing: the board verb renders rails to
// it, and only a drawing knows it.
let paneWidth = 0
let isPolling = false
const inflight = new Set<string>()

// Work started for later, a poll or a refetch: a reload or an ended session
// can cut it off mid-call, and nothing waits on it to hear that.
function detach(work: Promise<void>): void {
  work.catch(() => undefined)
}

async function lore($: EngineInterface, args: readonly string[], timeoutMs: number): Promise<Ran> {
  try {
    return await $.process.run(['lore', ...args], { timeoutMs })
  } catch {
    return null
  }
}

async function remember($: EngineInterface, slugs: string[]): Promise<void> {
  if (slugs.length === 0) return
  await update($, candidates, prior => [...prior.filter(s => !slugs.includes(s)), ...slugs].slice(-20))
}

async function pinKey($: EngineInterface): Promise<string> {
  return 'pin:' + (await $.session.id())
}

async function currentArc($: EngineInterface): Promise<LoreArc | null> {
  const shown = await read($, board)
  return shown ? boundArc(shown.arcs, await read($, candidates), await read($, pinned)) : null
}

async function poll($: EngineInterface): Promise<void> {
  if (isPolling) return
  isPolling = true
  try {
    const dir = await read($, store)
    if (!dir) return
    const isShown =
      (await read($, isOpen)) ||
      (!(await read($, isDismissed)) && ((await read($, pinned)) !== null || (await read($, candidates)).length > 0))
    if (!isShown) {
      // Nothing is drawn, so the board is not refreshed: the file as it stands
      // is enough to say whether there is an arc to offer /arcs for.
      if (!isOffered) await offerArcs($, boardOf(await readSnapshot($, dir)).arcs)
      return
    }

    let snapshot = await readSnapshot($, dir)
    if (isDue(snapshot, await $.clock.now())) {
      snapshot = refreshedSnapshotOf(await lore($, ['coordinate', 'read', '--refresh', '--json'], 30_000)) ?? snapshot
    }
    const fresh = boardOf(snapshot)
    await offerArcs($, fresh.arcs)
    const mine = boundArc(fresh.arcs, await read($, candidates), await read($, pinned))
    const key = JSON.stringify({ slugs: fresh.arcs.map(arc => arc.slug), mine, error: fresh.error })
    if (key !== lastBoardKey || (await read($, board)) === null) {
      lastBoardKey = key
      await update($, board, () => fresh)
    }
    if (mine) {
      const stamp = await ledgerStamp($, dir, mine.slug)
      if (stamp !== lastLedgerStamp) {
        lastLedgerStamp = stamp
        isDetailDirty = true
      }
    }

    const known = new Set((await read($, titles)).map(title => title.slug))
    if (fresh.arcs.some(arc => !known.has(arc.slug))) {
      const listed = titlesOf(await lore($, ['arc', 'list', '--json'], 20_000))
      if (listed) await update($, titles, () => listed)
    }
    await sync($)
  } finally {
    isPolling = false
  }
}

async function readSnapshot($: EngineInterface, dir: string): Promise<Snapshot | null> {
  try {
    const text = await $.fs.read(`${dir}/_coordination/display.json`)
    return snapshotOf(typeof text === 'string' ? text : null)
  } catch {
    return null
  }
}

// /arcs is offered once there is an active arc to show, so a lore store with
// none gains no command. The engine has no way to withdraw one, so it stays.
let isOffered = false

async function offerArcs($: EngineInterface, arcs: readonly LoreArc[]): Promise<void> {
  if (isOffered || arcs.length === 0) return
  isOffered = true
  await $.command.register({ name: 'arcs', description: "Open or close lore's arc window" })
}

let lastBoardKey = ''
let lastLedgerStamp = ''
let isDetailDirty = false

// The Brief, decisions and file list change when the coordinator writes the
// ledger or digest, which moves no stream row; their mtimes say when to refetch.
async function ledgerStamp($: EngineInterface, dir: string, slug: string): Promise<string> {
  const parts: string[] = []
  for (const name of ['coordination.md', 'digest.md']) {
    try {
      parts.push(String((await $.fs.stat(`${dir}/_work/_arcs/${slug}/${name}`)).mtimeMs))
    } catch {
      parts.push('-')
    }
  }
  try {
    parts.push(String((await $.fs.list(`${dir}/_work/_arcs/${slug}`)).length))
  } catch {
    parts.push('-')
  }
  return parts.join(':')
}

async function once(key: string, work: () => Promise<void>): Promise<void> {
  if (inflight.has(key)) return
  inflight.add(key)
  try {
    await work()
  } finally {
    inflight.delete(key)
  }
}

type Drawn = { slug: string; generation: number; width?: number } | null

function railWidth(width: number): number {
  return Math.max(16, Math.floor(width / 8) * 8)
}

function isRailsCurrent(arc: LoreArc, generation: number, width: number, drawn: Drawn): boolean {
  return drawn?.slug === arc.slug && drawn.width === width && drawn.generation === generation
}

function isDetailCurrent(arc: LoreArc, generation: number, loaded: Drawn): boolean {
  return loaded?.slug === arc.slug && loaded.generation === generation
}

async function sync($: EngineInterface): Promise<void> {
  if (!(await read($, isOpen)) || (await read($, size)) !== 'expanded' || (await read($, isPicking))) return
  const shown = await read($, board)
  const arc = await currentArc($)
  if (!shown || !arc || paneWidth <= 0) return
  const width = railWidth(paneWidth)
  const { generation } = shown
  const work: Promise<void>[] = []
  if (!isRailsCurrent(arc, generation, width, await read($, rails))) {
    work.push(
      once(`rails ${arc.slug} ${width} ${generation}`, async () => {
        const ran = await lore($, ['coordinate', 'board', '--arc', arc.slug, '--width', String(width), '--json'], 30_000)
        const drawn = railsOf(arc.slug, width, generation, ran)
        await update($, rails, () => drawn)
      }),
    )
  }
  if (isDetailDirty || !isDetailCurrent(arc, generation, await read($, detail))) {
    isDetailDirty = false
    work.push(
      once(`detail ${arc.slug} ${generation} ${lastLedgerStamp}`, async () => {
        const loaded = detailOf(arc.slug, generation, await lore($, ['arc', 'show', arc.slug, '--json'], 20_000))
        await update($, detail, () => loaded)
      }),
    )
  }
  await Promise.all(work)
}

async function openWindow($: EngineInterface): Promise<void> {
  await update($, isDismissed, () => false)
  await update($, isOpen, () => true)
  await $.ui.open(isSized ? { id: WINDOW, title: 'lore' } : { id: WINDOW, title: 'lore', columns: WINDOW_COLUMNS })
  isSized = true
  detach(poll($))
}

async function closeWindow($: EngineInterface): Promise<void> {
  await update($, isOpen, () => false)
  await update($, isPicking, () => false)
  await $.ui.close({ id: WINDOW })
}

// The pane, not a saved flag, says whether the window is up: a flag outlives a
// reload or a close the engine made, and a toggle trusting it closes nothing.
async function isWindowShown($: EngineInterface): Promise<boolean> {
  return (await $.ui.panes()).some(pane => pane.id === WINDOW && pane.isShown)
}

async function toggleWindow($: EngineInterface): Promise<void> {
  if (await isWindowShown($)) await closeWindow($)
  else await openWindow($)
}

// A document or work item replaces the window's body rather than opening a
// pane of its own: a second pane adds a tab row and reflows the dock.
async function popOut($: EngineInterface, load: () => Promise<LorePopout>): Promise<void> {
  const loaded = await load()
  await update($, popout, () => loaded)
}

function actionsFor($: EngineInterface): Actions {
  return {
    toggleWindow: () => toggleWindow($),
    minimize: () => closeWindow($),
    dismiss: async () => {
      await closeWindow($)
      await update($, isDismissed, () => true)
    },
    toggleSize: async () => {
      const chosen: LoreSize = (await read($, size)) === 'compact' ? 'expanded' : 'compact'
      await update($, size, () => chosen)
      detach(sync($))
    },
    pick: async picking => {
      await update($, isPicking, () => picking)
      if (!picking) detach(sync($))
    },
    pin: async slug => {
      await update($, pinned, () => slug)
      await update($, isPicking, () => false)
      await $.store.set(await pinKey($), slug)
      detach(sync($))
    },
    toggleDecision: async key => {
      await update($, openDecisions, open => (open.includes(key) ? open.filter(k => k !== key) : [...open, key]))
    },
    openDocument: async (file: LoreFile) => {
      const dir = await read($, store)
      const loaded = await read($, detail)
      if (!dir || !loaded) return
      const source = `${dir}/${loaded.path}/${file.path}`
      await popOut($, async () => {
        try {
          const text = await $.fs.read(source)
          return documentOf(file.path, source, typeof text === 'string' ? text : null)
        } catch {
          return documentOf(file.path, source, null)
        }
      })
    },
    openWorkItem: async slug => {
      await popOut($, async () => workItemOf(slug, await lore($, ['work', 'show', slug, '--json'], 30_000)))
    },
    closePopout: async () => {
      await update($, popout, () => null)
    },
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const dir = activeStoreOf(await lore($, ['active', '--harness', 'claude-code', '--json'], 10_000))
    await update($, store, () => dir)
    if (!dir) return next(e)

    const seen: string[] = []
    for (const message of await $.session.messages()) {
      for (const use of message.toolUses) {
        if (use.tool !== 'Bash') continue
        const command = typeof use.input['command'] === 'string' ? use.input['command'] : ''
        seen.push(...mentions(command, use.text ?? ''))
      }
    }
    await remember($, seen)
    const kept = await $.store.get(await pinKey($))
    if (typeof kept === 'string') await update($, pinned, () => kept)

    const shown = await isWindowShown($)
    await update($, isOpen, () => shown)
    await update($, isDismissed, () => false)
    $.clock.every(POLL_MS, () => detach(poll($)))
    detach(poll($))
    return next(e)
  })

  on('command.run', { command: 'arcs' }, async $ => {
    await toggleWindow($)
    return { text: (await isWindowShown($)) ? 'Opened the lore window.' : 'Closed the lore window.' }
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)
    if (e.agentId !== undefined || !(await read($, store))) return ran
    const found = mentions(e.command, typeof ran.text === 'string' ? ran.text : '')
    if (found.length === 0) return ran
    await remember($, found)
    detach(poll($))
    return ran
  })

  on('ui.close', async ($, e, next) => {
    if (e.id === WINDOW) {
      await update($, isOpen, () => false)
      await update($, isPicking, () => false)
    }
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey || !(await read($, store)) || (await read($, isDismissed))) return next(e)
    const arc = await currentArc($)
    if (!arc) return next(e)
    const title = titleOf(await read($, titles), arc.slug)
    return drawChip($.ui.resolve(e), arc, title, await read($, isOpen), e.props.bodyColumns, actionsFor($))
  })

  on('ui.render', { component: 'Pane', requestId: WINDOW }, async ($, e) => {
    const shownDocument = await read($, popout)
    if (shownDocument) return drawPopout($.ui.resolve(e), shownDocument, actionsFor($))
    const width = Math.max(10, e.props.bodyColumns - 4)
    paneWidth = width
    const shown = await read($, board)
    const arc = await currentArc($)
    const chosen = await read($, size)
    const picking = await read($, isPicking)
    const drawnRails = await read($, rails)
    const loaded = await read($, detail)
    const isStale =
      shown !== null &&
      arc !== null &&
      !picking &&
      chosen === 'expanded' &&
      (!isRailsCurrent(arc, shown.generation, railWidth(width), drawnRails) || !isDetailCurrent(arc, shown.generation, loaded))
    if (isStale) $.clock.after(0, () => detach(sync($)))
    return drawWindow(
      $.ui.resolve(e),
      {
        arcs: shown ? shown.arcs : null,
        error: shown?.error ?? null,
        arc,
        titles: await read($, titles),
        size: chosen,
        isPicking: picking,
        rails: drawnRails,
        detail: loaded,
        openDecisions: await read($, openDecisions),
        width,
        isTerminal: e.surface === 'terminal',
      },
      actionsFor($),
    )
  })
}
