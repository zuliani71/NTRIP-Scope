"""NTRIP Scope portable desktop client."""
from configparser import ConfigParser, Error as INIError
import json
import os
import queue
import sys
import threading
import time
import tkinter as tk
import webbrowser
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from tkinter.scrolledtext import ScrolledText

from charts import ASSETS, BG, MapSky, cnr_chart
from gnss import Decoder, dms, fields, from_dms, gga, observations
from transport import Cancelled, Connection, Outputs, run
from receivers import SerialReceiverHub
from nmea import GGAReader, position_from_gga, ReceiverFix
from ntripscope import AUTHOR, PROJECT_URL, arguments as cli_arguments, settings

DESKTOP_VERSION = "1.35"
ITALIAN = json.loads((ASSETS / "italian.json").read_text(encoding="utf-8"))
SETTINGS = Path(os.getenv("APPDATA") or os.getenv("XDG_CONFIG_HOME") or Path.home() / ".config") / "NTRIP Scope" / "settings.json"


def number(text):
    return float(text.replace(",", "."))


def hex_preview(data):
    lines = []
    for i in range(0, len(data), 16):
        line = data[i:i+16]
        ascii_text = "".join(chr(byte) if 32 <= byte <= 126 else "." for byte in line)
        lines.append(f"{line.hex(' ').upper():<47}  |{ascii_text}|")
    return "\n".join(lines)


def replace_text(widget, value):
    widget.configure(state="normal")
    widget.delete("1.0", "end")
    widget.insert("1.0", value)
    widget.configure(state="disabled")


