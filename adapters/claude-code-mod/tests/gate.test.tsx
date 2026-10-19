import { describe, expect, test } from 'claude-code/testing'

import { BAND, STORE, SURFACES, snapshot, start, world } from './world'

describe('the lore-loaded gate', () => {
  test('an inactive store registers nothing and starts no timer', async ($, on) => {
    const seen = world(on, { active: false })
    await start($, seen.clock)
    expect(seen.runs).toEqual(['active --harness claude-code --json'])
    expect(seen.commands).toEqual([])
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ plugin: 'lore', surface, ...BAND })
      expect(await ui.find({ key: 'chip' })).toBeUndefined()
      await ui.unmount()
    }
    await seen.clock.advance(120_000)
    expect(seen.runs).toEqual(['active --harness claude-code --json'])
    expect(seen.reads).toEqual([])
  })

  test('a missing lore registers nothing', async ($, on) => {
    const seen = world(on, { isLoreMissing: true })
    await start($, seen.clock)
    expect(seen.commands).toEqual([])
    await seen.clock.advance(120_000)
    expect(seen.runs).toEqual(['active --harness claude-code --json'])
    expect(seen.reads).toEqual([])
  })

  test('a store with no active arc offers no /arcs until the board lists one', async ($, on) => {
    const seen = world(on)
    const board = `${STORE}/_coordination/display.json`
    const closed = snapshot()
    seen.files[board] = JSON.stringify({ ...closed, coordination_arcs: closed.coordination_arcs.map(arc => ({ ...arc, status: 'closed' })) })
    await start($, seen.clock)
    expect(seen.commands).toEqual([])
    expect(seen.reads).toEqual([board])
    seen.files[board] = JSON.stringify(snapshot())
    await seen.clock.advance(30_000)
    expect(seen.commands).toEqual(['arcs'])
    await seen.clock.advance(30_000)
    expect(seen.commands).toEqual(['arcs'])
    // The project's reviews are listed once, to say whether to offer /reviews.
    expect(seen.runs).toEqual(['active --harness claude-code --json', 'followup list --json'])
  })

  test('an active store with an active arc registers /arcs and polls the snapshot file', async ($, on) => {
    const seen = world(on)
    await start($, seen.clock)
    expect(seen.commands).toEqual(['arcs'])
    const opened = await $.command.run({ command: 'arcs', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 120 } } as never)
    expect(opened.text).toBe('Opened the arc window.')
    await seen.clock.settle()
    expect(seen.reads).toContain('/store/_coordination/display.json')
    expect(seen.runs).not.toContain('coordinate read --refresh --json')
  })
})
