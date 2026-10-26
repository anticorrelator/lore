import { atom, read, update } from 'claude-code'
import type { EngineInterface, PaneOpenArgs, Register, UiPane } from 'claude-code'

import type { LoreArc, LoreFile, LorePopout, LoreReview, LoreReviewConfirm, LoreReviewList } from '../types'
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
  latestArc,
  mentions,
  pages,
  railsOf,
  refreshedSnapshotOf,
  sessionArcOf,
  snapshotOf,
  titlesOf,
  workItemOf,
} from './parse'
import type { Fields, ReviewActions } from './review-draw'
import { drawReviews } from './review-draw'
import { createdReviews, reviewOf, reviewsOf, shortTitle, touchedReviews } from './review-parse'

const WINDOW = 'lore-arcs'
const REVIEWS = 'lore-reviews'
const POLL_MS = 30_000
// One width for the life of the session: resizing the dock reflows the whole
// conversation, so the dock is sized once, by whichever pane opens first, and
// the person's own drag wins after.
const WINDOW_COLUMNS = 64
let isSized = false

const store = atom({ plugin: 'lore', key: 'store' } as const, null)
const board = atom({ plugin: 'lore', key: 'board' } as const, null)
const titles = atom({ plugin: 'lore', key: 'titles' } as const, [])
const candidates = atom({ plugin: 'lore', key: 'candidates' } as const, [])
const pinned = atom({ plugin: 'lore', key: 'pinned' } as const, null)
const hadArc = atom({ plugin: 'lore', key: 'hadArc' } as const, false)
const isOpen = atom({ plugin: 'lore', key: 'isOpen' } as const, false)
const rails = atom({ plugin: 'lore', key: 'rails' } as const, null)
const detail = atom({ plugin: 'lore', key: 'detail' } as const, null)
const openEntries = atom({ plugin: 'lore', key: 'openEntries' } as const, [])
const popout = atom({ plugin: 'lore', key: 'popout' } as const, null)
const isReviewsOpen = atom({ plugin: 'lore', key: 'isReviewsOpen' } as const, false)
const reviews = atom({ plugin: 'lore', key: 'reviews' } as const, null)
const review = atom({ plugin: 'lore', key: 'review' } as const, null)
const reviewChosen = atom({ plugin: 'lore', key: 'reviewChosen' } as const, null)
const reviewOpen = atom({ plugin: 'lore', key: 'reviewOpen' } as const, [])
const reviewEditing = atom({ plugin: 'lore', key: 'reviewEditing' } as const, null)
const reviewConfirm = atom({ plugin: 'lore', key: 'reviewConfirm' } as const, null)
const reviewBusy = atom({ plugin: 'lore', key: 'reviewBusy' } as const, null)
const reviewNotice = atom({ plugin: 'lore', key: 'reviewNotice' } as const, null)
const reviewPopout = atom({ plugin: 'lore', key: 'reviewPopout' } as const, null)

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

