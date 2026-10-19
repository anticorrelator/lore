import type { ElementTable, RenderElement } from 'claude-code'

import type {
  LoreNotice,
  LoreReview,
  LoreReviewConfirm,
  LoreReviewEvent,
  LoreReviewList,
} from '../types'
import { cut, firstSentence, heading } from './draw'
import { fromField, postableOf, shortTitle, toField } from './review-parse'

export type ReviewActions = {
  close: () => Promise<void>
  choose: (id: string) => Promise<void>
  toggleSelected: (key: string) => Promise<void>
  setAll: (kind: 'comments' | 'findings', selected: boolean) => Promise<void>
  toggleRow: (key: string) => Promise<void>
  edit: (key: string | null) => Promise<void>
  save: (key: string, body: string) => Promise<void>
  ask: (key: string) => Promise<void>
  setEvent: (event: LoreReviewEvent) => Promise<void>
  askConfirm: (confirm: LoreReviewConfirm) => Promise<void>
  confirm: () => Promise<void>
  preview: () => Promise<void>
  report: () => Promise<void>
}

// The field and picker, which every surface but the mobile app draws.
export type Fields = Pick<ElementTable<'terminal'>, 'Input' | 'Select'>

export type ReviewData = {
  reviews: LoreReviewList | null
  review: LoreReview | null
  chosen: string | null
  open: string[]
  editing: string | null
  confirm: LoreReviewConfirm
  busy: string | null
  notice: LoreNotice
  width: number
  isTerminal: boolean
  fields: Fields | null
}

const EVENT_WORDS: Record<LoreReviewEvent, string> = {
  COMMENT: 'Comment',
  APPROVE: 'Approve',
  REQUEST_CHANGES: 'Request changes',
}

// Checkbox, space, the row's own toggle mark and its space.
const ROW_LEAD = 6

