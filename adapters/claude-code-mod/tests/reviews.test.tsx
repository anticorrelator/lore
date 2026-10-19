import { describe, expect, test } from 'claude-code/testing'
import type { Engine, MockClock } from 'claude-code/testing'

import { SURFACES, pane, reviewFixture, reviewList, start, world } from './world'
import type { World } from './world'

const REVIEWS = { command: 'reviews', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } } as never

async function settle(clock: MockClock) {
  await clock.advance(0)
  await clock.settle()
}

async function openPanel($: Engine, seen: World, surface: (typeof SURFACES)[number] = 'terminal') {
  await $.command.run(REVIEWS)
  await settle(seen.clock)
  const panel = await $.ui.mount({ plugin: 'lore', surface, ...pane('lore-reviews', 70) })
  await settle(seen.clock)
  return panel
}

function edits(seen: World): string[] {
  return seen.runs.filter(run => run.startsWith('followup edit-review '))
}

describe('the review panel', () => {
  test('/reviews is offered only once the project has an open review', async ($, on) => {
    const none = world(on)
    await start($, none.clock)
    expect(none.commands).not.toContain('reviews')
  })

  test('a project with an open review offers /reviews', async ($, on) => {
    const seen = world(on, { reviews: reviewList() })
    await start($, seen.clock)
    expect(seen.commands).toContain('reviews')
  })

  for (const surface of SURFACES) {
    test(`lists open reviews newest first and shows the chosen one's comments on ${surface}`, async ($, on) => {
      const seen = world(on, { reviews: reviewList() })
      await start($, seen.clock)
      const panel = await openPanel($, seen, surface)
      expect(seen.opened.map(open => [open.id, open.title])).toEqual([['lore-reviews', 'Reviews']])
      const chooser = await panel.find({ key: 'choose' })
      expect((chooser?.props.options as { value: string }[]).map(option => option.value)).toEqual(['review-a', 'review-b'])
      expect(chooser?.props.value).toBe('review-a')
      expect(seen.runs).toContain('followup view --json review-a')
      expect((await panel.find({ key: 'row:comment:0' }))?.text).toContain('Guard drops the error')
      expect((await panel.find({ key: 'select:comment:0' }))?.props.label).toBe('[ ]')
      expect((await panel.find({ key: 'select:general' }))?.props.label).toBe('[x]')
      expect(await panel.find({ key: 'post' })).toBeDefined()
    })
  }

  test('a checkbox selects a comment through edit-review and the post button counts it', async ($, on) => {
    const seen = world(on, { reviews: reviewList() })
    await start($, seen.clock)
    const panel = await openPanel($, seen)
    expect((await panel.find({ key: 'post' }))?.props.label).toBe('Post the general comment')
    await panel.press({ key: 'select:comment:0' })
    expect(edits(seen)).toEqual(['followup edit-review review-a --comment 0 --select --json'])
    expect((await panel.find({ key: 'select:comment:0' }))?.props.label).toBe('[x]')
    expect((await panel.find({ key: 'post' }))?.props.label).toBe('Post 1 comment')
    await panel.press({ key: 'select:comment:0' })
    expect(edits(seen).at(-1)).toBe('followup edit-review review-a --comment 0 --deselect --json')
  })

  test('all · none select and clear every comment', async ($, on) => {
    const seen = world(on, { reviews: reviewList() })
    await start($, seen.clock)
    const panel = await openPanel($, seen)
    await panel.press({ key: 'all:comments' })
    expect(edits(seen)).toEqual(['followup edit-review review-a --all-comments --select --json'])
    expect((await panel.find({ key: 'post' }))?.props.label).toBe('Post 2 comments')
    await panel.press({ key: 'none:comments' })
    expect((await panel.find({ key: 'select:comment:1' }))?.props.label).toBe('[ ]')
  })

  test('a row opens into its place and whole text, and edit saves through stdin with line breaks restored', async ($, on) => {
    const seen = world(on, { reviews: reviewList() })
    await start($, seen.clock)
    const panel = await openPanel($, seen)
    await panel.press({ key: 'row:comment:0' })
    const opened = (await panel.find({ key: 'comment:0' }))?.text ?? ''
    expect(opened).toContain('a.py:3')
    expect(opened).toContain('The error is lost.')
    await panel.press({ key: 'edit:comment:0' })
    expect((await panel.find({ key: 'input:comment:0' }))?.props.value).toBe('The guard returns early. The error is lost.')
    await panel.input({ key: 'input:comment:0', text: 'First line. ⏎  ⏎ Second line.' })
    expect(edits(seen)).toEqual(['followup edit-review review-a --comment 0 --body-file - --json'])
    expect(seen.stdins).toEqual(['First line.\n\nSecond line.'])
    expect(await panel.find({ key: 'input:comment:0' })).toBeUndefined()
    expect((await panel.find({ key: 'comment:0' }))?.text).toContain('Second line.')
  })

  test('a body with line breaks is edited as one line with a visible mark', async ($, on) => {
    const held = reviewFixture(7)
    const comments = (held.proposed_comments as { comments: Record<string, unknown>[] }).comments
    if (comments[0]) comments[0].body = 'One.\n\nTwo.'
    const seen = world(on, { reviews: reviewList(), review: { 'review-a': held, 'review-b': reviewFixture(8) } })
    await start($, seen.clock)
    const panel = await openPanel($, seen)
    await panel.press({ key: 'row:comment:0' })
    await panel.press({ key: 'edit:comment:0' })
    expect((await panel.find({ key: 'input:comment:0' }))?.props.value).toBe('One. ⏎  ⏎ Two.')
  })

  test('the event buttons set the review event and name the post', async ($, on) => {
    const seen = world(on, { reviews: reviewList() })
    await start($, seen.clock)
    const panel = await openPanel($, seen)
    expect((await panel.find({ key: 'event:COMMENT' }))?.props.variant).toBe('primary')
    await panel.press({ key: 'event:APPROVE' })
    expect(edits(seen)).toEqual(['followup edit-review review-a --event APPROVE --json'])
    expect((await panel.find({ key: 'event:APPROVE' }))?.props.variant).toBe('primary')
    expect((await panel.find({ key: 'post' }))?.props.label).toBe('Approve with the general comment')
  })

  test('another review is chosen from the picker', async ($, on) => {
    const seen = world(on, { reviews: reviewList() })
    await start($, seen.clock)
    const panel = await openPanel($, seen)
    await panel.select({ key: 'choose', value: 'review-b' })
    expect(seen.runs).toContain('followup view --json review-b')
    expect((await panel.find({ key: 'choose' }))?.props.value).toBe('review-b')
  })

  test('post asks first, then posts, marks the review reviewed and moves to the next', async ($, on) => {
    const seen = world(on, { reviews: reviewList() })
    await start($, seen.clock)
    const panel = await openPanel($, seen)
    await panel.press({ key: 'select:comment:0' })
    await panel.press({ key: 'post' })
    expect(seen.runs.some(run => run.startsWith('followup post-review'))).toBe(false)
    expect((await panel.find({ key: 'footer' }))?.text).toContain('Post 1 comment on #7 in o/r?')
    await panel.press({ key: 'confirm' })
    expect(seen.runs).toContain('followup post-review review-a')
    expect(seen.runs).toContain('followup update review-a --status reviewed')
    expect((await panel.find({ key: 'notice' }))?.text).toContain('Posted to #7 · https://github.com/o/r/pull/7#pullrequestreview-1 · marked reviewed')
    expect(await panel.find({ key: 'choose' })).toBeUndefined()
    expect(await panel.find({ type: 'Text', text: 'Older change' })).toBeDefined()
  })

  test("a refused post says why and keeps the review", async ($, on) => {
    const seen = world(on, { reviews: reviewList(), postExit: 1 })
    await start($, seen.clock)
    const panel = await openPanel($, seen)
    await panel.press({ key: 'post' })
    await panel.press({ key: 'confirm' })
    expect((await panel.find({ key: 'notice' }))?.text).toContain("Couldn't post: [post-proposed-review] ERROR: head moved and two comments are lost")
    expect(seen.runs).not.toContain('followup update review-a --status reviewed')
    expect((await panel.find({ key: 'choose' }))?.props.value).toBe('review-a')
  })

  test('cancel leaves the review untouched; dismiss asks, then archives it', async ($, on) => {
    const seen = world(on, { reviews: reviewList() })
    await start($, seen.clock)
    const panel = await openPanel($, seen)
    await panel.press({ key: 'dismiss' })
    await panel.press({ key: 'cancel' })
    expect(seen.runs.some(run => run.startsWith('followup dismiss'))).toBe(false)
    await panel.press({ key: 'dismiss' })
    expect((await panel.find({ key: 'footer' }))?.text).toContain('Dismiss this review?')
    await panel.press({ key: 'confirm' })
    expect(seen.runs).toContain('followup dismiss --followup-id review-a')
    expect((await panel.find({ key: 'notice' }))?.text).toContain('Dismissed Newer change')
  })

  for (const surface of SURFACES) {
    test(`preview and report replace the panel's body until back on ${surface}`, async ($, on) => {
      const seen = world(on, { reviews: reviewList() })
      await start($, seen.clock)
      const panel = await openPanel($, seen, surface)
      await panel.press({ key: 'preview' })
      expect(seen.runs).toContain('followup post-review review-a --dry-run')
      expect((await panel.find({ type: 'Code' }))?.text).toContain('Inline comments: 1')
      await panel.press({ key: 'back' })
      await panel.press({ key: 'report' })
      expect((await panel.find({ type: 'Markdown' }))?.text).toContain('The whole report.')
      await panel.press({ key: 'back' })
      expect(await panel.find({ key: 'row:comment:0' })).toBeDefined()
    })
  }

  test('ask Claude fills the prompt with the comment and the verb that saves it', async ($, on) => {
    const seen = world(on, { reviews: reviewList() })
    await start($, seen.clock)
    const panel = await openPanel($, seen)
    await panel.press({ key: 'row:comment:1' })
    await panel.press({ key: 'ask:comment:1' })
    expect(seen.fills).toHaveLength(1)
    expect(seen.fills[0]).toContain('b.py:9')
    expect(seen.fills[0]).toContain('lore followup edit-review review-a --comment 1 --body-file -')
  })

  test('lens findings are selected and promoted to a work item', async ($, on) => {
    const held = reviewFixture(7)
    held.lens_findings = {
      pr: 7,
      findings: [
        { severity: 'blocking', title: 'Guard drops the error', file: 'a.py', line: 3, body: 'Lost.', lens: 'correctness', grounding: 'a.py:3', selected: false },
        { severity: 'suggestion', title: 'Rename', file: 'b.py', line: 0, body: 'Clearer.', lens: 'interface-clarity', grounding: 'b.py', selected: false },
      ],
    }
    const seen = world(on, { reviews: reviewList(), review: { 'review-a': held, 'review-b': reviewFixture(8) } })
    await start($, seen.clock)
    const panel = await openPanel($, seen)
    expect(await panel.find({ key: 'promote' })).toBeUndefined()
    await panel.press({ key: 'select:finding:0' })
    expect(edits(seen)).toEqual(['followup edit-review review-a --finding 0 --select --json'])
    await panel.press({ key: 'promote' })
    await panel.press({ key: 'confirm' })
    const promote = seen.runs.find(run => run.startsWith('followup promote')) ?? ''
    expect(promote).toContain('--followup-id review-a --findings-json')
    expect(promote).toContain('"title":"Guard drops the error"')
    expect(promote).not.toContain('Rename')
    expect((await panel.find({ key: 'notice' }))?.text).toContain("Promoted to work item 'Fix the guard' (fix-the-guard)")
  })

  test('a review this session makes is announced and chosen', async ($, on) => {
    const seen = world(on)
    on('tool.call', () => ({ result: { stdout: '', stderr: '', interrupted: false }, text: "Created follow-up 'Review: Newer change (#7)' at /store/_followups/review-a" }) as never)
    await start($, seen.clock)
    expect(seen.commands).not.toContain('reviews')
    seen.listed = reviewList()
    await $.tool.call({ tool: 'Bash', command: 'bash ~/.lore/scripts/create-followup.sh --source pr-review' })
    await seen.clock.settle()
    expect(seen.commands).toContain('reviews')
    expect(seen.toasts).toEqual(['Review ready: /reviews to select, edit and post its comments.'])
    const panel = await openPanel($, seen)
    expect((await panel.find({ key: 'choose' }))?.props.value).toBe('review-a')
  })

  test('an empty project says how reviews arrive', async ($, on) => {
    const seen = world(on, { reviews: [] })
    await start($, seen.clock)
    await $.command.run(REVIEWS)
    await settle(seen.clock)
    const panel = await $.ui.mount({ plugin: 'lore', surface: 'terminal', ...pane('lore-reviews', 70) })
    await settle(seen.clock)
    expect((await panel.find({ key: 'empty' }))?.text).toContain('No open reviews in this project.')
  })

  test('× closes the panel', async ($, on) => {
    const seen = world(on, { reviews: reviewList() })
    await start($, seen.clock)
    const panel = await openPanel($, seen)
    await panel.press({ key: 'close' })
    expect(seen.closed).toEqual(['lore-reviews'])
  })
})