async function lore($: EngineInterface, args: readonly string[], timeoutMs: number, stdin?: string): Promise<Ran> {
  try {
    return await $.process.run(['lore', ...args], { timeoutMs, ...(stdin === undefined ? {} : { stdin }) })
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
    const isShown = (await read($, isOpen)) || (await read($, pinned)) !== null || (await read($, candidates)).length > 0
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
    let mine = boundArc(fresh.arcs, await read($, candidates), await read($, pinned))
    if (!mine && (await read($, hadArc))) {
      // Remembered, so the window stays on it while other ledgers move.
      mine = latestArc(fresh.arcs, await ledgerTimes($, dir, fresh.arcs))
      if (mine) await remember($, [mine.slug])
    }
    if (mine && !(await read($, hadArc))) await update($, hadArc, () => true)
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

const LEDGER = ['coordination.md', 'digest.md']

async function mtimeOf($: EngineInterface, path: string): Promise<number | null> {
  try {
    return (await $.fs.stat(path)).mtimeMs
  } catch {
    return null
  }
}

// The Brief, decisions and file list change when the coordinator writes the
// ledger or digest, which moves no stream row; their mtimes say when to refetch.
async function ledgerStamp($: EngineInterface, dir: string, slug: string): Promise<string> {
  const parts: string[] = []
  for (const name of LEDGER) {
    parts.push(String((await mtimeOf($, `${dir}/_work/_arcs/${slug}/${name}`)) ?? '-'))
  }
  try {
    parts.push(String((await $.fs.list(`${dir}/_work/_arcs/${slug}`)).length))
  } catch {
    parts.push('-')
  }
  return parts.join(':')
}

async function ledgerTimes($: EngineInterface, dir: string, arcs: readonly LoreArc[]): Promise<Map<string, number>> {
  const times = new Map<string, number>()
  for (const arc of arcs) {
    for (const name of LEDGER) {
      const at = await mtimeOf($, `${dir}/_work/_arcs/${arc.slug}/${name}`)
      if (at !== null) times.set(arc.slug, Math.max(at, times.get(arc.slug) ?? at))
    }
  }
  return times
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
  if (!(await read($, isOpen))) return
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
  await update($, isOpen, () => true)
  await openInFront($, isSized ? { id: WINDOW, title: 'Arc' } : { id: WINDOW, title: 'Arc', columns: WINDOW_COLUMNS })
  isSized = true
  detach(poll($))
}

async function closeWindow($: EngineInterface): Promise<void> {
  await update($, isOpen, () => false)
  await update($, popout, () => null)
  await $.ui.close({ id: WINDOW })
}

// The pane, not a saved flag, says whether the window is up: a flag outlives a
// reload or a close the engine made, and a toggle trusting it closes nothing.
// The dock shows one pane and keeps the rest as tabs behind it, so open and
// shown differ: an open pane is kept fresh for when its tab is chosen, and only
// a shown one is what a toggle closes.
async function paneOf($: EngineInterface, id: string): Promise<UiPane | undefined> {
  return (await $.ui.panes()).find(pane => pane.id === id)
}

async function isPaneOpen($: EngineInterface, id: string): Promise<boolean> {
  return (await paneOf($, id)) !== undefined
}

async function isPaneShown($: EngineInterface, id: string): Promise<boolean> {
  return (await paneOf($, id))?.isShown === true
}

// Opening an open pane only retitles it; asking for the keyboard is what
// raises it over the tab holding the dock, such as the diff panel the engine
// opens once a session edits. Asked only when the plain open left it behind,
// so an ordinary open leaves the keys at the prompt.
async function openInFront($: EngineInterface, pane: PaneOpenArgs): Promise<void> {
  await $.ui.open(pane)
  if (!(await isPaneShown($, pane.id))) await $.ui.open({ ...pane, focus: true })
}

async function paneReply($: EngineInterface, id: string, name: string): Promise<string> {
  const pane = await paneOf($, id)
  if (!pane) return `Closed the ${name}.`
  return pane.isShown ? `Opened the ${name}.` : `The ${name} is open in a tab behind another pane.`
}

async function isWindowShown($: EngineInterface): Promise<boolean> {
  return isPaneShown($, WINDOW)
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
    close: () => closeWindow($),
    pin: async slug => {
      await update($, pinned, () => slug)
      await $.store.set(await pinKey($), slug)
      detach(sync($))
    },
    toggleOpen: async key => {
      await update($, openEntries, open => (open.includes(key) ? open.filter(k => k !== key) : [...open, key]))
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


// --- The review panel ---
// Open reviews are the project's pending follow-ups that /pr-review made. The
// panel reads them through `lore followup list|view --json` and changes them
// only through `lore followup edit-review|post-review|dismiss|promote`.

// /reviews is offered once the project has an open review, or a session makes
// one, as /arcs waits for an arc.
let isReviewsOffered = false
let reviewStamp = ''

async function offerReviews($: EngineInterface): Promise<void> {
  if (isReviewsOffered) return
  isReviewsOffered = true
  await $.command.register({ name: 'reviews', description: "Open or close lore's review panel" })
}

async function loadReviews($: EngineInterface): Promise<LoreReviewList> {
  const listed = reviewsOf(await lore($, ['followup', 'list', '--json'], 20_000))
  await update($, reviews, () => listed)
  if (listed.entries.length > 0) await offerReviews($)
  const chosen = await read($, reviewChosen)
  if (!listed.error && !listed.entries.some(entry => entry.id === chosen)) {
    await update($, reviewChosen, () => listed.entries[0]?.id ?? null)
  }
  return listed
}

async function loadReview($: EngineInterface, id: string): Promise<void> {
  const loaded = reviewOf(id, await lore($, ['followup', 'view', '--json', id], 20_000))
  if ((await read($, reviewChosen)) === id) await update($, review, () => loaded)
}

// Edits made outside the panel (the TUI, an agent running edit-review) move
// the review's files but not its index row; their mtimes say when to reread.
async function reviewFilesStamp($: EngineInterface, id: string): Promise<string> {
  const dir = await read($, store)
  const parts: string[] = [id]
  for (const name of ['proposed-comments.json', 'lens-findings.json', '_meta.json']) {
    try {
      parts.push(String((await $.fs.stat(`${dir}/_followups/${id}/${name}`)).mtimeMs))
    } catch {
      parts.push('-')
    }
  }
  return parts.join(':')
}

async function pollReviews($: EngineInterface): Promise<void> {
  if (!(await read($, isReviewsOpen))) return
  await once('reviews', async () => {
    await loadReviews($)
    const chosen = await read($, reviewChosen)
    if (!chosen) return
    const stamp = await reviewFilesStamp($, chosen)
    const shown = await read($, review)
    // A field being typed in keeps its text: a reread would redraw it.
    if (shown?.id === chosen && (stamp === reviewStamp || (await read($, reviewEditing)) !== null)) return
    reviewStamp = stamp
    await loadReview($, chosen)
  })
}

async function openReviews($: EngineInterface): Promise<void> {
  await update($, isReviewsOpen, () => true)
  await openInFront($, isSized ? { id: REVIEWS, title: 'Reviews' } : { id: REVIEWS, title: 'Reviews', columns: WINDOW_COLUMNS })
  isSized = true
  detach(pollReviews($))
}

async function closeReviews($: EngineInterface): Promise<void> {
  await update($, isReviewsOpen, () => false)
  await update($, reviewPopout, () => null)
  await update($, reviewEditing, () => null)
  await update($, reviewConfirm, () => null)
  await $.ui.close({ id: REVIEWS })
}

async function toggleReviews($: EngineInterface): Promise<void> {
  if (await isPaneShown($, REVIEWS)) await closeReviews($)
  else await openReviews($)
}

// The verb's own words for why it refused: its JSON error, else its last line.
function reasonOf(ran: Ran): string {
  if (!ran) return 'lore did not answer'
  try {
    const answer: unknown = JSON.parse(ran.stdout)
    if (typeof answer === 'object' && answer !== null && 'error' in answer && typeof answer.error === 'string') return answer.error
  } catch {
    // not JSON: fall through to the text
  }
  const lines = `${ran.stderr ?? ''}\n${ran.stdout}`.split('\n').map(line => line.trim()).filter(Boolean)
  return lines.at(-1) ?? `exit ${ran.exitCode}`
}

type Target = { args: string[]; kind: 'comment' | 'general' | 'finding'; index: number }

function targetOf(key: string): Target | null {
  if (key === 'general') return { args: ['--general'], kind: 'general', index: -1 }
  const match = /^(comment|finding):(\d+)$/.exec(key)
  if (!match?.[1] || !match[2]) return null
  const kind = match[1] === 'comment' ? 'comment' : 'finding'
  return { args: [`--${kind}`, match[2]], kind, index: Number(match[2]) }
}

function isSelectedIn(shown: LoreReview, target: Target): boolean {
  if (target.kind === 'general') return shown.general?.selected === true
  const items = target.kind === 'comment' ? shown.comments : shown.findings
  return items[target.index]?.selected === true
}

function withSelected(shown: LoreReview, target: Target, selected: boolean): LoreReview {
  if (target.kind === 'general') return shown.general ? { ...shown, general: { ...shown.general, selected } } : shown
  if (target.kind === 'comment') {
    return { ...shown, comments: shown.comments.map(c => (c.index === target.index ? { ...c, selected } : c)) }
  }
  return { ...shown, findings: shown.findings.map(f => (f.index === target.index ? { ...f, selected } : f)) }
}

function withBody(shown: LoreReview, target: Target, body: string): LoreReview {
  if (target.kind === 'general') return shown.general ? { ...shown, general: { ...shown.general, body } } : shown
  return { ...shown, comments: shown.comments.map(c => (c.index === target.index ? { ...c, body } : c)) }
}

// Each change is drawn at once, then made by the verb; the review is reread
// either way, so a refusal puts back what the files hold.
async function editReview($: EngineInterface, id: string, args: string[], stdin?: string): Promise<void> {
  const ran = await lore($, ['followup', 'edit-review', id, ...args, '--json'], 20_000, stdin)
  if (ran?.exitCode !== 0) await update($, reviewNotice, () => ({ text: "Couldn't save that: " + reasonOf(ran), isError: true }))
  await loadReview($, id)
  reviewStamp = await reviewFilesStamp($, id)
}

async function chosenReview($: EngineInterface): Promise<LoreReview | null> {
  const shown = await read($, review)
  return shown && shown.id === (await read($, reviewChosen)) && !shown.error ? shown : null
}

function askText(shown: LoreReview, target: Target): string {
  if (target.kind === 'general') {
    return `Revise the general comment of review ${shown.id}, then save it with \`lore followup edit-review ${shown.id} --general --body-file -\`. Change: `
  }
  if (target.kind === 'comment') {
    const comment = shown.comments[target.index]
    const where = comment ? `${comment.path}:${comment.line}` : ''
    return `Revise comment ${target.index + 1} of review ${shown.id} (${where}), then save it with \`lore followup edit-review ${shown.id} --comment ${target.index} --body-file -\`. Change: `
  }
  const finding = shown.findings[target.index]
  return `Look into finding "${finding?.title ?? target.index}" (${finding?.file ?? ''}:${finding?.line ?? ''}) from review ${shown.id}: `
}

async function settle($: EngineInterface, done: { text: string; isError: boolean }): Promise<void> {
  await update($, reviewNotice, () => done)
  await update($, reviewBusy, () => null)
  await update($, reviewOpen, () => [])
  const listed = await loadReviews($)
  const chosen = await read($, reviewChosen)
  if (chosen && listed.entries.some(entry => entry.id === chosen)) await loadReview($, chosen)
}

async function postReview($: EngineInterface, shown: LoreReview): Promise<void> {
  await update($, reviewBusy, () => 'Posting to GitHub')
  const ran = await lore($, ['followup', 'post-review', shown.id], 180_000)
  if (ran?.exitCode !== 0) {
    await settle($, { text: "Couldn't post: " + reasonOf(ran), isError: true })
    return
  }
  const url = /Posted: (\S+)/.exec(ran.stdout)?.[1]
  const marked = await lore($, ['followup', 'update', shown.id, '--status', 'reviewed'], 20_000)
  const where = `#${shown.pr ?? '?'}`
  await settle($, {
    text: `Posted to ${where}${url ? ' · ' + url : ''}${marked?.exitCode === 0 ? ' · marked reviewed' : ''}`,
    isError: false,
  })
}

async function dismissReview($: EngineInterface, shown: LoreReview): Promise<void> {
  await update($, reviewBusy, () => 'Dismissing')
  const ran = await lore($, ['followup', 'dismiss', '--followup-id', shown.id], 20_000)
  await settle($, ran?.exitCode === 0 ? { text: `Dismissed ${shortTitle(shown.title)}`, isError: false } : { text: "Couldn't dismiss: " + reasonOf(ran), isError: true })
}

async function promoteFindings($: EngineInterface, shown: LoreReview): Promise<void> {
  const chosen = shown.findings
    .filter(finding => finding.selected)
    .map(({ index: _index, ...finding }) => finding)
  await update($, reviewBusy, () => 'Promoting')
  const ran = await lore($, ['followup', 'promote', '--followup-id', shown.id, '--findings-json', JSON.stringify(chosen)], 60_000)
  const promoted = ran?.exitCode === 0 ? /Promoted: .*?→ (.*)$/m.exec(ran.stdout)?.[1] : undefined
  await settle($, ran?.exitCode === 0 ? { text: `Promoted to ${promoted ?? 'a work item'}`, isError: false } : { text: "Couldn't promote: " + reasonOf(ran), isError: true })
}

function reviewActionsFor($: EngineInterface): ReviewActions {
  return {
    close: () => closeReviews($),
    choose: async id => {
      await update($, reviewChosen, () => id)
      await update($, reviewOpen, () => [])
      await update($, reviewEditing, () => null)
      await update($, reviewConfirm, () => null)
      await update($, reviewNotice, () => null)
      await loadReview($, id)
      reviewStamp = await reviewFilesStamp($, id)
    },
    toggleSelected: async key => {
      const shown = await chosenReview($)
      const target = targetOf(key)
      if (!shown || !target) return
      const isSelected = isSelectedIn(shown, target)
      await update($, review, prior => (prior?.id === shown.id ? withSelected(prior, target, !isSelected) : prior))
      await editReview($, shown.id, [...target.args, isSelected ? '--deselect' : '--select'])
    },
    setAll: async (kind, selected) => {
      const shown = await chosenReview($)
      if (!shown) return
      await update($, review, prior =>
        prior?.id !== shown.id
          ? prior
          : kind === 'comments'
            ? { ...prior, comments: prior.comments.map(c => ({ ...c, selected })) }
            : { ...prior, findings: prior.findings.map(f => ({ ...f, selected })) },
      )
      await editReview($, shown.id, [kind === 'comments' ? '--all-comments' : '--all-findings', selected ? '--select' : '--deselect'])
    },
    toggleRow: async key => {
      await update($, reviewOpen, open => (open.includes(key) ? open.filter(k => k !== key) : [...open, key]))
    },
    edit: async key => {
      await update($, reviewEditing, () => key)
      if (key) await update($, reviewOpen, open => (open.includes(key) ? open : [...open, key]))
    },
    save: async (key, body) => {
      const shown = await chosenReview($)
      const target = targetOf(key)
      await update($, reviewEditing, () => null)
      if (!shown || !target || target.kind === 'finding') return
      await update($, review, prior => (prior?.id === shown.id ? withBody(prior, target, body) : prior))
      await editReview($, shown.id, [...target.args, '--body-file', '-'], body)
    },
    ask: async key => {
      const shown = await chosenReview($)
      const target = targetOf(key)
      if (!shown || !target) return
      const filled = await $.prompt.fill({ text: askText(shown, target), mode: 'insert' })
      if (!filled.isFilled) await update($, reviewNotice, () => ({ text: "Couldn't fill the prompt here.", isError: true }))
    },
    setEvent: async event => {
      const shown = await chosenReview($)
      if (!shown || shown.event === event) return
      await update($, review, prior => (prior?.id === shown.id ? { ...prior, event } : prior))
      await editReview($, shown.id, ['--event', event])
    },
    askConfirm: async (confirm: LoreReviewConfirm) => {
      await update($, reviewConfirm, () => confirm)
    },
    confirm: async () => {
      const confirm = await read($, reviewConfirm)
      const shown = await chosenReview($)
      await update($, reviewConfirm, () => null)
      if (!shown) return
      if (confirm === 'post') await postReview($, shown)
      else if (confirm === 'dismiss') await dismissReview($, shown)
      else if (confirm === 'promote') await promoteFindings($, shown)
    },
    preview: async () => {
      const shown = await chosenReview($)
      if (!shown) return
      await update($, reviewBusy, () => 'Building the payload')
      const ran = await lore($, ['followup', 'post-review', shown.id, '--dry-run'], 60_000)
      await update($, reviewBusy, () => null)
      const source = `lore followup post-review ${shown.id} --dry-run`
      const text = ran?.exitCode === 0 ? ran.stdout : "Couldn't build the payload: " + reasonOf(ran)
      await update($, reviewPopout, () => ({ title: 'What would be posted', source, blocks: pages('code', text, `\n… continues: ${source}`) }))
    },
    report: async () => {
      const shown = await chosenReview($)
      if (!shown?.report) return
      const source = `lore followup view ${shown.id}`
      await update($, reviewPopout, () => ({ title: shortTitle(shown.title), source, blocks: pages('markdown', shown.report ?? '', `\n\n… continues: ${source}`) }))
    },
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const active = await lore($, ['active', '--harness', 'claude-code', '--json'], 10_000)
    const dir = activeStoreOf(active)
    await update($, store, () => dir)
    if (!dir) return next(e)

    // A dispatched session never names its arc, so lore names it, as the oldest
    // candidate: an arc the session names, or a pin, still wins.
    const seeded = sessionArcOf(active)
    const seen: string[] = seeded ? [seeded] : []
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

    // Open, not shown: a pane in a tab behind another is still drawn the
    // moment its tab is chosen, so it is kept as fresh as one in front.
    const isWindowUp = await isPaneOpen($, WINDOW)
    await update($, isOpen, () => isWindowUp)
    const isReviewsUp = await isPaneOpen($, REVIEWS)
    await update($, isReviewsOpen, () => isReviewsUp)
    $.clock.every(POLL_MS, () => {
      detach(poll($))
      detach(pollReviews($))
    })
    detach(poll($))
    detach(isReviewsUp ? pollReviews($) : loadReviews($).then(() => undefined))
    return next(e)
  })

  on('command.run', { command: 'arcs' }, async $ => {
    await toggleWindow($)
    return { text: await paneReply($, WINDOW, 'arc window') }
  })

  on('command.run', { command: 'reviews' }, async $ => {
    await toggleReviews($)
    return { text: await paneReply($, REVIEWS, 'review panel') }
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)
    if (e.agentId !== undefined || !(await read($, store))) return ran
    const result = typeof ran.text === 'string' ? ran.text : ''
    const found = mentions(e.command, result)
    if (found.length > 0) {
      await remember($, found)
      detach(poll($))
    }
    const made = createdReviews(result).at(-1)
    if (made) {
      // A review this session just made becomes the panel's, open or not.
      await offerReviews($)
      await update($, reviewChosen, () => made)
      await update($, reviewNotice, () => null)
      if (await isPaneShown($, REVIEWS)) detach(pollReviews($))
      else $.ui.toast('Review ready: /reviews to select, edit and post its comments.')
    } else if (touchedReviews(e.command).includes((await read($, reviewChosen)) ?? '')) {
      detach(pollReviews($))
    }
    return ran
  })

  on('ui.close', async ($, e, next) => {
    if (e.id === WINDOW) await update($, isOpen, () => false)
    if (e.id === REVIEWS) await update($, isReviewsOpen, () => false)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey || !(await read($, store))) return next(e)
    const arc = await currentArc($)
    if (!arc) return next(e)
    const title = titleOf(await read($, titles), arc.slug)
    return drawChip($.ui.resolve(e), arc, title, await read($, isOpen), e.props.bodyColumns, actionsFor($))
  })

  on('ui.render', { component: 'Pane', requestId: WINDOW }, async ($, e) => {
    const shownDocument = await read($, popout)
    if (shownDocument) return drawPopout($.ui.resolve(e), shownDocument, e.surface === 'terminal', actionsFor($).closePopout)
    // The body less the window's one-cell gutter each side.
    const width = Math.max(10, e.props.bodyColumns - 2)
    paneWidth = width
    const shown = await read($, board)
    const arc = await currentArc($)
    const drawnRails = await read($, rails)
    const loaded = await read($, detail)
    const isStale =
      shown !== null &&
      arc !== null &&
      (!isRailsCurrent(arc, shown.generation, railWidth(width), drawnRails) || !isDetailCurrent(arc, shown.generation, loaded))
    if (isStale) $.clock.after(0, () => detach(sync($)))
    return drawWindow(
      $.ui.resolve(e),
      {
        arcs: shown ? shown.arcs : null,
        error: shown?.error ?? null,
        arc,
        titles: await read($, titles),
        rails: drawnRails,
        detail: loaded,
        open: await read($, openEntries),
        width,
        isTerminal: e.surface === 'terminal',
      },
      actionsFor($),
    )
  })

  on('ui.render', { component: 'Pane', requestId: REVIEWS }, async ($, e) => {
    const ui = $.ui.resolve(e)
    const isTerminal = e.surface === 'terminal'
    const shownPopout = await read($, reviewPopout)
    if (shownPopout) {
      return drawPopout(ui, shownPopout, isTerminal, async () => {
        await update($, reviewPopout, () => null)
      })
    }
    const listed = await read($, reviews)
    if (listed === null) $.clock.after(0, () => detach(pollReviews($)))
    // The mobile app draws no field or picker yet.
    let fields: Fields | null = null
    if (e.surface !== 'mobile') {
      const table = $.ui.resolve(e)
      fields = { Input: table.Input, Select: table.Select }
    }
    return drawReviews(
      ui,
      {
        reviews: listed,
        review: await read($, review),
        chosen: await read($, reviewChosen),
        open: await read($, reviewOpen),
        editing: await read($, reviewEditing),
        confirm: await read($, reviewConfirm),
        busy: await read($, reviewBusy),
        notice: await read($, reviewNotice),
        width: Math.max(10, e.props.bodyColumns - 2),
        isTerminal,
        fields,
      },
      reviewActionsFor($),
    )
  })
}
