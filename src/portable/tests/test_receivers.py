import sys
import threading
import time
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from receivers import SerialReceiverHub
from nmea import gga,position_from_gga

class Device:
    def __init__(self,path,baud,**kwargs):
        self.port=path;self.is_open=True;self.pending=bytearray();self.error=False;self.lock=threading.Lock()
    @property
    def in_waiting(self):
        if self.error:raise OSError('simulated receiver failure')
        with self.lock:return len(self.pending)
    def read(self,n):
        with self.lock:
            data=bytes(self.pending[:n]);del self.pending[:n];return data
    def feed(self,data):
        with self.lock:self.pending.extend(data)
    def close(self):self.is_open=False

class ReceiverTests(unittest.TestCase):
    def test_retained_port_discards_paused_input_and_reopens_failed_link(self):
        opened=[]
        def factory(*args,**kwargs):
            device=Device(*args,**kwargs);opened.append(device);return device
        hub=SerialReceiverHub(factory);self.addCleanup(hub.close)
        first=hub.configure((('COM-test',115200),))[0]
        first.feed(b'$GPGGA,first\r\n');time.sleep(.08)
        self.assertEqual(hub.poll(),[('Serial / Bluetooth · COM-test',b'$GPGGA,first\r\n')])
        hub.pause();first.feed(b'paused');time.sleep(.08);self.assertEqual(hub.poll(),[])
        self.assertIs(hub.configure((('COM-test',115200),))[0],first)
        first.feed(b'resumed');time.sleep(.08)
        self.assertEqual(hub.poll()[0][1],b'resumed');self.assertEqual(len(opened),1)
        first.error=True;time.sleep(.08)
        with self.assertRaisesRegex(OSError,'simulated receiver failure'):hub.poll()
        second=hub.configure((('COM-test',115200),))[0]
        self.assertIsNot(second,first);self.assertFalse(first.is_open);self.assertEqual(len(opened),2)
        hub.disconnect();self.assertFalse(second.is_open)
    def test_geographic_gga_height_and_invalid_fix(self):
        sentence=gga(-45.125,-12.5,100.123,40.1)
        lat,lon,height=position_from_gga(sentence)
        self.assertAlmostEqual(lat,-45.125);self.assertAlmostEqual(lon,-12.5);self.assertAlmostEqual(height,100.123)
        self.assertIsNone(position_from_gga(sentence[:-1]+'Z'))
