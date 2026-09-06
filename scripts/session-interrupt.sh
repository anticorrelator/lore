#!/usr/bin/env bash
# Interrupt the current turn without closing its session. Receipt confirms key delivery only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
SLUG=""; GENERATION=""; KDIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --generation) GENERATION="${2:?missing generation}"; shift 2 ;;
    --kdir) KDIR="${2:?missing kdir}"; shift 2 ;;
    --json) shift ;;
    --help|-h) echo 'Usage: lore session interrupt <slug> [--generation ID] [--kdir PATH] [--json]'; exit 0 ;;
    --*) die "unknown option: $1" ;;
    *) [[ -z "$SLUG" ]] || die 'only one slug allowed'; SLUG="$1"; shift ;;
  esac
done
[[ -n "$SLUG" ]] || die 'interrupt requires a session slug'
[[ -n "$KDIR" ]] || KDIR="$(resolve_knowledge_dir)"
SLUG="$(canonical_session_slug "$SLUG")"
OWNER="$(resolve_session_owner "$KDIR/_sessions/instances" "$SLUG" 30)"
[[ -n "$OWNER" ]] || die 'no live session owns the slug'
TARGET="$(python3 "$SCRIPT_DIR/session_target.py" "$KDIR/_sessions/instances" "$OWNER" "$SLUG")"
TARGET_GENERATION="$(jq -r .generation <<< "$TARGET")"
[[ -n "$TARGET_GENERATION" ]] || die 'target has no generation identity'
[[ -z "$GENERATION" || "$GENERATION" == "$TARGET_GENERATION" ]] || die "generation mismatch: $TARGET_GENERATION"
python3 - "$SCRIPT_DIR" "$KDIR" "$SLUG" "$OWNER" "$TARGET_GENERATION" <<'PY'
import datetime,json,os,pathlib,subprocess,sys,tempfile,uuid
scripts,kdir,slug,owner,generation=sys.argv[1:]
rid='interrupt-'+uuid.uuid4().hex
row=dict(request_id=rid,slug=slug,target_instance=owner,action='interrupt',generation=generation,
         body='',requested_by=os.environ.get('LORE_SESSION_INSTANCE',os.environ.get('USER','unknown')),
         requested_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
root=pathlib.Path(kdir)/'_sessions/send-requests';root.mkdir(parents=True,exist_ok=True)
fd,tmp=tempfile.mkstemp(prefix='.',dir=root)
with os.fdopen(fd,'w') as stream:
    json.dump(row,stream);stream.flush();os.fsync(stream.fileno())
os.replace(tmp,root/(rid+'.json'))
event=dict(event='interrupt_requested',request_id=rid,slug=slug,target_instance=owner,links={'generation':generation})
subprocess.run(['bash',str(pathlib.Path(scripts)/'session-event-append.sh'),'--kdir',kdir],input=json.dumps(event),text=True,check=True,stdout=subprocess.DEVNULL)
print(json.dumps(dict(request_id=rid,slug=slug,generation=generation,enqueued=True,outcome='pending')))
PY
