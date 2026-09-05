#!/usr/bin/env bash
# task-completed-capture-check.sh — TaskCompleted hook
# Ensures agents in impl-*/spec-* teams include required sections in
# their completion reports before marking tasks done.
# Agent type is read from team config to determine requirements.
#
# Compiled reports validate the assigned immutable dispatch and durable report
# before legacy team/template gates. Empty observations do not waive evidence.
# Legacy stamped reports retain structured-observation and convention checks;
# unstamped reports retain their migration warning and compatibility bypass.
#
# Input: JSON on stdin (TaskCompleted hook format)
# Output: exit 0 to allow, exit 2 + stderr to block

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
lore_agent_enabled || exit 0

INPUT=$(cat)

# Native TaskCompleted supplies task_id and task_description, but no assigned
# report identity. The wrapper retains its reference in native task metadata;
# fallback callers pass the same reference directly in the completion input.
TEAMS_DIR=$(resolve_harness_install_path teams 2>/dev/null || true)
COMPILED_RC=0
python3 - "$SCRIPT_DIR" "$TEAMS_DIR" 3<<<"$INPUT" <<'COMPILED_PY' || COMPILED_RC=$?
import importlib.util
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys

scripts, teams = Path(sys.argv[1]), sys.argv[2]
sys.path.insert(0, str(scripts))


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, scripts / filename)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def command(argv, **kwargs):
    result = subprocess.run(argv, capture_output=True, text=True, **kwargs)
    require(result.returncode == 0, result.stderr.strip() or result.stdout.strip() or
            f'{Path(argv[1]).name} failed ({result.returncode})')
    return result.stdout


def fields(text):
    headers, sections, current = {}, {}, None
    for line in text.splitlines():
        section = re.match(r'^\s*\*\*([^*]+?):\*\*\s*(.*)$', line)
        header = re.match(r'^([A-Za-z][A-Za-z0-9 -]+):[ \t]*(.*)$', line)
        if section or (header and header[1] == 'Task'):
            match = section or header
            current = match[1]
            require(current not in sections, f'duplicate report label: {current}')
            sections[current] = [match[2]]
        elif current is None and header:
            require(header[1] not in headers, f'duplicate report header: {header[1]}')
            headers[header[1]] = header[2].strip()
        elif current is not None:
            # Schema-1 Task is a header even though section readers also accept it.
            if current == 'Task' and header:
                require(header[1] not in headers, f'duplicate report header: {header[1]}')
                headers[header[1]] = header[2].strip()
            else:
                sections[current].append(line)
    return headers, {key: '\n'.join(value).strip() for key, value in sections.items()}


def marked(value):
    if any(re.match(r'^(?:position[-_]dispatch|compiled[-_]position)', key, re.I) for key in value):
        return True
    text = value.get('task_description') or ''
    return bool(re.search(r'^[ \t]*(?:\*\*)?(?:position[-_]dispatch|compiled[-_]position|'
                          r'template[-_]id:[ \t]*position/)', text, re.I | re.M))


