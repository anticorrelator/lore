import { describe, expect, test } from 'claude-code/testing'

import { mentions, pages } from '../hooks/parse'

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
  test('match the ledger path, the arc verbs, and the Opened line', () => {
    expect(mentions('sed -n 1,20p _work/_arcs/alpha/coordination.md')).toEqual(['alpha'])
    expect(mentions('lore arc member add beta some-item')).toEqual(['beta'])
    expect(mentions('lore arc show gamma && lore arc close delta')).toEqual(['gamma', 'delta'])
    expect(mentions('[arc] Opened: epsilon (Epsilon)')).toEqual(['epsilon'])
    expect(mentions('lore arc list')).toEqual([])
  })
})
