# NTRIP Scope CLI

The same command runs on macOS, Windows and Linux with Python 3.10 or later. On Windows, use `py -3` in place of `python3` if appropriate.

```sh
python3 ntripscope.py --help
python3 ntripscope.py --host caster.example.org --port 2101 --list
python3 ntripscope.py --host caster.example.org --mountpoint EXAMPLE > corrections.rtcm
```

Without an explicit destination, the stream is written as **binary RTCM to stdout**. Status and errors go to stderr. In list mode, stdout contains one mountpoint name per line, and configured stream destinations are ignored. On Windows, use Command Prompt or PowerShell 7.4+ for binary redirection, or use `--file`.

## Caster and rover

```sh
python3 ntripscope.py --ip 192.0.2.10 --port 2101 --mountpoint VRS \
  --username demo --ask-password --version 2 \
  --latitude 46.125000 --longitude 13.333333 --height 100.000
```

Use `--password` when supplying credentials non-interactively, or `--ask-password` to keep the password out of the command line. Use `--tls` if the caster supports it. Rover coordinates are signed decimal degrees. Height is ellipsoidal, in metres. Height and geoid separation default to zero. When both coordinates are supplied, the client sends GGA and refreshes it every 10 seconds while the connection is active.

## Multiple destinations

```sh
python3 ntripscope.py --host caster.example.org --mountpoint EXAMPLE \
  --file corrections.rtcm --tcp 5000 --serial /dev/ttyUSB0:115200 --stdout
```

Each of `--file`, `--tcp` and `--serial` can be repeated. Omit `--stdout` to write only to the destinations selected. File outputs replace existing files. TCP opens a local listener at `127.0.0.1:PORT` for one consumer per port. A consumer receives data from the point it connects. On Windows, a serial destination looks like `COM3:115200`. Serial output requires `python3 -m pip install pyserial`. The other CLI modes require only the standard library.

## Configuration file

Copy `ntrip-scope.example.ini` and edit the settings, then run:

```sh
python3 ntripscope.py --config ntrip.ini
python3 ntripscope.py --config ntrip.ini --list
```

Command-line options override the corresponding INI values. A repeated destination option replaces the configured list for that destination type. Relative output paths are resolved from the working directory. Keep INI files containing passwords private.

### INI syntax and accepted keys

Save the file as UTF-8. Write one `key = value` per line under its section.
Use `;` or `#` on a separate line for comments. For repeated destinations,
write the key once and indent each additional destination on its own line.
Do not quote paths, even when they contain spaces. Use a period as the decimal
separator. Boolean values accept `true` and `false`.

| Section | Key | Value or default |
| --- | --- | --- |
| `[caster]` | `host` | Required caster IP address or hostname |
| | `port` | TCP port, default `2101` |
| | `mountpoint` | Required for streaming |
| | `username`, `password` | Optional caster credentials |
| | `tls` | Default `false` |
| | `version` | `1` or `2`, default `2` |
| | `list` | `true` to list mountpoints and exit, default `false` |
| `[rover]` | `latitude`, `longitude` | Signed decimal degrees. Supply both to send GGA. |
| | `height`, `geoid` | Ellipsoidal height and geoid separation in metres, both default `0` |
| `[outputs]` | `file` | One output path per line |
| | `tcp` | One local listener port per line |
| | `serial` | One device per line, optionally followed by `:BAUD` |
| | `stdout` | Defaults to `true` when no other output is selected |

For a ready-to-edit VRS example, see [ntripscope-vrs.example.ini](ntripscope-vrs.example.ini).
