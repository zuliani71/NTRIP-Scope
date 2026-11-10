import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

CLI = Path(__file__).resolve().parents[1] / "ntripscope.py"
DATA = b"\xd3\x00\x03\x00\xff\r\n"


class CLITests(unittest.TestCase):
    def exchange(self, response, args, *, gga=False, tcp=False, folder=None):
        errors = []
        request = []
        delivered = []
        with socket.socket() as caster:
            caster.bind(("127.0.0.1", 0))
            caster.listen()
            caster.settimeout(4)
            port = caster.getsockname()[1]
            with socket.socket() as reserve:
                reserve.bind(("127.0.0.1", 0))
                output_port = reserve.getsockname()[1]

            def serve():
                try:
                    peer, _ = caster.accept()
                    with peer:
                        peer.settimeout(4)
                        with peer.makefile("rb") as lines:
                            while line := lines.readline():
                                if line == b"\r\n":
                                    break
                                request.append(line)
                            if gga:
                                peer.sendall(b"ICY 200 OK\r\n")
                                request.append(lines.readline())
                            if tcp:
                                peer.sendall(b"ICY 200 OK\r\n")
                                from time import monotonic, sleep
                                limit = monotonic() + 3
                                while True:
                                    try:
                                        consumer = socket.create_connection(("127.0.0.1", output_port), 1)
                                        break
                                    except ConnectionRefusedError:
                                        if monotonic() >= limit:
                                            raise
                                        sleep(.02)
                                with consumer:
                                    peer.sendall(response)
                                    delivered.append(consumer.makefile("rb").read(len(response)))
                            else:
                                peer.sendall(response)
                except Exception as error:
                    errors.append(error)

            worker = threading.Thread(target=serve)
            worker.start()
            options = ["--host", "127.0.0.1", "--port", str(port), *args]
            if tcp:
                options += ["--tcp", str(output_port)]
            result = subprocess.run([sys.executable, str(CLI), *options], cwd=folder,
                                    capture_output=True, timeout=8)
            worker.join(timeout=5)
        self.assertFalse(errors, errors)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result, b"".join(request), delivered

    def test_binary_stdout(self):
        result, _, _ = self.exchange(b"ICY 200 OK\r\n"+DATA, ["--mountpoint", "BASE", "--version", "1"])
        self.assertEqual(result.stdout, DATA)
        self.assertIn(b"Connected", result.stderr)

    def test_listing_overrides_stream_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "test.ini"
            config.write_text("[caster]\nmountpoint = BASE\n[outputs]\nfile = ignored.rtcm\n")
            result, request, _ = self.exchange(
                b"SOURCETABLE 200 OK\r\nContent-Type: text/plain\r\n\r\nSTR;Z\r\nSTR;A\r\nENDSOURCETABLE\r\n",
                ["--config", str(config), "--list"], folder=directory)
            self.assertEqual(result.stdout, b"A\nZ\n")
            self.assertIn(b"GET / HTTP/1.1", request)
            self.assertFalse((Path(directory) / "ignored.rtcm").exists())

    def test_file_tcp_stdout_and_config(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "test.ini"
            config.write_text("[caster]\nmountpoint = BASE\n[outputs]\nfile = a.rtcm\n    b.rtcm\n")
            result, _, delivered = self.exchange(DATA, ["--config", str(config), "--stdout"],
                                                 tcp=True, folder=directory)
            self.assertEqual(result.stdout, DATA)
            self.assertEqual(delivered, [DATA])
            for name in ("a.rtcm", "b.rtcm"):
                self.assertEqual((Path(directory) / name).read_bytes(), DATA)

    def test_rover_and_authentication(self):
        _, request, _ = self.exchange(DATA, ["--mountpoint", "VRS", "--username", "demo",
            "--password", "secret", "--lat", "46.125", "--lon", "-12.5"], gga=True)
        self.assertIn(b"Authorization: Basic ZGVtbzpzZWNyZXQ=", request)
        self.assertEqual(request.count(b"$GPGGA"), 2)
        self.assertIn(b",4607.500000,N,01230.000000,W,", request)


if __name__ == "__main__":
    unittest.main()
