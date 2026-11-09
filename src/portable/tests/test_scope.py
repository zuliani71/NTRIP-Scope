import socket
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pyrtcm import calc_crc24q
from gnss import Decoder, dms, from_dms, gga, observations
from transport import Connection, run


def frame(payload):
    packet = b"\xd3" + len(payload).to_bytes(2, "big") + payload
    return packet + calc_crc24q(packet).to_bytes(3, "big")


class ScopeTests(unittest.TestCase):
    def test_rover_and_gga(self):
        self.assertEqual(dms(46.125), (46, 7, 30))
        self.assertEqual(from_dms(12, 30, 0, True, 180), -12.5)
        with self.assertRaises(ValueError):
            from_dms(90, 1, 0, False, 90)
        line = gga(46.125, -12.5, 100.123, 40.100, datetime(2026, 1, 1, tzinfo=timezone.utc))
        self.assertEqual(line, "$GPGGA,000000.00,4607.500000,N,01230.000000,W,1,00,1.0,60.023,M,40.100,M,,*4D")

    def test_decoder_fragmentation_crc_and_history(self):
        packet = frame(bytes.fromhex("3ee07b543fff439eb2000165ec1500020f76d23039"))
        decoder = Decoder()
        damaged = packet[:-1] + bytes([packet[-1] ^ 1])
        for byte in damaged + packet * 23:
            decoder.feed(bytes([byte]))
        self.assertEqual(decoder.bad_crc, 1)
        self.assertEqual(decoder.counts[1006], 23)
        self.assertEqual(len(decoder.frames[1006]), 20)
        self.assertAlmostEqual(decoder.frames[1006][-1][3].DF028, 1.2345)

    def test_msm7_measurements(self):
        data = bytearray()
        specs = [(1077,12),(1,12),(0,49),(1<<63,64),(1<<30,32),(1,1),
                 (70,8),(0,4),(512,10),(-23,14),(100,20),(-200,24),
                 (0,10),(0,1),(643,10),(1250,15)]
        bits = "".join(f"{value % (1 << width):0{width}b}" for value,width in specs)
        bits += "0" * (-len(bits) % 8)
        data.extend(int(bits,2).to_bytes(len(bits)//8,"big"))
        decoder = Decoder()
        decoder.feed(frame(data))
        sat, signal, code, phase, cnr, rate = observations(decoder.frames[1077][0][3])[0]
        self.assertEqual((sat, signal), ("001","1C"))
        self.assertAlmostEqual(code, (70.5 + 100*2**-29) * 299_792.458)
        self.assertAlmostEqual(phase, (70.5 - 200*2**-31) * 299_792.458)
        self.assertAlmostEqual(cnr, 40.1875)
        self.assertAlmostEqual(rate, -22.875)

    def exchange(self, response, *, version=2, listing=False, file="", gga_factory=None):
        requests = []
        events = []
        errors = []
        with socket.socket() as listener:
            listener.bind(("127.0.0.1",0))
            listener.listen()
            listener.settimeout(5)
            def serve():
                try:
                    peer,_ = listener.accept()
                    with peer:
                        peer.settimeout(5)
                        request = bytearray()
                        while b"\r\n\r\n" not in request:
                            data = peer.recv(2048)
                            if not data:
                                raise EOFError("incomplete request")
                            request.extend(data)
                        requests.append(bytes(request))
                        if gga_factory:
                            headers, data = response.split(b"\r\n\r\n",1)
                            peer.sendall(headers+b"\r\n\r\n")
                            requests.append(peer.recv(2048))
                            peer.sendall(data)
                        else:
                            peer.sendall(response)
                except Exception as error:
                    errors.append(error)
            server = threading.Thread(target=serve,daemon=True)
            server.start()
            config = Connection("127.0.0.1",listener.getsockname()[1],"TEST","demo","secret",
                                version=version,file=file)
            run(config,threading.Event(),lambda *event: events.append(event),list_only=listing,gga=gga_factory)
            server.join(timeout=6)
        self.assertFalse(errors,errors)
        return requests, events

    def test_caster_table_and_legacy(self):
        headers, events = self.exchange(
            b"SOURCETABLE 200 OK\r\nContent-Type: text/plain\r\n\r\n"
            b"STR;TEST;x;RTCM3;;2;GPS;net;ITA;46.1;13.2\r\nENDSOURCETABLE\r\n",listing=True)
        self.assertIn(b"Authorization: Basic ZGVtbzpzZWNyZXQ=",headers[0])
        self.assertIn(("mounts", {"TEST":(46.1,13.2)}), events)
        request, events = self.exchange(b"ICY 200 OK\r\n\xd3\x00\x03",version=1)
        self.assertIn(b"GET /TEST HTTP/1.0",request[0])
        self.assertIn(("data",b"\xd3\x00\x03"),events)

    def test_chunked_gga_and_recording(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "saved.rtcm"
            sentence = gga(46,13,100)
            requests, events = self.exchange(
                b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
                b"3;foo=bar\r\n\xd3\x00\x01\r\n0\r\n\r\n",
                file=str(path),gga_factory=lambda:sentence)
            self.assertIn(f"Ntrip-GGA: {sentence}".encode(),requests[0])
            self.assertEqual(requests[1],(sentence+"\r\n").encode())
            self.assertEqual(path.read_bytes(),b"\xd3\x00\x01")
            self.assertIn(("data", b"\xd3\x00\x01"),events)


if __name__ == "__main__":
    unittest.main()