function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? '' : 's'}`
}

export function drawReviews(ui: ElementTable, data: ReviewData, actions: ReviewActions): RenderElement {
  const { Box, Text } = ui
  const entries = data.reviews?.entries ?? []
  const summary = data.reviews && entries.length > 0 ? <Text dimColor>{entries.length} open</Text> : null
  const frame = (...body: (RenderElement | null)[]) => (
    <Box flexDirection="column" paddingX={1}>
      {heading(ui, 'Reviews', summary, { key: 'close', label: '×', isClose: true, onPress: actions.close }, data.isTerminal)}
      {body}
    </Box>
  )

  if (data.reviews === null) return frame(<Text dimColor>Reading this project's reviews…</Text>)
  if (data.reviews.error) return frame(<Text color="red">{data.reviews.error}</Text>)
  if (entries.length === 0) {
    return frame(
      <Box key="empty" flexDirection="column" marginTop={1}>
        <Text dimColor>No open reviews in this project.</Text>
        <Text dimColor>/pr-review a pull request and its comments land here.</Text>
      </Box>,
    )
  }

  const review = data.review && data.review.id === data.chosen ? data.review : null
  return frame(
    entries.length > 1 ? chooser(ui, data, actions) : null,
    review ? body(ui, review, data, actions) : <Text dimColor>Reading the review…</Text>,
  )
}

function chooser(ui: ElementTable, data: ReviewData, actions: ReviewActions): RenderElement {
  const { Box, Button } = ui
  const entries = data.reviews?.entries ?? []
  const label = (entry: { title: string; pr: string }) => cut(`${entry.pr ? entry.pr + '  ' : ''}${shortTitle(entry.title)}`, data.width - 4)
  const Select = data.fields?.Select
  if (Select) {
    return (
      <Box key="chooser" marginTop={1}>
        <Select
          key="choose"
          options={entries.map(entry => ({ value: entry.id, label: label(entry) }))}
          {...(data.chosen ? { value: data.chosen } : {})}
          onSelect={id => actions.choose(id)}
        />
      </Box>
    )
  }
  return (
    <Box key="chooser" flexDirection="column" marginTop={1}>
      {entries.map(entry => (
        <Button key={'choose:' + entry.id} plain dimColor={entry.id !== data.chosen} label={label(entry)} onPress={() => actions.choose(entry.id)} />
      ))}
    </Box>
  )
}

function body(ui: ElementTable, review: LoreReview, data: ReviewData, actions: ReviewActions): RenderElement {
  const { Box, Text, Button } = ui
  if (review.error) {
    return (
      <Box key="review" marginTop={1}>
        <Text color="red">{review.error}</Text>
      </Box>
    )
  }
  const entries = data.reviews?.entries ?? []
  const selected = review.comments.filter(comment => comment.selected).length
  // A chooser already names the PR beside each title.
  const where = [review.pr && entries.length === 1 ? `#${review.pr}` : '', review.repo, review.comments.length > 0 ? `${selected} of ${plural(review.comments.length, 'comment')} selected` : '']
    .filter(Boolean)
    .join(' · ')
  const findingsSelected = review.findings.filter(finding => finding.selected).length

  return (
    <Box key="review" flexDirection="column">
      {entries.length === 1 ? (
        <Box key="title" marginTop={1}>
          <Text weight="semibold" wrap="truncate-end">
            {shortTitle(review.title)}
          </Text>
        </Box>
      ) : null}
      <Text dimColor wrap="truncate-end">
        {where}
      </Text>
      {data.notice ? (
        <Box key="notice">
          <Text {...(data.notice.isError ? { color: 'red' } : { color: data.isTerminal ? 'green' : 'success' })}>{data.notice.text}</Text>
        </Box>
      ) : null}
      {review.canPost ? eventRow(ui, review.event, actions) : null}
      {review.general ? (
        <Box key="general" flexDirection="column" marginTop={1}>
          {sectionTitle(ui, 'General comment', null)}
          {row(ui, data, actions, {
            key: 'general',
            selected: review.general.selected,
            lead: '',
            title: firstSentence(review.general.body) || '(empty)',
            detail: '',
            body: review.general.body,
            isEditable: true,
          })}
        </Box>
      ) : null}
      {review.comments.length > 0 ? (
        <Box key="comments" flexDirection="column" marginTop={1}>
          {sectionTitle(ui, 'Comments', allNone(ui, 'comments', actions))}
          {review.comments.map(comment =>
            row(ui, data, actions, {
              key: 'comment:' + comment.index,
              selected: comment.selected,
              lead: String(comment.ordinal ?? comment.index + 1),
              title: comment.title || firstSentence(comment.body),
              detail: [`${comment.path}${comment.line ? ':' + comment.line : ''}`, comment.severity, comment.lenses.join(', ')].filter(Boolean).join(' · '),
              body: comment.body,
              isEditable: true,
            }),
          )}
        </Box>
      ) : null}
      {review.findings.length > 0 ? (
        <Box key="findings" flexDirection="column" marginTop={1}>
          {sectionTitle(ui, 'Findings', allNone(ui, 'findings', actions))}
          {review.findings.map(finding =>
            row(ui, data, actions, {
              key: 'finding:' + finding.index,
              selected: finding.selected,
              lead: finding.severity ? finding.severity.slice(0, 1).toUpperCase() : '·',
              title: finding.title || firstSentence(finding.body),
              detail: [`${finding.file}${finding.line ? ':' + finding.line : ''}`, finding.severity, finding.lens].filter(Boolean).join(' · '),
              body: finding.grounding ? `${finding.body}\n\n*Grounding:* ${finding.grounding}` : finding.body,
              isEditable: false,
            }),
          )}
        </Box>
      ) : null}
      {footer(ui, review, data, findingsSelected, actions)}
      {review.comments.length === 0 && review.findings.length === 0 && !review.general ? (
        <Text dimColor>This review has no comments or findings to act on.</Text>
      ) : null}
      {!review.canPost && review.comments.length > 0 ? (
        <Text dimColor>This review can't be posted from here: its PR details are incomplete.</Text>
      ) : null}
      {data.busy ? <Text dimColor>{data.busy}…</Text> : null}
    </Box>
  )
}

function sectionTitle(ui: ElementTable, text: string, right: RenderElement | null): RenderElement {
  const { Box, Text } = ui
  return (
    <Box justifyContent="space-between">
      <Text weight="semibold" dimColor>
        {text}
      </Text>
      {right}
    </Box>
  )
}

function allNone(ui: ElementTable, kind: 'comments' | 'findings', actions: ReviewActions): RenderElement {
  const { Box, Text, Button } = ui
  return (
    <Box flexShrink={0}>
      <Button key={'all:' + kind} plain dimColor label="all" onPress={() => actions.setAll(kind, true)} />
      <Text dimColor> · </Text>
      <Button key={'none:' + kind} plain dimColor label="none" onPress={() => actions.setAll(kind, false)} />
    </Box>
  )
}

function eventRow(ui: ElementTable, event: LoreReviewEvent, actions: ReviewActions): RenderElement {
  const { Box, Button } = ui
  return (
    <Box key="event" marginTop={1} gap={1} flexWrap="wrap">
      {(Object.keys(EVENT_WORDS) as LoreReviewEvent[]).map(choice => (
        <Button
          key={'event:' + choice}
          variant={choice === event ? 'primary' : 'secondary'}
          dimColor={choice !== event}
          label={EVENT_WORDS[choice]}
          onPress={() => actions.setEvent(choice)}
        />
      ))}
    </Box>
  )
}

type Row = {
  key: string
  selected: boolean
  lead: string
  title: string
  detail: string
  body: string
  isEditable: boolean
}

