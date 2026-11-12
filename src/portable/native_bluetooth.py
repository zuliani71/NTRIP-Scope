"""macOS HC-06 RFCOMM bridge; stdout is exclusively receiver bytes."""
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time


def uses_native_bluetooth(port):
    tail = Path(port).name.lower()
    if tail.startswith(('cu.', 'tty.')):
        tail = tail.split('.', 1)[1]
    return sys.platform == 'darwin' and ''.join(c for c in tail if c.isalnum()) == 'hc06'


class NativeBluetoothPort:
    def __init__(self, port, baud=115200, *, helper=None):
        self.port = port
        base = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parent))
        helper = Path(helper) if helper else base / 'native' / 'ntripscope-bluetooth'
        if not helper.is_file():
            raise OSError('Native HC-06 helper missing: run src/portable/native/build.sh on macOS')
        self.error_file = tempfile.TemporaryFile()
        try:
            self.process = subprocess.Popen([str(helper)], stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE, stderr=self.error_file)
            os.set_blocking(self.process.stdout.fileno(), False)
            os.set_blocking(self.process.stdin.fileno(), False)
        except BaseException:
            self.error_file.close()
            raise
        self.closed = False

    def _check(self):
        if self.closed:
            raise OSError('HC-06 connection closed')
        if self.process.poll() is not None:
            self.error_file.seek(0)
            message = self.error_file.read(8192).decode(errors='replace').strip()
            raise OSError(message or 'HC-06 native Bluetooth bridge disconnected')

    @property
    def in_waiting(self):
        self._check()
        return 4096 if select.select([self.process.stdout], [], [], 0)[0] else 0

    def read(self, count):
        self._check()
        try:
            data = os.read(self.process.stdout.fileno(), count)
        except BlockingIOError:
            return b''
        if not data:
            self.process.wait(timeout=2)
            self._check()
        return data

    def write(self, data):
        view = memoryview(data)
        deadline = time.monotonic() + 2
        while view:
            self._check()
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([], [self.process.stdin], [], remaining)[1]:
                raise OSError('HC-06 native Bluetooth output timed out')
            try:
                sent = os.write(self.process.stdin.fileno(), view)
            except BlockingIOError:
                continue
            except BrokenPipeError:
                self.process.wait(timeout=2)
                self._check()
                raise OSError('HC-06 output closed')
            view = view[sent:]
        return len(data)

    def close(self):
        if self.closed:
            return
        self.closed = True
        # SIGTERM is handled on the helper main run loop and closes RFCOMM explicitly.
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process.stdin.close()
        self.process.stdout.close()
        self.error_file.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
