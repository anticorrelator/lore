# pr-revise Section 3 Review Findings table template

Used by `/pr-revise` Step 7b when emitting Section 3 of the followup report.

```markdown
## Review Findings

| # | Label | Item | File:Line | Category | Knowledge | Reviewer Quote | Summary |
|---|-------|------|-----------|----------|-----------|----------------|---------|
| 1 | issue | <title> | <file:line> | Agreed Changes | <citation or —> | "<quote>" | <hedged framing> |
| 2 | suggestion | <title> | <file:line> | Verification Needed | <citation or —> | "<quote>" | <hedged framing> |
| 3 | question | <title> | <file:line> | Deferred | <citation or —> | "<quote>" | <hedged framing> |
```

- **Label** column... - **Category** column... - **Knowledge** column... - **Reviewer Quote** column... - **Summary** column: the mechanism → consequence chain from the item's grounding, expressed in hedged voice. Must name the specific code behavior (mechanism) AND the observable impact that follows (consequence). The Reviewer Quote column already carries the reviewer's phrasing — do not restate it here. Follow `~/.lore/claude-md/review-protocol/review-voice.md`: hedge the inference, not the observed code fact. Key forms: "`<function>` does X — if <condition>, <consequence>" for issues; "the <situation> means <person> has to <friction>; <change> removes it" for suggestions; the reviewer's open question verbatim for question-labeled items. Do not include internal analysis headers (`**Grounding:**`, `**Severity:**`, etc.) — they are internal protocol language and must not appear in the report.
