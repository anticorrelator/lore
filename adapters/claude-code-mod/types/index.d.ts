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
export type LoreSize = 'compact' | 'expanded'

declare module 'claude-code' {
  interface PluginState {
    lore: {
      store: string | null
      board: LoreBoard | null
      titles: LoreTitle[]
      candidates: string[]
      pinned: string | null
      isOpen: boolean
      isDismissed: boolean
      isPicking: boolean
      size: LoreSize
      rails: LoreRails | null
      detail: LoreDetail | null
      openDecisions: string[]
      popout: LorePopout | null
    }
  }
}
