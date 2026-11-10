"""NTRIP Scope portable desktop client."""
from configparser import Error as INIError
import json
import os
import queue
import sys
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from charts import ASSETS, BG, MapSky, cnr_chart
from gnss import Decoder, dms, fields, from_dms, gga, observations
from transport import Cancelled, Connection, Outputs, run
from ntripscope import arguments as cli_arguments, settings

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
        self.serial = tk.BooleanVar()
        self.serial_port = tk.StringVar()
        self.baud = tk.StringVar(value="115200")
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
        self.last = self.started = 0
        self.windows = {}
        self.map_view = None
        self.monitor_widgets = None
        self.outputs = []
        root.title("NTRIP Scope · RTCM Decoder")
        root.minsize(620, 285)
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
        top = ttk.Frame(self.main)
        top.pack(fill="x", pady=(0, 12))
        ttk.Label(top, text="NTRIP Scope", font=("TkDefaultFont", 19, "bold")).pack(side="left")
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
        self.rover_button = ttk.Button(form,text=self.tr("Rover position"),
            command=lambda:self.open("rover","Rover position",self.rover))
        self.rover_button.grid(row=2,column=2,columnspan=2,sticky="ew",padx=(8,0))
        ttk.Separator(self.main).pack(fill="x",pady=12)
        footer = ttk.Frame(self.main)
        footer.pack(fill="x")
        self.action = ttk.Button(footer,command=self.toggle)
        self.action.pack(side="right")
        self.status_label = ttk.Label(footer)
        self.status_label.pack(anchor="w")
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
        try:
            SETTINGS.parent.mkdir(parents=True, exist_ok=True)
            SETTINGS.write_text(json.dumps({
                "language":self.lang.get(), "host":self.host.get(), "port":self.port.get(),
                "mount":self.mount.get(), "user":self.user.get(), "tls":self.tls.get(),
                "version":self.version.get(),
            }), encoding="utf-8")
        except OSError:
            pass
        self.root.destroy()

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
        ttk.Checkbutton(frame,text=self.tr("Forward over serial"),variable=self.serial).grid(row=5,column=0,sticky="w",pady=3)
        serial = ttk.Combobox(frame,textvariable=self.serial_port,values=[p.device for p in comports()])
        serial.grid(row=5,column=1,sticky="ew")
        ttk.Button(frame,text=self.tr("Refresh"),command=lambda:serial.configure(values=[p.device for p in comports()])).grid(row=5,column=2,padx=4)
        row(6,"Baud rate",ttk.Combobox(frame,textvariable=self.baud,values=(4800,9600,19200,38400,57600,115200,230400)))
        ttk.Button(frame,text=self.tr("Load configuration…"),command=lambda:self.load_config(win)).grid(row=7,column=0,pady=(10,0),sticky="w")
        ttk.Button(frame,text=self.tr("Done"),command=lambda:self.close_window("options")).grid(row=7,column=2,pady=(10,0))

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
        ttk.Checkbutton(frame,text=self.tr("Send GGA"),variable=self.send_rover).grid(row=0,column=0,columnspan=6,sticky="w")
        for axis,(label,hemispheres) in enumerate((("Latitude",("N","S")),("Longitude",("E","W")))):
            row = axis + 2
            ttk.Label(frame,text=self.tr(label)).grid(row=row,column=0,sticky="w",padx=4)
            variables = self.axes[axis]
            for i,name in enumerate(("Decimal degrees","Degrees","Minutes","Seconds")):
                ttk.Label(frame,text=self.tr(name)).grid(row=1,column=i+1,padx=4)
                entry = ttk.Entry(frame,textvariable=variables[i],width=13 if i in (0,3) else 8)
                entry.grid(row=row,column=i+1,padx=4,pady=4)
                entry.bind("<KeyRelease>",lambda _,a=axis,j=i:self.convert(a,j==0))
                entry.bind("<FocusOut>",lambda _,a=axis,j=i:self.convert(a,j==0,True))
            box=ttk.Combobox(frame,textvariable=variables[4],values=hemispheres,width=3,state="readonly")
            box.grid(row=row,column=5,padx=4)
            box.bind("<<ComboboxSelected>>",lambda _,a=axis:self.convert(a,False))
        for row,label,var in ((4,"Ellipsoidal height (m)",self.height),(5,"Geoid separation (m)",self.geoid),
                              (6,"Manual GGA (optional)",self.raw_gga)):
            ttk.Label(frame,text=self.tr(label)).grid(row=row,column=0,sticky="w",padx=4)
            entry=ttk.Entry(frame,textvariable=var)
            entry.grid(row=row,column=1,columnspan=5,sticky="ew",padx=4,pady=4)
            if row < 6:
                entry.bind("<FocusOut>",lambda _,v=var:self.format_height(v))
        ttk.Label(frame,text=self.tr("Geoid separation is optional. If omitted, GGA uses 0.000 m.")).grid(row=7,columnspan=6,sticky="w")
        ttk.Button(frame,text=self.tr("Done"),command=lambda:self.close_window("rover")).grid(row=8,column=5,pady=(10,0))

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
        self.map_view=MapSky(win,self.map_data,self.tr,street="--smoke-test" not in sys.argv)
        self.map_view.pack(fill="both",expand=True)

    def caster_key(self):
        return self.host.get().strip().lower(), self.port.get().strip(), self.tls.get()

    def map_data(self):
        mount=self.mount.get().strip().strip("/")
        key=self.caster_key()
        same_stream=(key,mount)==self.stream_key
        position=self.decoder.antenna if same_stream else None
        if not position and key==self.source_key:
            position=self.mounts.get(mount)
        return mount, position, self.decoder if same_stream else Decoder(), (tuple(self.values) if None not in self.values else None)

    def monitor(self, win):
        win.geometry("880x670")
        win.minsize(560,400)
        tabs=ttk.Notebook(win)
        tabs.pack(fill="both",expand=True,padx=8,pady=8)
        live=ttk.Frame(tabs); decoder=ttk.Frame(tabs)
        tabs.add(live,text=self.tr("HEX and ASCII"))
        tabs.add(decoder,text=self.tr("RTCM3 decoder"))
        raw=tk.Text(live,font="TkFixedFont",wrap="none",state="disabled")
        raw.pack(fill="both",expand=True)
        types=ttk.Treeview(decoder,columns=("type","count","signals"),show="headings",height=5)
        for key,name,width in (("type","Message type",115),("count","Count",75),("signals","Signals / details",540)):
            types.heading(key,text=self.tr(name)); types.column(key,width=width,stretch=key=="signals")
        types.pack(fill="x")
        selection=ttk.Combobox(decoder,state="readonly")
        selection.pack(fill="x",pady=5)
        detail=ttk.Notebook(decoder)
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
        types.bind("<<TreeviewSelect>>",lambda _:self.refresh_monitor(reset=True))
        selection.bind("<<ComboboxSelected>>",lambda _:self.refresh_monitor())
        chart.bind("<Configure>",lambda _:cnr_chart(chart,self.chart_rows,self.tr))
        self.chart_rows=[]
        self.refresh_monitor()

    def refresh_monitor(self,reset=False):
        if not self.monitor_widgets:
            return
        raw,types,select,field_text,table,chart,compact=self.monitor_widgets
        signature=self.bytes,self.decoder.bad_crc
        if signature!=self.monitor_signature:
            self.monitor_signature=signature
            replace_text(raw,f"{self.bytes:,} {self.tr('bytes received')}\n\n{hex_preview(self.recent)}")
            for item in types.get_children():
                if int(item) not in self.decoder.counts:
                    types.delete(item)
            for kind in sorted(self.decoder.counts):
                values=(kind,self.decoder.counts[kind],", ".join(sorted(self.decoder.signals[kind])))
                if types.exists(str(kind)): types.item(str(kind),values=values)
                else: types.insert("","end",iid=str(kind),values=values)
        chosen=types.selection()
        frames=list(reversed(self.decoder.frames.get(int(chosen[0]),()))) if chosen else []
        current=select.get()
        latest=self.tr("Latest frame")
        names=[latest]+[f"#{n} · {at:%H:%M:%S}" for n,at,_,_ in frames]
        select.configure(values=names if frames else ())
        select.set(current if current in names and not reset and frames else latest if frames else "")
        row=frames[names.index(select.get())-1] if frames and select.get()!=latest else frames[0] if frames else None
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
            extra = self.imported_outputs
            serial_entry = (serial, config.baud)
            files = extra.files if file and extra.files[:1] == (file,) else ((file,) if file else ())
            tcp_ports = extra.tcp_ports if tcp and extra.tcp_ports[:1] == (tcp,) else ((tcp,) if tcp else ())
            serial_ports = extra.serial_ports if serial and extra.serial_ports[:1] == (serial_entry,) else ((serial_entry,) if serial else ())
            outputs = Outputs(files, tcp_ports, serial_ports)
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
            self.decoder=Decoder()
            self.stream_key=(key,mount)
            self.bytes=0; self.last=0; self.started=0; self.recent=b""
        self.outputs=[]
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
                run(config,self.stopped,emit,list_only=list_only,gga=sentence,outputs=outputs)
            except Cancelled:
                pass
            except Exception as error:
                emit("status",str(error))
            finally:
                self.events.put(("finished",key))
        self.worker=threading.Thread(target=worker,daemon=True)
        self.worker.start()
        self.update_status()

    def toggle(self):
        if self.worker:
            self.status="Stop requested…"
            self.stopped.set()
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
        self.status_label.configure(text=status)
        now=time.monotonic()
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
            if kind=="data":
                now=time.monotonic()
                if now-self.last>=2.5:
                    self.started=now
                self.last=now
                self.bytes+=len(value)
                self.recent=(self.recent+value)[-256:]
                self.decoder.feed(value)
                self.status="Receiving data"
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
