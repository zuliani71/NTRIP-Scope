"""Canvas views for the offline map and GNSS plots."""
import json
import math
import webbrowser
from pathlib import Path
from tkinter import Canvas, PhotoImage, TclError, ttk
from concurrent.futures import ThreadPoolExecutor
from time import monotonic

from tiles import load_tile, project, unproject

from gnss import dms, orbit_position, sky_point

ASSETS = Path(__file__).resolve().parent / "assets"
COLORS = ("#38bdf8", "#fb923c", "#4ade80", "#f472b6", "#a78bfa", "#facc15")
BG = "#10243a"
FG = "#e5eef7"


def horizontal_distance(a,b):
    lat1,lat2 = math.radians(a[0]),math.radians(b[0])
    dl = math.radians((b[1]-a[1]+180)%360-180)
    h = math.sin((lat2-lat1)/2)**2 + math.cos(lat1)*math.cos(lat2)*math.sin(dl/2)**2
    return 2*6371.0088*math.asin(math.sqrt(max(0,min(1,h))))


def cnr_chart(canvas, rows, tr):
    canvas.delete("all")
    w, h = canvas.winfo_width(), canvas.winfo_height()
    valid = [row for row in rows if row[4] is not None]
    if not valid:
        canvas.create_text(w / 2, h / 2, text=tr("No C/N₀ values"), fill=FG)
        return
    satellites = list(dict.fromkeys(row[0] for row in valid))
    signals = sorted({row[1] for row in valid})
    left, top, bottom = 42, 25, h - 45
    width = max(1, w - left - 20)
    for level in range(0, 61, 10):
        y = bottom - level * (bottom - top) / 65
        canvas.create_line(left, y, w - 12, y, fill="#31495e")
        canvas.create_text(left - 6, y, text=str(level), fill=FG, anchor="e")
    for index, sat in enumerate(satellites):
        x = left + (index + 0.5) * width / len(satellites)
        if index % max(1, math.ceil(len(satellites) * 23 / width)) == 0:
            canvas.create_text(x, bottom + 12, text=sat, fill=FG)
    for sat, signal, _, _, cnr, _ in valid:
        x = left + (satellites.index(sat) + 0.5) * width / len(satellites)
        x += (signals.index(signal) - (len(signals) - 1) / 2) * min(5, width / len(satellites) / len(signals))
        y = bottom - cnr * (bottom - top) / 65
        canvas.create_oval(x-3, y-3, x+3, y+3, fill=COLORS[signals.index(signal)%len(COLORS)], outline="")
    canvas.create_text(left, 10, text="C/N₀ (dB-Hz)", fill=FG, anchor="w")
    for index, signal in enumerate(signals):
        canvas.create_text(left + (index + .5) * width / len(signals), h-10,
                           text=signal, fill=COLORS[index%len(COLORS)])


