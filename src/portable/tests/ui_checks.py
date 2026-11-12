"""Native Tk regression checks; run on Windows or under xvfb-run on Linux."""
import math
import sys
import tempfile
from pathlib import Path
import tkinter as tk
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
sys.path.insert(0,str(Path(__file__).resolve().parent))
sys.argv.append('--smoke-test')
import app
from nmea import gga
from gnss import Decoder
from pyrtcm import calc_crc24q

def station():
    lat,lon=map(math.radians,(45.5,12.5));a=6378137;e2=.00669437999014
    n=a/math.sqrt(1-e2*math.sin(lat)**2)
    x=n*math.cos(lat)*math.cos(lon);y=n*math.cos(lat)*math.sin(lon);z=n*(1-e2)*math.sin(lat)
    fields=[(1006,12),(1,12),(0,6),(1,1),(1,1),(1,1),(0,1),(round(x*10000),38),(0,2),(round(y*10000),38),(0,2),(round(z*10000),38),(10000,16)]
    bits=''.join(f'{value%(1<<width):0{width}b}' for value,width in fields);bits+='0'*(-len(bits)%8)
    payload=int(bits,2).to_bytes(len(bits)//8,'big');packet=b'\xd3'+len(payload).to_bytes(2,'big')+payload
    return packet+calc_crc24q(packet).to_bytes(3,'big')

with tempfile.TemporaryDirectory() as temp:
    app.SETTINGS=Path(temp)/'settings.json'
    root=tk.Tk();client=app.Client(root)
    try:
        client.host.set('caster.example');client.mount.set('TEST');client.stream_key=(client.caster_key(),'TEST')
        client.worker=object();client.stopped.clear()
        client.open('live','Live stream',client.monitor)
        client.events.put(('data',station()))
        sentence=(gga(45.501,12.501,100,40)+'\r\n').encode()
        client.events.put(('receiver',('Serial / Bluetooth · test',sentence)))
        client.poll();root.update()
        assert client.receiver_position[:2]==(45.501,12.501)
        assert client.map_data()[1] is not None
        assert '$GPGGA' not in client.monitor_widgets[0].get('1.0','end')
        assert '$GPGGA' in client.receiver_raw.get('1.0','end')
        # Both decoder regions grow and the upper table has a working scrollbar.
        types=client.monitor_widgets[1]
        decoder_tabs=client.decoder_panes.master.master
        decoder_tabs.select(1);root.update()
        win=client.decoder_panes.winfo_toplevel()
        top_before=types.winfo_height();bottom_before=client.decoder_panes.panes()[1]
        bottom_before=win.nametowidget(bottom_before).winfo_height()
        win.geometry("880x950");root.update()
        assert types.winfo_height()>top_before+20
        assert win.nametowidget(client.decoder_panes.panes()[1]).winfo_height()>bottom_before+20
        assert client.types_scroll.winfo_ismapped()
        assert types.cget("yscrollcommand")
        for number in range(2000,2050):types.insert("", "end", iid=str(number), values=(number,1,"test"))
        types.yview_moveto(1);root.update();assert types.yview()[0]>0
        for number in range(2000,2050):types.delete(str(number))
        types.yview_moveto(0)
        types=client.monitor_widgets[1];select=client.monitor_widgets[2]
        types.selection_set('1006');client.refresh_monitor()
        choices=list(select.cget('values'));select.set(choices[1]);client.choose_monitor_frame()
        pinned=client.monitor_pinned
        for _ in range(25):client.events.put(('data',station()))
        while not client.events.empty():client.poll()
        root.update();assert client.monitor_pinned==pinned
        assert pinned[0] not in [row[0] for row in client.decoder.frames[1006]]
        detail=client.detail_signature
        client.events.put(('receiver',('TCP · 5000',b'$GPGGA,not valid\r\n')));client.poll();root.update()
        assert client.detail_signature==detail and types.selection()==('1006',)
        select.set(client.tr('Latest frame'));client.choose_monitor_frame();assert client.monitor_pinned is None
        client.open('map','Map & sky',client.map_window);root.update()
        live_window=client.windows['live'];map_window=client.windows['map']
        assert live_window is not map_window
        assert not live_window.transient() and not map_window.transient()
        for focused in (root,live_window,map_window,root):
            focused.lift();focused.focus_force();root.update()
            assert live_window.winfo_viewable() and map_window.winfo_viewable()
            assert live_window.state()=='normal' and map_window.state()=='normal'
        client.close_window('map');root.update();assert live_window.winfo_viewable()
        client.open('map','Map & sky',client.map_window);root.update()
        assert client.windows['map'].winfo_viewable() and live_window.winfo_viewable()
        view=client.map_view;view.zoom(2);before=(view.scale,view.street_zoom,view.center)
        client.events.put(('receiver',('Serial / Bluetooth · test',(gga(46,13,90)+'\r\n').encode())))
        client.poll();root.update();assert (view.scale,view.street_zoom,view.center)==before
        view.fit_current();assert (view.scale,view.street_zoom,view.center)!=before
        from test_fix import fix, NOFIX
        client.send_rover.set(True)
        client.events.put(('receiver',('Serial / Bluetooth · test',(fix(4)+'\r\n').encode())))
        client.poll();root.update();assert 'RTK FIXED' in client.fix_label.cget('text')
        assert client.fix_note.cget('text')
        assert client.count.winfo_ismapped()
        assert client.count.winfo_rooty()+client.count.winfo_height() <= root.winfo_rooty()+root.winfo_height()
        client.events.put(('receiver',('Serial / Bluetooth · test',(NOFIX+'\r\n').encode())))
        client.poll();root.update();assert 'NO FIX' in client.fix_label.cget('text')
        client.send_rover.set(False)
        position=client.receiver_position;counts=dict(client.receiver_streams);master=client.map_data()[1]
        client.toggle()
        client.events.put(('receiver',('Serial / Bluetooth · test',(gga(47,14,95)+'\r\n').encode())))
        client.events.put(('data',station()));client.poll();root.update()
        assert client.receiver_position==position and client.receiver_streams==counts
        assert 'PAUSED' in client.fix_label.cget('text')
        client.decoder=Decoder();assert client.map_data()[1]==master
        client.events.put(('receiver_error','Receiver test: disconnected'));client.events.put(('finished',client.caster_key()));client.poll()
        assert 'Receiver test: disconnected' in client.status_label.cget('text')
        print('PASS native UI: separate streams, stable decoder history, receiver-GGA map, zoom retention/Show both, frozen Stop, cached master and persistent errors')
    finally:
        client.receivers.close();root.destroy()
