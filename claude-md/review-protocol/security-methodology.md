#### Security Lens Methodology

Canonical methodology for the security lens (`pr-security`). This is referenced by both the standalone `/pr-security` skill and the `/pr-review` orchestrator when spawning a security lens agent.

For each file with security-relevant changes, apply these checks:

**3a. Input validation** — For every function that accepts external input (user data, API parameters, file contents, environment variables, URL parameters):
- Is input validated before use? Check for type, length, range, and format validation
- Are validation errors handled explicitly (not silently swallowed)?
- Is validation applied at the boundary, not deferred to internal code?

**3b. Injection risk analysis** — For code that constructs queries, commands, or markup from dynamic data:
- SQL: parameterized queries or ORM, not string concatenation
- Command execution: argument arrays, not shell string interpolation
- HTML/template: context-aware escaping, not raw interpolation
- Path traversal: canonicalization and prefix validation for file paths built from input

**3c. Auth/authz boundary violations** — For code that gates access to resources or operations:
- Is authentication checked before authorization?
- Are authorization checks applied at the resource level, not just the route level?
- Do new endpoints or operations inherit the correct auth middleware?
- Are permission escalation paths possible (e.g., modifying a role check without updating dependent checks)?

**3d. Cryptographic misuse** — For code that uses cryptographic operations:
- Are deprecated algorithms used (MD5, SHA1 for security, ECB mode, DES)?
- Are keys/IVs hardcoded or derived from predictable sources?
- Is random number generation using a cryptographically secure source?
- Are comparison operations constant-time where timing attacks are relevant?

**3e. Secrets exposure** — For code changes that handle credentials, tokens, or keys:
- Are secrets logged, included in error messages, or exposed in responses?
- Are secrets stored in environment variables or secret managers, not in code?
- Do new configuration files or environment variable additions introduce secret storage?
- Are secrets removed from version control if previously committed?

**3f. Edge cases (empty/null/concurrent)** — Security-specific edge cases beyond general correctness:
- Empty or null values that bypass validation (e.g., empty string passing a "not null" check)
- Race conditions in authentication or authorization checks (TOCTOU)
- Concurrent access to shared resources without proper synchronization
- Integer overflow or underflow in security-critical calculations (e.g., permission bitmasks)

**3g. Adversarial path analysis** — Think like an attacker:
- What is the most valuable asset accessible through this code path?
- What is the minimum effort to reach that asset from an unauthenticated state?
- Are there paths that combine individually-benign operations into a harmful sequence?
- Does this change widen the attack surface (new endpoints, new input sources, new dependencies)?

**Scoping for large diffs:** If more than ~10 files have security-relevant changes, prioritize: (1) authentication/authorization boundaries, (2) external input handlers, (3) cryptographic operations, (4) new endpoints or API surfaces. Apply full methodology to priority files; do a lighter pass on the rest.

