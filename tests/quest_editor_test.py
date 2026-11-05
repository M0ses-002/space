"""行星 / 太空城事件与委托编辑器回归：地图与事件校验、路径映射、保存分工、Tk 门禁。

类名刻意带 A/B/C 前缀：`unittest` 按模块内字母序发现用例，C 类最后执行，
用于断言前面所有用例都没有写入项目内的真实数据文件。
"""
import copy
import glob
import hashlib
import importlib.util
import json
import os
import shutil
import tempfile
import tkinter as tk
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location('space_quest_editor', os.path.join(ROOT, 'tools', 'quest_editor.py'))
editor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(editor)

MAPS_DIR = os.path.join(ROOT, 'maps')
PLANET_DIR = os.path.join(ROOT, 'data', 'planets')


def snapshot():
    """项目内会被编辑器读写的真实文件指纹。"""
    result = {}
    for path in sorted(glob.glob(os.path.join(MAPS_DIR, '*.json')) + glob.glob(os.path.join(PLANET_DIR, '*.json'))):
        with open(path, 'rb') as handle:
            result[path] = hashlib.sha256(handle.read()).hexdigest()
    return result


BEFORE = snapshot()


def sample_map():
    return {
        'version': 1,
        'objects': [
            {
                'type': 'planet', 'id': 'planet_1', 'position': [0.0, 0.0],
                'fields': {
                    'display_name': '行星', 'radius_m': 50000.0, 'field_height_m': 3000.0,
                    'surface_gravity': 9.81, 'max_gravity_radius_m': 100000.0,
                    'interaction_data_path': 'res://data/planets/planet_a.json',
                },
            },
            {
                'type': 'city', 'id': 'city_1', 'position': [1000.0, 1000.0],
                'fields': {
                    'display_name': '城', 'city_size_m': [100000.0, 20000.0], 'gravity_height_m': 30000.0,
                    'port_offset_m': [60000.0, 0.0], 'docking_radius_m': 20000.0,
                    'dock_offset_m': [0.0, -5000.0],
                    'interaction_data_path': 'res://data/planets/flat_nuclear_city.json',
                },
            },
        ],
        'ship': {'position': [0.0, 0.0], 'velocity': [0.0, 0.0]},
    }


def sample_planet():
    return {
        'schema_version': 1,
        'planet_id': 'planet_a',
        'name': '示例港',
        'events': [{'id': 'e1', 'title': '标题', 'body': '正文'}],
        'diplomacy': {'persons': [{
            'id': 'p1', 'name': '人', 'role': '角色', 'description': '描述', 'portrait': '',
            'dialogue': ['一句台词'],
            'quests': [{
                'id': 'q1', 'title': '委托', 'description': '说明', 'type': 'dock_city',
                'count': 1, 'reward_credits': 0, 'target': '',
            }],
        }]},
    }


def quest(data, **overrides):
    data['diplomacy']['persons'][0]['quests'][0].update(overrides)
    return data


