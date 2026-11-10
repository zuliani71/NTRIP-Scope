"""Cross-platform command-line entry point for NTRIP Scope."""
import argparse
import configparser
import getpass
import math
import os
from pathlib import Path
import sys
import threading

from nmea import gga
from transport import Cancelled, Connection, Outputs, run

SCHEMA = {
    "caster": {"host": str, "port": int, "mountpoint": str, "username": str,
               "password": str, "tls": bool, "version": int, "list": bool},
    "rover": {"latitude": float, "longitude": float, "height": float, "geoid": float},
    "outputs": {"file": list, "tcp": list, "serial": list, "stdout": bool},
}


def settings(path):
    if path is None:
        return {}
    config = configparser.ConfigParser(interpolation=None)
    with path.open(encoding="utf-8-sig") as stream:
        config.read_file(stream)
    if config.defaults():
        raise ValueError("Use [caster], [rover] or [outputs] instead of [DEFAULT]")
    result = {}
    for section in config.sections():
        if section not in SCHEMA:
            raise ValueError(f"Unknown config section [{section}]")
        for key, value in config[section].items():
            kind = SCHEMA[section].get(key)
            if kind is None:
                raise ValueError(f"Unknown setting [{section}] {key}")
            if kind is bool:
                value = config.getboolean(section, key)
            elif kind is list:
                value = [line.strip() for line in value.splitlines() if line.strip()]
            else:
                value = kind(value)
            result[key] = value
    return result


def port(value):
    value = int(value)
    if not 1 <= value <= 65535:
        raise ValueError("Port must be between 1 and 65535")
    return value


def serial_destination(value):
    device, separator, baud = value.rpartition(":")
    if not separator:
        device, baud = value, "115200"
    if not device or int(baud) <= 0:
        raise ValueError("Serial destination must be DEVICE[:BAUD]")
    return device, int(baud)


def arguments(argv):
    parser = argparse.ArgumentParser(prog="ntripscope",
        description="Receive raw RTCM from an NTRIP caster or list its mountpoints.",
        argument_default=argparse.SUPPRESS)
    parser.add_argument("--config", type=Path, help="UTF-8 INI configuration file")
    parser.add_argument("--host", "--ip", help="Caster IP address or hostname")
    parser.add_argument("--port", type=int, help="Caster port (default: 2101)")
    parser.add_argument("--mountpoint", "--mount", help="Caster mountpoint")
    parser.add_argument("--username", "--user", help="Caster username")
    auth = parser.add_mutually_exclusive_group()
    auth.add_argument("--password", help="Caster password")
    auth.add_argument("--ask-password", action="store_true", help="Prompt for the password without echo")
    parser.add_argument("--tls", action=argparse.BooleanOptionalAction, help="Use TLS")
    parser.add_argument("--version", type=int, choices=(1, 2), help="NTRIP version (default: 2)")
    parser.add_argument("--list", action=argparse.BooleanOptionalAction, help="List mountpoint names and exit")
    parser.add_argument("--file", action="append", metavar="PATH", help="Record raw RTCM (repeatable, overwrites file)")
    parser.add_argument("--tcp", action="append", metavar="PORT", help="Forward to a TCP listener on 127.0.0.1 (repeatable)")
    parser.add_argument("--serial", action="append", metavar="DEVICE[:BAUD]", help="Write to serial (repeatable, default 115200 baud)")
    parser.add_argument("--stdout", action=argparse.BooleanOptionalAction,
                        help="Write raw RTCM to stdout, also the default when no outputs are selected")
    parser.add_argument("--latitude", "--lat", type=float, help="Rover latitude in decimal degrees")
    parser.add_argument("--longitude", "--lon", type=float, help="Rover longitude in decimal degrees")
    parser.add_argument("--height", type=float, help="Rover ellipsoidal height in metres (default: 0)")
    parser.add_argument("--geoid", type=float, help="Geoid separation in metres (default: 0)")
    parser.add_argument("--quiet", action="store_true", help="Suppress status messages on stderr")
    flags = vars(parser.parse_args(argv))
    try:
        options = settings(flags.pop("config", None))
        options.update(flags)
        host = options.get("host", "").strip()
        if host.startswith("[") and host.endswith("]"):
            host = host[1:-1]
        mount = options.get("mountpoint", "").strip().strip("/")
        listing = options.get("list", False)
        if not host or any(c.isspace() or c in "/?#[]" for c in host):
            raise ValueError("Provide a valid caster address with --host")
        if not mount and not listing:
            raise ValueError("Provide --mountpoint or use --list")
        version = options.get("version", 2)
        if version not in (1, 2):
            raise ValueError("NTRIP version must be 1 or 2")
        outputs = Outputs(
            () if listing else tuple(dict.fromkeys(options.get("file", []))),
            () if listing else tuple(dict.fromkeys(map(port, options.get("tcp", [])))),
            () if listing else tuple(dict.fromkeys(map(serial_destination, options.get("serial", [])))),
        )
        if len({name for name, _ in outputs.serial_ports}) != len(outputs.serial_ports):
            raise ValueError("A serial device cannot use more than one baud rate")
        stdout = options.get("stdout", not (outputs.files or outputs.tcp_ports or outputs.serial_ports))
        if not listing and not (stdout or outputs.files or outputs.tcp_ports or outputs.serial_ports):
            raise ValueError("Select at least one output")
        sentence = None
        if not listing and any(key in options for key in SCHEMA["rover"]):
            lat, lon = options.get("latitude"), options.get("longitude")
            height, geoid = options.get("height", 0), options.get("geoid", 0)
            if lat is None or lon is None or not (-90 <= lat <= 90 and -180 <= lon <= 180):
                raise ValueError("Rover needs both decimal latitude (±90) and longitude (±180)")
            if not all(map(math.isfinite, (height, geoid, height-geoid))):
                raise ValueError("Rover height and geoid separation must be finite")
            def sentence():
                return gga(lat, lon, height, geoid)
        caster_port = port(options.get("port", 2101))
        password = getpass.getpass("Caster password: ") if options.get("ask_password") else options.get("password", "")
        config = Connection(host, caster_port, mount, options.get("username", ""), password,
                            options.get("tls", False), version)
    except (OSError, ValueError, configparser.Error) as error:
        parser.error(str(error))
    return config, outputs, listing, stdout, sentence, options.get("quiet", False)


def main(argv=None):
    config, outputs, listing, stdout, gga_factory, quiet = arguments(argv)

    def emit(kind, value):
        if kind == "data":
            if stdout:
                sys.stdout.buffer.write(value)
                sys.stdout.buffer.flush()
        elif kind == "mounts":
            sys.stdout.buffer.write("".join(f"{name}\n" for name in sorted(value)).encode("utf-8"))
            sys.stdout.buffer.flush()
        elif not quiet:
            print(value, file=sys.stderr, flush=True)

    try:
        if os.name == "nt":
            import msvcrt
            msvcrt.setmode(sys.stdout.fileno(), os.O_BINARY)
        run(config, threading.Event(), emit, list_only=listing, gga=gga_factory, outputs=outputs)
    except (KeyboardInterrupt, Cancelled):
        return 130
    except BrokenPipeError:
        # Avoid a second flush error when the receiving program closes a pipe.
        with open(os.devnull, "wb") as discard:
            os.dup2(discard.fileno(), sys.stdout.fileno())
        return 0
    except ModuleNotFoundError as error:
        if error.name != "serial":
            raise
        print("ntripscope: serial output requires pySerial (python -m pip install pyserial)", file=sys.stderr)
        return 1
    except (OSError, ValueError, EOFError) as error:
        print(f"ntripscope: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
