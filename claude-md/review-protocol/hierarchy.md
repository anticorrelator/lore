## Review Protocol

Shared reference for all PR review skills (`/pr-review`, `/pr-self-review`, `/pr-pair-review`, `/pr-revise`). Skills reference this protocol rather than duplicating the checklist.

### Review Hierarchy

Reviews proceed top-down through three tiers. Higher tiers gate lower ones — an architectural problem makes logic-level comments premature.

1. **Architecture / Approach** — Is the overall design sound? Right abstraction boundaries? Proportional to the problem?
2. **Logic / Correctness** — Does it work? Edge cases handled? Invariants preserved across boundaries?
3. **Maintainability / Evolvability** — Will this be easy to change later? Conventions followed? No unnecessary coupling?

Style and formatting are automated (linters, formatters) and are never review topics.

