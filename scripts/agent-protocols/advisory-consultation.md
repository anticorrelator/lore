# Advisory Consultation Protocol

You have access to domain-expert advisors on your team. Consult them for guidance in their areas of expertise before and during implementation.

## Available Advisors

{{advisors}}

## Consultation Modes

Each advisor has a declared consultation mode:

### Must-Consult

**Before starting any task** that touches files or domains covered by a must-consult advisor, you MUST:

1. Send the advisor a consultation request via SendMessage:
   ```
   type: "message"
   recipient: "<advisor-name>"
   summary: "Consulting on <brief topic>"
   content: |
     **Task:** <task subject from TaskGet>
     **Files I will modify:** <list of files>
     **My approach:** <1-3 sentence summary of planned changes>
     **Specific questions:**
     - <concrete question about domain constraints, patterns, or risks>
   ```
2. **Wait for the advisor's response** before proceeding with implementation. Do not begin writing code until you receive their reply.
3. Incorporate the advisor's guidance into your implementation. If the advisor's response contradicts your planned approach, follow the advisor's guidance.

### On-Demand

On-demand advisors are available when you need them. Consult an on-demand advisor when:
- You encounter an unfamiliar pattern or convention in the advisor's domain
- You are unsure whether a change respects domain invariants
- You discover unexpected coupling or complexity in the advisor's area

Use the same SendMessage format as must-consult requests. You do not need to wait before starting work, but you should pause the relevant subtask while waiting for a response if your question affects correctness.

## Determining When to Consult

For must-consult advisors, the trigger is structural: any task touching covered files or domains requires consultation before implementation begins. There is no judgment call — if there is overlap, consult.

For on-demand advisors, consult when you have a specific question that the advisor's domain expertise would answer better than reading the code alone. Do not consult for general implementation questions that do not require domain knowledge.

## Report Format Addition

Include an `**Advisor input:**` section in your completion report (between `**Tests:**` and `**Discoveries:**`):

```
**Advisor input:**
- <advisor-name>: <one-sentence summary of the guidance received and how it influenced the implementation>
```

If you did not consult any advisor for a task (no must-consult overlap, no on-demand need), write:

```
**Advisor input:** None
```
