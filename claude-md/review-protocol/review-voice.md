### Review Voice

#### Purpose

Voice is distinct from materiality and severity. The **materiality gate** (`severity.md`) determines whether a finding is worth surfacing at all. **Severity** is the reviewer's own triage axis — how urgently *they* should verify — and is not posted to the author; the conditional stake delegates that call to the reader instead. **Voice** determines how the finding is expressed: the sentence structure, the framing of uncertainty, and the choice of words.

Agent reviewers are not the authority on correctness. A reviewer analyzing a diff cannot know the full system context, the author's intent, or what tests already exist. Every finding is a hypothesis formed from incomplete information. Voice encodes this epistemic position without abandoning the finding's substance. A hedged observation that names the code precisely is more useful than a confident assertion that names nothing.

---

#### Uncertain Framing

Hedge the inference, not the observed code fact.

Code observations are direct — they describe what the diff shows. Impact claims are conditional — they describe what might follow from the observation if certain conditions hold. These two things have different epistemic status and should be framed differently.

**The pattern: observed fact → conditional impact → verification ask**

- **Observed fact:** state directly, without hedging. The reviewer can see the code.
- **Conditional impact:** state with an explicit condition. The reviewer cannot know whether the scenario applies.
- **Verification ask:** invite the author to confirm or clarify.

**Before (hedges the observation):**
> This might be storing the session token in a way that could potentially be readable.

**After (hedges the impact):**
> This function writes the session token to the log output. If the log destination is accessible outside the application process, that token is readable by anyone with log access — worth confirming whether log output is treated as sensitive in this environment.

**Before (asserts the impact):**
> This will cause a nil dereference and crash the server.

**After (hedges the impact, states the code fact directly):**
> `session.user` is dereferenced here without a nil check. If this handler is reachable before authentication completes, the nil dereference panics — confirm whether the middleware chain guarantees a non-nil user at this point.

The finding becomes weaker when the observation is hedged ("might be storing") and stronger when only the impact is hedged ("if this handler is reachable"). The goal is to be maximally precise about what was observed and appropriately uncertain about what it means.

---

#### Severity Calibrates the Reviewer, Not the Comment

Severity is the reviewer's triage axis — it orders what *they* look at and how urgently *they* verify. It is not posted to the author and it does not set the comment's tone. The posted comment is the same neutral shape regardless of severity: the **conditional stake** carries the stakes, and the reader — who knows whether the condition holds — assigns the criticality. A reviewer never writes "this is a merge blocker" into a comment; they state the fact and the condition and let it land.

What does change with severity is how sharply the condition is drawn. A high-stakes finding names the consequence concretely so the reader can weigh it; a low-stakes one stays light.

**High-stakes — name the consequence in the condition**

Before (hedges the observation, then asserts the verdict):
> You might want to look into whether the token expiry check is skipped when `exp` is absent — this is a merge blocker.

After (states the fact, draws the condition, lets the reader judge):
> The token expiry check is skipped when `exp` is absent — any token without that claim authenticates indefinitely if the token source can omit the field.

**Suggestion — low-pressure observation**

The verification ask is a light invitation, not a demand. The author can address it now or defer it.

Before:
> You should really extract the retry logic into a helper function because it's used in many places.

After:
> The retry loop appears in three callsites with identical logic. Extracting it into `withRetry()` would let each callsite express intent without repeating implementation — worth considering if there's future work planned in this area.

**Question — genuine uncertainty**

The reviewer does not know whether a concern exists. The ask is a direct question without an embedded claim.

Before:
> I'm not sure if this is intentional, but maybe the fallback behavior could cause issues?

After:
> When `config.Timeout` is zero, this falls back to a 30-second default. Is zero a valid caller-supplied value, or should it be treated as "not set"?

---

#### Sentence Structure

**Lead with the observation, not the hedge.**

