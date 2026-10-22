import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'bin'))
from lid_awake import LidSession


class LidSessionTests(unittest.TestCase):
    def connected(self, messages):
        session = LidSession()
        session.was_ready = True
        session.connection = Mock()
        session.connection.recv.side_effect = messages
        session.process = Mock()
        session.process.poll.return_value = 0  # The client exits once the daemon has connected.
        return session

    def test_status_and_release_require_acknowledgments(self):
        session = self.connected([b'{"lid_awake": true}\n', b'{"released": true}\n'])
        connection, process = session.connection, session.process
        self.assertTrue(session.update(123))
        session.close()
        sent = [json.loads(call.args[0]) for call in connection.sendall.call_args_list]
        self.assertEqual(sent, [{'deadline': 123}, {'stop': True}])
        process.terminate.assert_not_called()
        connection.close.assert_called_once()

    def test_release_failure_is_reported(self):
        session = self.connected([b'{"error": "powerd unavailable"}\n'])
        connection = session.connection
        with self.assertRaisesRegex(RuntimeError, 'powerd unavailable'):
            session.close()
        connection.close.assert_called_once()

    def test_rejects_eof_and_unconfirmed_power_state(self):
        for response in [b'', b'{"ready": true}\n', b'{"lid_awake": 1}\n']:
            with self.subTest(response=response):
                session = self.connected([response])
                with self.assertRaises(RuntimeError):
                    session.update(123)

    def test_cancel_pending_touch_id_terminates_client(self):
        session = LidSession()
        session.process = Mock()
        session.process.poll.return_value = None
        process = session.process
        session.close()
        process.terminate.assert_called_once()

    def test_client_failure_is_reported(self):
        with tempfile.TemporaryDirectory(prefix='sleep-in-client-', dir='/tmp') as directory:
            client = Path(directory) / 'client'
            client.touch()
            session = LidSession(client)
            process = Mock()
            process.poll.return_value = 1

            def launch(args, **kwargs):
                kwargs['stdout'].write(b'Approval was cancelled. No lid-closed session was started.\n')
                return process

            try:
                with patch('lid_awake.subprocess.Popen', side_effect=launch) as popen:
                    with self.assertRaisesRegex(RuntimeError, '^Approval was cancelled'):
                        session.start(lambda: False)
                args = popen.call_args.args[0]
                self.assertEqual(args[0], str(client))
                self.assertTrue(args[1].startswith('/tmp/sleep-in-lid-') and args[1].endswith('/helper.sock'))
            finally:
                session.close()


if __name__ == '__main__':
    unittest.main()
