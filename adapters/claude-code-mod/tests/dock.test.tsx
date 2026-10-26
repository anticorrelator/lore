import { describe, expect, test } from 'claude-code/testing'
import type { MockClock } from 'claude-code/testing'

import { bash, pane, reviewList, start, world } from './world'

// The dock shows one pane and keeps the rest as tabs behind it. The engine's
// diff panel opens itself in front once a session edits, so lore's panes are
// often open without being shown.

const ARCS = { command: 'arcs', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } } as never
const REVIEWS = { command: 'reviews', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } } as never

async function settle(clock: MockClock) {
  await clock.advance(0)
  await clock.settle()
}

describe('the dock', () => {
  test('a window in a tab behind another pane keeps loading, so its tab shows the arc when chosen', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')], panes: ['lore-arcs'], front: 'diff' })
    await start($, seen.clock)
    // The person chooses the arc tab, and the engine draws it.
    seen.dock.front = 'lore-arcs'
    const window = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...pane('lore-arcs', 96) })
    await settle(seen.clock)
    expect(seen.runs).toContain('coordinate board --arc alpha --width 88 --json')
    expect(seen.runs).toContain('arc show alpha --json')
    expect((await window.find({ key: 'brief' }))?.text).toContain('Landed')
  })

  test('/arcs raises a window in a tab behind another pane, asking for the keyboard only then', async ($, on) => {
    const seen = world(on, { panes: ['lore-arcs'], front: 'diff' })
    await start($, seen.clock)
    const answered = await $.command.run(ARCS)
    expect(answered.text).toBe('Opened the arc window.')
    expect(seen.closed).toEqual([])
    expect(seen.opened.map(open => open.focus ?? false)).toEqual([false, true])
    expect(seen.dock.front).toBe('lore-arcs')
  })

  test('/arcs over another pane opens a new window in front and leaves the keyboard at the prompt', async ($, on) => {
    const seen = world(on, { front: 'diff' })
    await start($, seen.clock)
    const answered = await $.command.run(ARCS)
    expect(answered.text).toBe('Opened the arc window.')
    expect(seen.opened.map(open => open.focus ?? false)).toEqual([false])
  })

  test('/arcs closes the window only when it is the pane shown', async ($, on) => {
    const seen = world(on, { panes: ['lore-arcs'] })
    await start($, seen.clock)
    const answered = await $.command.run(ARCS)
    expect(answered.text).toBe('Closed the arc window.')
    expect(seen.closed).toEqual(['lore-arcs'])
  })

  test('/reviews raises a review panel in a tab behind another pane, and it stays fresh', async ($, on) => {
    const seen = world(on, { reviews: reviewList(), panes: ['lore-reviews'], front: 'diff' })
    await start($, seen.clock)
    expect(seen.runs.filter(run => run === 'followup view --json review-a')).toHaveLength(1)
    const answered = await $.command.run(REVIEWS)
    expect(answered.text).toBe('Opened the review panel.')
    expect(seen.closed).toEqual([])
    expect(seen.dock.front).toBe('lore-reviews')
  })
})