class QuestEditorAValidateTest(unittest.TestCase):
    def test_map_requires_whitelisted_fields(self):
        data = sample_map()
        data['objects'][0]['fields']['unknown_key'] = 1
        with self.assertRaises(ValueError):
            editor.validate_map(data)
        data = sample_map()
        data['objects'][0]['fields']['interaction_data_path'] = 'res://data/other.json'
        with self.assertRaises(ValueError):
            editor.validate_map(data)
        data = sample_map()
        data['objects'][1]['id'] = 'planet_1'
        with self.assertRaises(ValueError):
            editor.validate_map(data)
        data = sample_map()
        data['objects'][1]['fields']['city_size_m'] = [0.0, 20000.0]
        with self.assertRaises(ValueError):
            editor.validate_map(data)

    def test_map_keeps_legacy_asteroid_fields(self):
        data = sample_map()
        data['objects'].append({
            'type': 'asteroid', 'id': 'rock_1', 'position': [0.0, 0.0],
            'fields': {'initial_velocity': [0.0, 0.0], 'radius_m': 1000.0, 'mass_kg': 1000000.0,
                       'style_index': 0, 'mineral_id': '1', 'mineral_unit_mass': 1.0},
        })
        editor.validate_map(data)

    def test_planet_rejects_broken_events(self):
        data = sample_planet()
        data['events'].append({'id': 'e1', 'title': '重复', 'body': '正文'})
        self.assertTrue(editor.collect_planet_errors(data))
        data = sample_planet()
        data['events'][0]['title'] = ''
        self.assertTrue(editor.collect_planet_errors(data))
        data = sample_planet()
        data['events'] = 'nope'
        self.assertTrue(editor.collect_planet_errors(data))
        data = sample_planet()
        data['schema_version'] = 2
        self.assertTrue(editor.collect_planet_errors(data))
        with self.assertRaises(ValueError):
            editor.validate_planet(data)

    def test_planet_rejects_broken_persons(self):
        data = sample_planet()
        data['diplomacy']['persons'][0]['role'] = ''
        self.assertTrue(editor.collect_planet_errors(data))
        data = sample_planet()
        data['diplomacy']['persons'][0]['dialogue'] = 'nope'
        self.assertTrue(editor.collect_planet_errors(data))
        data = sample_planet()
        data['diplomacy']['persons'][0]['id'] = 'planet_1'
        data['diplomacy']['persons'].append(copy.deepcopy(data['diplomacy']['persons'][0]))
        self.assertTrue(editor.collect_planet_errors(data))

    def test_quest_type_rules(self):
        for override in ({'type': 'unknown_type'}, {'count': 0}, {'reward_credits': -1},
                         {'title': ''}, {'id': '带中文'}):
            data = quest(sample_planet(), **override)
            self.assertTrue(editor.collect_planet_errors(data), override)

    def test_reward_unlock_rules(self):
        # 只有 equipment.json 里 requires_unlock=true 的装备可以被任务解锁。
        ok = quest(sample_planet(), reward_unlock='hangar')
        self.assertEqual(editor.collect_planet_errors(ok), [])
        free_item = quest(sample_planet(), reward_unlock='capture_net')
        self.assertTrue(editor.collect_planet_errors(free_item))
        unknown = quest(sample_planet(), reward_unlock='hangar_v9')
        self.assertTrue(editor.collect_planet_errors(unknown))
        not_text = quest(sample_planet(), reward_unlock=3)
        self.assertTrue(editor.collect_planet_errors(not_text))

    def test_requires_return_rules(self):
        # 需要返回复命的委托：requires_return 必须是布尔；return_line 只在需要复命时有意义。
        ok = quest(sample_planet(), requires_return=True, return_line='回来复命。')
        self.assertEqual(editor.collect_planet_errors(ok), [])
        no_line = quest(sample_planet(), requires_return=True)
        self.assertEqual(editor.collect_planet_errors(no_line), [])
        explicit_false = quest(sample_planet(), requires_return=False)
        self.assertEqual(editor.collect_planet_errors(explicit_false), [])
        not_bool = quest(sample_planet(), requires_return='yes')
        self.assertTrue(editor.collect_planet_errors(not_bool))
        orphan_line = quest(sample_planet(), return_line='没人要的台词')
        self.assertTrue(editor.collect_planet_errors(orphan_line))
        empty_line = quest(sample_planet(), requires_return=True, return_line='   ')
        self.assertTrue(editor.collect_planet_errors(empty_line))
        not_text = quest(sample_planet(), requires_return=True, return_line=5)
        self.assertTrue(editor.collect_planet_errors(not_text))
        too_long = quest(sample_planet(), requires_return=True, return_line='字' * (editor.TEXT_LIMIT + 1))
        self.assertTrue(editor.collect_planet_errors(too_long))

    def test_arrive_point_rules(self):
        ok = quest(sample_planet(), type='arrive_point', position=[1000.0, -2000.0], radius_m=500.0)
        ok['diplomacy']['persons'][0]['quests'][0].pop('target')
        self.assertEqual(editor.collect_planet_errors(ok), [])
        missing = copy.deepcopy(ok)
        missing['diplomacy']['persons'][0]['quests'][0].pop('position')
        self.assertTrue(editor.collect_planet_errors(missing))
        zero = copy.deepcopy(ok)
        zero['diplomacy']['persons'][0]['quests'][0]['radius_m'] = 0.0
        self.assertTrue(editor.collect_planet_errors(zero))

    def test_targets_must_exist_on_map(self):
        data = quest(sample_planet(), type='arrive_target', target='planet_1', radius_m=1000.0)
        self.assertEqual(editor.collect_planet_errors(data, sample_map()), [])
        ghost = quest(sample_planet(), type='arrive_target', target='planet_9', radius_m=1000.0)
        self.assertTrue(editor.collect_planet_errors(ghost, sample_map()))

        dock = quest(sample_planet(), type='dock_city', target='')
        self.assertEqual(editor.collect_planet_errors(dock, sample_map()), [])
        dock['diplomacy']['persons'][0]['quests'][0]['target'] = 'city_1'
        self.assertEqual(editor.collect_planet_errors(dock, sample_map()), [])
        dock['diplomacy']['persons'][0]['quests'][0]['target'] = 'planet_1'
        self.assertTrue(editor.collect_planet_errors(dock, sample_map()))

        talk = quest(sample_planet(), type='talk_to_person', target='p1')
        self.assertEqual(editor.collect_planet_errors(talk, sample_map()), [])
        talk['diplomacy']['persons'][0]['quests'][0]['target'] = 'p9'
        self.assertTrue(editor.collect_planet_errors(talk, sample_map()))

    def test_talk_target_can_cross_planets(self):
        """「与指定人物对话」允许指向别的行星上的人：校验看全项目，而不是只看当前文件。"""
        other = sample_planet()
        other['planet_id'] = 'planet_b'
        other['name'] = '另一边'
        other['diplomacy']['persons'][0]['id'] = 'p_other'
        registry = editor.person_registry(sample_map(), current_data=other)
        self.assertIn('p_other', registry)
        self.assertEqual(registry['p_other'][0]['name'], '人')
        self.assertIn('p_other', registry['p_other'][0]['label'])

        data = quest(sample_planet(), type='talk_to_person', target='p_other')
        self.assertEqual(editor.collect_planet_errors(data, sample_map(), registry), [])
        # 不传索引时保持旧行为：只认同文件人物，跨行星目标会被拦下。
        self.assertTrue(editor.collect_planet_errors(data, sample_map()))

        ghost = quest(sample_planet(), type='talk_to_person', target='p_ghost')
        self.assertTrue(editor.collect_planet_errors(ghost, sample_map(), registry))
        # target_name / target_planet 只是界面提示，类型不对要被拦下。
        bad_hint = quest(sample_planet(), type='talk_to_person', target='p_other', target_name=5)
        self.assertTrue(editor.collect_planet_errors(bad_hint, sample_map(), registry))

    def test_talk_target_allows_duplicate_person_ids(self):
        """人物 id 允许跨行星重名（老数据每颗星都有 person_1），靠 target_planet_id 定位。"""
        registry = {'p1': [
            {'id': 'p1', 'name': '人', 'planet': '甲星', 'planet_id': 'planet_jia'},
            {'id': 'p1', 'name': '人', 'planet': '乙星', 'planet_id': 'planet_yi'},
        ]}
        # 不带行星：按 id 匹配，保留旧数据行为。
        data = quest(sample_planet(), type='talk_to_person', target='p1')
        self.assertEqual(editor.collect_planet_errors(data, sample_map(), registry), [])
        # 指定了行星：必须真在那颗星上。
        same = quest(sample_planet(), type='talk_to_person', target='p1', target_planet_id='planet_yi')
        self.assertEqual(editor.collect_planet_errors(same, sample_map(), registry), [])
        wrong = quest(sample_planet(), type='talk_to_person', target='p1', target_planet_id='planet_bing')
        errors = editor.collect_planet_errors(wrong, sample_map(), registry)
        self.assertTrue(errors)
        self.assertIn('target_planet_id', errors[0])

    def test_quest_ids_are_globally_unique(self):
        data = quest(sample_planet())
        second = copy.deepcopy(data['diplomacy']['persons'][0])
        second['id'] = 'p2'
        data['diplomacy']['persons'].append(second)
        self.assertTrue(editor.collect_planet_errors(data))

    def test_quest_id_must_not_clash_with_other_planets(self):
        """跨文件撞名会让运行期任务表互相顶掉：接了 A 星同 id 的委托后，B 星的显示成已接取。"""
        data = quest(sample_planet())
        clash = {'q1': [{'id': 'q1', 'planet_id': 'planets_other', 'current': False}]}
        errors = editor.collect_planet_errors(data, sample_map(), None, clash)
        self.assertTrue(errors)
        self.assertIn('撞名', errors[0])
        own = {'q1': [{'id': 'q1', 'planet_id': 'planet_a', 'current': True}]}
        self.assertEqual(editor.collect_planet_errors(data, sample_map(), None, own), [])

    def test_project_data_has_no_duplicate_quest_ids(self):
        """项目数据本身要满足：委托 id 全项目唯一（运行期任务表只按 id 建键）。"""
        duplicates = {}
        for quest_id, entries in editor.quest_registry().items():
            if len(entries) > 1:
                duplicates[quest_id] = [entry['planet_id'] for entry in entries]
        self.assertEqual(duplicates, {})

    def test_default_planet_data_is_valid_and_roundtrips(self):
        data = editor.default_planet_data('planet_demo', '示例行星')
        self.assertEqual(editor.collect_planet_errors(data, sample_map()), [])
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'planet_demo.json')
            editor.write_json(path, data)
            self.assertEqual(editor.read_planet(path), data)

    def test_res_to_disk_mapping(self):
        self.assertEqual(editor.disk_to_res(os.path.join(PLANET_DIR, 'planet_a.json')),
                         'res://data/planets/planet_a.json')
        self.assertEqual(editor.res_to_disk('res://data/planets/planet_a.json'),
                         os.path.join(PLANET_DIR, 'planet_a.json'))
        for rejected in ('res://data/other/x.json', 'res://data/planets/sub/x.json',
                         'res://data/planets/../x.json', 'res://data/x.json'):
            with self.assertRaises(ValueError):
                editor.res_to_disk(rejected)
        with self.assertRaises(ValueError):
            editor.disk_to_res(os.path.join(ROOT, 'data', 'other', 'x.json'))

    def test_speech_when_text_roundtrips(self):
        """条件文本框是「每行 key = 值」，解析与回写必须互逆，否则一存就变样。"""
        text = 'quests_done = q1, q2\nflags = met:true, gone:false\nstage_min = 2\nplanet_id = planet_a'
        when, errors = editor.parse_when_text(text)
        self.assertEqual(errors, [])
        self.assertEqual(when['quests_done'], ['q1', 'q2'])
        self.assertEqual(when['flags'], {'met': True, 'gone': False})
        self.assertEqual(when['stage_min'], 2)
        again, again_errors = editor.parse_when_text(editor.format_when_text(when))
        self.assertEqual(again_errors, [])
        self.assertEqual(again, when)

    def test_speech_when_rejects_bad_lines(self):
        self.assertTrue(editor.parse_when_text('没有等号')[1])
        self.assertTrue(editor.parse_when_text('unknown_key = 1')[1])
        self.assertTrue(editor.parse_when_text('stage_min = 二')[1])
        self.assertTrue(editor.parse_when_text('flags = met:maybe')[1])
        self.assertTrue(editor.parse_when_text('quests_done =')[1])

    def test_speech_structure_rules(self):
        """speech 的结构错误要在保存前就报出来，别等游戏里发现这个人再也不说话。"""
        valid = {'id': 'p1', 'name': '人', 'role': '角色', 'description': '描述', 'speech': [{
            'id': 's1',
            'when': {'quests_done': ['q1'], 'flags': {'met': True}},
            'lines': ['一句'],
            'once': True,
            'set_flags': {'thanked': True},
        }]}
        self.assertEqual(editor.collect_speech_errors(valid, 'persons[0]', 'p1', {'q1': []}), [])

        unknown_field = copy.deepcopy(valid)
        unknown_field['speech'][0]['typo'] = 1
        self.assertTrue(editor.collect_speech_errors(unknown_field, 'persons[0]', 'p1'))

        empty_lines = copy.deepcopy(valid)
        empty_lines['speech'][0]['lines'] = []
        self.assertTrue(editor.collect_speech_errors(empty_lines, 'persons[0]', 'p1'))

        duplicate_id = copy.deepcopy(valid)
        duplicate_id['speech'].append(copy.deepcopy(duplicate_id['speech'][0]))
        self.assertTrue(any('重复' in text for text in editor.collect_speech_errors(duplicate_id, 'persons[0]', 'p1')))

        bad_key = copy.deepcopy(valid)
        bad_key['speech'][0]['when'] = {'no_such_key': ['x']}
        self.assertTrue(any('未知条件键' in text for text in editor.collect_speech_errors(bad_key, 'persons[0]', 'p1')))

        missing_quest = copy.deepcopy(valid)
        missing_quest['speech'][0]['when'] = {'quests_done': ['nope']}
        self.assertTrue(any('不存在' in text for text in editor.collect_speech_errors(missing_quest, 'persons[0]', 'p1', {'q1': []})))

        bad_flag = copy.deepcopy(valid)
        bad_flag['speech'][0]['set_flags'] = {'thanked': 'yes'}
        self.assertTrue(editor.collect_speech_errors(bad_flag, 'persons[0]', 'p1'))

    def test_speech_does_not_break_legacy_persons(self):
        """没有 speech 的人物照旧按 dialogue / quest_greeting 校验，老数据零迁移。"""
        legacy = sample_planet()['diplomacy']['persons'][0]
        self.assertEqual(editor.collect_speech_errors(legacy, 'persons[0]', 'p1'), [])
        empty = copy.deepcopy(legacy)
        empty['speech'] = []
        self.assertTrue(editor.collect_speech_errors(empty, 'persons[0]', 'p1'))


