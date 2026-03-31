### AI-Awareness Calibration

When the `--ai` flag is active (or AI authorship is auto-detected from the PR description), review calibration shifts to account for known AI-generated code failure modes. This section defines the specific adjustments — they are additive to the standard review process, not a replacement.

#### Hallucination check

Verify that every API, function, method, class, or module referenced in the changed code actually exists in the codebase or its declared dependencies. AI-generated code has a unique failure mode: calling nonexistent APIs with plausible-looking signatures.

**Procedure:**
1. For each new function call, import, or type reference in the diff, confirm it resolves to a real definition
2. For external dependencies, confirm the referenced version exports the used API
3. Flag any reference that cannot be traced to a real definition as a `blocking` finding with title "Hallucinated reference"

This check applies to all lens passes when `--ai` is active. Each lens agent includes it as part of its methodology.

#### Amplified review weights

When `--ai` is active, the following checklist items receive elevated attention:

| Checklist item | Standard weight | `--ai` weight | Rationale |
|---------------|----------------|---------------|-----------|
| 5. Adversarial path analysis | Normal | Elevated | AI code handles happy paths well but misses edge cases at ~3x the rate |
| 1. Semantic contract check | Normal | Elevated | AI code uses APIs correctly at the type level but violates implicit contracts |
| 8. Test assertion audit | Normal | Elevated | AI-generated tests are frequently tautological |
| 3. Convention match | Normal | Elevated | AI gravitates toward training-data patterns over project conventions |

"Elevated" means: apply the checklist item with extra scrutiny, flag marginal cases as `suggestion` rather than skipping, and consider Investigation Escalation (see below) for ambiguous findings.

#### Proof evidence requirement

When `--ai` is active, the synthesis step must include a **proof evidence** section in the final output. This shifts review from "does the code look right?" to "is there evidence the code works?"

**Required proof types (at least one per blocking or compound finding):**
- Test results demonstrating the behavior works as intended
- Manual verification steps the reviewer performed
- Trace of the code path confirming correct execution
- Reference to an existing test that covers the changed behavior

If no proof evidence can be produced for a blocking finding, append "[unverified]" to the finding title. This signals to the author that the finding is based on analysis, not confirmed behavior.