try:
    event = json.load(os.fdopen(3))
    require(isinstance(event, dict), 'completion input must be an object')
    metadata = {}
    team, native_id = event.get('team_name'), event.get('task_id')
    if teams and teams != 'unsupported' and team and native_id:
        require(all(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', str(v))
                    for v in (team, native_id)), 'invalid native task identity')
        task_file = Path(teams).parent / 'tasks' / team / f'{native_id}.json'
        if task_file.exists():
            task = json.loads(task_file.read_text())
            metadata = task.get('metadata') or {}
            require(isinstance(metadata, dict), 'invalid native task metadata')
    if not marked(event) and not marked(metadata):
        sys.exit(3)
    import yaml
    binder = module('completion_position_bind', 'position-bind.py')
    assigned = metadata.get('position_dispatch', event.get('position_dispatch'))
    require(isinstance(assigned, dict), 'compiled completion requires assigned position_dispatch reference')
    if 'position_dispatch' in metadata and 'position_dispatch' in event:
        require(metadata['position_dispatch'] == event['position_dispatch'], 'conflicting assigned dispatch references')
    path, sha = assigned.get('manifest_path'), assigned.get('manifest_sha256')
    require(isinstance(path, str) and Path(path).is_absolute() and
            isinstance(sha, str) and re.fullmatch(r'[0-9a-f]{64}', sha),
            'compiled completion requires absolute manifest_path and full manifest_sha256')
    task_id = metadata.get('lore_task_id', event.get('lore_task_id', native_id))
    require(isinstance(task_id, str) and task_id, 'compiled completion requires independent task identity')
    expected = {'task_id': task_id, 'position': 'worker'}
    if team and team.startswith(('impl-', 'spec-')):
        expected['work_item'] = team.split('-', 1)[1]
    for key in ('work_item', 'report_id', 'dispatch_attempt_id', 'packet_id', 'revision_id', 'position', 'framework'):
        if key in event:
            require(key not in expected or expected[key] == event[key], f'conflicting completion {key}')
            expected[key] = event[key]
    manifest = binder.validate_dispatch(path, sha, expected=expected)
    binding, producer = manifest['bindings'], manifest['producer']
    require(all(binding.get(key) for key in binder.TASK_BINDINGS), 'compiled task completion requires task/revision/packet bindings')
    item = Path(manifest['work_item_path'])
    report_path = Path(binding['report_path'])
    require(report_path.is_file() and not report_path.is_symlink(), 'durable report missing at assigned report path')
    report = report_path.read_text()
    supplied = event.get('task_description')
    if supplied:
        require(supplied.rstrip('\n') == report.rstrip('\n'), 'task description differs from durable report')
    headers, sections = fields(report)
    required_headers = {'Report-schema': '1', 'Report-id': binding['report_id'],
                        'Work-item': binding['work_item'], 'Producer-role': 'worker',
                        'Harness': producer['framework'], 'Template-version': producer['template_version'],
                        'Position-dispatch-manifest': path, 'Position-dispatch-sha256': sha,
                        'Packet-id': binding['packet_id'], 'Revision-id': binding['revision_id'],
                        'Dispatch-attempt-id': binding['dispatch_attempt_id']}
    for label, value in required_headers.items():
        require(headers.get(label) == value, f'report {label} missing or mismatched')
    require(headers.get('Status') in ('completed', 'degraded'), 'report status does not permit completion')
    require(headers.get('Dispatch-path') in ('harness-subagent', 'codex-chaperone', 'worker-session'), 'invalid report Dispatch-path')
    for label in ('Task', 'Artifacts', 'Changes', 'Checks', 'Skills used', 'Observations',
                  'Tier 2 evidence', 'Convention handling', 'Surfaced concerns', 'Blockers'):
        require(sections.get(label), f'missing or empty report section: {label}')
    require(sections['Blockers'].lower() == 'none', 'report has blockers')
    observations = yaml.safe_load(sections['Observations'])
    empty = observations == [] or observations == [{'claim': 'None'}] or observations == 'None'
    if not empty:
        require(isinstance(observations, list) and observations, 'malformed compiled observations')
        for observation in observations:
            require(isinstance(observation, dict) and all(observation.get(key) for key in
                    ('claim', 'file', 'line_range', 'exact_snippet', 'normalized_snippet_hash', 'falsifier', 'significance')),
                    'malformed compiled observation entry')
            require(observation['significance'] in ('low', 'medium', 'high'), 'invalid observation significance')
        command(['python3', str(scripts / 'validate-structured-report.py'), 'Observations'], input=report)
    tier_body = sections['Tier 2 evidence']
    ids = [] if tier_body == 'none' else yaml.safe_load(tier_body)
    require(isinstance(ids, list) and all(isinstance(cid, str) and cid for cid in ids), 'invalid Tier 2 evidence references')
    require(len(ids) == len(set(ids)), 'duplicate Tier 2 evidence references')
    canonical = []
    if ids:
        canonical = [json.loads(line) for line in (item / 'task-claims.jsonl').read_text().splitlines() if line.strip()]
    for cid in ids:
        rows = [row for row in canonical if row.get('claim_id') == cid]
        require(len(rows) == 1, f'canonical claim missing or ambiguous: {cid}')
        require(rows[0].get('task_id') == task_id and rows[0].get('producer_role') == 'worker', f'canonical claim task/producer mismatch: {cid}')
        command(['bash', str(scripts / 'validate-tier2.sh')], input=json.dumps(rows[0]))
    if not empty:
        root = Path(binding['execution_root'])
        for observation in observations:
            observed_file = Path(observation['file'])
            if not observed_file.is_absolute():
                observed_file = root / observed_file
            require(any(row.get('claim_id') in ids and
                        (root / row['file']).resolve() == observed_file.resolve() and
                        all(row.get(key) == observation.get(key) for key in
                            ('claim', 'line_range', 'exact_snippet', 'normalized_snippet_hash', 'falsifier'))
                        for row in canonical), 'observation has no matching referenced canonical claim')
    if 'Tier 3 candidates' in sections:
        candidates = yaml.safe_load(sections['Tier 3 candidates'])
        require(isinstance(candidates, list) and candidates, 'invalid Tier 3 candidates')
        for candidate in candidates:
            require(isinstance(candidate, dict) and all(candidate.get(key) for key in
                    ('claim', 'why_future_agent_cares', 'falsifier', 'source_artifact_ids')), 'invalid Tier 3 candidate')
            require(isinstance(candidate['source_artifact_ids'], list) and
                    all(cid in ids for cid in candidate['source_artifact_ids']), 'Tier 3 candidate references unreported claims')
    artifacts = yaml.safe_load(sections['Artifacts'])
    require(isinstance(artifacts, list) and artifacts, 'Artifacts must index durable evidence')
    evidence = runpy.run_path(str(scripts / 'work-evidence.py'))
    result_ids = set()
    for artifact in artifacts:
        require(isinstance(artifact, dict) and all(isinstance(artifact.get(key), str) and artifact[key].strip()
                    for key in ('path', 'kind', 'writer', 'identity')), 'invalid artifact entry')
        target = Path(artifact['path'])
        if not target.is_absolute():
            base = Path(binding['execution_root']) if artifact['kind'] == 'source' else item
            target = base / target
        require(target.is_file(), f'artifact missing: {target}')
        identity = artifact['identity']
        if artifact['kind'] == 'source':
            root = Path(binding['execution_root'])
            relative = str(target.resolve().relative_to(root))
            if identity not in (artifact['path'], str(target), relative):
                require(re.fullmatch(r'[0-9a-f]{7,40}', identity), 'source identity must be a revision or its path')
                command(['git', '-C', str(root), 'cat-file', '-e', f'{identity}:{relative}'])
        elif artifact['kind'] == 'tier2-claims':
            require(target.resolve() == (item / 'task-claims.jsonl').resolve() and identity in ids and
                    artifact['writer'] == 'evidence-append.sh', 'artifact claim is not a referenced canonical row')
        elif artifact['kind'] == 'result' or identity.startswith('result-'):
            source = evidence['read_ledger'](item / 'results.jsonl', item, {'1'})
            evidence['validate_records'](source, 'results')
            require(source['state'] == 'read', 'canonical result history unavailable')
            rows = [row for row in source['rows'] if row.get('result_id') == identity]
            require(len(rows) == 1, 'canonical result missing or ambiguous')
            row = rows[0]
            require(artifact['writer'] == 'criteria-run.sh', 'result artifact requires canonical writer')
            refs = evidence['references'](row, item, Path(manifest['kdir']))
            allowed_paths = {(item / ref['reference']).resolve() for ref in refs}
            allowed_paths.add((item / 'results.jsonl').resolve())
            require(target.resolve() in allowed_paths, 'result artifact path mismatch')
            result_ids.add(identity)
            require(all(row.get(key) == binding[key] for key in
                        ('task_id', 'revision_id', 'packet_id', 'dispatch_attempt_id')), 'result binding mismatch')
            require(all(ref['state'] == 'read' for ref in evidence['references'](row, item, Path(manifest['kdir']))),
                    'canonical result artifact missing or corrupt')
    cited_results = set(re.findall(r'\bresult-[A-Za-z0-9_-]+', sections['Checks']))
    require(cited_results <= result_ids, 'Checks cites a result without a validated artifact')
    history = evidence['read_ledger'](item / 'revisions.jsonl', item, {'1'})
    evidence['validate_records'](history, 'revisions')
    require(history['state'] == 'read', 'revision history unavailable')
    revisions = [row for row in history['rows'] if row.get('record_type', 'revision') == 'revision'
                 and row['revision_id'] == binding['revision_id']]
    require(len(revisions) == 1, 'assigned revision missing or ambiguous')
    revision = revisions[0]
    require(all(ref['state'] == 'read' for ref in evidence['references'](revision, item, Path(manifest['kdir']))),
            'assigned revision snapshot missing or corrupt')
    snapshot = json.loads((item / revision['tasks_path']).read_text())
    tasks = [task for task in evidence['task_rows'](snapshot) if task.get('id') == task_id]
    require(len(tasks) == 1, 'assigned task missing from revision')
    required_domains = tasks[0].get('consultations_required')
    if required_domains is None:
        parser = runpy.run_path(str(scripts / 'generate-tasks.py'))['_parse_consultations_required']
        phase = next((p for p in snapshot.get('phases', []) if tasks[0] in p.get('tasks', [])), {})
        required_domains = parser(tasks[0].get('description') or '') or parser(phase.get('phase_context') or '')
    require(isinstance(required_domains, list), 'invalid assigned consultation requirements')
    transcript = item / 'consultation-transcript.jsonl'
    if required_domains:
        require(transcript.is_file(), 'required consultations need canonical transcript')
        replies = [json.loads(line) for line in transcript.read_text().splitlines() if line.strip()]
        consultations = yaml.safe_load(sections.get('Consultations', '[]'))
        require(isinstance(consultations, list), 'required consultations missing from report')
        for domain in required_domains:
            require(any(isinstance(entry, dict) and entry.get('domain') == domain and
                        any(reply.get('consultation_id') == entry.get('consultation_id') and
                            reply.get('domain') == domain and reply.get('handler') == entry.get('handler') and
                            reply.get('answer') and reply.get('replied_at') for reply in replies)
                        for entry in consultations), f'required consultation lacks canonical acknowledgment: {domain}')
    env = dict(os.environ, LORE_KNOWLEDGE_DIR=manifest['kdir'])
    argv = ['bash', str(scripts / 'impl-check-report.sh'), binding['work_item'], '--task', task_id,
            '--report', str(report_path), '--provider-status', 'unavailable', '--json']
    if transcript.is_file():
        argv += ['--transcript', str(transcript)]
    log = item / 'execution-log.md'
    before = log.read_bytes() if log.is_file() else b''
    checked = json.loads(command(argv, env=env))
    require(log.is_file(), 'canonical report-check append did not produce a log file')
    after = log.read_bytes()
    require(after.startswith(before) and len(after) > len(before) and
            f'Check-report task: {task_id}'.encode() in after[len(before):],
            'canonical report-check append missing from durable log')
    require(checked.get('mechanical_pass') and checked.get('execution_log') == 'appended', 'canonical report checks did not complete')
    print('[task-completed] compiled report validated; prepared reference is not delivery or acceptance evidence', file=sys.stderr)