class QuestEditorBUiTest(unittest.TestCase):
    def setUp(self):
        self.root = tk.Tk()
        self.root.withdraw()
        self.ui = editor.Editor(self.root)
        self.temporary = tempfile.mkdtemp(prefix='quest_editor_test_')
        self.map_path = os.path.join(self.temporary, 'map.json')
        shutil.copyfile(os.path.join(MAPS_DIR, 'default_map.json'), self.map_path)

    def tearDown(self):
        try:
            self.root.destroy()
        except tk.TclError:
            pass
        shutil.rmtree(self.temporary, ignore_errors=True)

    def select_planet(self, object_id='planet_1'):
        """选中对象后把事件数据指向临时副本：用例绝不允许写项目内 planet_a.json。"""
        self.assertTrue(self.ui.select_object(object_id))
        if self.ui.planet_data is not None and self.ui.planet_path:
            safe_path = os.path.join(self.temporary, 'planet_copy.json')
            shutil.copyfile(self.ui.planet_path, safe_path)
            self.ui.planet_path = safe_path
        return self.ui.planet_data

    def test_map_is_required_before_configuration(self):
        self.assertIsNone(self.ui.map_data)
        self.assertIn('disabled', self.ui.notebook.state())
        self.assertIn('disabled', self.ui.save_button.state())
        self.assertIn('disabled', self.ui.check_button.state())
        self.assertIn('disabled', self.ui.create_button.state())
        self.assertEqual(self.ui.tree.get_children(), ())

        self.ui.load_map_path(self.map_path)
        self.assertNotIn('disabled', self.ui.notebook.state())
        self.assertNotIn('disabled', self.ui.save_button.state())
        self.assertEqual(len(self.ui.tree.get_children()), len(editor.map_objects(self.ui.map_data)))

    def test_select_object_fills_three_tabs(self):
        self.ui.load_map_path(self.map_path)
        self.assertIsNotNone(self.select_planet())
        self.assertIsNotNone(self.ui.planet_data)
        self.assertEqual(self.ui.event_list.size(), len(self.ui.planet_data['events']))
        persons = self.ui.planet_data['diplomacy']['persons']
        self.assertEqual(self.ui.person_list.size(), len(persons))
        # 委托挂在人物下，数量取决于数据本身：统计全部人物的委托总数，逐个页面核对。
        expected = sum(len(person.get('quests', [])) for person in persons
                       if isinstance(person.get('quests'), list))
        total = 0
        for index in range(len(persons)):
            self.ui.quest_person_index = index
            self.ui.refresh_quest_list()
            total += self.ui.quest_list.size()
        self.assertEqual(total, expected)

    def test_talk_target_combo_lists_every_planet_and_writes_planet_id(self):
        """下拉列全项目人物且显示所在地；保存时把 target 与 target_planet_id 一起写进去。"""
        self.ui.load_map_path(self.map_path)
        data = self.select_planet()
        person = data['diplomacy']['persons'][0]
        person.setdefault('quests', []).append({
            'id': 'q_cross_planet', 'title': '跨星对话', 'description': '找机库管理员',
            'type': 'talk_to_person', 'target': 'person_1', 'count': 1, 'reward_credits': 0,
        })
        self.ui.quest_person_index = 0
        self.ui.quest_index = len(person['quests']) - 1
        self.ui.refresh_quest_list()
        labels = list(self.ui.quest_target_combo['values'])
        # 三颗星上都有 person_1，下拉必须都列出来，并且显示可读标签而不是裸 id。
        self.assertGreaterEqual(len(labels), 3)
        self.assertTrue(all('·' in label for label in labels), labels)
        self.assertNotEqual(self.ui.quest_target_var.get(), 'person_1')
        self.assertIn('person_1', self.ui.quest_target_var.get())
        self.assertEqual(self.ui.quest_target_value('talk_to_person'), 'person_1')
        # 改选另一颗星上的同名人物：target 仍是 person_1，但 planet_id 指向那颗星。
        other = next(label for label in labels if '（planet_1）' in label)
        self.ui.quest_target_var.set(other)
        self.assertTrue(self.ui.apply_quest())
        saved = person['quests'][-1]
        self.assertEqual(saved['target'], 'person_1')
        self.assertEqual(saved['target_planet_id'], 'planet_1')

    def test_event_only_edit_does_not_rewrite_map(self):
        self.ui.load_map_path(self.map_path)
        self.select_planet()
        with open(self.map_path, 'rb') as handle:
            before = handle.read()
        self.ui.event_index = 0
        self.ui.event_title_var.set('改过的标题')
        self.assertTrue(self.ui.apply_event())
        self.assertTrue(self.ui.save_all(silent=True))
        with open(self.map_path, 'rb') as handle:
            self.assertEqual(handle.read(), before)
        self.assertTrue(self.ui.planet_data['events'][0]['title'] == '改过的标题')
        with open(self.ui.planet_path, encoding='utf-8') as handle:
            self.assertEqual(json.load(handle)['events'][0]['title'], '改过的标题')

    def test_binding_new_file_writes_both_map_and_event_json(self):
        self.ui.load_map_path(self.map_path)
        self.select_planet()
        event_path = os.path.join(self.temporary, 'planet_1_new.json')
        data = editor.read_planet(os.path.join(PLANET_DIR, 'planet_a.json'))
        # _set_object_path 会把 planet_path 指到项目内新文件；用例改用临时路径，避免写项目数据。
        self.assertTrue(self.ui._set_object_path('res://data/planets/planet_1_new.json'))
        self.ui.planet_data = data
        self.ui.planet_path = event_path
        self.ui.planet_saved = copy.deepcopy(data)
        self.ui.refresh_all_tabs()
        self.assertTrue(self.ui.map_dirty())
        self.assertTrue(self.ui.save_all(silent=True))
        self.assertFalse(self.ui.map_dirty())
        self.assertTrue(os.path.isfile(event_path))
        written = editor.read_map(self.map_path)
        paths = {obj['id']: obj['fields'].get('interaction_data_path') for obj in editor.map_objects(written)}
        self.assertEqual(paths['planet_1'], 'res://data/planets/planet_1_new.json')
        self.assertEqual(paths['city_1'], 'res://data/planets/flat_nuclear_city.json')
        # 保存路径按全项目人物索引校验（目标人物可以在别的行星上），这里与编辑器保持一致。
        editor.validate_planet(editor.read_planet(event_path), written, editor.person_registry(written))

    def test_binding_new_file_requires_no_map_rewrite_before_save(self):
        self.ui.load_map_path(self.map_path)
        self.select_planet()
        with open(self.map_path, 'rb') as handle:
            before = handle.read()
        self.ui._set_object_path('res://data/planets/unused_binding.json')
        with open(self.map_path, 'rb') as handle:
            self.assertEqual(handle.read(), before, '绑定新路径只改内存，保存前不落盘')
        self.assertTrue(self.ui.map_dirty())