The observation is the signal. The hedge is epistemic context. When the hedge leads, the reader has to parse through uncertainty qualifiers before reaching the fact. Put the fact first.

Before:
> It seems like there may be a case where the lock is not released.

After:
> The lock acquired at line 42 is not released in the error path at line 58.

**Use active voice for code observations.**

Passive constructions obscure which code is doing what.

Before:
> The token is not being validated before the handler is called.

After:
> `authMiddleware` does not validate the token before calling the handler.

**Keep conditionals explicit.**

When a finding depends on a condition, name the condition precisely rather than leaving it implied.

Before:
> This could panic if something goes wrong.

After:
> `items[0]` is accessed without a length check — if `items` is empty, this panics.

---

#### Body Construction

**Lead with the path, not the code — and post one distilled line.** A posted comment is an input to the reader's triage — and the reader has *domain* context but not your *code-internal* context. The job is to translate from code facts (which you have) into the usage-level path (which they can map): *when* does this happen, and *what would they see* — and post that as a single scannable line. A reviewer fielding a dozen-plus findings, often across several reviewers, cannot hold a paragraph per finding in their head, so the posted comment is one line, not a re-oriented-but-still-long writeup. A second sentence is earned only by a soft fix-as-question, never by more explanation.

The full three-part body below is the **reviewer-facing** finding — the cockpit, where the mechanism anchor, caveats, and lens attribution live. The posted comment is its distilled translation: keep the path, drop the call-chain and the caveats. A finding body has three parts: a path lead, an optional mechanism anchor, and an optional fix suggestion.

**Path lead — open with when it happens and what you'd see.**

The first sentence establishes the trigger (in usage terms) and the observable symptom — not the code location, and not an internal call chain. When a finding is produced via pr-review, the bolded title prefix carries the headline; the body then opens with the path. A reviewer who has never seen the code should be able to read the lead and judge whether the trigger is realistic and the outcome a problem.

