"""RTCM3 framing, observations, and station/GPS geometry."""
from collections import defaultdict, deque
from datetime import datetime, timezone
from math import atan2, cos, degrees, hypot, pi, radians, sin, sqrt
from time import time

from pyrtcm import RTCMMessage, RTCMParseError, RTCM_DATA_FIELDS, calc_crc24q

MS_PER_WEEK = 604_800_000


def gga(lat, lon, height, geoid=0, now=None):
    now = now or datetime.now(timezone.utc)

    def coordinate(angle, digits):
        units = round(abs(angle) * 60_000_000)
        deg, rest = divmod(units, 60_000_000)
        minutes, fraction = divmod(rest, 1_000_000)
        return f"{deg:0{digits}d}{minutes:02d}.{fraction:06d}"

    ns = "S" if lat < 0 else "N"
    ew = "W" if lon < 0 else "E"
    body = (f"GPGGA,{now:%H%M%S}.00,{coordinate(lat, 2)},{ns},{coordinate(lon, 3)},{ew},"
            f"1,00,1.0,{height-geoid:.3f},M,{geoid:.3f},M,,")
    checksum = 0
    for byte in body.encode("ascii"):
        checksum ^= byte
    return f"${body}*{checksum:02X}"


def dms(angle):
    units = round(abs(angle) * 36_000_000)
    deg, rest = divmod(units, 36_000_000)
    minutes, seconds = divmod(rest, 600_000)
    return deg, minutes, seconds / 10_000


def from_dms(deg, minutes, seconds, negative, limit):
    if not (0 <= deg <= limit and 0 <= minutes < 60 and 0 <= seconds < 60):
        raise ValueError("Invalid coordinates")
    result = deg + minutes / 60 + seconds / 3600
    if result > limit:
        raise ValueError("Invalid coordinates")
    return -result if negative else result


class Decoder:
    def __init__(self):
        self.buffer = bytearray()
        self.frames = defaultdict(lambda: deque(maxlen=20))
        self.counts = defaultdict(int)
        self.signals = defaultdict(set)
        self.bad_crc = 0
        self.antenna = None
        self.orbits = {}
        self.epoch = None

    def feed(self, data):
        self.buffer.extend(data)
        cursor = 0
        while (start := self.buffer.find(0xD3, cursor)) >= 0:
            cursor = start
            if len(self.buffer) - start < 3:
                break
            high = self.buffer[start + 1]
            length = ((high & 3) << 8) | self.buffer[start + 2]
            if high & 0xFC or length < 2:
                cursor += 1
                continue
            end = start + length + 6
            if end > len(self.buffer):
                break
            raw = bytes(self.buffer[start:end])
            if calc_crc24q(raw):
                self.bad_crc += 1
                cursor += 1
                continue
            cursor = end
            payload = raw[3:-3]
            kind = (payload[0] << 4) | (payload[1] >> 4)
            try:
                message = RTCMMessage(payload=payload)
            except (RTCMParseError, ValueError, TypeError, AttributeError, IndexError):
                message = None
            self.counts[kind] += 1
            self.frames[kind].append((self.counts[kind], datetime.now(), payload, message))
            if message is None:
                continue
            self.signals[kind].update(row[1] for row in observations(message))
            if kind in (1005, 1006):
                self.antenna = geodetic(message.DF025, message.DF026, message.DF027) or self.antenna
            elif kind == 1019 and message.DF102 == 0 and 1 <= message.DF009 <= 32:
                self.orbits[message.DF009] = message
            elif 1071 <= kind <= 1077 and 0 <= message.DF004 < MS_PER_WEEK:
                tow = message.DF004 / 1000
                self.epoch = tow, round((time() - 315_964_800 - tow) / 604_800)
        else:
            cursor = len(self.buffer)
        del self.buffer[:cursor]


