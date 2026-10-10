import { describe, expect, test } from 'claude-code/testing'
import type { Engine, MockClock } from 'claude-code/testing'

import { SURFACES, bash, pane, start, world } from './world'
import type { World } from './world'

const ARCS = { command: 'arcs', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } } as never

async function openExpanded($: Engine, seen: World, surface: (typeof SURFACES)[number]) {
  await $.command.run(ARCS)
  await seen.clock.settle()
  const compact = await $.ui.mount({ plugin: 'lore', surface, ...pane('lore-arcs', 30) })
  await compact.press({ key: 'size' })
  await compact.unmount()
  const window = await $.ui.mount({ plugin: 'lore', surface, ...pane('lore-arcs', 96) })
  await settle(seen.clock)
  return window
}

async function settle(clock: MockClock) {
  await clock.advance(0)
  await clock.settle()
}

describe('the arc window', () => {
  test('compact shows the bound arc as counts and a glyph strip', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    await start($, seen.clock)
    await $.command.run(ARCS)
    await seen.clock.settle()
    expect(seen.opened.map(open => [open.id, open.columns])).toEqual([['lore-arcs', 64]])
    for (const surface of SURFACES) {
      const window = await $.ui.mount({ plugin: 'lore', surface, ...pane('lore-arcs', 30) })
      expect(await window.find({ type: 'Text', text: 'Alpha arc' })).toBeDefined()
      expect((await window.find({ key: 'strip' }))?.text.replace(/\s+/g, '')).toBe('✓●▲●')
      expect((await window.find({ key: 'counts' }))?.text).toContain('▲ 1 waiting on you')
      expect(await window.find({ key: 'streams' })).toBeUndefined()
      await window.unmount()
    }
    expect(seen.runs.some(run => run.startsWith('coordinate board'))).toBe(false)
  })

  test('□ expands in place to rails drawn at the body width rounded down to 8, and back', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    await start($, seen.clock)
    const window = await openExpanded($, seen, 'terminal')
    expect(seen.opened.map(open => open.columns)).toEqual([64])
    expect(seen.runs).toContain('coordinate board --arc alpha --width 88 --json')
    const streams = (await window.find({ key: 'streams' }))?.text ?? ''
    expect(streams).toContain('✓─╮  1  Read the board')
    expect(streams).toContain('waiting on you')
    expect(await window.find({ key: 'stream:2' })).toBeDefined()
    expect(await window.find({ key: 'stream:3' })).toBeUndefined()
    await window.press({ key: 'size' })
    expect(seen.opened.map(open => open.columns)).toEqual([64])
    expect(await window.find({ key: 'streams' })).toBeUndefined()
    expect(await window.find({ key: 'strip' })).toBeDefined()
  })

  test('off the terminal the rails sit in one Code block so they align', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    await start($, seen.clock)
    const window = await openExpanded($, seen, 'desktop')
    const code = await window.find({ type: 'Code' })
    expect(code?.text.split('\n')).toHaveLength(4)
    expect(code?.text).toContain('▲ │  3  Ask the owner')
    expect(await window.find({ key: 'stream:2' })).toBeDefined()
  })

  for (const surface of SURFACES) {
    test(`an older lore-tui (exit 3) falls back to one line per stream on ${surface}`, async ($, on) => {
      const seen = world(on, { history: [bash('lore arc show alpha')], boardExit: 3 })
      await start($, seen.clock)
      const window = await openExpanded($, seen, surface)
      const streams = (await window.find({ key: 'streams' }))?.text ?? ''
      expect(streams).toContain('Draw the window')
      expect(streams).toContain('waiting on you')
      expect(await window.find({ type: 'Text', text: 'run lore rebuild for the graph' })).toBeDefined()
      expect(await window.find({ type: 'Code' })).toBeUndefined()
    })
  }

  test('a narrow expanded window drops step text rather than wrap', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')], boardExit: 3 })
    await start($, seen.clock)
    await $.command.run(ARCS)
    await seen.clock.settle()
    const compact = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...pane('lore-arcs', 30) })
    await compact.press({ key: 'size' })
    await compact.unmount()
    const window = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...pane('lore-arcs', 28) })
    await settle(seen.clock)
    const streams = (await window.find({ key: 'streams' }))?.text ?? ''
    expect(streams).not.toContain('Draw the window')
    expect(streams).toContain('running')
  })

  test('expanded shows the Brief, decisions collapsed to a first sentence, and documents', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    await start($, seen.clock)
    const window = await openExpanded($, seen, 'terminal')
    expect(seen.runs).toContain('arc show alpha --json')
    const brief = (await window.find({ key: 'brief' }))?.text ?? ''
    expect(brief).toContain('Landed')
    expect(brief).toContain('The board reads truthfully.')
    const decision = 'decision:0'
    expect((await window.find({ key: decision }))?.text).toContain('Keep the chip to one row.')
    expect((await window.find({ key: decision }))?.text).not.toContain('every bound session')
    await window.press({ key: 'toggle:' + decision })
    expect((await window.find({ key: decision }))?.text).toContain('every bound session')
    expect(await window.find({ key: 'toggle:decision:1' })).toBeUndefined()
    expect(await window.find({ key: 'doc:coordination.md' })).toBeDefined()
    expect(await window.find({ key: 'doc:drafts/long.md' })).toBeDefined()
  })

  for (const surface of SURFACES) {
    test(`a document replaces the window's body until back on ${surface}`, async ($, on) => {
      const seen = world(on, { history: [bash('lore arc show alpha')] })
      await start($, seen.clock)
      const window = await openExpanded($, seen, surface)
      await window.press({ key: 'doc:coordination.md' })
      expect(seen.opened.map(open => open.id)).toEqual(['lore-arcs'])
      expect((await window.find({ type: 'Markdown' }))?.text).toContain('The steps so far.')
      expect(await window.find({ type: 'Text', text: '/store/_work/_arcs/alpha/coordination.md' })).toBeDefined()
      expect(await window.find({ key: 'streams' })).toBeUndefined()
      await window.press({ key: 'back' })
      const after = (await window.findAll({ type: 'Markdown' })).map(block => block.text).join('\n')
      expect(after).not.toContain('The steps so far.')
      expect(after).toContain('The board reads truthfully.')
      expect(await window.find({ key: 'streams' })).toBeDefined()
      expect(seen.closed).toEqual([])
    })
  }

  test("a long document is paged into blocks under the element's limit", async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    await start($, seen.clock)
    const window = await openExpanded($, seen, 'terminal')
    await window.press({ key: 'doc:drafts/long.md' })
    const blocks = await window.findAll({ type: 'Markdown' })
    expect(blocks.length).toBe(3)
    for (const block of blocks) expect(block.text.length).toBeLessThanOrEqual(10_000)
    expect(blocks.map(block => block.text).join('\n')).toContain('Line 499')
  })

  test("a stream's work item opens its plan and notes", async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    await start($, seen.clock)
    const window = await openExpanded($, seen, 'terminal')
    await window.press({ key: 'stream:2' })
    expect(seen.runs).toContain('work show alpha-two --json')
    const text = (await window.findAll({ type: 'Markdown' })).map(block => block.text).join('\n')
    expect(text).toContain('Draw it.')
    expect(text).toContain('Drawn once.')
    expect(await window.find({ type: 'Text', text: 'Draw the window' })).toBeDefined()
  })

  test('switch arc shows the picker inside a bound window', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    await start($, seen.clock)
    await $.command.run(ARCS)
    await seen.clock.settle()
    const window = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...pane('lore-arcs', 30) })
    await window.press({ key: 'switch' })
    expect(await window.find({ type: 'Text', text: 'Show another arc here:' })).toBeDefined()
    await window.press({ key: 'pin:beta' })
    expect(await window.find({ type: 'Text', text: 'Beta arc' })).toBeDefined()
  })

  test('× closes the window and hides the chip until /arcs', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    await start($, seen.clock)
    await $.command.run(ARCS)
    await seen.clock.settle()
    const window = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...pane('lore-arcs', 30) })
    await window.press({ key: 'close' })
    expect(seen.closed).toEqual(['lore-arcs'])
    const band = await $.ui.mount({
      plugin: 'lore',
      surface: 'terminal',
      component: 'AbovePrompt',
      props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 100, scroll: { offset: 0, bodyRows: 10 }, view: {} },
    })
    expect(await band.find({ key: 'chip' })).toBeUndefined()
    await $.command.run(ARCS)
    expect(await band.find({ key: 'chip' })).toBeDefined()
  })

  test('polls the snapshot file every 30 seconds and refreshes only once it is due', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')], nextUpdate: 1_030 })
    await start($, seen.clock)
    const refreshes = () => seen.runs.filter(run => run === 'coordinate read --refresh --json').length
    const reads = () => seen.reads.filter(path => path.endsWith('display.json')).length
    expect([reads(), refreshes()]).toEqual([1, 0])
    await seen.clock.advance(30_000)
    expect([reads(), refreshes()]).toEqual([2, 1])
  })
})