except Exception as exc:
    print(f'[task-completed] compiled completion failed: {exc}', file=sys.stderr)
    sys.exit(2)
COMPILED_PY
case "$COMPILED_RC" in
  0) exit 0 ;;
  3) ;; # No compiled marker: preserve the legacy gates below.
  *) exit 2 ;;
esac

# Extract fields from hook input
TEAM_NAME=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('team_name') or '')")

# Fast exit: not a team task
if [[ -z "$TEAM_NAME" ]]; then
  exit 0
fi

# Only enforce for impl-*/spec-* teams
case "$TEAM_NAME" in
  impl-*|spec-*) ;;
  *) exit 0 ;;
esac

TASK_DESC=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('task_description') or '')")
AGENT_NAME=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('teammate_name') or d.get('agent_name') or d.get('owner') or '')")

# Legacy reports retain the degraded-capability bypass when team metadata
# cannot be read. Explicit compiled attempts have already been validated.
if [[ -z "$TEAMS_DIR" ]]; then
  echo "[lore] degraded: task-completed-capture-check via install_paths.teams=no-evidence; allowing (capabilities.json unreadable)" >&2
  exit 0
fi
if [[ "$TEAMS_DIR" == "unsupported" ]]; then
  echo "[lore] degraded: task-completed-capture-check via team_messaging=none; allowing (no team-config surface on active harness)" >&2
  exit 0
