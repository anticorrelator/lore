import { describe, expect, test } from 'claude-code/testing'

import { latestArc, mentions, pages, sessionArcOf } from '../hooks/parse'

describe('paging long text', () => {
  test('a short body is one block', () => {
    expect(pages('markdown', '# Title\n\nBody.', ' continues')).toEqual([{ kind: 'markdown', text: '# Title\n\nBody.' }])
  })

  test('a block cut inside a code fence closes it and the next reopens it', () => {
    const body = ['Intro', '```', ...Array.from({ length: 400 }, (_, i) => `code ${i} ${'y'.repeat(40)}`), '```', 'After'].join('\n')
    const blocks = pages('markdown', body, ' continues')
    expect(blocks.length).toBe(3)
    for (const block of blocks) {
      expect(block.text.length).toBeLessThanOrEqual(10_000)
      expect((block.text.match(/^```/gm) ?? []).length % 2).toBe(0)
    }
    expect(blocks.at(-1)?.text.endsWith('After')).toBe(true)
  })

  test('past ten blocks the last one says the text continues', () => {
    const body = Array.from({ length: 4_000 }, (_, i) => `line ${i} ${'z'.repeat(40)}`).join('\n')
    const blocks = pages('code', body, '\n… continues in /store/x.md')
    expect(blocks.length).toBe(10)
    expect(blocks.at(-1)?.text.endsWith('… continues in /store/x.md')).toBe(true)
    for (const block of blocks) expect(block.text.length).toBeLessThanOrEqual(10_000)
  })

  test('one line longer than a block is split across blocks', () => {
    const blocks = pages('code', 'q'.repeat(25_000), ' continues')
    expect(blocks.map(block => block.text.length)).toEqual([9_800, 9_800, 5_400])
  })
})

describe('arc mentions', () => {
  test('a command names an arc by its ledger path or an arc verb', () => {
    expect(mentions('sed -n 1,20p _work/_arcs/alpha/coordination.md', '')).toEqual(['alpha'])
    expect(mentions('lore arc member add beta some-item', '')).toEqual(['beta'])
    expect(mentions('lore arc show gamma && lore arc close delta', '')).toEqual(['gamma', 'delta'])
    expect(mentions('lore arc list', '')).toEqual([])
  })

  test("a result names an arc only through arc open's Opened line", () => {
    expect(mentions('lore arc open --title Epsilon --anchor x', '[arc] Opened: epsilon (Epsilon)')).toEqual(['epsilon'])
    const listing = JSON.stringify([{ slug: 'alpha', path: '_work/_arcs/alpha' }, { slug: 'beta', path: '_work/_arcs/beta' }])
    expect(mentions('lore arc list --json', listing)).toEqual([])
    expect(mentions('cat notes.md', 'see lore arc show alpha')).toEqual([])
  })
})

describe('the arc lore names for a session', () => {
  test("lore active's arc field names it; a missing or empty one names none", () => {
    const answer = (arc: unknown) => ({ exitCode: 0, stdout: JSON.stringify({ active: true, store: '/store', reason: 'ok', arc }), isStdoutTruncated: false })
    expect(sessionArcOf(answer('alpha'))).toBe('alpha')
    expect(sessionArcOf(answer(null))).toBeNull()
    expect(sessionArcOf(answer(''))).toBeNull()
    expect(sessionArcOf({ exitCode: 1, stdout: 'not json', isStdoutTruncated: false })).toBeNull()
    expect(sessionArcOf(null)).toBeNull()
  })
})

describe('the fallback arc', () => {
  const arcs = ['alpha', 'beta', 'delta'].map(slug => ({ slug, streams: [] }))

  test('is the arc whose ledger changed last', () => {
    expect(latestArc(arcs, new Map([['alpha', 5], ['beta', 9], ['delta', 7]]))?.slug).toBe('beta')
  })

  test('an arc with no ledger yet comes after every arc with one; ties keep board order', () => {
    expect(latestArc(arcs, new Map([['delta', 1]]))?.slug).toBe('delta')
    expect(latestArc(arcs, new Map())?.slug).toBe('alpha')
    expect(latestArc([], new Map())).toBeNull()
  })
})
