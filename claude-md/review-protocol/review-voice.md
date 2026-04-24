### Review Voice

#### Purpose

Voice is distinct from grounding and severity. Grounding determines whether a finding has evidentiary weight — a concrete failure scenario or a named improvement. Severity determines how urgently the author should verify. Voice determines how that finding is expressed: the sentence structure, the framing of uncertainty, and the choice of words.

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

#### Verification Urgency by Severity

Severity calibrates the urgency of the verification ask. It does not calibrate reviewer confidence — all findings hedge the inference regardless of severity. A blocking finding is not a more-certain finding; it is a finding where the failure scenario, if real, cannot be shipped.

**Blocking — urgent verification request**

The verification ask is direct and frames the consequence of not verifying. The author should understand that this question needs an answer before the PR merges.

Before:
> You might want to look into whether the token expiry check is skipped when `exp` is absent.

After:
> The token expiry check is skipped when `exp` is absent — any token without that claim authenticates indefinitely. If tokens from external providers can omit `exp`, this is a merge blocker. Confirm whether the token source guarantees the field.

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

A finding body has three parts: an impact lead, evidence, and an optional fix suggestion.

**Impact lead — open with the observable consequence.**

The first sentence establishes why the finding matters. It names the failure scenario or the cost, not the code location. When a finding is produced via pr-review, the bolded title prefix (prepended by the review step) serves as the impact lead — the body then opens directly with evidence. When authoring findings manually, lead with the consequence.

Before (opens with location, buries impact):
> In `verifyToken()`, the `exp` field is not validated.

After (opens with consequence):
> Any token without an `exp` claim authenticates indefinitely — the expiry check is only reached when the field is present.

**Evidence — name the specific mechanism the author can check.**

Evidence is a short prose statement pointing to the code that makes the claim verifiable. It describes what the diff shows: a function, a path, a missing check. The author can confirm it directly against the diff without running the code.

Before (asserts the impact without grounding it):
> Token expiry is not enforced, which is a security issue.

After (names the mechanism):
> The `exp` claim is not validated in `verifyToken()` — the check at line 34 is only reached when `exp` is present, so absent-field tokens skip expiry entirely.

**Fix suggestion — include only when the fix is non-obvious, and keep it secondary.**

The default posture is to identify the issue and stop. The role of the review is to surface the problem with enough precision that the author can choose the response — a small local fix, a broader refactor, or a deeper redesign. Fix suggestions foreclose that judgment and inflate body length when the fix is evident. Include a suggestion only when one of these conditions holds: the fix is non-local (requires changes outside the immediate diff), the problem is hard to characterize without showing a resolution, or there are unusual constraints the author may not see.

Before (prescribes the obvious fix):
> Add a nil check before dereferencing `user`.

After (identifies the issue, stops — fix is self-evident):
> `session.user` is dereferenced at line 58 without a nil check — if this handler is reachable before authentication completes, the nil dereference panics.

When a suggestion is warranted:
- **Place it last** — after impact and evidence. Never lead a finding with a fix.
- **Frame it as one option** ("One approach: …"), not a directive.
- **Keep the scope open** — avoid language that commits the author to the smallest local patch if the finding could motivate a broader change.

> One approach: validate `exp` presence before signature verification, so the failure is an explicit rejection rather than a silent skip.

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
