"""Create the portable desktop executable on its target OS."""
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    root = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory() as folder:
        options = []
        if sys.platform == "win32":
            # Vista+ ICO files can embed a PNG directly.
            from PIL import Image
            with Image.open(root / "assets/orbit.png") as source:
                png = Path(folder) / "orbit.png"
                source.resize((256, 256), Image.Resampling.LANCZOS).save(png)
            data = png.read_bytes()
            icon = Path(folder) / "orbit.ico"
            icon.write_bytes(struct.pack("<HHHBBBBHHII", 0, 1, 1, 0, 0, 0, 0, 1, 32, len(data), 22) + data)
            options += ["--icon", str(icon), "--windowed"]
        subprocess.run([sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", "--onefile",
                        "--name", "NTRIP-Scope", "--add-data", "assets:assets",
                        "--collect-submodules", "serial", *options, "app.py"],
                       cwd=root, check=True)


if __name__ == "__main__":
    main()
