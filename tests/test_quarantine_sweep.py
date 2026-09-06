import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('sweep',Path(__file__).resolve().parents[1]/'scripts/quarantine-sweep.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class Sweep(unittest.TestCase):
    def test_only_integrated_complete_trees_are_released(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            def git(*args,data=None): return m.git(root,*args,data=data)
            git('init','-q');git('config','user.name','Fixture');git('config','user.email','f@example.test')
            (root/'file').write_text('base\n');git('add','.');git('commit','-qm','base')
            base=git('rev-parse','HEAD');tree=git('rev-parse','HEAD^{tree}')
            snap=git('commit-tree',tree,'-p',base,data='synthetic snapshot\n')
            git('update-ref','refs/lore/quarantine/integrated',snap)
            (root/'file').write_text('unaccepted\n');git('add','.')
            unaccepted=git('commit-tree',git('write-tree'),'-p',base,data='unaccepted\n')
            git('update-ref','refs/lore/quarantine/pending',unaccepted)
            git('reset','--hard',base)
            result=m.sweep(root)
            self.assertEqual(result['eligible'],1)
            self.assertEqual(git('rev-parse','refs/lore/quarantine/integrated'),snap)
            m.sweep(root,apply=True)
            refs=git('for-each-ref','--format=%(refname)','refs/lore/quarantine/')
            self.assertEqual(refs,'refs/lore/quarantine/pending')
            self.assertEqual(git('rev-parse','HEAD'),base)

    def test_old_historical_tree_does_not_prove_a_new_revert_integrated(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            def git(*args,data=None): return m.git(root,*args,data=data)
            git('init','-q');git('config','user.name','Fixture');git('config','user.email','f@example.test')
            (root/'file').write_text('old\n');git('add','.');git('commit','-qm','old')
            old_tree=git('rev-parse','HEAD^{tree}')
            (root/'file').write_text('new\n');git('add','.');git('commit','-qm','new')
            base=git('rev-parse','HEAD')
            captured=git('commit-tree',git('rev-parse','HEAD^{tree}'),'-p',base,data='captured\n')
            git('update-ref','refs/lore/worktrees/revert/captured',captured)
            proposed=git('commit-tree',old_tree,'-p',base,data='unaccepted revert\n')
            git('update-ref','refs/lore/quarantine/revert',proposed)
            result=m.sweep(root,apply=True)
            self.assertEqual(result['eligible'],0)
            self.assertEqual(git('rev-parse','refs/lore/quarantine/revert'),proposed)

    def test_registered_renamed_worktree_keeps_its_recovery_ref(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)/'repo';root.mkdir()
            def git(*args,data=None): return m.git(root,*args,data=data)
            git('init','-q');git('config','user.name','Fixture');git('config','user.email','f@example.test')
            (root/'file').write_text('base\n');git('add','.');git('commit','-qm','base')
            base=git('rev-parse','HEAD')
            live=Path(temp)/'renamed';git('worktree','add','--detach',str(live),base)
            admin=Path(m.git(live,'rev-parse','--absolute-git-dir'))
            (admin/'lore-worktree-epoch').write_text('original-epoch\n')
            git('update-ref','refs/lore/quarantine/original-epoch',base)
            result=m.sweep(root,apply=True)
            self.assertEqual(result['eligible'],0)
            self.assertEqual(result['refs'][0]['reason'],'worktree-still-registered')

if __name__=='__main__': unittest.main()