def observations(message):
    if message is None or not hasattr(message, "NCell"):
        return []
    satellites = {getattr(message, f"PRN_{i:02d}", None): i for i in range(1, message.NSat + 1)}
    rows = []
    for index in range(1, message.NCell + 1):
        def value(field, number=index, default=None):
            return getattr(message, f"DF{field}_{number:02d}", default)

        prn = getattr(message, f"CELLPRN_{index:02d}", None)
        signal = getattr(message, f"CELLSIG_{index:02d}", None)
        sat = satellites.get(prn)
        if sat is None:
            continue
        integer = value(397, sat, 0)
        modulo = value(398, sat)
        base = None if integer == 255 or modulo is None else integer + modulo
        code = value(405, default=value(400))
        phase = value(406, default=value(401))
        rough, fine = value(399, sat), value(404)
        rate = rough + fine if rough is not None and fine is not None and rough != -8192 and fine != -1.6384 else None
        rows.append((prn, signal or "?",
                     (base + code) * 299_792.458 if base is not None and code not in (None, -2**-10) else None,
                     (base + phase) * 299_792.458 if base is not None and phase not in (None, -2**-8) else None,
                     value(408, default=value(403)) or None, rate))
    return rows


def fields(message):
    if message is None:
        return ""
    rows = []
    text_fields = {}
    for key, value in vars(message).items():
        if not key.startswith("DF"):
            continue
        code = key.split("_")[0]
        spec = RTCM_DATA_FIELDS.get(code)
        label = spec[-1] if spec else code
        if code in {"DF030", "DF033", "DF228", "DF230", "DF232"}:
            text_fields.setdefault(label, []).append(chr(value) if isinstance(value, int) else str(value))
        else:
            rows.append(f"{key}  {label}  {value}")
    return "\n".join([f"{k}: {''.join(v)}" for k, v in text_fields.items()] + rows)


def geodetic(x, y, z):
    a, e2 = 6_378_137.0, 0.00669437999014
    p = hypot(x, y)
    if not 6_000_000 <= hypot(p, z) <= 7_000_000:
        return None
    lat = atan2(z, p * (1 - e2))
    for _ in range(8):
        n = a / sqrt(1 - e2 * sin(lat)**2)
        lat = atan2(z + n * e2 * sin(lat), p)
    n = a / sqrt(1 - e2 * sin(lat)**2)
    return degrees(lat), degrees(atan2(y, x)), p*cos(lat) + z*sin(lat) - n*(1-e2*sin(lat)**2)


def orbit_position(message, tow, week):
    a = message.DF092**2
    dt = ((week - message.DF076 + 512) % 1024 - 512) * 604_800 + tow - message.DF093
    if abs(dt) > 7200 or not 4500 <= message.DF092 <= 6000:
        return None
    earth = 7.2921151467e-5
    e = message.DF090
    mean = message.DF088*pi + (sqrt(3.986005e14/a**3) + message.DF087*pi)*dt
    anomaly = mean
    for _ in range(10):
        anomaly -= (anomaly - e*sin(anomaly) - mean)/(1-e*cos(anomaly))
    angle = atan2(sqrt(1-e*e)*sin(anomaly), cos(anomaly)-e) + message.DF099*pi
    s, c = sin(2*angle), cos(2*angle)
    radius = a*(1-e*cos(anomaly)) + message.DF086*s + message.DF098*c
    inclination = (message.DF097 + message.DF079*dt)*pi + message.DF096*s + message.DF094*c
    argument = angle + message.DF091*s + message.DF089*c
    node = message.DF095*pi + (message.DF100*pi-earth)*dt - earth*message.DF093
    x, y = radius*cos(argument), radius*sin(argument)
    return x*cos(node)-y*cos(inclination)*sin(node), x*sin(node)+y*cos(inclination)*cos(node), y*sin(inclination)


def sky_point(station, satellite):
    lat, lon = map(radians, station[:2])
    h = station[2] if len(station) > 2 else 0
    e2 = 0.00669437999014
    n = 6_378_137 / sqrt(1-e2*sin(lat)**2)
    x, y, z = satellite
    dx = x-(n+h)*cos(lat)*cos(lon)
    dy = y-(n+h)*cos(lat)*sin(lon)
    dz = z-(n*(1-e2)+h)*sin(lat)
    east = -sin(lon)*dx + cos(lon)*dy
    north = -sin(lat)*(cos(lon)*dx + sin(lon)*dy) + cos(lat)*dz
    up = cos(lat)*(cos(lon)*dx + sin(lon)*dy) + sin(lat)*dz
    return (atan2(east, north), atan2(up, hypot(east, north))) if up >= 0 else None
