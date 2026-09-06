#!/usr/bin/env python3
"""Drop quarantine refs whose complete result tree is already in accepted history."""
import argparse
import json
from pathlib import Path
import subprocess


def git(repo, *args, data=None):
    result = subprocess.run(['git', '-C', str(repo), *args], input=data, text=True, capture_output=True)
    if result.returncode:
        raise ValueError(result.stderr.strip())
    return result.stdout.strip()


def sweep(repo, target='HEAD', apply=False):
    target_oid = git(repo, 'rev-parse', '--verify', target + '^{commit}')
    # Exact tree identity proves the whole snapshot occurred on this history,
    # including binary files, deletions and modes. Patch similarity is insufficient.
    trees_after = {}
    accepted = set(git(repo, 'rev-list', target_oid).splitlines())
    def integrated(ref, oid):
        if oid in accepted:
            return True
        tree = git(repo, 'rev-parse', oid + '^{tree}')
        parents = git(repo, 'show', '-s', '--format=%P', oid).split()
        # Synthetic snapshots of an already accepted parent add no result.
        if len(parents) == 1 and parents[0] in accepted and tree == git(repo, 'rev-parse', parents[0] + '^{tree}'):
            return True
        epoch = ref.rsplit('/', 1)[1]
        try:
            # Captures are synthetic commits whose parent is the allocation base.
            base = git(repo, 'rev-parse', '--verify', 'refs/lore/worktrees/' + epoch + '/captured^')
        except ValueError:
            return False
        if base not in accepted:
            return False
        if base not in trees_after:
            trees_after[base] = set(git(repo, 'log', '--ancestry-path', '--format=%T', base + '..' + target_oid).splitlines())
        return tree in trees_after[base]
    worktrees = [line[9:] for line in git(repo, 'worktree', 'list', '--porcelain').splitlines() if line.startswith('worktree ')]
    common = Path(git(repo, 'rev-parse', '--path-format=absolute', '--git-common-dir'))
    active_epochs = {Path(path).name for path in worktrees}
    active_epochs.update(path.read_text().strip() for path in (common / 'worktrees').glob('*/lore-worktree-epoch'))
    rows = []
    for line in git(repo, 'for-each-ref', '--format=%(refname) %(objectname)', 'refs/lore/quarantine/').splitlines():
        ref, oid = line.split()
        epoch = ref.rsplit('/', 1)[1]
        if epoch in active_epochs:
            reason = 'worktree-still-registered'
        elif integrated(ref, oid):
            reason = 'result-in-target-history'
        else:
            reason = 'result-not-proven-integrated'
        rows.append(dict(ref=ref, oid=oid, eligible=reason == 'result-in-target-history', reason=reason))
    selected = [row for row in rows if row['eligible']]
    if apply and selected:
        # One transaction, old-OID checked: changed refs are never deleted.
        commands = 'start\n' + ''.join(f"delete {r['ref']} {r['oid']}\n" for r in selected) + 'prepare\ncommit\n'
        git(repo, 'update-ref', '--stdin', data=commands)
    return dict(target=target_oid, applied=apply, eligible=len(selected), retained=len(rows)-len(selected), refs=rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default='.')
    parser.add_argument('--target', default='HEAD', help='Accepted history (default HEAD)')
    parser.add_argument('--apply', action='store_true', help='Delete proven refs; default is a dry run')
    args = parser.parse_args()
    try:
        print(json.dumps(sweep(args.repo, args.target, args.apply), indent=2))
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
