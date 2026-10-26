import { describe, expect, test } from 'claude-code/testing'

import { ARC_LIST, BAND, SESSION, STORE, SURFACES, bash, pane, snapshot, start, world } from './world'

const ARCS = { command: 'arcs', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 120 } } as never

async function chipText(ui: { find: (q: { key: string }) => Promise<{ text: string } | undefined> }) {
  return (await ui.find({ key: 'chip' }))?.text
}

const BOARD = `${STORE}/_coordination/display.json`
const LEDGERS = `${STORE}/_work/_arcs`

// The board with these arcs in this order, each in its status.
function boardWith(arcs: Record<string, string>): string {
  return JSON.stringify({ ...snapshot(), coordination_arcs: Object.entries(arcs).map(([arc, status]) => ({ arc, status })) })
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

  test("a later arc listing's output leaves a resumed session on its earlier arc", async ($, on) => {
    const listing = JSON.stringify(ARC_LIST.map(arc => ({ ...arc, path: '_work/_arcs/' + arc.slug })))
    const seen = world(on, { history: [bash('lore arc show alpha'), bash('lore arc list --json', listing)] })
    await start($, seen.clock)
    const ui = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    expect(await chipText(ui)).toContain('Alpha arc')
  })

  test("a live arc listing's output leaves the session on its earlier arc", async ($, on) => {
    const listing = JSON.stringify(ARC_LIST.map(arc => ({ ...arc, path: '_work/_arcs/' + arc.slug })))
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    on('tool.call', () => ({ result: { stdout: listing, stderr: '', interrupted: false }, text: listing }) as never)
    await start($, seen.clock)
    await $.tool.call({ tool: 'Bash', command: 'lore arc list --json' })
    await seen.clock.settle()
    const ui = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
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
    expect(await window.find({ type: 'Text', text: 'No arc is bound to this session. Pin one:' })).toBeDefined()
    expect(await window.find({ key: 'pin:alpha' })).toBeDefined()
    expect(await window.find({ key: 'pin:gamma' })).toBeUndefined()
    await window.press({ key: 'pin:beta' })
    expect(seen.store.get('pin:' + SESSION)).toBe('beta')
    const band = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    expect(await chipText(band)).toContain('Beta arc')
    expect(await window.find({ type: 'Text', text: 'Beta arc' })).toBeDefined()
  })
})

describe('the arc lore names for a dispatched session', () => {
  test('a session whose work item an active arc lists is bound to that arc', async ($, on) => {
    const seen = world(on, { arc: 'alpha' })
    await start($, seen.clock)
    const ui = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    expect(await chipText(ui)).toContain('Alpha arc')
  })

  test('an arc the session names wins over the arc lore names', async ($, on) => {
    const seen = world(on, { arc: 'alpha', history: [bash('lore arc show beta')] })
    await start($, seen.clock)
    const ui = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    expect(await chipText(ui)).toContain('Beta arc')
  })

  test('a pin wins over the arc lore names', async ($, on) => {
    const seen = world(on, { arc: 'alpha', store: { ['pin:' + SESSION]: 'beta' } })
    await start($, seen.clock)
    const ui = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    expect(await chipText(ui)).toContain('Beta arc')
  })
})

describe('when the arcs a session had close', () => {
  test('the window moves to the active arc whose ledger changed last, until the session names another', async ($, on) => {
    const seen = world(on, {
      arc: 'alpha',
      mtimes: {
        [`${LEDGERS}/delta/coordination.md`]: 1_000,
        [`${LEDGERS}/beta/coordination.md`]: 500,
        [`${LEDGERS}/beta/digest.md`]: 2_000,
      },
    })
    seen.files[BOARD] = boardWith({ alpha: 'active', delta: 'active', beta: 'active' })
    on('tool.call', () => ({ result: { stdout: '', stderr: '', interrupted: false } }))
    await start($, seen.clock)
    const ui = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    expect(await chipText(ui)).toContain('Alpha arc')
    seen.files[BOARD] = boardWith({ alpha: 'closed', delta: 'active', beta: 'active' })
    await seen.clock.advance(30_000)
    expect(await chipText(ui)).toContain('Beta arc')
    await $.tool.call({ tool: 'Bash', command: 'lore arc show delta' })
    await seen.clock.settle()
    expect(await chipText(ui)).toContain('delta')
  })

  test('a pinned arc that closes falls back the same way', async ($, on) => {
    const seen = world(on, { store: { ['pin:' + SESSION]: 'beta' }, mtimes: { [`${LEDGERS}/alpha/coordination.md`]: 1_000 } })
    await start($, seen.clock)
    const ui = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    expect(await chipText(ui)).toContain('Beta arc')
    seen.files[BOARD] = boardWith({ alpha: 'active', beta: 'closed' })
    await seen.clock.advance(30_000)
    expect(await chipText(ui)).toContain('Alpha arc')
  })

  test('a session that never had an arc keeps the picker', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show gamma')], mtimes: { [`${LEDGERS}/alpha/coordination.md`]: 1_000 } })
    await start($, seen.clock)
    await seen.clock.advance(30_000)
    const band = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...BAND })
    expect(await chipText(band)).toBeUndefined()
    await $.command.run(ARCS)
    await seen.clock.settle()
    const window = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...pane('lore-arcs', 30) })
    expect(await window.find({ type: 'Text', text: 'No arc is bound to this session. Pin one:' })).toBeDefined()
  })
})
