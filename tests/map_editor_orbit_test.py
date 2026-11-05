"""地图编辑器真实 Godot 桥接、JSON 与 Tk 操作回归。"""
import copy
import importlib.util
import math
import os
import tempfile
import tkinter as tk
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location('space_map_editor', os.path.join(ROOT, 'tools', 'map_editor.py'))
editor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(editor)


def sample():
    return {'version': 1, 'objects': [
        {'id': 'planet', 'type': 'planet', 'position': [1000, -2000], **copy.deepcopy(editor.DEFAULTS['planet'])},
        {'id': 'junk', 'type': 'debris', 'position': [81000, -2000], **copy.deepcopy(editor.DEFAULTS['debris'])},
        {'id': 'rock', 'type': 'asteroid', 'position': [1000, -53500], **copy.deepcopy(editor.DEFAULTS['asteroid'])},
    ]}


class MapEditorOrbitTest(unittest.TestCase):
    def test_roundtrip_mass_and_legacy(self):
        data = sample()
        data['objects'][1]['mass_kg'] = 1234.125
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'map.json')
            editor.write_map(path, data)
            self.assertEqual(editor.read_map(path), data)
            del data['objects'][1]['mass_kg']
            editor.write_map(path, data)
            legacy = editor.read_map(path)['objects'][1]
            self.assertEqual(legacy.get('mass_kg', editor.DEFAULTS['debris']['mass_kg']), 1000)
            for invalid in [0, -1, True, '12', float('inf'), 1e16]:
                data['objects'][1]['mass_kg'] = invalid
                with self.assertRaises(ValueError):
                    editor.write_map(path, data)

    def test_real_godot_bridge(self):
        data = sample()
        for target in ['junk', 'rock']:
            clockwise = editor.circular_velocity(data, target, 'planet')
            counter = editor.circular_velocity(data, target, 'planet', False)
            self.assertEqual(clockwise['velocity'], [-v for v in counter['velocity']])
            self.assertEqual(clockwise['other_source_count'], 0)
            distance = 80000 if target == 'junk' else 51500
            expected_acceleration = 9.81 * (53000 / distance) ** 2 if distance > 53000 else 9.81
            self.assertAlmostEqual(clockwise['relative_speed'], math.sqrt(distance * expected_acceleration), delta=0.0001)
        data['objects'][1]['position'] = [251001, -2000]
        with self.assertRaisesRegex(ValueError, '引力范围'):
            editor.circular_velocity(data, 'junk', 'planet')

    def test_tk_calculate_apply_staleness(self):
        root = tk.Tk()
        root.withdraw()
        try:
            ui = editor.Editor(root)
            ui.data = sample()
            ui.selected = ui.data['objects'][1]
            ui.form_for_selection()
            ui.calculate_orbit()
            self.assertIsNotNone(ui.orbit_suggestion)
            self.assertEqual(str(ui.orbit_apply['state']), 'normal')
            expected = list(ui.orbit_suggestion[-1]['velocity'])
            ui.apply_orbit()
            self.assertEqual(ui.selected['initial_velocity'], expected)
            self.assertEqual(ui.selected['position'], [81000, -2000])
            self.assertEqual(ui.selected['mass_kg'], 1000)
            ui.calculate_orbit()
            ui.fields['position'][0].set('82000, -2000')
            ui.apply_orbit()
            self.assertIsNone(ui.orbit_suggestion)
            self.assertEqual(ui.selected['initial_velocity'], expected)
            ui.calculate_orbit()
            ui.orbit_direction.set('逆时针')
            ui.apply_orbit()
            self.assertIsNone(ui.orbit_suggestion)
            self.assertEqual(ui.selected['initial_velocity'], expected)
        finally:
            root.destroy()


if __name__ == '__main__':
    unittest.main(verbosity=2)
