import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from nmea import gga, gga_quality, valid_gga, GGAReader, ReceiverFix

def sentence(body):
    checksum=0
    for byte in body.encode():checksum^=byte
    return '$'+body+f'*{checksum:02X}'

def fix(quality):
    body=gga(45.5,12.5,100)[1:-3].split(',');body[6]=str(quality)
    return sentence(','.join(body))
NOFIX=sentence('GNGGA,120000.00,,,,,0,00,99.99,,,,,,')

class FixTests(unittest.TestCase):
    def test_no_fix_and_quality_validation_do_not_change_forwarding(self):
        self.assertEqual(gga_quality(NOFIX),0)
        self.assertFalse(valid_gga(NOFIX))
        self.assertEqual(GGAReader().feed((NOFIX+'\r\n').encode()),[])
        for quality in range(9):self.assertEqual(gga_quality(fix(quality)),quality)
        self.assertIsNone(gga_quality(fix(4)[:-2]+'ZZ'))
        self.assertIsNone(gga_quality(sentence('GNRMC,120000.00,,,,,4,00,99.99,,,,,,')))
    def test_fragmented_sources_stale_and_paused(self):
        model=ReceiverFix();line=(fix(4)+'\r\n').encode()
        model.feed('BT',line[:20],100);self.assertIsNone(model.quality)
        model.feed('TCP',b'unrelated\n',101)
        model.feed('BT',line[20:],102)
        self.assertIn('RTK FIXED',model.display(102,True)[0])
        self.assertEqual(model.display(102,True)[1],'#188342')
        self.assertIn('STALE',model.display(108,True)[0])
        self.assertIn('PAUSED',model.display(108,False)[0])
        model.feed('BT',(NOFIX+'\n').encode(),109)
        self.assertEqual(model.quality,0);self.assertIn('NO FIX',model.display(109,True)[0])
        model.feed('BT',b'$GNGGA,broken*00\n',110);self.assertEqual(model.received,109)
        model.reset();self.assertIsNone(model.quality)
