"""NMEA rover position sentences shared by the desktop app and CLI."""
from datetime import datetime, timezone


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

def valid_gga(sentence):
    """Return a checksum-verified GGA with a usable geographic position."""
    import math
    import re

    if not re.fullmatch(r"\$[A-Z0-9]{2}GGA,[ -~]+\*[0-9A-Fa-f]{2}", sentence) or len(sentence) > 256:
        return False
    body, checksum = sentence[1:].split("*", 1)
    value = 0
    for byte in body.encode("ascii"):
        value ^= byte
    if value != int(checksum, 16):
        return False
    fields = body.split(",")
    try:
        if len(fields) < 15 or not 1 <= int(fields[6]) <= 8:
            return False
        for raw, hemisphere, degrees, limit in ((fields[2], fields[3], 2, 90), (fields[4], fields[5], 3, 180)):
            if hemisphere not in ("NS" if degrees == 2 else "EW") or not re.fullmatch(r"[0-9]+\.[0-9]+|[0-9]+", raw):
                return False
            if len(raw.split(".")[0]) != degrees + 2:
                return False
            units, minutes = int(raw[:degrees]), float(raw[degrees:])
            if not math.isfinite(minutes) or not 0 <= minutes < 60 or units + minutes / 60 > limit:
                return False
        if not all(not fields[index] or math.isfinite(float(fields[index])) for index in (9, 11)):
            return False
    except (ValueError, IndexError):
        return False
    return True


class GGAReader:
    """Bounded NMEA framing for serial and Bluetooth byte streams."""

    def __init__(self, include_no_fix=False):
        self.buffer = bytearray()
        self.include_no_fix = include_no_fix

    def feed(self, data):
        sentences = []
        for byte in data:
            if byte == 36:
                self.buffer = bytearray([byte])
            elif byte in (10, 13):
                if self.buffer:
                    try:
                        text = self.buffer.decode("ascii")
                        accepted = gga_quality(text) is not None if self.include_no_fix else valid_gga(text)
                        if accepted:
                            sentences.append(text)
                    except UnicodeDecodeError:
                        pass
                self.buffer.clear()
            elif self.buffer:
                if 32 <= byte <= 126 and len(self.buffer) < 256:
                    self.buffer.append(byte)
                else:
                    self.buffer.clear()
        return sentences


def position_from_gga(sentence):
    """Return decimal latitude/longitude and optional ellipsoidal height."""
    if not valid_gga(sentence):
        return None
    import math
    f = sentence[1:-3].split(",")
    def angle(raw, width, hemisphere):
        value = float(raw[:width]) + float(raw[width:]) / 60
        return -value if hemisphere in ("S", "W") else value
    height = None
    if f[9] and f[11] and f[10] == f[12] == "M":
        h = float(f[9]) + float(f[11])
        if math.isfinite(h): height = h
    return angle(f[2], 2, f[3]), angle(f[4], 3, f[5]), height


def gga_quality(sentence):
    """Receiver telemetry, including quality 0 with empty coordinates; never forward NO FIX."""
    import re
    if len(sentence)>256 or not re.fullmatch(r"\$[A-Z0-9]{2}GGA,[ -~]+\*[0-9A-Fa-f]{2}",sentence):return None
    body=sentence[1:-3];checksum=0
    for byte in body.encode('ascii'):checksum^=byte
    if checksum!=int(sentence[-2:],16):return None
    fields=body.split(',')
    if len(fields)<15 or fields[6] not in tuple(str(i) for i in range(9)):return None
    quality=int(fields[6])
    return quality if quality==0 or valid_gga(sentence) else None


FIX_LABELS={0:'NO FIX',1:'GNSS',2:'DGNSS',4:'RTK FIXED',5:'RTK FLOAT',6:'ESTIMATED'}
class ReceiverFix:
    def __init__(self):self.reset()
    def reset(self):
        self.readers={};self.quality=None;self.received=None;self.source=''
    def feed(self,source,data,now):
        for sentence in self.readers.setdefault(source,GGAReader(include_no_fix=True)).feed(data):
            self.quality=gga_quality(sentence);self.received=now;self.source=source
    def display(self,now,active):
        if self.quality is None:return ('Waiting for receiver GGA','gray')
        age=max(0,int(now-self.received));label=FIX_LABELS.get(self.quality,f'QUALITY {self.quality}')
        prefix='PAUSED · ' if not active else 'STALE · ' if age>5 else ''
        color='gray' if prefix else '#bc3030' if self.quality==0 else '#188342' if self.quality==4 else '#936400'
        return (f'{prefix}{label} · {age} s · {self.source}',color)
