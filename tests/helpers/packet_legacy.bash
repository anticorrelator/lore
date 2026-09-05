packet_legacy_fixture() {
  mkdir -p "$TEST_KDIR/_work/legacy-packet" "$TEST_KDIR/conventions" "$TEST_KDIR/determinism" "$TEST_KDIR/bin"
  printf '%s\n' '{"title":"Legacy packet","status":"active"}' > "$TEST_KDIR/_work/legacy-packet/_meta.json"
  printf '%s\n' '# Legacy packet' '' '### Phase 1: Build' '' '- [ ] Build widget' > "$TEST_KDIR/_work/legacy-packet/plan.md"
  python3 - "$TEST_KDIR" <<'PY'
import hashlib, json, pathlib, sys
root=pathlib.Path(sys.argv[1])
plan=root/'_work/legacy-packet/plan.md'
tasks={'plan_checksum':hashlib.sha256(plan.read_bytes()).hexdigest(),'recommended_workers':1,'phases':[{'phase_number':1,'phase_name':'Build','objective':'Build widget','files':['src/widget.py'],'retrieval_directive':{'seeds':['widget'],'hop_budget':0,'scale_set':['subsystem']},'tasks':[{'id':'task-1','subject':'Build widget','activeForm':'Building widget','description':'Build widget','blockedBy':[],'file_targets':['src/widget.py']}]}]}
(plan.parent/'tasks.json').write_text(json.dumps(tasks))
(root/'determinism/sitecustomize.py').write_text('import pathlib, uuid\n'
    '# deterministic and distinct across processes: a file-backed counter, reproducible across runs; the first id is the historical pinned one\n'
    '_counter = pathlib.Path(__file__).with_name("counter")\n'
    'def _next():\n'
    '    n = int(_counter.read_text()) + 1 if _counter.exists() else 0\n'
    '    _counter.write_text(str(n))\n'
    '    return n\n'
    'uuid.uuid4 = lambda: uuid.UUID(int=(0x12345678123456781234567812345678 + (_next() << 96)) & ((1 << 128) - 1))\n')
PY
  export PYTHONPATH="$TEST_KDIR/determinism${PYTHONPATH:+:$PYTHONPATH}"
  python3 - "$REPO_DIR" "$TEST_KDIR/bin/lore" <<'PY'
import pathlib, sys
root=pathlib.Path(sys.argv[1])
text=(root/'cli/lore').read_text()
lines=text.splitlines()
lines=[f'SCRIPTS_DIR="{root}/scripts"' if line.startswith('SCRIPTS_DIR=') else line for line in lines]
path=pathlib.Path(sys.argv[2]); path.write_text('\n'.join(lines)+'\n'); path.chmod(0o755)
PY
  export PATH="$TEST_KDIR/bin:$PATH"
}
