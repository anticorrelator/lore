import { describe, expect, test } from 'claude-code/testing'

import { BAND, SURFACES, start, world } from './world'

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

  test('an active store registers /arcs and polls the snapshot file', async ($, on) => {
    const seen = world(on)
    await start($, seen.clock)
    expect(seen.commands).toEqual(['arcs'])
    const opened = await $.command.run({ command: 'arcs', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 120 } } as never)
    expect(opened.text).toBe('Opened the lore window.')
    await seen.clock.settle()
    expect(seen.reads).toContain('/store/_coordination/display.json')
    expect(seen.runs).not.toContain('coordinate read --refresh --json')
  })
})
