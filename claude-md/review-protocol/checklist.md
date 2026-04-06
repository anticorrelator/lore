### 8-Point Review Checklist

Each item targets a specific failure mode observed in agent-generated code. Apply every item to each changed file or logical unit.

#### 1. Semantic contract check
Does the code honor the *semantic* contract of the abstractions it uses, not just the syntactic interface?

**Failure mode:** Agent code frequently calls APIs correctly at the type level but violates implicit contracts — e.g., calling a function in the wrong lifecycle phase, passing technically-valid but semantically-wrong arguments, or misusing a data structure's intended access pattern.

#### 2. Cross-boundary invariant trace
What invariants does this change assume about code it does *not* modify? Are those assumptions still valid?

**Failure mode:** Changes that are locally correct but break because they depend on undocumented invariants in other modules — ordering assumptions, state preconditions, or implicit coupling that isn't visible in the diff.

#### 3. Convention match
Does this follow *this project's* patterns, or does it use generic/textbook patterns that diverge from established conventions?

**Failure mode:** Agent code gravitates toward common patterns from training data rather than matching the specific conventions of the codebase. This creates inconsistency even when the code is technically correct.

#### 4. Rationale probe
Can the "why" behind each design choice be articulated? If the rationale is "this is how it's usually done," that's a flag.

**Failure mode:** Cargo-culted patterns — code that exists because the agent reproduced a common pattern without understanding whether it applies here. Often manifests as unnecessary abstractions, premature generalization, or framework idioms in non-framework code.

#### 5. Adversarial path analysis
What happens with empty inputs, null values, out-of-order calls, duplicate invocations, or concurrent access?

**Failure mode:** Agent code tends to handle the happy path thoroughly but miss edge cases that a human developer would catch through experience — especially around empty collections, missing keys, and race conditions.

#### 6. Proportionality check
Is the solution proportional to the problem? Are there new abstractions with only one consumer? Layers that don't carry their weight?

**Failure mode:** Over-engineering. Agent code frequently introduces unnecessary indirection — wrapper classes, strategy patterns, factory methods — for problems that need a function and a conditional.

#### 7. Existing utility scan
Does this duplicate functionality that already exists in the codebase or its dependencies?

**Failure mode:** Agent code creates new helpers, utilities, or implementations for things that already exist. Limited codebase awareness means it doesn't find existing solutions, leading to redundant code and missed opportunities to reuse.

#### 8. Test assertion audit
Do tests verify the *requirements*, or do they just confirm the generated code's behavior?

**Failure mode:** Tautological tests — agent writes implementation then writes tests that pass by construction because they test what the code does rather than what it should do. These tests provide false confidence and don't catch regressions.

