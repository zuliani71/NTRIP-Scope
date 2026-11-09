"""Fetch only visible OpenStreetMap tiles, with a local HTTP cache."""
import json
import math
import os
import time
from email.utils import parsedate_to_datetime
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

CACHE = Path(os.getenv("LOCALAPPDATA") or os.getenv("XDG_CACHE_HOME") or Path.home()/".cache") / "NTRIP Scope" / "tiles"


def project(lat, lon, zoom):
    size = 256 * 2**zoom
    phi = math.radians(max(-85.05112878, min(85.05112878, lat)))
    return (lon + 180) / 360 * size, (1 - math.asinh(math.tan(phi))/math.pi) * size / 2


def unproject(x, y, zoom):
    size = 256 * 2**zoom
    y = max(0, min(size, y))
    return math.degrees(math.atan(math.sinh(math.pi * (1 - 2*y/size)))), (x/size*360)%360-180


def load_tile(key):
    z, x, y = key
    path = CACHE / str(z) / str(x) / f"{y}.tile"
    meta = {}
    data = None
    try:
        raw = path.read_bytes()
        header, data = raw.split(b"\n", 1)
        meta = json.loads(header)
        if meta.get("expiry", 0) > time.time():
            return data
    except (OSError, ValueError):
        pass
    headers = {"User-Agent": "NTRIP-Scope/1.9"}
    for name, header in (("etag", "If-None-Match"), ("modified", "If-Modified-Since")):
        if meta.get(name):
            headers[header] = meta[name]
    try:
        response = urlopen(Request(f"https://tile.openstreetmap.org/{z}/{x}/{y}.png", headers=headers), timeout=5)
    except HTTPError as error:
        if error.code != 304 or data is None:
            error.close()
            return None
        response = error
    except OSError:
        return None
    with response:
        if response.code != 304:
            data = response.read(1_000_001)
            if not data.startswith(b"\x89PNG\r\n\x1a\n") or len(data) > 1_000_000:
                return None
            meta = {}
        directives = dict(item.strip().partition("=")[::2]
                          for item in response.headers.get("Cache-Control", "").split(","))
        expiry = time.time() + 7*86400
        try:
            if "max-age" in directives:
                expiry = time.time() + int(directives["max-age"]) - int(response.headers.get("Age", 0))
            elif response.headers.get("Expires"):
                expiry = parsedate_to_datetime(response.headers["Expires"]).timestamp()
        except (ValueError, TypeError, OverflowError):
            pass
        if "no-cache" in directives:
            expiry = 0
        meta.update(expiry=expiry, etag=response.headers.get("ETag", meta.get("etag")),
                    modified=response.headers.get("Last-Modified", meta.get("modified")))
        try:
            if "no-store" in directives:
                path.unlink(missing_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(json.dumps(meta).encode() + b"\n" + data)
        except OSError:
            pass
        return data