fi

# Resolve agent type from team config
AGENT_TYPE=""
TEAM_CONFIG="$TEAMS_DIR/$TEAM_NAME/config.json"
if [[ -f "$TEAM_CONFIG" && -n "$AGENT_NAME" ]]; then
  AGENT_TYPE=$(python3 -c "
import json, sys
with open('$TEAM_CONFIG') as f:
    config = json.load(f)
for m in config.get('members', []):
    if m.get('name') == '$AGENT_NAME':
        print(m.get('agentType', ''))
        sys.exit(0)
print('')
" 2>/dev/null || true)
fi

# report_has_template_version — look for a `Template-version:` line or a
# `template_version:` yaml-style field anywhere in $TASK_DESC.
# Returns 0 if present, 1 if absent.
report_has_template_version() {
  # Both the Template-version: execution-log header style and the yaml-style
  # template_version: field used in YAML front-matter / scorecard row bodies
  # are accepted. Case-insensitive on the key to tolerate minor authoring drift.
  printf '%s' "$TASK_DESC" | grep -qiE '^[[:space:]]*template[_-]version[[:space:]]*:[[:space:]]*[A-Za-z0-9_-]+'
}

# derive_work_slug — derive the work-item slug from the team name.
# team_name convention is "impl-<slug>" or "spec-<slug>"; strip the prefix.
derive_work_slug() {
  case "$TEAM_NAME" in
    impl-*) echo "${TEAM_NAME#impl-}" ;;
    spec-*) echo "${TEAM_NAME#spec-}" ;;
    *) echo "" ;;
  esac
}

