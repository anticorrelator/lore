import { describe, expect, test } from 'claude-code/testing'

import { BAND, SESSION, SURFACES, bash, pane, start, world } from './world'

const ARCS = { command: 'arcs', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 120 } } as never

async function chipText(ui: { find: (q: { key: string }) => Promise<{ text: string } | undefined> }) {
  return (await ui.find({ key: 'chip' }))?.text
}

describe('which arc a session is bound to', () => {
  test('a session resumed after `lore arc show` is bound to that arc', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc list'), bash('lore arc show alpha --json')] })
    await start($, seen.clock)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ plugin: 'lore', surface, ...BAND })
      expect(await chipText(ui)).toContain('Alpha arc')
      await ui.unmount()
    }
  })

  test("history counts the arc a result names: arc open's Opened line", async ($, on) => {
    const seen = world(on, { history: [bash('lore arc open --title "Beta arc" --anchor x', '[arc] Opened: beta (Beta arc)')] })
    await start($, seen.clock)
    const ui = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    expect(await chipText(ui)).toContain('Beta arc')
  })

  test('a live Bash call binds the session, and the most recent mention wins', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    on('tool.call', () => ({ result: { stdout: 'ok', stderr: '', interrupted: false } }))
    await start($, seen.clock)
    const ui = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    expect(await chipText(ui)).toContain('Alpha arc')
    await $.tool.call({ tool: 'Bash', command: 'cat _work/_arcs/beta/coordination.md' })
    await seen.clock.settle()
    expect(await chipText(ui)).toContain('Beta arc')
  })

  test('a live result naming an arc binds the session', async ($, on) => {
    const seen = world(on)
    on('tool.call', () => ({ result: { stdout: '', stderr: '', interrupted: false }, text: '[arc] Opened: alpha (Alpha arc)' }) as never)
    await start($, seen.clock)
    const ui = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    expect(await chipText(ui)).toBeUndefined()
    await $.tool.call({ tool: 'Bash', command: 'lore arc open --title "Alpha arc" --anchor x' })
    await seen.clock.settle()
    expect(await chipText(ui)).toContain('Alpha arc')
  })

  test("a subagent's Bash call does not bind the session", async ($, on) => {
    const seen = world(on)
    on('tool.call', () => ({ result: { stdout: '', stderr: '', interrupted: false } }))
    await start($, seen.clock)
    await $.tool.call({ tool: 'Bash', command: 'lore arc show alpha', agentId: 'a-1' } as never)
    await seen.clock.settle()
    const ui = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    expect(await chipText(ui)).toBeUndefined()
  })

  test('only active arcs bind: a later closed arc leaves the earlier active one', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha'), bash('lore arc show gamma')] })
    await start($, seen.clock)
    const ui = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    expect(await chipText(ui)).toContain('Alpha arc')
  })

  test('a pin overrides every mention', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')], store: { ['pin:' + SESSION]: 'beta' } })
    on('tool.call', () => ({ result: { stdout: '', stderr: '', interrupted: false } }))
    await start($, seen.clock)
    await $.tool.call({ tool: 'Bash', command: 'lore arc show alpha' })
    await seen.clock.settle()
    const ui = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    expect(await chipText(ui)).toContain('Beta arc')
  })

  test('an unbound session shows no chip; /arcs opens a picker whose buttons pin the session', async ($, on) => {
    const seen = world(on)
    await start($, seen.clock)
    for (const surface of SURFACES) {
      const band = await $.ui.mount({ plugin: 'lore', surface, ...BAND })
      expect(await chipText(band)).toBeUndefined()
      await band.unmount()
    }
    await $.command.run(ARCS)
    await seen.clock.settle()
    expect(seen.opened.map(open => open.id)).toEqual(['lore-arcs'])
    const window = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...pane('lore-arcs', 30) })
    expect(await window.find({ type: 'Text', text: 'Pin an arc to this session:' })).toBeDefined()
    expect(await window.find({ key: 'pin:alpha' })).toBeDefined()
    expect(await window.find({ key: 'pin:gamma' })).toBeUndefined()
    await window.press({ key: 'pin:beta' })
    expect(seen.store.get('pin:' + SESSION)).toBe('beta')
    const band = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    expect(await chipText(band)).toContain('Beta arc')
    expect(await window.find({ type: 'Text', text: 'Beta arc' })).toBeDefined()
  })
})
