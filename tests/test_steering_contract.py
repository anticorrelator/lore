import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / file)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value
watch = module('watch', 'coordinate_watch_state.py')
interrupt = module('interrupt', 'session-interrupt.py')


def sample(activity='blocked', generation='g', signature='modal-a'):
    return dict(slug='demo', observation=dict(schema_version=1, fresh=True, max_age_seconds=5,
        activity=activity, generation=generation, session_id='native', authority='screen-signature',
        observed_at=watch.timestamp(), block_signature=signature, evidence={'matcher': 'fixture'}))


class Steering(unittest.TestCase):
    def test_receipt_repaint_new_block_generation_and_lost_delivery(self):
        with tempfile.TemporaryDirectory() as tmp:
            kdir = Path(tmp)
            delivery = watch.Delivery(kdir / '_coordination/watch-delivery-fixture.json')
            identity = dict(owner_kind='pid', owner_value=str(os.getpid()))
            saved = watch.reconcile_samples({}, [sample()])
            row = saved['pending']['demo']
            def payload(row):
                return dict(outcome='current_delta', tier='confirmed', current_delta=[row],
                            current_observations={'current': [row], 'delta': [row]}, next_cursor=1)
            first = delivery.publish(payload(row), identity, 0)
            self.assertEqual(delivery.pending()['wake_id'], first['wake_id'])
            receipt = watch.wake_receipt(kdir, first['wake_id'], acknowledge=True)
            self.assertFalse(receipt['action_completed'])
            self.assertIsNone(delivery.pending())
            saved['pending'] = {}
            saved = watch.reconcile_samples(saved, [sample('unknown')])
            self.assertEqual(saved['states']['demo']['activity'], 'unknown')
            saved = watch.reconcile_samples(saved, [sample()])
            self.assertEqual(saved['pending'], {})
            repainted = dict(row, observation=dict(row['observation'], observed_at=watch.timestamp()))
            self.assertIsNone(delivery.publish(payload(repainted), identity, 0))
            # Same activity with a different modal must survive acknowledgment.
            saved = watch.reconcile_samples(saved, [sample(signature='modal-b')])
            second = delivery.publish(payload(saved['pending']['demo']), identity, 0)
            self.assertNotEqual(first['wake_id'], second['wake_id'])
            watch.wake_receipt(kdir, second['wake_id'], acknowledge=True)
            saved['pending'] = {}
            saved = watch.reconcile_samples(saved, [sample('working')])
            saved = watch.reconcile_samples(saved, [sample(signature='modal-b')])
            third = delivery.publish(payload(saved['pending']['demo']), identity, 0)
            self.assertNotEqual(second['wake_id'], third['wake_id'])
            saved = watch.reconcile_samples(saved, [sample(generation='next')])
            fourth = delivery.publish(payload(saved['pending']['demo']), identity, 0)
            self.assertNotEqual(third['wake_id'], fourth['wake_id'])

    def test_interrupt_binds_exact_supported_owner_without_starting_host(self):
        with tempfile.TemporaryDirectory() as tmp:
            kdir = Path(tmp)
            path = kdir / '_sessions/instances/host.json'
            owner = dict(name='host', pid=os.getpid(), started='owner-start',
                         runtime_capabilities=['interrupt-current-turn-v1'], sessions=[dict(
                         slug='demo', pid=os.getpid(), session_id='native', request_id='launch',
                         harness='claude-code', worktree={'epoch': 'epoch'})])
            watch.atomic(path, owner)
            bound = interrupt.bind(kdir, 'demo')
            self.assertEqual(bound['launch_request_id'], 'launch')
            self.assertEqual(bound['epoch'], 'epoch')
            self.assertEqual(bound['owner_started'], 'owner-start')
            for field in ('runtime_capabilities', 'started'):
                changed = dict(owner); changed.pop(field)
                watch.atomic(path, changed)
                with self.assertRaises(RuntimeError): interrupt.bind(kdir, 'demo')
            watch.atomic(path, owner)
            os.utime(path, (time.time()-31, time.time()-31))
            with self.assertRaises(RuntimeError): interrupt.bind(kdir, 'demo')
            watch.atomic(path, owner)
            duplicate = path.with_name('other.json');watch.atomic(duplicate, dict(owner, name='other'))
            with self.assertRaises(RuntimeError): interrupt.bind(kdir, 'demo')
            duplicate.unlink()
            # A timeout preserves intent and an expiring exact row, never retries.
            with patch.object(interrupt.managed, 'append') as append:
                result = interrupt.interrupt(kdir, 'demo', timeout=0)
            self.assertEqual(append.call_args.args[1]['event'], 'interrupt_requested')
            self.assertIsNone(result['turn_ended'])
            rows = list((kdir / '_sessions/interrupt-requests').glob('*.json'))
            self.assertEqual(len(rows), 1)
            row = json.loads(rows[0].read_text())
            self.assertEqual(row['session_id'], 'native')
            self.assertAlmostEqual(watch.epoch(row['expires_at'])-watch.epoch(row['requested_at']), 15)
            self.assertFalse((kdir / '_sessions/hosts').exists())

if __name__ == '__main__': unittest.main()