Before (code-state — unsituatable, can't be judged):
> `toolChoice` may be left pointing at a removed tool name.

After (path — a reviewer can judge it):
> If the agent renames a tool that's set as the prompt's required choice, the next run is rejected by the provider for forcing a tool that no longer exists — and the write gave no warning.

**Mechanism anchor — optional, secondary, for the author who wants to verify.**

The code mechanism (function, path, missing check) is a short trailing anchor that lets the *author* confirm the claim against the diff — it is not the substance and never leads. Keep it to a clause, and never let it replace the usage-level path: a comment that is *only* mechanism ("the reset fires only on the delete path") leaves an unfamiliar reviewer unable to situate the problem.

Before (mechanism stands in for the path):
> The `exp` claim is not validated in `verifyToken()` — the check at line 34 is only reached when `exp` is present.

After (path leads; mechanism anchors):
> Any externally-issued token that omits `exp` authenticates indefinitely. (The expiry check in `verifyToken()` is only reached when the field is present.)

**Fix suggestion — include only when the fix is non-obvious, and keep it secondary.**

The default posture is to identify the issue and stop. The role of the review is to surface the problem with enough precision that the author can choose the response — a small local fix, a broader refactor, or a deeper redesign. Fix suggestions foreclose that judgment and inflate body length when the fix is evident. Include a suggestion only when one of these conditions holds: the fix is non-local (requires changes outside the immediate diff), the problem is hard to characterize without showing a resolution, or there are unusual constraints the author may not see.

Before (prescribes the obvious fix):
> Add a nil check before dereferencing `user`.

After (identifies the issue, stops — fix is self-evident):
> `session.user` is dereferenced at line 58 without a nil check — if this handler is reachable before authentication completes, the nil dereference panics.

When a suggestion is warranted:
- **Place it last** — after impact and evidence. Never lead a finding with a fix.
- **Frame it softly — as a question or a light suggestion, never a confident prescription.** The reviewer is missing the context that would justify a directive, so a fix should invite the author's judgment rather than presume it. Prefer the question form when it fits ("Share a `withRetry()`, or is the duplication deliberate?"); otherwise a tentative "Worth …?" or "Could … here?" Avoid framings that sound settled.
- **Keep the scope open** — avoid language that commits the author to the smallest local patch if the finding could motivate a broader change.

> Could `exp` presence be validated before signature verification, so the failure is an explicit rejection rather than a silent skip?

---

#### Anchored Deixis (Inline Comments)

A posted inline comment is attached to a specific line, so every demonstrative — "this", "these", "here" — must resolve to something visible *on that line*. The reviewer-facing report has the whole finding in view; the author has only the anchored line plus the comment.

This also reconciles deixis with the lead-in-usage-terms rule: a symbol that appears **on the commented line** is a legitimate anchor — naming it resolves the reference, it is not jargon. A symbol that lives **off-screen** (a function called elsewhere, a type defined in another file) is the mechanism that belongs in the cockpit, not the comment.

When the issue spans several spots, anchor on the first occurrence and give a count the author can verify — "the other 9 occurrences" — never a vague plural that points off-screen.

Before (points off-screen — the author cannot see "these cases"):
> These eval cases still declare the removed `instanceIds` shape.

After (anchored to the line; the count is verifiable):
> This declares the removed `instanceIds` shape (9 other lines in this file do too) — the agent is handed an empty instance list at runtime.

---

#### Addressing the Author

Use impersonal constructions that describe the code, not the author's choices.

Findings that address "you" carry an implicit accusation about intent or competence. The concern is about the code, not the person who wrote it. Impersonal constructions ("this function", "the handler", "this path") keep the focus on the artifact.

Before:
> You should add a nil check here before dereferencing.

After:
> A nil check before the dereference at line 34 would prevent a panic if `user` is absent.

Before:
> You forgot to close the file handle in the error path.

After:
> The file handle opened at line 12 is not closed in the error path at line 29 — this leaks a file descriptor on each error.

The exception: direct questions to the author are natural and appropriate for question-severity findings. "Was this intentional?" and "Can callers pass nil here?" are direct without being accusatory.

---

#### Vocabulary to Avoid

**Terms that overstate reviewer confidence** — these assert certainty the reviewer does not have:

| Avoid | Prefer |
|-------|--------|
| "this will crash" | "this panics if `x` is nil" |
| "this is wrong" | "this deviates from the contract in..." |
| "this is a bug" | "this produces incorrect output when..." |
| "this will fail" | "this returns an error when..." |
| "definitely", "certainly" | name the specific condition |

**Terms that weaken findings** — these introduce uncertainty where precision is possible:

| Avoid | Prefer |
|-------|--------|
| "seems like" | state the observation directly |
| "might want to consider" | state the benefit directly, then invite action |
| "could potentially" | name the condition; "could" without a condition is not informative |
| "I think" | state the code fact; hedge the impact, not the observation |
| "maybe", "perhaps" (for observations) | reserve for genuine uncertainty about conditions, not observations |

The asymmetry: hedge impact claims, not code observations. "This might be a problem" hedges the observation. "This is a nil dereference — if the nil case is reachable from user input, it panics" hedges the impact. The second is both more honest and more useful.

---

#### Rhetorical Padding

State the fact and stop. These flourishes add length without adding information, and they read worse at the volume an author faces across a review:

- **Validation flourishes** — "Good catch on X, but…", "Nicely structured, though…". The comment's job is the finding, not reassurance.
- **Restating the author's point back as insight** — re-narrating what the diff already does before getting to the issue. The author wrote it; open with what they cannot see.

The one to judge, not ban, is the **"X, not Y" closer**. When the contrast *is* the finding — "delete already resets the choice; rename doesn't" — it is the most compact way to state the asymmetry that makes this a bug; keep it. When it merely editorializes — "this is fragile, not robust" — it is padding; cut it. The test is whether the contrast carries the asymmetry being flagged or just decorates it.
