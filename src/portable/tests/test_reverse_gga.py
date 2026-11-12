import socket
import sys
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from nmea import GGAReader, gga, valid_gga
from transport import Connection, Outputs, run

DATA = b"\xd3\x00\x02\x3e\xd0\x00\xff\x00"


class ReverseGGATests(unittest.TestCase):
    def test_bounded_fragmented_gga_validation(self):
        sentence = gga(46.125, 13.333333, 100)
        reader = GGAReader()
        self.assertFalse(valid_gga(sentence[:-2] + "XX"))
        self.assertEqual(reader.feed(b"x" * 8192 + b"$GPGGA," + b"x" * 4096), [])
        self.assertEqual(reader.feed((sentence[:24]).encode()), [])
        self.assertEqual(reader.feed((sentence[24:] + "\r\n").encode()), [sentence])
        self.assertEqual(reader.feed((sentence[:-1] + "Z\n").encode()), [])

    def exchange(self, manual, native=False):
        incoming = gga(45.5, 12.5, 21).encode()
        override = gga(46.125, 13.333333, 100)
        header = threading.Event()
        drained = threading.Event()
        errors, received, corrections, events = [], [], [], []
        stopped = threading.Event()

        class Receiver:
            pending = bytearray(b"$GPGGA,broken*00\r\n" + incoming + b"\r\n")
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            @property
            def in_waiting(self):
                return min(29, len(self.pending)) if header.is_set() else 0
            def read(self, count):
                value = bytes(self.pending[:count])
                del self.pending[:count]
                if not self.pending: drained.set()
                return value
            def write(self, data):
                corrections.append(data)

        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            listener.settimeout(5)
            def caster():
                try:
                    peer, _ = listener.accept()
                    with peer:
                        peer.settimeout(5)
                        stream = peer.makefile("rb")
                        while line := stream.readline():
                            if line == b"\r\n":
                                break
                        peer.sendall(b"ICY 200 OK\r\n")
                        header.set()
                        received.append(stream.readline().strip())
                        # Corrections deliberately wait for the first upstream GGA.
                        drained.wait(3)
                        peer.sendall(DATA)
                except Exception as error:
                    errors.append(error)

            thread = threading.Thread(target=caster)
            thread.start()
            from contextlib import ExitStack
            with ExitStack() as mocks:
                if native:
                    mocks.enter_context(patch("native_bluetooth.sys.platform", "darwin"))
                    opened = mocks.enter_context(patch("native_bluetooth.NativeBluetoothPort", return_value=Receiver()))
                    serial = mocks.enter_context(patch("serial.Serial", side_effect=AssertionError("virtual serial must not open")))
                else:
                    serial = mocks.enter_context(patch("serial.Serial", return_value=Receiver()))
                run(Connection("127.0.0.1", listener.getsockname()[1], "VRS", version=1),
                    stopped, lambda *args: events.append(args), gga=(lambda: override) if manual else None,
                    outputs=Outputs(serial_ports=((("/dev/cu.HC-06" if native else "test-serial"), 115200),)))
                if native:
                    opened.assert_called_once_with("/dev/cu.HC-06", 115200)
                    serial.assert_not_called()
                else:
                    self.assertEqual(serial.call_args.kwargs["timeout"], 0)
            thread.join(6)
        self.assertFalse(thread.is_alive())
        self.assertFalse(errors, errors)
        self.assertEqual(received, [override.encode() if manual else incoming])
        self.assertEqual(b"".join(corrections), DATA)
        self.assertEqual(b"".join(value[1] for kind, value in events if kind == "receiver"), b"$GPGGA,broken*00\r\n" + incoming + b"\r\n")

    def test_receiver_gga_unblocks_caster_and_returns_rtcm(self):
        self.exchange(False)

    def test_native_hc06_gga_and_rtcm(self):
        self.exchange(False, native=True)

    def test_native_hc06_manual_priority(self):
        self.exchange(True, native=True)

    def test_manual_gga_has_priority(self):
        self.exchange(True)


if __name__ == "__main__":
    unittest.main()
