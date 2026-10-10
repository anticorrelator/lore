import { describe, expect, test } from 'claude-code/testing'

import { BAND, SURFACES, bash, start, world } from './world'

describe('the band chip', () => {
  test('counts running streams and those waiting on you', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    await start($, seen.clock)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ plugin: 'lore', surface, ...BAND })
      const chip = (await ui.find({ key: 'chip' }))?.text ?? ''
      expect(chip).toContain('▣ Alpha arc')
      expect(chip).toContain('● 2 running')
      expect(chip).toContain('▲ 1 waiting on you')
      expect((await ui.find({ key: 'toggle' }))?.props.label).toBe('▴')
      await ui.unmount()
    }
  })

  test('leaves out "waiting on you" at zero', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show beta')] })
    await start($, seen.clock)
    const ui = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    const chip = (await ui.find({ key: 'chip' }))?.text ?? ''
    expect(chip).toContain('● 0 running')
    expect(chip).not.toContain('waiting')
  })

  test('drops the words before it wraps in a narrow band', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    await start($, seen.clock)
    const ui = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND, props: { ...BAND.props, bodyColumns: 40 } })
    const chip = (await ui.find({ key: 'chip' }))?.text ?? ''
    expect(chip).toContain('● 2 ▲ 1')
    expect(chip).not.toContain('running')
    expect(chip.length).toBeLessThanOrEqual(40)
  })

  test('▴ opens the window and ▾ closes it', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    await start($, seen.clock)
    const ui = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    await ui.press({ key: 'toggle' })
    expect(seen.opened.map(open => [open.id, open.columns])).toEqual([['lore-arcs', 64]])
    expect((await ui.find({ key: 'toggle' }))?.props.label).toBe('▾')
    await ui.press({ key: 'toggle' })
    expect(seen.closed).toEqual(['lore-arcs'])
    expect((await ui.find({ key: 'toggle' }))?.props.label).toBe('▴')
  })
})
