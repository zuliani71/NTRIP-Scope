"""NTRIP wire protocol and optional byte-for-byte outputs."""
import base64
import socket
import ssl
import time
from contextlib import ExitStack
from dataclasses import dataclass
from urllib.parse import quote


@dataclass(frozen=True)
class Connection:
    host: str
    port: int
    mount: str = ""
    username: str = ""
    password: str = ""
    tls: bool = False
    version: int = 2
    file: str = ""
    tcp: int = 0
    serial: str = ""
    baud: int = 115200


class Cancelled(Exception):
    pass


class Stream:
    def __init__(self, sock, stopped):
        self.socket = sock
        self.stopped = stopped
        self.buffer = bytearray()
        self.gga = None
        self.next_gga = float("inf")
        self.last_read = time.monotonic()

    def receive(self):
        while not self.stopped.is_set():
            now = time.monotonic()
            if now - self.last_read >= 30:
                raise TimeoutError("No data received for 30 seconds")
            if now >= self.next_gga:
                self.socket.sendall((self.gga() + "\r\n").encode("ascii"))
                self.next_gga = now + 10
            try:
                data = self.socket.recv(65536)
            except TimeoutError:
                continue
            self.last_read = time.monotonic()
            return data
        raise Cancelled

    def line(self, limit=16384):
        while True:
            end = self.buffer.find(b"\r\n")
            if 0 <= end <= limit:
                result = bytes(self.buffer[:end])
                del self.buffer[:end + 2]
                return result
            if len(self.buffer) > limit:
                raise ValueError("Invalid NTRIP header")
            data = self.receive()
            if not data:
                raise EOFError("Incomplete NTRIP response")
            self.buffer.extend(data)

    def take(self, count):
        while len(self.buffer) < count:
            data = self.receive()
            if not data:
                raise EOFError("Incomplete NTRIP chunk")
            self.buffer.extend(data)
        result = bytes(self.buffer[:count])
        del self.buffer[:count]
        return result

    def body(self, headers):
        if b"chunked" in headers.get(b"transfer-encoding", b"").lower():
            while True:
                size = int(self.line(1024).split(b";", 1)[0], 16)
                if not 0 <= size <= 8 * 1024 * 1024:
                    raise ValueError("Invalid NTRIP chunk size")
                if not size:
                    return
                while size:
                    part = min(size, 65536)
                    yield self.take(part)
                    size -= part
                if self.take(2) != b"\r\n":
                    raise ValueError("Invalid NTRIP chunk")
        else:
            if self.buffer:
                yield bytes(self.buffer)
                self.buffer.clear()
            while data := self.receive():
                yield data


def parse_sourcetable(data):
    mounts = {}
    for line in data.decode("utf-8", errors="replace").splitlines():
        fields = line.split(";")
        if len(fields) < 2 or fields[0] != "STR" or not fields[1]:
            continue
        location = None
        if len(fields) > 10:
            try:
                lat, lon = map(float, fields[9:11])
                if -90 <= lat <= 90 and -180 <= lon <= 180 and (lat or lon):
                    location = lat, lon
            except ValueError:
                pass
        mounts[fields[1]] = location
    return mounts


def request(config, list_only, gga):
    host = f"[{config.host}]" if ":" in config.host else config.host
    path = "" if list_only else quote(config.mount, safe="")
    lines = [f"GET /{path} HTTP/1.{int(config.version == 2)}",
             f"Host: {host}:{config.port}", "User-Agent: NTRIP NTRIP Scope/1.8",
             "Connection: close"]
    if config.version == 2:
        lines.append("Ntrip-Version: Ntrip/2.0")
        if not list_only and gga:
            lines.append(f"Ntrip-GGA: {gga()}")
    if config.username or config.password:
        token = base64.b64encode(f"{config.username}:{config.password}".encode()).decode()
        lines.append(f"Authorization: Basic {token}")
    return ("\r\n".join(lines) + "\r\n\r\n").encode("ascii")


def run(config, stopped, emit, *, list_only=False, gga=None):
    with ExitStack() as resources:
        sock = resources.enter_context(socket.create_connection((config.host, config.port), timeout=5))
        if config.tls:
            sock = resources.enter_context(ssl.create_default_context().wrap_socket(sock, server_hostname=config.host))
        sock.settimeout(0.5)
        if stopped.is_set():
            raise Cancelled
        sock.sendall(request(config, list_only, gga))
        stream = Stream(sock, stopped)
        status = stream.line().split(maxsplit=2)
        if len(status) < 2 or status[1] != b"200":
            raise ValueError("Caster: " + b" ".join(status).decode(errors="replace"))
        legacy = status[0] == b"ICY"
        sourcetable = status[0] == b"SOURCETABLE"
        if not (legacy or sourcetable or status[0].startswith(b"HTTP/")):
            raise ValueError("Invalid NTRIP response")
        headers = {}
        if not legacy:
            header_bytes = 0
            while line := stream.line():
                header_bytes += len(line) + 2
                if header_bytes > 16384:
                    raise ValueError("Invalid NTRIP header")
                key, _, value = line.partition(b":")
                headers[key.lower()] = value.strip()
        if list_only:
            table = bytearray()
            for block in stream.body(headers):
                table.extend(block)
                if len(table) > 4_000_000:
                    raise ValueError("Mountpoint list is too large")
                if b"ENDSOURCETABLE" in table:
                    break
            emit("mounts", parse_sourcetable(table))
            return
        if sourcetable or b"sourcetable" in headers.get(b"content-type", b"").lower():
            raise ValueError("Caster returned the mountpoint list")
        if gga:
            sock.sendall((gga() + "\r\n").encode("ascii"))
            stream.gga, stream.next_gga = gga, time.monotonic() + 10

        device = None
        if config.serial:
            import serial
            device = resources.enter_context(serial.Serial(config.serial, config.baud, write_timeout=1))
        listener = None
        if config.tcp:
            listener = resources.enter_context(socket.socket())
            listener.bind(("127.0.0.1", config.tcp))
            listener.listen(1)
            listener.setblocking(False)
            emit("output", f"TCP 127.0.0.1:{config.tcp}")
        output = resources.enter_context(open(config.file, "wb", buffering=0)) if config.file else None
        if device:
            emit("output", config.serial)
        emit("status", "Connected, waiting for data…")
        peer = None
        try:
            for block in stream.body(headers):
                if stopped.is_set():
                    raise Cancelled
                if output:
                    output.write(block)
                if device:
                    device.write(block)
                if listener and peer is None:
                    try:
                        peer, _ = listener.accept()
                        peer.settimeout(0.2)
                    except BlockingIOError:
                        pass
                if peer:
                    try:
                        peer.sendall(block)
                    except OSError:
                        peer.close()
                        peer = None
                emit("data", block)
        finally:
            if peer:
                peer.close()
        emit("status", "Connection closed by caster")
