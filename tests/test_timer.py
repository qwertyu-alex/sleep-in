import contextlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / 'bin'))
loader = importlib.machinery.SourceFileLoader('sleep_in', str(PROJECT / 'bin/sleep-in'))
spec = importlib.util.spec_from_loader(loader.name, loader)
timer = importlib.util.module_from_spec(spec)
loader.exec_module(timer)


class TimerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='sleep-in-test-', dir='/tmp')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.events = []

    def run_timer(self, *, dry_run=False, ready=True, start_error=None, update_error=None, close_error=None):
        events = self.events

        class Awake:
            def poll(self): return None
            def terminate(self): events.append('caffeinate released')
            def wait(self): return 0

        class Lid:
            def __init__(self, helper): pass
            def start(self, cancelled):
                events.append('authorize')
                if start_error: raise start_error
                return ready
            def update(self, deadline):
                if update_error: raise update_error
                events.append('charger checked')
                return True
            def close(self):
                events.append('sleep restored')
                if close_error: raise close_error

        def command(args, **kwargs):
            self.assertEqual(args, ['/usr/bin/pmset', 'sleepnow'])
            events.append('sleep requested')
            return subprocess.CompletedProcess(args, 0, '', '')

        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.multiple(timer, ROOT=self.root, SOCKET=self.root / 'timer.sock', STATE=self.root / 'state.json'))
            stack.enter_context(patch.object(timer, 'LidSession', Lid))
            stack.enter_context(patch.object(timer.subprocess, 'Popen', return_value=Awake()))
            stack.enter_context(patch.object(timer.subprocess, 'run', side_effect=command))
            stack.enter_context(patch.object(timer.signal, 'signal'))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            with (self.root / 'lock').open('w') as lock:
                timer.run_timer(0.02, dry_run, lock, True, None, True)

    def test_restores_before_sleep_request(self):
        self.run_timer()
        self.assertLess(self.events.index('sleep restored'), self.events.index('sleep requested'))
        state = json.loads((self.root / 'state.json').read_text())
        self.assertEqual(state['status'], 'completed')
        self.assertFalse(state['lid_awake'])

    def test_dry_run_restores_without_requesting_sleep(self):
        self.run_timer(dry_run=True)
        self.assertIn('sleep restored', self.events)
        self.assertNotIn('sleep requested', self.events)

    def test_cancel_during_authorization(self):
        self.run_timer(ready=False)
        self.assertNotIn('charger checked', self.events)
        self.assertNotIn('sleep requested', self.events)
        self.assertEqual(json.loads((self.root / 'state.json').read_text())['status'], 'cancelled')

    def test_authorization_failure_releases_everything(self):
        with self.assertRaisesRegex(RuntimeError, 'denied'):
            self.run_timer(start_error=RuntimeError('denied'))
        self.assertIn('sleep restored', self.events)
        self.assertIn('caffeinate released', self.events)
        self.assertNotIn('sleep requested', self.events)

    def test_disconnected_helper_fails_without_sleep_command(self):
        with self.assertRaisesRegex(RuntimeError, 'disconnected'):
            self.run_timer(update_error=RuntimeError('disconnected'))
        self.assertIn('sleep restored', self.events)
        self.assertIn('caffeinate released', self.events)
        self.assertNotIn('sleep requested', self.events)

    def test_restoration_failure_blocks_final_sleep_request(self):
        with self.assertRaisesRegex(RuntimeError, 'restore failed'):
            self.run_timer(close_error=RuntimeError('restore failed'))
        self.assertIn('caffeinate released', self.events)
        self.assertNotIn('sleep requested', self.events)
        self.assertEqual(json.loads((self.root / 'state.json').read_text())['status'], 'failed')


if __name__ == '__main__':
    unittest.main()
