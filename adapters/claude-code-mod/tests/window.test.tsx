import { describe, expect, test } from 'claude-code/testing'
import type { Engine, MockClock } from 'claude-code/testing'

import { SURFACES, bash, pane, start, world } from './world'
import type { World } from './world'

const ARCS = { command: 'arcs', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } } as never

async function openWindow($: Engine, seen: World, surface: (typeof SURFACES)[number], bodyColumns = 96) {
  await $.command.run(ARCS)
  await seen.clock.settle()
  const window = await $.ui.mount({ plugin: 'lore', surface, ...pane('lore-arcs', bodyColumns) })
  await settle(seen.clock)
  return window
}

async function settle(clock: MockClock) {
  await clock.advance(0)
  await clock.settle()
}

describe('the arc window', () => {
  for (const surface of SURFACES) {
    test(`one view on ${surface}: a heading with the tally, the rails, the Brief a line a field`, async ($, on) => {
      const seen = world(on, { history: [bash('lore arc show alpha')] })
      await start($, seen.clock)
      const window = await openWindow($, seen, surface)
      expect(seen.opened.map(open => [open.id, open.title, open.columns])).toEqual([['lore-arcs', 'Arc', 64]])
      expect(await window.find({ type: 'Text', text: 'Alpha arc' })).toBeDefined()
      expect((await window.find({ key: 'summary' }))?.text).toContain('1/4 done · 2 running · ▲ 1')
      expect(seen.runs).toContain('coordinate board --arc alpha --width 88 --json')
      const streams = (await window.find({ key: 'streams' }))?.text ?? ''
      expect(streams).toContain('✓─╮  1  Read the board')
      expect(streams).toContain('waiting on you')
      expect((await window.find({ key: 'brief' }))?.text).toContain('Landed')
      for (const gone of ['size', 'minimize', 'switch']) expect(await window.find({ key: gone })).toBeUndefined()
    })

    test(`each stream with a work item is one pressable row, never a second list, on ${surface}`, async ($, on) => {
      const seen = world(on, { history: [bash('lore arc show alpha')] })
      await start($, seen.clock)
      const window = await openWindow($, seen, surface)
      expect(await window.find({ type: 'Code' })).toBeUndefined()
      expect((await window.find({ key: 'stream:2' }))?.text).toContain('Draw the window')
      expect(await window.find({ key: 'stream:3' })).toBeUndefined()
      expect((await window.findAll({ type: 'Text', text: 'Open a step' })).length).toBe(0)
    })

    test(`an older lore-tui (exit 3) falls back to one line per stream on ${surface}`, async ($, on) => {
      const seen = world(on, { history: [bash('lore arc show alpha')], boardExit: 3 })
      await start($, seen.clock)
      const window = await openWindow($, seen, surface)
      const streams = (await window.find({ key: 'streams' }))?.text ?? ''
      expect(streams).toContain('Draw the window')
      expect(streams).toContain('waiting on you')
      expect(await window.find({ type: 'Text', text: 'run lore rebuild for the graph' })).toBeDefined()
      expect(await window.find({ key: 'stream:2' })).toBeDefined()
    })
  }

  test('a narrow window drops step text rather than wrap', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')], boardExit: 3 })
    await start($, seen.clock)
    const window = await openWindow($, seen, 'terminal', 30)
    const streams = (await window.find({ key: 'streams' }))?.text ?? ''
    expect(streams).not.toContain('Draw the window')
    expect(streams).toContain('running')
  })

  test('Brief fields and decisions show their first sentence and open whole when pressed', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    await start($, seen.clock)
    const window = await openWindow($, seen, 'terminal')
    expect(seen.runs).toContain('arc show alpha --json')
    expect((await window.find({ key: 'brief' }))?.text).toContain('The board reads truthfully.')
    const decision = 'decision:0'
    expect((await window.find({ key: decision }))?.text).toContain('Keep the chip to one row.')
    expect((await window.find({ key: decision }))?.text).not.toContain('every bound session')
    await window.press({ key: 'toggle:' + decision })
    expect((await window.find({ key: decision }))?.text).toContain('every bound session')
    await window.press({ key: 'toggle:' + decision })
    expect((await window.find({ key: decision }))?.text).not.toContain('every bound session')
    expect(await window.find({ key: 'doc:coordination.md' })).toBeDefined()
    expect(await window.find({ key: 'doc:drafts/long.md' })).toBeDefined()
  })

  for (const surface of SURFACES) {
    test(`a document replaces the window's body until back on ${surface}`, async ($, on) => {
      const seen = world(on, { history: [bash('lore arc show alpha')] })
      await start($, seen.clock)
      const window = await openWindow($, seen, surface)
      await window.press({ key: 'doc:coordination.md' })
      expect(seen.opened.map(open => open.id)).toEqual(['lore-arcs'])
      expect((await window.find({ type: 'Markdown' }))?.text).toContain('The steps so far.')
      expect(await window.find({ type: 'Text', text: '/store/_work/_arcs/alpha/coordination.md' })).toBeDefined()
      expect(await window.find({ key: 'streams' })).toBeUndefined()
      await window.press({ key: 'back' })
      expect(await window.find({ key: 'streams' })).toBeDefined()
      expect(seen.closed).toEqual([])
    })
  }

  test("a long document is paged into blocks under the element's limit", async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    await start($, seen.clock)
    const window = await openWindow($, seen, 'terminal')
    await window.press({ key: 'doc:drafts/long.md' })
    const blocks = await window.findAll({ type: 'Markdown' })
    expect(blocks.length).toBe(3)
    for (const block of blocks) expect(block.text.length).toBeLessThanOrEqual(10_000)
    expect(blocks.map(block => block.text).join('\n')).toContain('Line 499')
  })

  test("a stream's work item opens its plan and notes", async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    await start($, seen.clock)
    const window = await openWindow($, seen, 'terminal')
    await window.press({ key: 'stream:2' })
    expect(seen.runs).toContain('work show alpha-two --json')
    const text = (await window.findAll({ type: 'Markdown' })).map(block => block.text).join('\n')
    expect(text).toContain('Draw it.')
    expect(text).toContain('Drawn once.')
    expect(await window.find({ type: 'Text', text: 'Draw the window' })).toBeDefined()
  })

  test('× closes the window and leaves the chip to reopen it', async ($, on) => {
    const seen = world(on, { history: [bash('lore arc show alpha')] })
    await start($, seen.clock)
    const window = await openWindow($, seen, 'terminal')
    await window.press({ key: 'close' })
    expect(seen.closed).toEqual(['lore-arcs'])
    const band = await $.ui.mount({
      plugin: 'lore',
      surface: 'terminal',
      component: 'AbovePrompt',
      props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 100, scroll: { offset: 0, bodyRows: 10 }, view: {} },
    })
    expect((await band.find({ key: 'toggle' }))?.props.label).toBe('▴')
    await band.press({ key: 'toggle' })
    expect(seen.opened.map(open => open.id)).toEqual(['lore-arcs', 'lore-arcs'])
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
