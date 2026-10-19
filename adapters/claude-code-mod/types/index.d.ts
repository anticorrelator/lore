export type LoreStream = {
  id: string
  step: string
  status: string
  verdict: string
  workItem: string | null
}
export type LoreArc = { slug: string; streams: LoreStream[] }
export type LoreBoard = { arcs: LoreArc[]; generation: number; error: string | null }
export type LoreTitle = { slug: string; title: string }
export type LoreRailLine = { text: string; wordsAt: number }
export type LoreRailRow = { id: string; lines: LoreRailLine[] }
export type LoreRails = {
  slug: string
  generation: number
  width: number
  rows: LoreRailRow[]
  isOld: boolean
}
export type LoreBriefField = { label: string; text: string }
export type LoreDecision = { text: string; heading: string }
export type LoreFile = { path: string; size: number }
export type LoreDetail = {
  slug: string
  generation: number
  path: string
  brief: LoreBriefField[]
  decisions: LoreDecision[]
  files: LoreFile[]
  error: string | null
}
export type LoreBlock = { kind: 'markdown' | 'code'; text: string }
export type LorePopout = { title: string; source: string; blocks: LoreBlock[] }
export type LoreReviewEntry = { id: string; title: string; pr: string; updated: string }
export type LoreReviewList = { entries: LoreReviewEntry[]; error: string | null }
export type LoreReviewComment = {
  index: number
  path: string
  line: number
  title: string
  body: string
  selected: boolean
  severity: string
  lenses: string[]
  ordinal: number | null
}
export type LoreReviewFinding = {
  index: number
  severity: string
  title: string
  file: string
  line: number
  body: string
  lens: string
  grounding: string
  selected: boolean
}
export type LoreReviewEvent = 'COMMENT' | 'APPROVE' | 'REQUEST_CHANGES'
export type LoreReview = {
  id: string
  title: string
  pr: number | null
  repo: string
  event: LoreReviewEvent
  general: { body: string; selected: boolean } | null
  comments: LoreReviewComment[]
  findings: LoreReviewFinding[]
  report: string | null
  canPost: boolean
  error: string | null
}
export type LoreReviewConfirm = 'post' | 'dismiss' | 'promote' | null
export type LoreNotice = { text: string; isError: boolean } | null

declare module 'claude-code' {
  interface PluginState {
    lore: {
      store: string | null
      board: LoreBoard | null
      titles: LoreTitle[]
      candidates: string[]
      pinned: string | null
      isOpen: boolean
      rails: LoreRails | null
      detail: LoreDetail | null
      openEntries: string[]
      popout: LorePopout | null
      isReviewsOpen: boolean
      reviews: LoreReviewList | null
      review: LoreReview | null
      reviewChosen: string | null
      reviewOpen: string[]
      reviewEditing: string | null
      reviewConfirm: LoreReviewConfirm
      reviewBusy: string | null
      reviewNotice: LoreNotice
      reviewPopout: LorePopout | null
    }
  }
}