class Client:
    def __init__(self, root):
        self.root = root
        try:
            saved = json.loads(SETTINGS.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            saved = {}
        self.lang = tk.StringVar(value=saved.get("language", "English"))
        self.host = tk.StringVar(value=saved.get("host", ""))
        self.port = tk.StringVar(value=saved.get("port", "2101"))
        self.mount = tk.StringVar(value=saved.get("mount", ""))
        self.user = tk.StringVar(value=saved.get("user", ""))
        self.password = tk.StringVar()
        self.tls = tk.BooleanVar(value=saved.get("tls", False))
        self.version = tk.StringVar(value=saved.get("version", "2"))
        self.record = tk.BooleanVar()
        self.output = tk.StringVar()
        self.tcp = tk.BooleanVar()
        self.tcp_port = tk.StringVar(value="5000")
        self.serial = tk.BooleanVar(value=saved.get("serial", False))
        self.serial_port = tk.StringVar(value=saved.get("serial_port", ""))
        self.baud = tk.StringVar(value=saved.get("baud", "115200"))
        self.send_rover = tk.BooleanVar()
        self.raw_gga = tk.StringVar()
        self.imported_outputs = Outputs()
        self.height = tk.StringVar()
        self.geoid = tk.StringVar()
        self.axes = [[tk.StringVar() for _ in range(4)] + [tk.StringVar(value=hemisphere)]
                     for hemisphere in ("N", "E")]
        self.values = [None, None]
        self.status = "Ready"
        self.events = queue.Queue(maxsize=512)
        self.stopped = threading.Event()
        self.worker = None
        self.decoder = Decoder()
        self.mounts = {}
        self.source_key = self.stream_key = None
        self.bytes = 0
        self.recent = b""
        self.receiver_streams = {}
        self.receivers = SerialReceiverHub()
        self.receiver_fix = ReceiverFix()
        self.receiver_position = None
        self.receiver_source = ""
        self.receiver_parsers = {}
        self.station_cache = {}
        self.receiver_error = ""
        self.last = self.started = 0
        self.windows = {}
        self.map_view = None
        self.monitor_widgets = None
        self.outputs = []
        root.title("NTRIP Scope · RTCM Decoder")
        root.minsize(608, 300)
        root.geometry("640x350")
        try:
            self.icon = tk.PhotoImage(file=str(ASSETS / "orbit.png")).subsample(8)
            root.iconphoto(True, self.icon)
        except tk.TclError:
            self.icon = None
        root.protocol("WM_DELETE_WINDOW", self.close)
        self.main = ttk.Frame(root, padding=16)
        self.main.pack(fill="both", expand=True)
        self.build()
        self.root.after(100, self.poll)

    def tr(self, text):
        return ITALIAN.get(text, text) if self.lang.get() == "Italiano" else text

    def build(self):
        for child in self.main.winfo_children():
            child.destroy()
        menu = tk.Menu(self.root)
        help_menu = tk.Menu(menu, tearoff=False)
        help_menu.add_command(label=self.tr("About NTRIP Scope"),
                              command=self.open_about)
        menu.add_cascade(label=self.tr("Help"), menu=help_menu)
        self.root.configure(menu=menu)
        top = ttk.Frame(self.main)
        top.pack(fill="x", pady=(0, 12))
        if self.icon is not None:
            artwork = tk.PhotoImage(file=str(ASSETS / "orbit.png")).zoom(6).subsample(116)
            logo = ttk.Label(top, image=artwork)
            logo.image = artwork
            logo.pack(side="left", padx=(0, 12))
        heading = ttk.Frame(top)
        heading.pack(side="left")
        title = ttk.Frame(heading); title.pack(anchor="w")
        ttk.Label(title, text="NTRIP Scope", font=("TkDefaultFont", 17, "bold")).pack(side="left")
        ttk.Label(title, text="v"+DESKTOP_VERSION, font=("TkDefaultFont", 9, "bold")).pack(side="left", padx=(6,0))
        ttk.Label(heading, text=self.tr("NTRIP client · RTCM decoder"), font=("TkDefaultFont",9)).pack(anchor="w")
        ttk.Button(top, text="ⓘ", width=3, command=self.open_about).pack(side="right", padx=2)
        for key, label, method in reversed((
            ("map","Map & sky",self.map_window), ("live","Live stream",self.monitor),
            ("options","Options",self.options),
        )):
            ttk.Button(top, text=self.tr(label), command=lambda k=key, l=label, f=method: self.open(k,l,f)).pack(side="right", padx=2)
        form = ttk.Frame(self.main)
        form.pack(fill="x")
        form.columnconfigure(1, weight=1)
        self.connection_fields = []
        for row, (label, variable) in enumerate((("Caster address", self.host), ("Mountpoint", self.mount),
                                                  ("Username", self.user), ("Password", self.password))):
            ttk.Label(form, text=self.tr(label)).grid(row=row,column=0,sticky="w",padx=(0,8),pady=3)
            if row == 1:
                self.mount_menu = ttk.Combobox(form,textvariable=variable,values=sorted(self.mounts))
                entry = self.mount_menu
            else:
                entry = ttk.Entry(form,textvariable=variable,show="•" if row==3 else "")
            entry.grid(row=row,column=1,sticky="ew",pady=3)
            self.connection_fields.append(entry)
        self.port_field = ttk.Entry(form,textvariable=self.port,width=8)
        self.port_field.grid(row=0,column=3,padx=(4,0))
        self.connection_fields.append(self.port_field)
        ttk.Label(form,text=self.tr("Port")).grid(row=0,column=2,padx=(8,0))
        self.fetch = ttk.Button(form,text=self.tr("Fetch mountpoints"),command=lambda:self.start(True))
        self.fetch.grid(row=1,column=2,columnspan=2,sticky="ew",padx=(8,0))
        self.rover_button = ttk.Button(form,text=self.tr("Manual Rover position"),
            command=lambda:self.open("rover","Manual Rover position",self.rover))
        self.rover_button.grid(row=2,column=2,columnspan=2,sticky="ew",padx=(8,0))
        ttk.Separator(self.main).pack(fill="x",pady=12)
        footer = ttk.Frame(self.main)
        footer.pack(fill="x")
        self.action = ttk.Button(footer,command=self.toggle)
        self.action.pack(side="right")
        self.status_label = ttk.Label(footer,wraplength=440,justify="left")
        self.status_label.pack(anchor="w")
        self.fix_label=ttk.Label(footer,wraplength=440,justify="left",font=("TkDefaultFont",9,"bold"))
        self.fix_label.pack(anchor="w")
        self.fix_note=ttk.Label(footer,wraplength=440,justify="left")
        self.fix_note.pack(anchor="w")
        self.bar = tk.Canvas(footer,width=156,height=10,highlightthickness=0)
        self.bar.pack(anchor="w",pady=3)
        self.segments = [self.bar.create_rectangle(i*13,0,i*13+10,9,outline="") for i in range(12)]
        self.count = ttk.Label(footer)
        self.count.pack(anchor="w")
        self.update_status()

    def open(self,key,title,render):
        win = self.windows.get(key)
        if win and win.winfo_exists():
            win.lift()
            return
        win = tk.Toplevel(self.root)
        win.title(self.tr(title))
        self.windows[key] = win
        win.protocol("WM_DELETE_WINDOW", lambda:self.close_window(key))
        render(win)

    def close_window(self,key):
        self.windows.pop(key).destroy()
        if key == "map":
            self.map_view = None
        elif key == "live":
            self.monitor_widgets = None

    def close(self):
        self.stopped.set()
        self.receivers.pause()
        threading.Thread(target=self.receivers.close, daemon=True).start()
        try:
            SETTINGS.parent.mkdir(parents=True, exist_ok=True)
            SETTINGS.write_text(json.dumps({
                "language":self.lang.get(), "host":self.host.get(), "port":self.port.get(),
                "mount":self.mount.get(), "user":self.user.get(), "tls":self.tls.get(),
                "version":self.version.get(), "serial":self.serial.get(),
                "serial_port":self.serial_port.get(), "baud":self.baud.get(),
            }), encoding="utf-8")
        except OSError:
            pass
        self.root.destroy()

    def open_about(self):
        self.open("about", "About NTRIP Scope", self.about)

    def about(self, win):
        frame = ttk.Frame(win, padding=20)
        frame.pack(fill="both", expand=True)
        header = ttk.Frame(frame)
        header.pack(fill="x", pady=(0, 8))
        if self.icon is not None:
            artwork = self.icon.subsample(2)
            icon = ttk.Label(header, image=artwork)
            icon.image = artwork
            icon.pack(side="left", padx=(0, 12))
        title = ttk.Frame(header)
        title.pack(side="left")
        ttk.Label(title, text="NTRIP Scope", font=("TkDefaultFont", 15, "bold")).pack(anchor="w")
        ttk.Label(title, text=f"{self.tr('Version')} {DESKTOP_VERSION}").pack(anchor="w")
        for line in (AUTHOR,
                     self.tr("Software: MIT License"),
                     self.tr("Original published project materials: CC BY 4.0 unless indicated otherwise."),
                     PROJECT_URL):
            ttk.Label(frame, text=line, wraplength=410).pack(anchor="w", pady=3)
        ttk.Button(frame, text=self.tr("Open on GitHub"),
                   command=lambda: webbrowser.open(PROJECT_URL)).pack(anchor="w", pady=(10, 0))

    def options(self, win):
        from serial.tools.list_ports import comports

        frame = ttk.Frame(win,padding=14)
        frame.pack(fill="both",expand=True)
        frame.columnconfigure(1,weight=1)
        def row(index,label,widget):
            ttk.Label(frame,text=self.tr(label)).grid(row=index,column=0,sticky="w",padx=(0,8),pady=4)
            widget.grid(row=index,column=1,sticky="ew",pady=4)
        language = ttk.Combobox(frame,textvariable=self.lang,values=("English","Italiano"),state="readonly")
        row(0,"Language",language)
        def refresh_language(_):
            for key in list(self.windows):
                self.close_window(key)
            self.build()
            self.open("options","Options",self.options)
        language.bind("<<ComboboxSelected>>", refresh_language)
        row(1,"NTRIP version",ttk.Combobox(frame,textvariable=self.version,values=("1","2"),state="readonly"))
        ttk.Checkbutton(frame,text=self.tr("TLS connection"),variable=self.tls).grid(row=2,column=0,sticky="w",pady=3)
        ttk.Checkbutton(frame,text=self.tr("Save RTCM to file"),variable=self.record).grid(row=3,column=0,sticky="w",pady=3)
        ttk.Entry(frame,textvariable=self.output,width=35).grid(row=3,column=1,sticky="ew")
        def browse():
            name = filedialog.asksaveasfilename(parent=win,defaultextension=".rtcm")
            if name:
                self.output.set(name)
                self.record.set(True)
        ttk.Button(frame,text=self.tr("Browse…"),command=browse).grid(row=3,column=2,padx=4)
        ttk.Checkbutton(frame,text=self.tr("Forward over TCP"),variable=self.tcp).grid(row=4,column=0,sticky="w",pady=3)
        ttk.Entry(frame,textvariable=self.tcp_port).grid(row=4,column=1,sticky="ew")
        ttk.Label(frame,text="127.0.0.1").grid(row=4,column=2,padx=4)
        ttk.Checkbutton(frame,text=self.tr("Serial / Bluetooth SPP (RTCM out, GGA in)"),variable=self.serial).grid(row=5,column=0,sticky="w",pady=3)
        serial = ttk.Combobox(frame,textvariable=self.serial_port,values=[p.device for p in comports()])
        serial.grid(row=5,column=1,sticky="ew")
        ttk.Button(frame,text=self.tr("Refresh"),command=lambda:serial.configure(values=[p.device for p in comports()])).grid(row=5,column=2,padx=4)
        row(6,"Baud rate",ttk.Combobox(frame,textvariable=self.baud,values=(4800,9600,19200,38400,57600,115200,230400)))
        ttk.Label(frame, text=self.tr("Manual rover GGA has priority over received serial/Bluetooth GGA."),
                  wraplength=500).grid(row=7, column=0, columnspan=3, sticky="w", pady=(6, 0))
        ttk.Button(frame,text=self.tr("Load configuration…"),command=lambda:self.load_config(win)).grid(row=8,column=0,pady=(10,0),sticky="w")
        ttk.Button(frame,text=self.tr("Save configuration…"),command=lambda:self.save_config(win)).grid(row=8,column=1,pady=(10,0),sticky="w")
        ttk.Button(frame,text=self.tr("Done"),command=lambda:self.close_window("options")).grid(row=8,column=2,pady=(10,0))
        ttk.Label(frame,text=self.tr("Stop freezes displayed data and keeps the receiver link open."),wraplength=500).grid(row=9,column=0,columnspan=3,sticky="w",pady=(8,0))
        ttk.Button(frame,text=self.tr("Disconnect receiver"),command=self.receivers.disconnect,state="disabled" if self.worker else "normal").grid(row=10,column=0,sticky="w")

    def configured_outputs(self, file, tcp, serial, baud):
        extra = self.imported_outputs
        serial_entry = (serial, baud)
        files = extra.files if file and extra.files[:1] == (file,) else ((file,) if file else ())
        ports = extra.tcp_ports if tcp and extra.tcp_ports[:1] == (tcp,) else ((tcp,) if tcp else ())
        devices = extra.serial_ports if serial and extra.serial_ports[:1] == (serial_entry,) else ((serial_entry,) if serial else ())
        return Outputs(files, ports, devices)

    def save_config(self, win):
        ini = ConfigParser(interpolation=None)
        try:
            host = self.host.get().strip()
            port = int(self.port.get())
            if not host or not 1 <= port <= 65535 or any(c.isspace() or c in "/?#" for c in host):
                raise ValueError("Invalid caster or port")
            ini["caster"] = {
                "host": host, "port": str(port), "mountpoint": self.mount.get().strip(),
                "username": self.user.get(), "version": self.version.get(),
                "tls": str(self.tls.get()).lower(),
            }
            if self.send_rover.get():
                lat, lon = self.values
                height = number(self.height.get())
                geoid = number(self.geoid.get().strip() or "0")
                if lat is None or lon is None or not abs(height) < 100000 or not abs(geoid) < 100000:
                    raise ValueError("Invalid coordinates")
                ini["rover"] = dict(latitude=f"{lat:.6f}", longitude=f"{lon:.6f}",
                                    height=f"{height:.3f}", geoid=f"{geoid:.3f}")
            elif self.raw_gga.get().strip():
                raise ValueError("Enter rover coordinates to export GGA settings")
            file = self.output.get() if self.record.get() else ""
            tcp = int(self.tcp_port.get()) if self.tcp.get() else 0
            serial = self.serial_port.get() if self.serial.get() else ""
            baud = int(self.baud.get()) if serial else 115200
            if self.record.get() and not file:
                raise ValueError("Choose an output file")
            if self.tcp.get() and not 1 <= tcp <= 65535:
                raise ValueError("Invalid TCP output port")
            if self.serial.get() and (not serial or baud <= 0):
                raise ValueError("Select a serial port")
            outputs = self.configured_outputs(file, tcp, serial, baud)
            values = [*ini["caster"].values(), *outputs.files, *(device for device, _ in outputs.serial_ports)]
            if any("\n" in value or "\r" in value for value in values):
                raise ValueError("INI values must fit on one line")
            destinations = {
                "file": "\n".join(outputs.files),
                "tcp": "\n".join(map(str, outputs.tcp_ports)),
                "serial": "\n".join(f"{device}:{speed}" for device, speed in outputs.serial_ports),
            }
            if any(destinations.values()):
                ini["outputs"] = {key: value for key, value in destinations.items() if value}
            filename = filedialog.asksaveasfilename(parent=win, initialfile="ntripscope.ini",
                                                    defaultextension=".ini", filetypes=[("INI", "*.ini")])
            if filename:
                with Path(filename).open("w", encoding="utf-8") as stream:
                    ini.write(stream)
                message = "Configuration saved without password" if self.password.get() else "Configuration saved"
                self.status = message
                messagebox.showinfo("NTRIP Scope", self.tr(message), parent=win)
        except (OSError, ValueError) as error:
            messagebox.showerror("NTRIP Scope", self.tr(str(error)), parent=win)

    def load_config(self, win):
        if self.worker:
            return
        filename = filedialog.askopenfilename(parent=win, filetypes=[("INI", "*.ini"), ("All files", "*")])
        if not filename:
            return
        if self.import_config(filename, win):
            self.close_window("options")

    def import_config(self, filename, win):
        try:
            parsed = settings(Path(filename))
            # The desktop user chooses Connect or Fetch mountpoints explicitly.
            flags = ["--config", filename, "--no-list", "--stdout"]
            if not parsed.get("mountpoint"):
                flags += ["--mountpoint", "placeholder"]
            config, outputs, _, _, rover, _ = cli_arguments(flags)
        except (INIError, OSError, ValueError, SystemExit):
            messagebox.showerror("NTRIP Scope", self.tr("Invalid INI configuration"), parent=win)
            return False
        self.host.set(config.host); self.port.set(str(config.port))
        self.mount.set(parsed.get("mountpoint", "")); self.user.set(config.username)
        self.password.set(config.password); self.tls.set(config.tls); self.version.set(str(config.version))
        self.imported_outputs = outputs
        self.record.set(bool(outputs.files)); self.output.set(outputs.files[0] if outputs.files else "")
        self.tcp.set(bool(outputs.tcp_ports)); self.tcp_port.set(str(outputs.tcp_ports[0]) if outputs.tcp_ports else "5000")
        self.serial.set(bool(outputs.serial_ports))
        device, baud = outputs.serial_ports[0] if outputs.serial_ports else ("", 115200)
        self.serial_port.set(device); self.baud.set(str(baud))
        self.send_rover.set(rover is not None); self.raw_gga.set("")
        for axis, key in enumerate(("latitude", "longitude")):
            self.axes[axis][0].set(str(parsed[key]) if key in parsed else "")
            self.convert(axis, True, True)
        self.height.set(str(parsed.get("height", 0))); self.geoid.set(str(parsed.get("geoid", 0)))
        self.status = "Configuration loaded"
        if any(len(items) > 1 for items in (outputs.files, outputs.tcp_ports, outputs.serial_ports)):
            messagebox.showinfo("NTRIP Scope", self.tr("Additional INI destinations stay active when their first destination is unchanged."), parent=win)
        return True

    def rover(self, win):
        frame = ttk.Frame(win,padding=14)
        frame.pack(fill="both",expand=True)
        ttk.Checkbutton(frame,text=self.tr("Send manual rover GGA"),variable=self.send_rover).grid(row=0,column=0,columnspan=6,sticky="w")
        ttk.Label(frame,text=self.tr("When enabled, manual coordinates override GGA from Bluetooth, serial and TCP sources."),wraplength=580).grid(row=1,column=0,columnspan=6,sticky="w",pady=(2,5))
        for axis,(label,hemispheres) in enumerate((("Latitude",("N","S")),("Longitude",("E","W")))):
            row = axis + 3
            ttk.Label(frame,text=self.tr(label)).grid(row=row,column=0,sticky="w",padx=4)
            variables = self.axes[axis]
            for i,name in enumerate(("Decimal degrees","Degrees","Minutes","Seconds")):
                ttk.Label(frame,text=self.tr(name)).grid(row=2,column=i+1,padx=4)
                entry = ttk.Entry(frame,textvariable=variables[i],width=13 if i in (0,3) else 8)
                entry.grid(row=row,column=i+1,padx=4,pady=4)
                entry.bind("<KeyRelease>",lambda _,a=axis,j=i:self.convert(a,j==0))
                entry.bind("<FocusOut>",lambda _,a=axis,j=i:self.convert(a,j==0,True))
            box=ttk.Combobox(frame,textvariable=variables[4],values=hemispheres,width=3,state="readonly")
            box.grid(row=row,column=5,padx=4)
            box.bind("<<ComboboxSelected>>",lambda _,a=axis:self.convert(a,False))
        for row,label,var in ((5,"Ellipsoidal height (m)",self.height),(6,"Geoid separation (m)",self.geoid),
                              (7,"Manual GGA (optional)",self.raw_gga)):
            ttk.Label(frame,text=self.tr(label)).grid(row=row,column=0,sticky="w",padx=4)
            entry=ttk.Entry(frame,textvariable=var)
            entry.grid(row=row,column=1,columnspan=5,sticky="ew",padx=4,pady=4)
            if row < 7:
                entry.bind("<FocusOut>",lambda _,v=var:self.format_height(v))
        ttk.Label(frame,text=self.tr("Geoid separation is optional. If omitted, GGA uses 0.000 m.")).grid(row=8,columnspan=6,sticky="w")
        ttk.Button(frame,text=self.tr("Done"),command=lambda:self.close_window("rover")).grid(row=9,column=5,pady=(10,0))

    @staticmethod
    def format_height(variable):
        try:
            value = number(variable.get())
            if abs(value)<100_000:
                variable.set(f"{value:.3f}")
        except ValueError:
            pass

    def convert(self, axis, decimal, normalize=False):
        v = self.axes[axis]
        limit = (90,180)[axis]
        try:
            if decimal:
                angle = number(v[0].get())
                if not -limit <= angle <= limit:
                    raise ValueError
                v[4].set(("S","W")[axis] if angle < 0 else ("N","E")[axis])
            else:
                angle = from_dms(int(v[1].get()),int(v[2].get()),number(v[3].get()),v[4].get() in ("S","W"),limit)
            self.values[axis] = angle
            if decimal or normalize:
                d,m,s=dms(angle)
                v[1].set(str(d)); v[2].set(str(m)); v[3].set(f"{s:.4f}")
            if not decimal or normalize:
                v[0].set(f"{angle:.6f}")
        except ValueError:
            self.values[axis] = None
            for field in (v[1:4] if decimal else [v[0]]):
                field.set("")

    def map_window(self, win):
        win.geometry("750x570")
        win.minsize(470,330)
        self.map_view=MapSky(win,self.map_data,self.tr,street="--smoke-test" not in sys.argv,
                             context_key=lambda:(self.caster_key(),self.mount.get().strip().strip("/")),
                             rover_source=lambda:self.tr("Manual Rover position") if self.send_rover.get() else self.receiver_source)
        self.map_view.pack(fill="both",expand=True)

    def caster_key(self):
        return self.host.get().strip().lower(), self.port.get().strip(), self.tls.get()

    def map_data(self):
        mount=self.mount.get().strip().strip("/")
        key=self.caster_key()
        stream=(key,mount)
        same_stream=stream==self.stream_key
        position=self.decoder.antenna if same_stream else None
        position=position or self.station_cache.get(stream)
        if not position and key==self.source_key:
            position=self.mounts.get(mount)
        manual=None
        if None not in self.values:
            try: height=number(self.height.get()) if self.height.get().strip() else None
            except ValueError: height=None
            manual=(*self.values,height)
        rover=manual if self.send_rover.get() and manual else self.receiver_position or manual
        return mount, position, self.decoder if same_stream else Decoder(), rover


    def monitor(self, win):
        win.geometry("880x670")
        win.minsize(560,400)
        tabs=ttk.Notebook(win)
        tabs.pack(fill="both",expand=True,padx=8,pady=8)
        live=ttk.Frame(tabs); decoder=ttk.Frame(tabs)
        tabs.add(live,text=self.tr("HEX and ASCII"))
        tabs.add(decoder,text=self.tr("RTCM3 decoder"))
        panes=ttk.Panedwindow(live,orient="vertical");panes.pack(fill="both",expand=True)
        caster=ttk.LabelFrame(panes,text=self.tr("Caster → RTCM"));receiver=ttk.LabelFrame(panes,text=self.tr("Receiver → Client"))
        panes.add(caster,weight=1);panes.add(receiver,weight=2)
        raw=ScrolledText(caster,font="TkFixedFont",wrap="none",state="disabled",height=6);raw.pack(fill="both",expand=True)
        self.receiver_choice=ttk.Combobox(receiver,state="readonly");self.receiver_choice.pack(fill="x")
        self.receiver_raw=ScrolledText(receiver,font="TkFixedFont",wrap="none",state="disabled",height=10);self.receiver_raw.pack(fill="both",expand=True)
        self.receiver_choice.bind("<<ComboboxSelected>>",lambda _:self.refresh_monitor())
        decoder_panes=ttk.Panedwindow(decoder,orient="vertical")
        decoder_panes.pack(fill="both",expand=True)
        type_frame=ttk.Frame(decoder_panes)
        detail_frame=ttk.Frame(decoder_panes)
        decoder_panes.add(type_frame,weight=1)
        decoder_panes.add(detail_frame,weight=2)
        self.decoder_panes=decoder_panes
        types=ttk.Treeview(type_frame,columns=("type","count","signals"),show="headings",height=5)
        for key,name,width in (("type","Message type",115),("count","Count",75),("signals","Signals / details",540)):
            types.heading(key,text=self.tr(name)); types.column(key,width=width,stretch=key=="signals")
        type_scroll=ttk.Scrollbar(type_frame,orient="vertical",command=types.yview)
        type_scroll.pack(side="right",fill="y")
        types.configure(yscrollcommand=type_scroll.set)
        types.pack(fill="both",expand=True)
        self.types_scroll=type_scroll
        selection=ttk.Combobox(detail_frame,state="readonly")
        selection.pack(fill="x",pady=5)
        detail=ttk.Notebook(detail_frame)
        detail.pack(fill="both",expand=True)
        field_frame=ttk.Frame(detail)
        detail.add(field_frame,text=self.tr("Fields"))
        field_text=tk.Text(field_frame,font="TkFixedFont",wrap="none",state="disabled")
        scroll=ttk.Scrollbar(field_frame,command=field_text.yview)
        scroll.pack(side="right",fill="y"); field_text.configure(yscrollcommand=scroll.set)
        field_text.pack(fill="both",expand=True)
        measure_frame=ttk.Frame(detail)
        detail.add(measure_frame,text=self.tr("Measurements"))
        columns=("sat","signal","code","phase","cnr","rate")
        measurements=ttk.Treeview(measure_frame,columns=columns,show="headings")
        for key,label in zip(columns,("Satellite","Signal","Pseudorange (m)","Phase range (m)","C/N₀ (dB-Hz)","Range rate (m/s)")):
            measurements.heading(key,text=self.tr(label)); measurements.column(key,width=108)
        meas_scroll=ttk.Scrollbar(measure_frame,command=measurements.yview)
        meas_scroll.pack(side="right",fill="y"); measurements.configure(yscrollcommand=meas_scroll.set)
        measurements.pack(fill="both",expand=True)
        compact=ttk.Label(measure_frame); compact.pack(anchor="w")
        chart=tk.Canvas(detail,background=BG,highlightthickness=0)
        detail.add(chart,text=self.tr("C/N₀ chart"))
        self.monitor_widgets=(raw,types,selection,field_text,measurements,chart,compact)
        self.monitor_signature=None
        self.detail_signature=None
        self.decoder_signature=None
        self.monitor_pinned=None
        self.monitor_type=None
        self.frame_choices={}
        types.bind("<<TreeviewSelect>>",lambda _:self.refresh_monitor(reset=True))
        selection.bind("<<ComboboxSelected>>",lambda _:self.choose_monitor_frame())
        chart.bind("<Configure>",lambda _:cnr_chart(chart,self.chart_rows,self.tr))
        self.chart_rows=[]
        self.refresh_monitor()

    @staticmethod
    def combo_posted(combo):
        try:
            pop=combo.tk.call("ttk::combobox::PopdownWindow",str(combo))
            return bool(int(combo.tk.call("winfo","ismapped",pop)))
        except tk.TclError:
            return False

    def choose_monitor_frame(self):
        self.monitor_pinned=self.frame_choices.get(self.monitor_widgets[2].get())
        self.refresh_monitor()

    def refresh_monitor(self,reset=False):
        if not self.monitor_widgets:return
        raw,types,select,field_text,table,chart,compact=self.monitor_widgets
        source=self.receiver_choice.get()
        signature=(self.bytes,tuple((key,value[0]) for key,value in self.receiver_streams.items()),source)
        if signature!=self.monitor_signature:
            self.monitor_signature=signature
            replace_text(raw,f"{self.bytes:,} {self.tr('bytes received')}\n\n{hex_preview(self.recent)}")
            names=sorted(self.receiver_streams)
            if not self.combo_posted(self.receiver_choice):
                self.receiver_choice.configure(values=names)
                if source not in names:
                    source=names[0] if names else "";self.receiver_choice.set(source)
            count,data=self.receiver_streams.get(source,(0,b""))
            ascii_text="".join(chr(b) if 32<=b<127 or b in (10,13) else "." for b in data)
            text=f"{count:,} {self.tr('bytes received')}\nASCII\n{ascii_text}\n\nHEX + ASCII (latest 256 bytes)\n{hex_preview(data[-256:])}" if data else self.tr("Waiting for receiver data")
            replace_text(self.receiver_raw,text)
        decoder_signature=(id(self.decoder),tuple(self.decoder.counts.items()),self.decoder.bad_crc)
        if decoder_signature!=self.decoder_signature:
            self.decoder_signature=decoder_signature
            for item in types.get_children():
                if int(item) not in self.decoder.counts:types.delete(item)
            for kind in sorted(self.decoder.counts):
                values=(kind,self.decoder.counts[kind],", ".join(sorted(self.decoder.signals[kind])))
                if types.exists(str(kind)):types.item(str(kind),values=values)
                else:types.insert("","end",iid=str(kind),values=values)
        chosen=types.selection()
        selected_type=int(chosen[0]) if chosen else None
        if selected_type!=self.monitor_type:
            self.monitor_type=selected_type;self.monitor_pinned=None
            select.set(self.tr("Latest frame") if chosen else "")
        frames=list(reversed(self.decoder.frames.get(selected_type,()))) if chosen else []
        if self.monitor_pinned and all(row[0]!=self.monitor_pinned[0] for row in frames):frames.append(self.monitor_pinned)
        latest=self.tr("Latest frame")
        names=[latest]+[f"#{n} · {at:%H:%M:%S}" for n,at,_,_ in frames]
        if not self.combo_posted(select):
            self.frame_choices={name:row for name,row in zip(names[1:],frames)}
            if tuple(select.cget("values"))!=tuple(names if frames else ()):
                select.configure(values=names if frames else ())
            if not frames:select.set("")
            elif not self.monitor_pinned:select.set(latest)
        row=self.monitor_pinned or (frames[0] if frames else None)
        detail_signature=(int(chosen[0]),row[0],row[1]) if row else None
        if detail_signature==getattr(self,"detail_signature",None) and not reset:
            return
        self.detail_signature=detail_signature
        for child in table.get_children():
            table.delete(child)
        self.chart_rows=[]
        compact.configure(text="")
        if row:
            _,_,payload,message=row
            self.chart_rows=observations(message)
            replace_text(field_text,f"{self.tr('Frames with invalid CRC')}: {self.decoder.bad_crc}\n\n{fields(message)}\n\nHEX\n{hex_preview(payload)}")
            if self.chart_rows and int(chosen[0])%10<=3:
                compact.configure(text=self.tr("Compact MSM ranges are modulo 1 ms."))
            for sat,signal,*values in self.chart_rows:
                table.insert("","end",values=(sat,signal,*("—" if x is None else f"{x:.4f}" for x in values)))
        else:
            replace_text(field_text,"")
        cnr_chart(chart,self.chart_rows,self.tr)

    def start(self,list_only=False):
        if self.worker:
            return
        key=self.caster_key()
        try:
            host=self.host.get().strip()
            port=int(self.port.get())
            mount=self.mount.get().strip().strip("/")
            if not host or not 1<=port<=65535 or any(c.isspace() or c in "/?#" for c in host) or (not list_only and not mount):
                raise ValueError("Invalid caster or port")
            tcp=int(self.tcp_port.get()) if self.tcp.get() and not list_only else 0
            if self.tcp.get() and not list_only and not 1<=tcp<=65535:
                raise ValueError("Invalid TCP output port")
            file=self.output.get() if self.record.get() and not list_only else ""
            if self.record.get() and not list_only and not file:
                raise ValueError("Choose an output file")
            serial=self.serial_port.get() if self.serial.get() and not list_only else ""
            if self.serial.get() and not list_only and not serial:
                raise ValueError("Select a serial port")
            config=Connection(host,port,mount,self.user.get(),self.password.get(),self.tls.get(),
                              int(self.version.get()),file,tcp,serial,int(self.baud.get()) if serial else 115200)
            outputs = self.configured_outputs(file, tcp, serial, config.baud)
            files = outputs.files
            if any(Path(path).exists() for path in files) and not messagebox.askyesno(
                    "NTRIP Scope", self.tr("Overwrite existing output files?"), parent=self.root):
                return
            sentence=None
            if not list_only and self.send_rover.get():
                lat,lon=self.values
                height=number(self.height.get())
                geoid=number(self.geoid.get()) if self.geoid.get().strip() else 0
                if lat is None or lon is None or not abs(height)<100_000 or not abs(geoid)<100_000:
                    raise ValueError("Invalid coordinates")
                sentence=lambda:gga(lat,lon,round(height,3),round(geoid,3))
            elif not list_only and self.raw_gga.get().strip():
                raw=self.raw_gga.get().strip()
                if not raw.startswith("$") or raw[3:6]!="GGA" or not raw.isascii() or any(c in raw for c in "\r\n"):
                    raise ValueError("Enter a single NMEA GGA sentence")
                sentence=lambda:raw
        except ValueError as error:
            messagebox.showerror("NTRIP Scope",self.tr(str(error)),parent=self.root)
            return
        if not list_only:
            if self.stream_key!=(key,mount):self.receiver_position=None
            self.receiver_parsers={}
            self.receiver_fix.reset()
            self.monitor_pinned=None
            self.decoder=Decoder()
            self.stream_key=(key,mount)
            self.bytes=0; self.last=0; self.started=0; self.recent=b""
            self.receiver_streams = {}
        self.outputs=[]
        self.receiver_error=""
        self.stopped.clear()
        self.status="Connecting…"
        def emit(kind,value):
            while not self.stopped.is_set():
                try:
                    self.events.put((kind,value),timeout=.2)
                    return
                except queue.Full:
                    continue
        def worker():
            try:
                run(config,self.stopped,emit,list_only=list_only,gga=sentence,outputs=outputs,receivers=self.receivers)
            except Cancelled:
                pass
            except Exception as error:
                emit("receiver_error" if "Receiver" in str(error) else "status",str(error))
            finally:
                self.events.put(("finished",key))
        self.worker=threading.Thread(target=worker,daemon=True)
        self.worker.start()
        self.update_status()

    def toggle(self):
        if self.worker:
            self.status="Stop requested…"
            self.stopped.set()
            self.receivers.pause()
        else:
            self.start()

    def update_status(self):
        state="disabled" if self.worker else "normal"
        for widget in (*self.connection_fields,self.fetch,self.rover_button):
            if str(widget.cget("state")) != state:
                widget.configure(state=state)
        self.action.configure(text=self.tr("Stop" if self.worker else "Connect"))
        status=self.tr(self.status)
        if self.outputs:
            status+=" · "+" · ".join(self.outputs)
        if self.receiver_error:status+=" · "+self.receiver_error
        self.status_label.configure(text=status)
        now=time.monotonic()
        fix_text,fix_color=self.receiver_fix.display(now,bool(self.worker) and not self.stopped.is_set())
        text=self.tr("Receiver fix")+": "+(self.tr(fix_text) if self.receiver_fix.quality is None else fix_text)
        note=self.tr("Manual GGA is sent to the caster; receiver fix is shown separately.") if self.send_rover.get() else ""
        changed=self.fix_label.cget("text")!=text or self.fix_note.cget("text")!=note
        self.fix_label.configure(text=text,foreground=fix_color)
        self.fix_note.configure(text=note)
        if changed:
            self.root.update_idletasks()
            self.root.minsize(608,max(300,self.main.winfo_reqheight()))
        lit=int((now-self.started)/.12)%13 if self.worker and now-self.last<2.5 else 0
        for index,seg in enumerate(self.segments):
            self.bar.itemconfigure(seg,fill="#24a65a" if index<lit else "#cbd5db")
        self.count.configure(text=f"{self.bytes:,} {self.tr('bytes received')}")

    def poll(self):
        until=time.monotonic()+.035
        while time.monotonic()<until:
            try:
                kind,value=self.events.get_nowait()
            except queue.Empty:
                break
            if kind in ("data","receiver") and (self.stopped.is_set() or not self.worker):continue
            if kind=="data":
                now=time.monotonic()
                if now-self.last>=2.5:
                    self.started=now
                self.last=now
                self.bytes+=len(value)
                self.recent=(self.recent+value)[-256:]
                self.decoder.feed(value)
                if self.decoder.antenna is not None:
                    self.station_cache[self.stream_key]=self.decoder.antenna
                    if len(self.station_cache)>100:self.station_cache={self.stream_key:self.decoder.antenna}
                self.status="Receiving data"
            elif kind=="receiver":
                source, data = value
                self.receiver_fix.feed(source,data,time.monotonic())
                count, recent = self.receiver_streams.get(source, (0, b""))
                self.receiver_streams[source] = (count + len(data), (recent + data)[-8192:])
                for sentence in self.receiver_parsers.setdefault(source,GGAReader()).feed(data):
                    position=position_from_gga(sentence)
                    if position is not None:self.receiver_position=position;self.receiver_source=source
            elif kind=="receiver_error":
                self.receiver_error=value;self.status=value
            elif kind=="mounts":
                self.mounts=value
                self.source_key=self.caster_key()
                self.mount_menu.configure(values=sorted(value))
                self.status=f"{len(value)} {self.tr('mountpoints available')}"
            elif kind=="finished":
                self.worker=None
                if self.stopped.is_set():
                    self.status="Disconnected"
            elif kind=="output":
                self.outputs.append(value)
            else:
                self.status=value
        self.update_status()
        self.refresh_monitor()
        if self.map_view:
            self.map_view.refresh()
        self.root.after(100,self.poll)


def main():
    root=tk.Tk()
    client=Client(root)
    failures = []
    if "--smoke-test" in sys.argv:
        def failed(kind, value, traceback):
            failures.append(value)
            root.destroy()
        root.report_callback_exception = failed
        client.mount.set("SMOKE")
        client.source_key = client.caster_key()
        client.mounts = {"SMOKE": (46.1, 13.2)}
        client.open("rover","Rover position",client.rover)
        client.open("live","Live stream",client.monitor)
        client.open("options","Options",client.options)
        client.open_about()
        client.open("map","Map & sky",client.map_window)
        if len(sys.argv) == 3:
            original_dialog = filedialog.askopenfilename
            original_info = messagebox.showinfo
            try:
                filedialog.askopenfilename = lambda **kwargs: sys.argv[2]
                messagebox.showinfo = lambda *args, **kwargs: None
                client.load_config(client.windows["options"])
            finally:
                filedialog.askopenfilename = original_dialog
                messagebox.showinfo = original_info
            assert "options" not in client.windows
            assert client.host.get() == "caster.example.org" and client.mount.get() == "VRS"
            assert client.send_rover.get() and tuple(client.values) == (46.125, 13.333333)
            assert client.height.get() == "100.0" and client.tcp_port.get() == "5000"
            assert client.imported_outputs.files == ("corrections.rtcm", "second-copy.rtcm")
        root.after(400,root.destroy)
    root.mainloop()
    if failures:
        raise failures[0]


if __name__=="__main__":
    main()