class QuestEditorBCgTest(unittest.TestCase):
    """地图级 CG：cg_data_path 校验、CG 文件校验、归属交叉检查与保存分工。"""

    def setUp(self):
        self.root = tk.Tk()
        self.root.withdraw()
        self.ui = editor.Editor(self.root)
        self.temporary = tempfile.mkdtemp(prefix='quest_editor_cg_')
        self.map_path = os.path.join(self.temporary, 'map.json')
        shutil.copyfile(os.path.join(MAPS_DIR, 'default_map.json'), self.map_path)
        self.ui.load_map_path(self.map_path)

    def tearDown(self):
        try:
            self.root.destroy()
        except tk.TclError:
            pass
        shutil.rmtree(self.temporary, ignore_errors=True)

    def cg_file(self, name='cg.json'):
        return os.path.join(self.temporary, name)

    def use_cg(self, data, name='cg.json'):
        path = self.cg_file(name)
        editor.write_json(path, data)
        self.ui.cg_path = path
        self.ui.cg_res = editor.CG_PREFIX + name
        self.ui.cg_data = editor.read_cg(path)
        self.ui.cg_saved = copy.deepcopy(self.ui.cg_data)
        self.ui.refresh_cg_list()
        return path

    def sample_cg(self, trigger=None, **extra):
        item = {
            'id': 'cg_1',
            'image': 'res://assets/cg/cg_1.png',
            'text': '开场',
            'duration': 3.0,
            'trigger': trigger or {'type': 'map_enter', 'map': 'map'},
        }
        item.update(extra)
        return {'version': 1, 'map': 'map', 'cgs': [item]}

    def test_cg_data_path_must_live_under_data_cg(self):
        base = {'version': 1, 'objects': []}
        for good in ('res://data/cg/default_map.json', 'res://data/cg/a.json'):
            editor.validate_map(dict(base, cg_data_path=good))
        for bad in ('res://data/planets/a.json', 'res://data/cg/sub/a.json',
                    'res://data/cg/a.json.bak', 'res://data/cg/../a.json', 'data/cg/a.json'):
            with self.assertRaises(ValueError, msg=bad):
                editor.validate_map(dict(base, cg_data_path=bad))

    def test_cg_file_validation(self):
        self.assertEqual(editor.collect_cg_errors(self.sample_cg()), [])
        bad_type = self.sample_cg({'type': 'unknown'})
        self.assertTrue(editor.collect_cg_errors(bad_type))
        bad_duration = self.sample_cg(duration=0)
        self.assertTrue(editor.collect_cg_errors(bad_duration))
        bad_image = self.sample_cg(image='http://x/a.png')
        self.assertTrue(editor.collect_cg_errors(bad_image))
        duplicate = {'version': 1, 'map': 'map', 'cgs': [self.sample_cg()['cgs'][0]] * 2}
        self.assertTrue(any('重复' in text for text in editor.collect_cg_errors(duplicate)))

    def test_enter_object_must_exist_in_map(self):
        trigger = {'type': 'enter_object', 'object': 'nope_city', 'kind': 'city'}
        self.assertTrue(editor.collect_cg_errors(self.sample_cg(trigger), self.ui.map_data))
        good = {'type': 'enter_object', 'object': 'city_1', 'kind': 'city'}
        self.assertEqual(editor.collect_cg_errors(self.sample_cg(good), self.ui.map_data), [])
        anywhere = {'type': 'enter_object', 'object': '*', 'kind': 'any'}
        self.assertEqual(editor.collect_cg_errors(self.sample_cg(anywhere), self.ui.map_data), [])

    def test_reach_point_needs_position_and_radius(self):
        bad_radius = {'type': 'reach_point', 'position': [0, 0], 'radius_m': 0}
        self.assertTrue(editor.collect_cg_errors(self.sample_cg(bad_radius)))
        bad_point = {'type': 'reach_point', 'position': 'x', 'radius_m': 100}
        self.assertTrue(editor.collect_cg_errors(self.sample_cg(bad_point)))
        good = {'type': 'reach_point', 'position': [1200, -800], 'radius_m': 500}
        self.assertEqual(editor.collect_cg_errors(self.sample_cg(good)), [])

    def test_map_owner_mismatch_is_an_error(self):
        data = self.sample_cg({'type': 'map_enter', 'map': 'another_map'})
        self.assertTrue(any('trigger.map' in text for text in editor.collect_cg_errors(data)))
        wildcard = self.sample_cg({'type': 'map_enter', 'map': '*'})
        self.assertEqual(editor.collect_cg_errors(wildcard), [])

    def test_warnings_do_not_block_saving(self):
        data = self.sample_cg({'type': 'quest_complete', 'quest': 'no_such_quest'})
        self.assertEqual(editor.collect_cg_errors(data, self.ui.map_data), [])
        warnings = editor.collect_cg_warnings(data, self.ui.map_data)
        self.assertTrue(any('图片不存在' in text for text in warnings))
        self.assertTrue(any('no_such_quest' in text for text in warnings))

    def test_cg_page_saves_file_and_map_binding(self):
        path = self.use_cg(editor.default_cg_data('map'))
        self.assertEqual(self.ui.cg_list.size(), 0)
        self.ui.add_cg()
        self.assertEqual(len(self.ui.cg_data['cgs']), 1)
        self.ui.cg_id_var.set('map_open')
        self.ui.cg_image_var.set('res://assets/cg/map_open.png')
        self.ui.cg_duration_var.set('4.5')
        self.ui.cg_trigger_var.set(editor.CG_TRIGGER_LABELS['enter_object'])
        self.ui.on_cg_type_change()
        self.ui.cg_object_var.set('*')
        self.ui._set_text(self.ui.cg_text, '地图开场')
        self.assertTrue(self.ui.apply_cg())
        self.ui.map_data['cg_data_path'] = editor.CG_PREFIX + 'cg.json'
        self.assertTrue(self.ui.cg_dirty())
        self.assertTrue(self.ui.save_all(silent=True))
        self.assertFalse(self.ui.cg_dirty())
        self.assertFalse(self.ui.map_dirty())
        saved = editor.read_cg(path)
        self.assertEqual(saved['cgs'][0]['id'], 'map_open')
        self.assertEqual(saved['cgs'][0]['trigger'], {'type': 'enter_object', 'object': '*', 'kind': ''})
        self.assertEqual(saved['map'], 'map')
        written_map = editor.read_map(self.map_path)
        self.assertEqual(written_map['cg_data_path'], editor.CG_PREFIX + 'cg.json')

    def test_cg_form_rejects_bad_numbers(self):
        self.use_cg(self.sample_cg())
        self.ui.cg_duration_var.set('abc')
        with self.assertRaises(ValueError):
            self.ui.cg_form_values()
        self.ui.cg_duration_var.set('2')
        self.assertEqual(self.ui.cg_form_values()['duration'], 2.0)


class QuestEditorCProjectUntouchedTest(unittest.TestCase):
    def test_no_project_files_were_modified(self):
        self.assertEqual(snapshot(), BEFORE, '用例不应写入 maps/ 或 data/planets/ 下的真实文件')


if __name__ == '__main__':
    unittest.main(verbosity=2)
