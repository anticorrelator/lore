# Agent Protocols

Lightweight injectable protocol fragments for agent output formats and behavioral constraints.

## Three-Tier Agent Architecture

Lore uses three tiers of agent definition, from most to least formal:

### Tier 1: Explicit Protocol Agents (`agents/` → `~/.claude/agents/`)

Durable, named agent definitions for roles with complex protocols that are prone to instruction fade. These define the full behavioral contract: report format, tool usage, knowledge retrieval expectations, and completion workflow.

Canonical source lives in the repo's `agents/` directory. `install.sh` symlinks each `.md` file to `~/.claude/agents/` for global availability across all projects. Skills reference agents via the global path (`~/.claude/agents/X.md`).

**When to use:** The role has a multi-step protocol that agents frequently drift from when instructions are inlined in a spawn prompt. Creating an explicit definition anchors the protocol in a stable file that skills reference by name.

**Current agents:**
- `researcher.md` — read-only investigation agent used by `/spec`
- `worker.md` — read-write implementation agent used by `/implement`
- `advisor.md` — read-only domain advisor agent used by `/implement` when plans declare advisors
- `classifier.md` — read-only significance classification agent used by `/renormalize`
- `structure-analyst.md` — read-only cluster/imbalance analysis agent used by `/renormalize`
- `crossref-scout.md` — read-only cross-reference discovery agent used by `/renormalize`

### Tier 2: Protocol Mixins (`scripts/agent-protocols/`)

Single-file protocol fragments that define a specific output format or behavioral constraint. A mixin is injected into an agent's prompt alongside (not instead of) its tier-1 definition or ad-hoc instructions. Mixins are composable — an agent can receive multiple mixins.

**When to use:** A specific output format or constraint applies to some invocations of an agent but not all. Rather than forking the agent definition, add a mixin that layers the additional protocol on top.

**Examples:**
- `verifier-verdict.md` — defines the structured verdict format (confirmed/refuted/uncertain + evidence) for agents performing assertion verification. The same researcher agent definition works for both general investigation and verification — the mixin adds the verdict protocol only when needed.
- `advisory-consultation.md` — defines the consultation workflow for workers that have access to advisor agents. Contains a `{{advisors}}` template variable resolved at injection time with advisor names, domains, and consultation modes (must-consult vs on-demand). Workers follow the mixin to request domain-specific guidance via SendMessage before or during implementation.

### Tier 3: Ad-Hoc Agents

No definition file. The lead composes the agent's behavior entirely in the spawn prompt. Used for one-off or simple tasks where the overhead of a formal definition provides no benefit.

**When to use:** The task is straightforward, the output format is simple, and instruction fade is not a concern. Most Explore agents spawned for investigation escalation (e.g., in review skills) fall into this tier.

**Example:** An Explore agent spawned to check whether a function is called from multiple sites. The prompt is a focused question with a file list — no complex protocol to drift from.

## Choosing a Tier

| Signal | Tier |
|--------|------|
| Role is reused across multiple skills | Tier 1 |
| Protocol has >3 required output fields | Tier 1 |
| Agents frequently omit parts of the protocol | Tier 1 |
| Format applies to some invocations but not all | Tier 2 (mixin) |
| Constraint is orthogonal to the agent's core role | Tier 2 (mixin) |
| Task is one-off with simple output | Tier 3 (ad-hoc) |
| Output is a single answer or short summary | Tier 3 (ad-hoc) |

## File Convention

Protocol mixin files in this directory use the naming pattern `<purpose>.md`. Each file is self-contained: it defines the output format, any constraints, and examples. Skills inject the file content into agent prompts using `Read` or `cat`. Mixins that use template variables (e.g., `{{advisors}}` in `advisory-consultation.md`) are resolved by the injecting skill before concatenation into the agent prompt.

**Current mixins:**
- `verifier-verdict.md` — structured verdict format for assertion verification
- `advisory-consultation.md` — advisor consultation workflow with template variable injection