# emit_legacy_warning — append a one-line migration-signal entry to the work
# item's execution-log. Best-effort: if write-execution-log.sh is not callable
# or the slug can't be derived, fall back to a stderr warning so the signal is
# still visible to the operator. Never blocks — this is the backwards-compat
# path, so returning a non-zero from here would defeat the gate's purpose.
emit_legacy_warning() {
  local slug reason
  slug=$(derive_work_slug)
  reason="$1"
  local warning="LEGACY REPORT: $AGENT_NAME ($AGENT_TYPE) completed task without template_version. Reason: $reason. Migration signal for /retro."

  if [[ -n "$slug" && -x "$SCRIPT_DIR/write-execution-log.sh" ]]; then
    printf '%s\n' "$warning" \
      | "$SCRIPT_DIR/write-execution-log.sh" \
          --slug "$slug" \
          --source "manual" \
          --phase "legacy-compat-warning" \
          >/dev/null 2>&1 \
      || echo "[task-completed] warning: $warning" >&2
  else
    echo "[task-completed] warning: $warning" >&2
  fi
}

# validate_structured_report — hard-validate that $TASK_DESC contains either
# ≥1 structured observation/assertion OR a well-formed escalation verdict.
# Prints a human-readable diagnostic to stderr when it fails.
# Accepts one arg: the heading name to look under ("Observations" or "Assertions").
#
# Returns 0 on pass, 1 on fail (sets FAIL_REASON in the caller for use in error message).
validate_structured_report() {
  local section_heading="$1"
  local verdict
  verdict=$(printf '%s' "$TASK_DESC" | python3 "$SCRIPT_DIR/validate-structured-report.py" "$section_heading" 2>&1) || true

  if [[ "${verdict}" == PASS_* ]]; then
    return 0
  fi
  # Strip leading "FAIL: " for the reason string
  FAIL_REASON="${verdict#FAIL: }"
  return 1
}

