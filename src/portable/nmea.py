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