// One comment, finding or the general body: a checkbox and a one-line
// headline, opening into its location, its whole text and what can be done
// to it.
function row(ui: ElementTable, data: ReviewData, actions: ReviewActions, item: Row): RenderElement {
  const { Box, Text, Button, Markdown } = ui
  const isOpen = data.open.includes(item.key)
  const isEditing = data.editing === item.key
  const Input = data.fields?.Input
  const lead = item.lead ? item.lead.padStart(2) + '  ' : ''
  const room = Math.max(8, data.width - ROW_LEAD - lead.length)
  return (
    <Box key={item.key} flexDirection="column">
      <Box>
        <Button key={'select:' + item.key} plain label={item.selected ? '[x]' : '[ ]'} onPress={() => actions.toggleSelected(item.key)} />
        <Text> </Text>
        <Button key={'row:' + item.key} plain onPress={() => actions.toggleRow(item.key)}>
          <Text dimColor>{isOpen ? '▾' : '▸'} </Text>
          {lead ? <Text dimColor>{lead}</Text> : null}
          <Text {...(item.selected ? {} : { dimColor: true })}>{cut(item.title, room)}</Text>
        </Button>
      </Box>
      {isOpen ? (
        <Box flexDirection="column" paddingLeft={4}>
          {item.detail ? (
            <Text dimColor wrap="truncate-middle">
              {item.detail}
            </Text>
          ) : null}
          {isEditing && Input ? (
            <Box flexDirection="column">
              <Input
                key={'input:' + item.key}
                value={toField(item.body)}
                submitLabel="save"
                autoFocus
                onSubmit={value => actions.save(item.key, fromField(value))}
              />
              <Text dimColor>⏎ marks a line break · Enter saves</Text>
            </Box>
          ) : (
            <Markdown text={cut(item.body, 9_800)} />
          )}
          <Box gap={2}>
            {item.isEditable && Input ? (
              <Button
                key={'edit:' + item.key}
                plain
                dimColor
                label={isEditing ? 'cancel' : 'edit'}
                onPress={() => actions.edit(isEditing ? null : item.key)}
              />
            ) : null}
            <Button key={'ask:' + item.key} plain dimColor label="ask Claude" onPress={() => actions.ask(item.key)} />
          </Box>
        </Box>
      ) : null}
    </Box>
  )
}

function postLabel(event: LoreReviewEvent, comments: number, hasBody: boolean): string {
  const what = comments > 0 ? plural(comments, 'comment') : hasBody ? 'the general comment' : ''
  if (event === 'APPROVE') return what ? `Approve with ${what}` : 'Approve'
  if (event === 'REQUEST_CHANGES') return `Request changes${what ? ' with ' + what : ''}`
  return `Post ${what}`
}

function footer(ui: ElementTable, review: LoreReview, data: ReviewData, findingsSelected: number, actions: ReviewActions): RenderElement | null {
  const { Box, Text, Button } = ui
  if (data.busy) return null
  const postable = postableOf(review)
  if (data.confirm) {
    const question =
      data.confirm === 'post'
        ? `${postLabel(review.event, postable.comments, postable.hasBody)} on #${review.pr ?? '?'}${review.repo ? ' in ' + review.repo : ''}?`
        : data.confirm === 'promote'
          ? `Promote ${plural(findingsSelected, 'finding')} to a work item?`
          : 'Dismiss this review? It moves to the archive.'
    const yes = data.confirm === 'post' ? 'Post' : data.confirm === 'promote' ? 'Promote' : 'Dismiss'
    return (
      <Box key="footer" flexDirection="column" marginTop={1}>
        <Text>{question}</Text>
        <Box gap={1}>
          <Button key="confirm" variant="primary" label={yes} onPress={actions.confirm} />
          <Button key="cancel" label="Cancel" onPress={() => actions.askConfirm(null)} />
        </Box>
      </Box>
    )
  }
  const hasComments = review.comments.length > 0 || review.general !== null
  return (
    <Box key="footer" marginTop={1} gap={2} flexWrap="wrap">
      {review.canPost && postable.isPostable ? (
        <Button key="post" variant="primary" label={postLabel(review.event, postable.comments, postable.hasBody)} onPress={() => actions.askConfirm('post')} />
      ) : review.canPost && hasComments ? (
        <Text dimColor>Select a comment to post</Text>
      ) : null}
      {findingsSelected > 0 ? (
        <Button key="promote" label={`Promote ${plural(findingsSelected, 'finding')}`} onPress={() => actions.askConfirm('promote')} />
      ) : null}
      {review.canPost ? <Button key="preview" plain dimColor label="preview" onPress={actions.preview} /> : null}
      {review.report ? <Button key="report" plain dimColor label="report" onPress={actions.report} /> : null}
      <Button key="dismiss" plain dimColor label="dismiss" onPress={() => actions.askConfirm('dismiss')} />
    </Box>
  )
}
