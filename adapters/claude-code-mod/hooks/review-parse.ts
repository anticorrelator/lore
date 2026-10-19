import type {
  LoreReview,
  LoreReviewComment,
  LoreReviewEntry,
  LoreReviewEvent,
  LoreReviewFinding,
  LoreReviewList,
} from '../types'
import type { Ran } from './parse'

const EVENTS: readonly LoreReviewEvent[] = ['COMMENT', 'APPROVE', 'REQUEST_CHANGES']

function parse(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}

function record(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : {}
}

function list(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

function text(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function count(value: unknown): number {
  if (typeof value === 'number' && Number.isFinite(value)) return value
  if (typeof value === 'string' && /^\d+$/.test(value)) return Number(value)
  return 0
}

function prRef(attachments: unknown): string {
  const pr = list(attachments).map(record).find(attachment => attachment.type === 'pr')
  return pr ? text(pr.ref) : ''
}

// A follow-up is a review when /pr-review made it or it is attached to a PR.
function isReview(entry: Record<string, unknown>): boolean {
  return entry.source === 'pr-review' || prRef(entry.attachments) !== ''
}

export function reviewsOf(ran: Ran): LoreReviewList {
  const listed = ran?.exitCode === 0 ? parse(ran.stdout) : undefined
  if (!Array.isArray(listed)) return { entries: [], error: "Can't list this project's reviews." }
  const entries: LoreReviewEntry[] = listed
    .map(record)
    .filter(entry => typeof entry.id === 'string' && isReview(entry))
    .map(entry => ({ id: text(entry.id), title: text(entry.title), pr: prRef(entry.attachments), updated: text(entry.updated) }))
    .sort((a, b) => b.updated.localeCompare(a.updated))
  return { entries, error: null }
}

// /pr-review titles its follow-ups `Review: <PR title> (#N)`; the panel shows
// the PR number on its own line, so the title drops both.
export function shortTitle(title: string): string {
  return title.replace(/^Review:\s*/i, '').replace(/\s*\(#\d+\)\s*$/, '') || title
}

function commentsOf(raw: unknown): LoreReviewComment[] {
  const comments = Array.isArray(raw) ? raw : list(record(raw).comments)
  return comments.map(record).map((comment, index) => ({
    index,
    path: text(comment.path),
    line: count(comment.line),
    title: text(comment.title),
    body: text(comment.body),
    selected: comment.selected === true,
    severity: text(comment.severity),
    lenses: list(comment.lenses).filter((lens): lens is string => typeof lens === 'string'),
    ordinal: typeof comment.finding_ordinal === 'number' ? comment.finding_ordinal : null,
  }))
}

function findingsOf(raw: unknown): LoreReviewFinding[] {
  return list(record(raw).findings)
    .map(record)
    .map((finding, index) => ({
      index,
      severity: text(finding.severity),
      title: text(finding.title),
      file: text(finding.file),
      line: count(finding.line),
      body: text(finding.body),
      lens: text(finding.lens),
      grounding: text(finding.grounding),
      selected: finding.selected === true,
    }))
}

// The review as `lore followup view --json` reports it.
export function reviewOf(id: string, ran: Ran): LoreReview {
  const empty: LoreReview = {
    id,
    title: id,
    pr: null,
    repo: '',
    event: 'COMMENT',
    general: null,
    comments: [],
    findings: [],
    report: null,
    canPost: false,
    error: "Can't read this review.",
  }
  if (ran?.isStdoutTruncated) return { ...empty, error: 'This review is too large to show here.' }
  const shown = ran?.exitCode === 0 ? parse(ran.stdout) : undefined
  if (shown === undefined) return empty
  const item = record(shown)
  const raw = item.proposed_comments
  const proposed = record(raw)
  const isWrapped = typeof raw === 'object' && raw !== null && !Array.isArray(raw)
  const pr = count(proposed.pr) || count(prRef(item.attachments).replace(/^#/, '')) || null
  const owner = text(proposed.owner)
  const repo = text(proposed.repo)
  const event = EVENTS.find(known => known === proposed.review_event) ?? 'COMMENT'
  return {
    id,
    title: text(item.title) || id,
    pr,
    repo: owner && repo ? `${owner}/${repo}` : '',
    event,
    general: isWrapped && typeof proposed.review_body === 'string' ? { body: proposed.review_body, selected: proposed.review_body_selected === true } : null,
    comments: commentsOf(raw),
    findings: findingsOf(item.lens_findings),
    report: typeof item.finding_content === 'string' ? item.finding_content : null,
    canPost: isWrapped && count(proposed.pr) > 0 && owner !== '' && repo !== '' && text(proposed.head_sha) !== '',
    error: null,
  }
}

export type Postable = { comments: number; hasBody: boolean; isPostable: boolean }

// What a post would send, by the rule post-proposed-review.sh holds: selected
// comments, the general body when it is selected and not blank, and an
// approval may go alone.
export function postableOf(review: LoreReview): Postable {
  const comments = review.comments.filter(comment => comment.selected).length
  const hasBody = review.general !== null && review.general.selected && review.general.body.trim() !== ''
  return { comments, hasBody, isPostable: review.canPost && (comments > 0 || hasBody || review.event === 'APPROVE') }
}

// An Input is one line on every surface, so a body's line breaks travel as a
// visible mark while it is edited and come back on save.
const BREAK = '⏎'

export function toField(body: string): string {
  return body.replace(/\n/g, ` ${BREAK} `)
}

export function fromField(value: string): string {
  return value.replace(new RegExp(` ?${BREAK} ?`, 'g'), '\n')
}

// A review a Bash call touched: one /pr-review just made (create-followup's
// own line) or a followup verb naming it.
const CREATED = /Created follow-up '[^']*' at \S*\/_followups\/([a-z0-9][a-z0-9-]*)/g
const TOUCHED = /lore followup (?:edit-review|post-review|view(?: --json)?) ([a-z0-9][a-z0-9-]*)/g

function ids(text: string, pattern: RegExp): string[] {
  const found: string[] = []
  for (const match of text.matchAll(pattern)) {
    if (match[1]) found.push(match[1])
  }
  return found
}

export function createdReviews(result: string): string[] {
  return ids(result, CREATED)
}

export function touchedReviews(command: string): string[] {
  return ids(command, TOUCHED)
}
