"""A Touch ID-approved session with Sleep In's root daemon; the timer stays unprivileged."""

import ctypes
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


def default_helper():
    """The client in the app that contains this script, or else in an installed copy of the app."""
    client = 'Sleep In.app/Contents/MacOS/SleepInLidClient'
    candidates = [Path(__file__).resolve().parents[1] / 'MacOS/SleepInLidClient',
                  Path.home() / 'Applications' / client, Path('/Applications') / client]
    return next((path for path in candidates if path.is_file()), candidates[-1])


class LidSession:
    def __init__(self, helper=None):
        self.helper = helper or default_helper()
        self.directory = None
        self.listener = None
        self.connection = None
        self.process = None
        self.diagnostics = None
        self.buffer = b''
        self.was_ready = False

    def start(self, cancelled):
        if not self.helper.is_file():
            raise RuntimeError('Install the Sleep In app in Applications before using lid-closed mode.')
        # /tmp keeps the AF_UNIX path below macOS's 104-byte limit.
        self.directory = tempfile.TemporaryDirectory(prefix='sleep-in-lid-', dir='/tmp')
        path = str(Path(self.directory.name) / 'helper.sock')
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(path)
        self.listener.listen(1)
        self.listener.settimeout(0.2)
        self.diagnostics = tempfile.TemporaryFile()
        # The signed client asks for Touch ID, then the daemon connects here before the client exits.
        self.process = subprocess.Popen([str(self.helper), path], stdin=subprocess.DEVNULL,
                                        stdout=self.diagnostics, stderr=self.diagnostics)
        limit = time.monotonic() + 120
        while not cancelled():
            # Checked before accepting, so a connection made just before the client exited still counts.
            exited = self.process.poll() is not None
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                if exited:
                    self.diagnostics.seek(0)
                    detail = self.diagnostics.read().decode(errors='replace').strip()
                    raise RuntimeError(detail[-500:] or 'Could not start lid-closed mode.')
                if time.monotonic() >= limit:
                    raise RuntimeError('Approval timed out. Please start the timer again.')
                continue
            # Only the privileged daemon can acknowledge that sleep was changed.
            uid, gid = ctypes.c_uint(), ctypes.c_uint()
            libc = ctypes.CDLL(None, use_errno=True)
            result = libc.getpeereid(connection.fileno(), ctypes.byref(uid), ctypes.byref(gid))
            if result != 0 or uid.value != 0:
                connection.close()
                continue
            self.connection = connection
            connection.settimeout(8)
            message = self._receive()
            if message.get('ready') is not True:
                raise RuntimeError('The lid-closed helper did not become ready.')
            self.was_ready = True
            return True
        return False

    def _receive(self):
        while b'\n' not in self.buffer:
            chunk = self.connection.recv(1024)
            if not chunk:
                raise RuntimeError('The lid-closed helper disconnected unexpectedly.')
            self.buffer += chunk
            if len(self.buffer) > 4096:
                raise RuntimeError('Invalid response from the lid-closed helper.')
        line, self.buffer = self.buffer.split(b'\n', 1)
        message = json.loads(line)
        if not isinstance(message, dict):
            raise RuntimeError('Invalid response from the lid-closed helper.')
        if 'error' in message:
            raise RuntimeError(message['error'])
        return message

    def _exchange(self, message):
        self.connection.sendall(json.dumps(message).encode() + b'\n')
        return self._receive()

    def update(self, deadline):
        message = self._exchange({'deadline': deadline})
        if not isinstance(message.get('lid_awake'), bool):
            raise RuntimeError('The lid-closed helper did not confirm its power state.')
        return message['lid_awake']

    def close(self):
        error = None
        try:
            if self.connection is not None:
                if self._exchange({'stop': True}).get('released') is not True:
                    raise RuntimeError('The lid-closed helper did not confirm sleep restoration.')
        except (OSError, ValueError, RuntimeError) as caught:
            error = caught
        finally:
            if self.connection is not None:
                self.connection.close()  # EOF also makes the independent daemon restore sleep.
                self.connection = None
            if self.listener is not None:
                self.listener.close()
                self.listener = None
            if self.process is not None:
                # A client still running is only waiting for Touch ID; the daemon does the restoring.
                if self.process.poll() is None:
                    self.process.terminate()
                self.process.wait()
                self.process = None
            if self.directory is not None:
                self.directory.cleanup()
                self.directory = None
            if self.diagnostics is not None:
                self.diagnostics.close()
                self.diagnostics = None
        if error is not None:
            raise RuntimeError(f'Could not confirm normal sleep settings: {error}')
