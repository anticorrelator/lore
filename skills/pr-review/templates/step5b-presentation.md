# Step 5b presentation templates (severity groups + supplementary)

Load when presenting the review at Step 5b.

## 5b. By severity

Present findings grouped by severity. Compound findings appear first within each group.

```
### Findings requiring action

#### 1. [compound] <title>
**Lenses:** correctness, security
**File:** `path/to/file.ext:42`

<merged body>

**Knowledge:** [knowledge: entry-title] — relevance summary

---

#### 2. <title>
**Lens:** correctness
**File:** `path/to/file.ext:87`

<body>

**Knowledge:** [knowledge: entry-title] — relevance summary

---

### Improvement opportunities
...

### Open questions
...
```

## 5b-supplementary. Supplementary Reports

Include this block **only** when one or more ceremony lenses produced non-conforming output (classified in Step 3d). Present each non-conforming ceremony lens result verbatim under its own header:

```
### Supplementary Reports

These reports are from ceremony-configured lenses that did not produce findings in the standard format. They are presented as-is and are not included in the synthesis verdict.

#### <skill-name> [ceremony]

<raw output from the ceremony lens>

---

#### <skill-name> [ceremony] [malformed]

<raw text from the ceremony lens that produced malformed JSON>
```
