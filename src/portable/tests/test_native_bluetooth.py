import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_bluetooth import NativeBluetoothPort, uses_native_bluetooth


class NativeBluetoothTests(unittest.TestCase):
    def test_platform_and_name_routing(self):
        with patch('native_bluetooth.sys.platform', 'darwin'):
            self.assertTrue(uses_native_bluetooth('/dev/cu.HC-06'))
            self.assertTrue(uses_native_bluetooth('/dev/tty.HC06'))
            self.assertFalse(uses_native_bluetooth('/dev/cu.usbserial'))
        with patch('native_bluetooth.sys.platform', 'linux'):
            self.assertFalse(uses_native_bluetooth('/dev/cu.HC-06'))

    @unittest.skipIf(sys.platform == 'win32', 'POSIX helper pipes')
    def test_raw_bridge_and_deterministic_close(self):
        payload = b'\xd3\x00\xff\n$GPGGA,raw\r\n'
        with NativeBluetoothPort('/dev/cu.HC-06', helper='/bin/cat') as port:
            self.assertEqual(port.write(payload), len(payload))
            result = bytearray(); deadline = time.monotonic()+3
            while len(result) < len(payload) and time.monotonic() < deadline:
                if port.in_waiting: result.extend(port.read(4096))
                else: time.sleep(.01)
            self.assertEqual(result,payload)
        self.assertIsNotNone(port.process.poll())
        port.close()

    @unittest.skipIf(sys.platform == 'win32', 'POSIX helper pipes')
    def test_failed_helper_is_reported(self):
        with NativeBluetoothPort('/dev/cu.HC-06', helper='/usr/bin/false') as port:
            port.process.wait(timeout=3)
            with self.assertRaisesRegex(OSError, 'disconnected'):
                _ = port.in_waiting