# validate_tier_sections — shape-check optional **Tier 2 evidence:** and
# **Tier 3 candidates:** sections (implement-rewrite task #4). Sole-writer
# discipline: the hook verifies section structure only; claim content is
# validated at write-time by evidence-append.sh (Tier 2) and lore-promote.sh
# (Tier 3). Both sections absent → pass. If a section is present but malformed,
# sets FAIL_REASON and returns 1.
validate_tier_sections() {
  local verdict
  verdict=$(printf '%s' "$TASK_DESC" | python3 "$SCRIPT_DIR/validate-tier-sections.py" 2>&1) || true

  if [[ "${verdict}" == "PASS" ]]; then
    return 0
  fi
  FAIL_REASON="${verdict#FAIL: }"
  return 1
}

# Enforce required sections based on agent type
# Explore → researcher: require **Assertions:** with ≥1 structured entry OR escalation
# general-purpose → worker: require **Observations:** with ≥1 structured entry OR escalation
# Other types (team-lead, unknown) → no structural requirements

# Backwards-compat gate (task #23): only enforce for reports that carry a
# template_version marker. Legacy/pre-F0 reports emit a migration warning and
# pass. Team-leads always pass (no structural requirements); they do not need
# to trip the legacy-warning path, so we skip the gate for them below.
if [[ "$AGENT_TYPE" != "team-lead" ]]; then
  if ! report_has_template_version; then
    emit_legacy_warning "no template_version line in report; enforcement skipped"
    exit 0
  fi
fi

FAIL_REASON=""
case "$AGENT_TYPE" in
  Explore)
    # Researcher agents: hard-validate Assertions. Observations (prose) is no longer
    # separately required — the structured Assertions schema carries the primary signal.
    if validate_structured_report "Assertions"; then
      exit 0
    fi
    echo "Update the task description before marking complete." >&2
    echo "Required: ≥1 structured assertion under **Assertions:** with all of {claim, file, line_range, falsifier, significance} (significance ∈ {low, medium, high}), OR a well-formed escalation verdict {escalation: \"task-too-trivial-for-solo-decomposition\", rationale: \"<one-sentence reason>\"}." >&2
    echo "Validation failure: $FAIL_REASON" >&2
    exit 2
    ;;
  general-purpose)
    # Worker agents: hard-validate Observations, then shape-check optional
    # Tier 2 evidence / Tier 3 candidates sections when present.
    if ! validate_structured_report "Observations"; then
      echo "Update the task description before marking complete." >&2
      echo "Required: ≥1 structured observation under **Observations:** with all of {claim, file, line_range, falsifier, significance} (significance ∈ {low, medium, high}), AND a non-empty **Convention handling:** section dispositioning each woven norm (honored / diverged / none in scope), OR a well-formed escalation verdict {escalation: \"task-too-trivial-for-solo-decomposition\", rationale: \"<one-sentence reason>\"}." >&2
      echo "Validation failure: $FAIL_REASON" >&2
      exit 2
    fi
    if ! validate_tier_sections; then
      echo "Update the task description before marking complete." >&2
      echo "Tier section shape-check failed: $FAIL_REASON" >&2
      exit 2
    fi
    exit 0
    ;;
  team-lead)
    # Team leads have no structural requirements.
    exit 0
    ;;
  *)
    # Unknown or empty agent type — apply worker-style hard-validation as default.
    if ! validate_structured_report "Observations"; then
      echo "Update the task description before marking complete." >&2
      echo "Required: ≥1 structured observation under **Observations:** with all of {claim, file, line_range, falsifier, significance} (significance ∈ {low, medium, high}), AND a non-empty **Convention handling:** section dispositioning each woven norm (honored / diverged / none in scope), OR a well-formed escalation verdict {escalation: \"task-too-trivial-for-solo-decomposition\", rationale: \"<one-sentence reason>\"}." >&2
      echo "Validation failure: $FAIL_REASON" >&2
      exit 2
    fi
    if ! validate_tier_sections; then
      echo "Update the task description before marking complete." >&2
      echo "Tier section shape-check failed: $FAIL_REASON" >&2
      exit 2
    fi
    exit 0
    ;;
esac
