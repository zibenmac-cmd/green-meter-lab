import importlib.util
import struct
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('gateway', Path(__file__).parents[1] / 'adapters/ys8000_gateway.py')
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


class Frames(unittest.TestCase):
    def packet(self, byte_order='<'):
        return b'h01' + struct.pack(byte_order + 'h'*256, *range(-128,128)) + b'end'

    def test_6400_stream_split_coalesced_and_garbage(self):
        parser = g.FrameParser(128,b'h01',b'end')
        packet = self.packet()
        self.assertEqual(len(packet),518)
        self.assertEqual(parser.feed(b'garbage'+packet[:2]),[])
        frames = parser.feed(packet[2:]+packet)
        self.assertEqual(len(frames),2)
        self.assertEqual(frames[0][0][0],-128)
        self.assertEqual(frames[0][1][-1],127)
        self.assertEqual(len(parser.buffer),0)

    def test_invalid_trailer_realign_and_big_endian(self):
        parser = g.FrameParser(128,b'h01',b'end')
        frames=parser.feed(self.packet()[:-3]+b'bad'+self.packet())
        self.assertEqual(len(frames),1)
        self.assertGreater(parser.rejected,0)
        parser=g.FrameParser(128,b'h01',b'end','big')
        self.assertEqual(parser.feed(self.packet('>'))[0][0][0],-128)

    def test_no_connect_without_configuration(self):
        import json
        cfg=json.loads((Path(__file__).parents[1]/'public/hardware/ys8000-config.json').read_text())
        with self.assertRaisesRegex(ValueError,'calibration'):
            g.validate_config(cfg)
        cfg.update(calibration_confirmed=True,frame_format_confirmed=True,header_hex='683031',trailer_hex='656e64')
        self.assertEqual(g.validate_config(cfg).length,518)
        cfg['sample_rate_hz']=1600
        with self.assertRaisesRegex(ValueError,'sample_rate'):
            g.validate_config(cfg)

    def test_offsets_and_current_direction(self):
        cfg=dict(voltage_offset_adc=1,current_offset_adc=2,voltage_scale=2,current_scale=.5,current_sign=-1)
        self.assertEqual(g.physical([3],[4],cfg),([4],[-1.]))


if __name__=='__main__':
    unittest.main()