class MapSky(ttk.Frame):
    def __init__(self, parent, provider, tr, *, street=True):
        super().__init__(parent, padding=10)
        self.provider, self.tr = provider, tr
        self.station = self.center = self.rover = None
        self.map_key = None
        self.scale = 8.0
        self.street = street
        self.street_zoom = 12
        self.tiles = {}
        self.pending = {}
        self.failed = {}
        self.pool = ThreadPoolExecutor(max_workers=3)
        self.tile_poll = None
        self.bind("<Destroy>", self.close_tiles, add="+")
        self.drag = None
        self.land = json.loads((ASSETS / "land.json").read_text(encoding="utf-8"))
        self.tabs = ttk.Notebook(self)
        self.tabs.pack(fill="both", expand=True)
        self.map = ttk.Frame(self.tabs)
        self.sky = ttk.Frame(self.tabs)
        self.tabs.add(self.map, text=tr("Map"))
        self.tabs.add(self.sky, text=tr("GPS sky"))
        controls = ttk.Frame(self.map)
        controls.pack(fill="x")
        ttk.Button(controls, text=tr("Street map"), command=lambda: self.change_map(True)).pack(side="left", padx=(0,3))
        ttk.Button(controls, text=tr("Offline map"), command=lambda: self.change_map(False)).pack(side="left", padx=(0,8))
        ttk.Button(controls, text="+", width=4, command=lambda: self.zoom(2)).pack(side="left")
        ttk.Button(controls, text="−", width=4, command=lambda: self.zoom(.5)).pack(side="left")
        ttk.Button(controls, text=tr("Open detailed map"), command=self.open_browser).pack(side="right")
        self.canvas = Canvas(self.map, background=BG, highlightthickness=0)
        self.canvas.pack(fill="both", expand=True)
        self.coordinates = ttk.Label(self.map, justify="left")
        self.coordinates.pack(fill="x", pady=(7, 0))
        self.sky_canvas = Canvas(self.sky, background=BG, highlightthickness=0)
        self.sky_canvas.pack(fill="both", expand=True)
        ttk.Label(self.sky, text=tr("GPS tracks · ±30 min around the latest GPS MSM epoch")).pack(pady=4)
        self.canvas.bind("<Configure>", lambda _: self.draw_map())
        self.sky_canvas.bind("<Configure>", lambda _: self.draw_sky())
        self.canvas.bind("<ButtonPress-1>", lambda e: setattr(self, "drag", (e.x, e.y)))
        self.canvas.bind("<B1-Motion>", self.pan)
        self.canvas.bind("<MouseWheel>", lambda e: self.zoom(2 if e.delta > 0 else .5))
        self.canvas.bind("<Button-4>", lambda _: self.zoom(2))
        self.canvas.bind("<Button-5>", lambda _: self.zoom(.5))
        self.tabs.bind("<<NotebookTabChanged>>", lambda _: self.refresh())
        self.refresh()

    def refresh(self):
        name, position, decoder, rover = self.provider()
        self.station = position
        key = name, position[:2] if position else None
        if key != self.map_key or rover != self.rover:
            self.map_key, self.rover = key, rover
            self.center = position[:2] if position else None
            if position and rover:
                self.fit_baseline(position[:2], rover)
            self.draw_map()
        if position:
            lat, lon = position[:2]
            def sexagesimal(angle, positive, negative):
                d, m, s = dms(angle)
                return f"{d}° {m:02d}′ {s:07.4f}″ {negative if angle < 0 else positive}"
            height = f"{position[2]:.3f} m" if len(position) == 3 else self.tr("Unavailable")
            self.coordinates.configure(text=(
                f"{self.tr('Latitude')} {lat:.6f}°  ·  {sexagesimal(lat, 'N', 'S')}\n"
                f"{self.tr('Longitude')} {lon:.6f}°  ·  {sexagesimal(lon, 'E', self.tr('W'))}\n"
                f"{self.tr('Ellipsoidal height')}  {height}"))
        else:
            self.coordinates.configure(text="")
        if self.tabs.select() == str(self.sky):
            self.draw_sky(decoder)

    def fit_baseline(self, station, rover):
        lat, lon = station
        delta = (rover[1]-lon+180)%360-180
        w = max(360, self.canvas.winfo_width()) * .68
        h = max(260, self.canvas.winfo_height()) * .68
        dx = abs(delta)
        dy = abs(rover[0]-lat)
        self.center = (lat+rover[0])/2, (lon+delta/2+180)%360-180
        self.scale = min(32768, w/max(.001,dx), h/max(.001,dy))
        sx, sy = project(lat,lon,0)
        rx, ry = project(rover[0],lon+delta,0)
        ratio = min(w/max(.001,abs(rx-sx)), h/max(.001,abs(ry-sy)))
        self.street_zoom = max(2,min(18,math.floor(math.log2(ratio))))
        if self.street:
            self.center = unproject((sx+rx)/2,(sy+ry)/2,0)

    def close_tiles(self, event):
        if event.widget is self:
            if self.tile_poll is not None:
                self.after_cancel(self.tile_poll)
            self.pool.shutdown(wait=False, cancel_futures=True)

    def change_map(self, street):
        self.street = street
        self.draw_map()

    def zoom(self, factor):
        if self.street:
            self.street_zoom = max(2, min(18, self.street_zoom + (1 if factor > 1 else -1)))
        self.scale = max(2, min(32_768, self.scale * factor))
        self.draw_map()

    def pan(self, event):
        if not self.center or not self.drag:
            return
        lat, lon = self.center
        dx, dy = event.x - self.drag[0], event.y - self.drag[1]
        if self.street:
            x, y = project(lat, lon, self.street_zoom)
            self.center = unproject(x-dx, y-dy, self.street_zoom)
        else:
            self.center = max(-90, min(90, lat + dy/self.scale)), (lon-dx/self.scale+180)%360-180
        self.drag = event.x, event.y
        self.draw_map()

    def open_browser(self):
        if self.station:
            lat, lon = self.station[:2]
            webbrowser.open(f"https://www.openstreetmap.org/?mlat={lat:.6f}&mlon={lon:.6f}#map=14/{lat:.6f}/{lon:.6f}")

    def draw_map(self):
        c = self.canvas
        c.delete("all")
        w, h = c.winfo_width(), c.winfo_height()
        if not self.center:
            c.create_text(w/2, h/2, text=self.tr("Select a mountpoint or receive RTCM 1005/1006"), fill=FG)
            return
        if self.street:
            self.draw_street(w, h)
            return
        lat, lon = self.center
        scale = self.scale
        def pixel(x, y):
            return w/2+(x-lon)*scale, h/2-(y-lat)*scale
        for ring in self.land:
            left, right = min(p[0] for p in ring), max(p[0] for p in ring)
            low, high = min(p[1] for p in ring), max(p[1] for p in ring)
            if high < lat-h/(2*scale) or low > lat+h/(2*scale):
                continue
            for shift in (0, -360, 360):
                if right+shift < lon-w/(2*scale) or left+shift > lon+w/(2*scale):
                    continue
                c.create_polygon([coordinate for x, y in ring for coordinate in pixel(x+shift,y)],
                                 fill="#345563", outline="#54808a")
        slat, slon = self.station[:2]
        x, y = pixel(lon + (slon-lon+180)%360-180, slat)
        if self.rover:
            rlat, rlon = self.rover
            rx, ry = pixel(lon+(rlon-lon+180)%360-180, rlat)
            self.draw_baseline(x,y,rx,ry)
        self.map_overlay(w, h, x, y, 111.32 * max(.001, math.cos(math.radians(lat))) / scale,
                         "Natural Earth · 1:110m", False)

    def draw_street(self, w, h):
        z = self.street_zoom
        world = 2**z
        lat, lon = self.center
        x, y = project(lat, lon, z)
        left, top = x-w/2, y-h/2
        visible = [(tx, ty) for tx in range(math.floor(left/256), math.floor((left+w)/256)+1)
                   for ty in range(max(0, math.floor(top/256)), min(world, math.floor((top+h)/256)+1))]
        keys = {(z, tx%world, ty) for tx, ty in visible}
        for key in list(self.tiles):
            if key not in keys:
                del self.tiles[key]
        for key, future in list(self.pending.items()):
            if future.done():
                del self.pending[key]
                try:
                    data = future.result()
                    if key in keys and data:
                        self.tiles[key] = PhotoImage(data=data)
                    elif not data:
                        self.failed[key] = monotonic()+15
                except (OSError, ValueError, TclError):
                    self.failed[key] = monotonic()+15
            elif key not in keys and future.cancel():
                del self.pending[key]
        for tx, ty in visible:
            key = z, tx%world, ty
            if key in self.tiles:
                self.canvas.create_image(tx*256-left, ty*256-top, anchor="nw", image=self.tiles[key])
            elif key not in self.pending and len(self.pending)<12 and self.failed.get(key,0)<monotonic():
                self.pending[key] = self.pool.submit(load_tile, key)
        sx, sy = project(*self.station[:2], z)
        sx = x + (sx-x+128*world)%(256*world)-128*world
        if self.rover:
            rx, ry = project(*self.rover,z)
            rx = x + (rx-x+128*world)%(256*world)-128*world
            self.draw_baseline(sx-left,sy-top,rx-left,ry-top)
        self.map_overlay(w,h,sx-left,sy-top,40075.017*math.cos(math.radians(lat))/(256*world),
                         "© OpenStreetMap contributors", True)
        if not self.tiles and not self.pending:
            self.canvas.create_text(w/2,h/2,text=self.tr("Street map unavailable. Switch to Offline map."),fill=FG)
        if self.pending and self.tile_poll is None:
            def poll():
                self.tile_poll = None
                if self.street:
                    self.draw_map()
            self.tile_poll = self.after(100,poll)

    def draw_baseline(self, x, y, rx, ry):
        c = self.canvas
        c.create_line(x,y,rx,ry,fill="white",width=5)
        c.create_line(x,y,rx,ry,fill="#1676ca",width=3)
        c.create_oval(rx-7,ry-7,rx+7,ry+7,fill="#1676ca",outline="white",width=2)
        for px,py,text in ((rx+10,ry,"Rover"),((x+rx)/2,(y+ry)/2-12,
                            f"{horizontal_distance(self.station,self.rover):.3f} km")):
            label = c.create_text(px,py,text=text,fill=FG,anchor="w" if text=="Rover" else "center",
                                  font=("TkDefaultFont",10,"bold"))
            bounds = c.bbox(label)
            if bounds:
                bg = c.create_rectangle(bounds[0]-3,bounds[1]-2,bounds[2]+3,bounds[3]+2,fill=BG,outline="")
                c.tag_lower(bg,label)

    def map_overlay(self,w,h,x,y,km_per_pixel,credit,street):
        c = self.canvas
        c.create_oval(x-7,y-7,x+7,y+7,fill="#e45348",outline="white",width=2)
        label = c.create_text(x+11,y,text=self.map_key[0],fill=FG,anchor="w",font=("TkDefaultFont",10,"bold"))
        bounds = c.bbox(label)
        if bounds:
            bg = c.create_rectangle(bounds[0]-3,bounds[1]-2,bounds[2]+3,bounds[3]+2,fill=BG,outline="")
            c.tag_lower(bg,label)
        max_km = min(140, max(w,1)/3)*km_per_pixel
        base = 10**math.floor(math.log10(max_km))
        km = base * (5 if max_km/base >= 5 else 2 if max_km/base >= 2 else 1)
        x2, y2 = w-15, h-28
        x1 = x2-km/km_per_pixel
        c.create_rectangle(x1-6,y2-24,x2+6,y2+5,fill=BG,outline="")
        c.create_line(x1,y2,x2,y2,fill=FG,width=2)
        for xx in (x1,(x1+x2)/2,x2):
            c.create_line(xx,y2,xx,y2-5,fill=FG)
        c.create_text(x2,y2-8,text=f"{km:g} km",fill=FG,anchor="se")
        item = c.create_text(7,h-6,text=credit,fill=FG,anchor="sw")
        box = c.bbox(item)
        if box:
            bg = c.create_rectangle(*box,fill=BG,outline="")
            c.tag_lower(bg,item)
        if street:
            c.tag_bind(item,"<Button-1>",lambda _:webbrowser.open("https://www.openstreetmap.org/copyright"))

    def draw_sky(self, decoder=None):
        decoder = decoder or self.provider()[2]
        c = self.sky_canvas
        c.delete("all")
        w, h = c.winfo_width(), c.winfo_height()
        if not self.station or not decoder.epoch or not decoder.orbits:
            c.create_text(w/2,h/2,text=self.tr("GPS sky needs station coordinates, RTCM 1019 and GPS MSM"),fill=FG)
            return
        r = max(5,min(w,h)/2-30)
        cx, cy = w/2,h/2
        for factor in (1,2/3,1/3):
            rr = r*factor
            c.create_oval(cx-rr,cy-rr,cx+rr,cy+rr,outline="#536c83")
        for label, dx, dy in (("N",0,-1),("E",1,0),("S",0,1),(self.tr("W"),-1,0)):
            c.create_text(cx+dx*(r+12),cy+dy*(r+12),text=label,fill=FG)
        tow, week = decoder.epoch
        for prn, eph in sorted(decoder.orbits.items()):
            previous = None
            color = COLORS[prn%len(COLORS)]
            for offset in range(-1800,1801,120):
                xyz = orbit_position(eph,tow+offset,week)
                point = sky_point(self.station, xyz) if xyz else None
                if not point:
                    previous = None
                    continue
                az, el = point
                distance = r*(1-el/(math.pi/2))
                x,y = cx+distance*math.sin(az),cy-distance*math.cos(az)
                if previous:
                    c.create_line(*previous,x,y,fill=color,width=2)
                if offset == 0:
                    c.create_oval(x-3,y-3,x+3,y+3,fill=color,outline="")
                    c.create_text(x+7,y,text=f"G{prn:02d}",fill=FG,anchor="w")
                previous = x,y
