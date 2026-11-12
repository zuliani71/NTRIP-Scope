import socket
import sys
import threading
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from transport import Connection, Outputs, run

class MonitorTests(unittest.TestCase):
    def test_raw_tcp_input_is_visible_before_caster_sends_rtcm(self):
        raw = b'$GPGGA,raw and unvalidated\r\n\x00\xff'
        observed = threading.Event()
        events, peers, errors = [], [], []
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        with socket.socket() as caster:
            caster.bind(('127.0.0.1', 0)); caster.listen(); caster.settimeout(5)
            def serve():
                try:
                    connection, _ = caster.accept()
                    with connection:
                        connection.settimeout(5)
                        request = b''
                        while b'\r\n\r\n' not in request: request += connection.recv(4096)
                        connection.sendall(b'ICY 200 OK\r\n')
                        if not observed.wait(4): raise AssertionError('TCP receiver input was not monitored')
                        connection.sendall(b'\xd3\x00\xff')
                except Exception as error: errors.append(error)
            def emit(kind, value):
                events.append((kind, value))
                if kind == 'output' and value.startswith('TCP '):
                    peer = socket.create_connection(('127.0.0.1', port), timeout=3)
                    peers.append(peer); peer.sendall(raw)
                if kind == 'receiver': observed.set()
            thread = threading.Thread(target=serve); thread.start()
            try:
                run(Connection('127.0.0.1', caster.getsockname()[1], 'BASE', version=1),
                    threading.Event(), emit, outputs=Outputs(tcp_ports=(port,)))
            finally:
                for peer in peers: peer.close()
                thread.join(6)
        self.assertFalse(errors, errors)
        incoming = [(source, data) for kind, (source, data) in (e for e in events if e[0] == 'receiver')]
        self.assertEqual(b''.join(data for _, data in incoming), raw)
        self.assertTrue(all(source == f'TCP · {port}' for source, _ in incoming))
        self.assertEqual(b''.join(data for kind, data in events if kind == 'data'), b'\xd3\x00\xff')
