"""行星 / 太空城 事件与委托编辑器，仅依赖 Python 标准库。

工作流：先用 tools/map_editor.py 画地图 JSON，再用本工具打开该地图，
选中一个 planet / city 对象，编辑它 fields.interaction_data_path 指向的事件 JSON。
校验规则严格对齐 scripts/navigation/map_loader.gd、scripts/ports/port_session.gd
与 scripts/quest/quest_manager.gd，避免编辑器放行游戏会拒绝的数据。
"""
import copy
import glob
import json
import math
import os
import re
import sys
import tempfile
import tkinter as tk
from collections import Counter
from tkinter import filedialog, messagebox, ttk

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAPS_DIR = os.path.join(PROJECT_ROOT, 'maps')
PLANET_DIR = os.path.join(PROJECT_ROOT, 'data', 'planets')
MAX_BYTES = 1048576
JS_INDENT = 2

RES_PREFIX = 'res://data/planets/'
ID_PATTERN = re.compile(r'[A-Za-z0-9_-]{1,64}')
TEXT_LIMIT = 4000

FIELDS = {
    'planet': ['display_name', 'radius_m', 'field_height_m', 'surface_gravity', 'max_gravity_radius_m', 'interaction_data_path', 'texture_id'],
    'city': ['display_name', 'rotation_degrees_m', 'city_size_m', 'gravity_height_m', 'port_offset_m', 'docking_radius_m', 'dock_offset_m', 'interaction_data_path'],
    'asteroid': ['initial_velocity', 'radius_m', 'mass_kg', 'style_index', 'texture_id'],
    'debris': ['initial_velocity', 'radius_m', 'mass_kg', 'debris_count', 'debris_size_m', 'minimum_fragment_pixels', 'texture_id'],
}
VECTORS = ('city_size_m', 'port_offset_m', 'dock_offset_m', 'initial_velocity')
STRINGS = ('display_name', 'interaction_data_path')
ZERO_ALLOWED = ('field_height_m', 'surface_gravity', 'style_index', 'debris_count', 'minimum_fragment_pixels')
LEGACY_FIELDS = ('mineral_id', 'mineral_unit_mass')

QUEST_TYPES = ('arrive_point', 'arrive_target', 'talk_to_person', 'dock_city', 'install_upgrade', 'recycle_mass')
QUEST_LABELS = {
    'arrive_point': '抵达坐标点',
    'arrive_target': '抵达目标天体',
    'talk_to_person': '与指定人物对话',
    'dock_city': '在太空城停泊',
    'install_upgrade': '安装指定装备',
    'recycle_mass': '回收指定质量物资',
}
# 装备清单来自 data/equipment.json（与游戏共用一份配置）；读不到时回退到内置五项，
# 保证编辑器仍能打开旧文件。新增改装只需要改 JSON，这里不用再跟着改。
EQUIPMENT_PATH = os.path.join(PROJECT_ROOT, 'data', 'equipment.json')
FALLBACK_UPGRADES = ('computer', 'fuel', 'shield', 'thruster', 'capture_net')


def load_equipment(path=EQUIPMENT_PATH):
    """返回 (全部装备 id, id->名称, 可解锁装备 [(id, 名称)])。"""
    try:
        with open(path, 'rb') as handle:
            data = json.loads(handle.read(MAX_BYTES + 1).decode('utf-8'))
        equipment = data.get('equipment')
        if not isinstance(equipment, dict) or not equipment:
            raise ValueError('equipment 为空')
        labels = {}
        unlockable = []
        for key, entry in equipment.items():
            if not isinstance(entry, dict):
                continue
            labels[key] = str(entry.get('name', key))
            if bool(entry.get('requires_unlock', False)):
                unlockable.append((key, labels[key]))
        if not labels:
            raise ValueError('equipment 为空')
        return tuple(labels), labels, tuple(unlockable)
    except Exception:
        labels = {key: key for key in FALLBACK_UPGRADES}
        return FALLBACK_UPGRADES, labels, ()


UPGRADE_IDS, UPGRADE_LABELS, UNLOCKABLE_UPGRADES = load_equipment()
UNLOCKABLE_IDS = tuple(key for key, _ in UNLOCKABLE_UPGRADES)
UNLOCK_NO_CHOICE = '（不解锁装备）'
UNLOCK_LABELS = {UNLOCK_NO_CHOICE: ''}
for _key, _name in UNLOCKABLE_UPGRADES:
    UNLOCK_LABELS[_name] = _key
LABEL_QUESTS = {label: kind for kind, label in QUEST_LABELS.items()}
KIND_LABELS = {'planet': '行星', 'city': '太空城'}

# 人物台词候选（speech）与运行期 StoryConditions 的白名单保持一致。
# 键分成四类：列表、数字、布尔、字符串，编辑器按类型解析文本，写错类型保存时就报。
SPEECH_FIELDS = ('id', 'when', 'lines', 'once', 'set_flags')
WHEN_LIST_KEYS = ('quests_done', 'quests_active', 'quests_awaiting', 'quests_untouched',
                  'visited', 'has_equipment', 'unlocked_equipment')
WHEN_NUMBER_KEYS = ('stage_min', 'credits_min')
WHEN_BOOL_KEYS = ('offerable_quest',)
WHEN_TEXT_KEYS = ('planet_id',)
WHEN_FLAG_KEY = 'flags'
WHEN_KEYS = WHEN_LIST_KEYS + WHEN_NUMBER_KEYS + WHEN_BOOL_KEYS + WHEN_TEXT_KEYS + (WHEN_FLAG_KEY,)
WHEN_KEY_HINTS = {
    'quests_done': '已完成的委托 id，逗号分隔',
    'quests_active': '进行中的委托 id，逗号分隔',
    'quests_awaiting': '待复命的委托 id，逗号分隔',
    'quests_untouched': '从未接取的委托 id，逗号分隔',
    'visited': '去过的 planet_id，逗号分隔',
    'has_equipment': '船上已装的装备 id，逗号分隔',
    'unlocked_equipment': '已解锁的装备 id，逗号分隔',
    'stage_min': '教程阶段下限，整数',
    'credits_min': '信用点下限，整数',
    'offerable_quest': 'true/false：这次是否真能领到新委托',
    'planet_id': '当前所在行星的 planet_id',
    'flags': '剧情标记，name=true，逗号分隔',
}


def parse_when_text(text):
    """把「每行 key = 值」的文本解析成 when 字典，返回 (when, errors)。"""
    when = {}
    errors = []
    for raw_line in str(text).splitlines():
        line = raw_line.strip()
        if not line or line.startswith('#'):
            continue
        if '=' not in line:
            errors.append(f'条件行缺少「=」：{line}')
            continue
        key, _, value = line.partition('=')
        key = key.strip()
        value = value.strip()
        if key not in WHEN_KEYS:
            errors.append(f'未知条件键：{key}（可用：{", ".join(WHEN_KEYS)}）')
            continue
        if key in WHEN_LIST_KEYS:
            items = [item.strip() for item in value.split(',') if item.strip()]
            if not items:
                errors.append(f'{key} 至少要写一个值')
                continue
            when[key] = items
        elif key in WHEN_NUMBER_KEYS:
            try:
                when[key] = int(value)
            except ValueError:
                errors.append(f'{key} 必须是整数：{value}')
        elif key in WHEN_BOOL_KEYS:
            lowered = value.lower()
            if lowered in ('true', '1', 'yes', '是'):
                when[key] = True
            elif lowered in ('false', '0', 'no', '否'):
                when[key] = False
            else:
                errors.append(f'{key} 必须是 true 或 false：{value}')
        elif key == WHEN_FLAG_KEY:
            flags = {}
            for pair in value.split(','):
                pair = pair.strip()
                if not pair:
                    continue
                name, _, flag_value = pair.partition(':')
                name = name.strip()
                flag_value = flag_value.strip().lower()
                if not name:
                    errors.append(f'flags 里有空的标记名：{pair}')
                    continue
                if flag_value not in ('true', 'false'):
                    errors.append(f'flags 的值必须是 true/false：{pair}')
                    continue
                flags[name] = flag_value == 'true'
            if not flags:
                errors.append('flags 至少要写一个 name=true')
                continue
            when[key] = flags
        else:
            if not value:
                errors.append(f'{key} 不能为空')
            else:
                when[key] = value
    return when, errors


def format_when_text(when):
    """when 字典回写成「每行 key = 值」，与 parse_when_text 互逆。"""
    if not isinstance(when, dict):
        return ''
    lines = []
    for key, value in when.items():
        if key == WHEN_FLAG_KEY and isinstance(value, dict):
            pairs = [f'{name}:{"true" if bool(flag) else "false"}' for name, flag in value.items()]
            lines.append(f'{key} = {", ".join(pairs)}')
        elif isinstance(value, list):
            lines.append(f'{key} = {", ".join(str(item) for item in value)}')
        elif isinstance(value, bool):
            lines.append(f'{key} = {"true" if value else "false"}')
        else:
            lines.append(f'{key} = {value}')
    return '\n'.join(lines)


def format_when_summary(when):
    """列表里显示的一行条件摘要，让人不点开也能看出这条台词什么时候说。"""
    if not isinstance(when, dict) or not when:
        return '无条件'
    parts = []
    for key, value in when.items():
        if isinstance(value, list):
            parts.append(f'{key}={len(value)} 项')
        elif isinstance(value, dict):
            parts.append(f'flags={len(value)} 项')
        elif isinstance(value, bool):
            parts.append(f'{key}={"是" if value else "否"}')
        else:
            parts.append(f'{key}={value}')
    return ' 且 '.join(parts)


FLAG_PAIR = re.compile(r'^([A-Za-z0-9_\-\.]+)\s*[:=]\s*(true|false|1|0|yes|no|是|否)$', re.IGNORECASE)


def parse_flag_text(text):
    """set_flags 的文本框：name=true，逗号或换行分隔。返回 (flags, errors)。"""
    flags = {}
    errors = []
    for pair in str(text).replace('\n', ',').split(','):
        pair = pair.strip()
        if not pair:
            continue
        match = FLAG_PAIR.match(pair)
        if match is None:
            errors.append(f'标记要写成 name=true：{pair}')
            continue
        name = match.group(1)
        value = match.group(2).lower()
        flags[name] = value in ('true', '1', 'yes', '是')
    return flags, errors


def format_flag_text(flags):
    if not isinstance(flags, dict):
        return ''
    return ', '.join(f'{name}={"true" if bool(value) else "false"}' for name, value in flags.items())

CG_DIR = os.path.join(PROJECT_ROOT, 'data', 'cg')
CG_PREFIX = 'res://data/cg/'
CG_IMAGE_EXTENSIONS = ('png', 'jpg', 'jpeg', 'webp', 'svg', 'bmp', 'tres')
CG_TRIGGERS = ('map_enter', 'enter_object', 'quest_complete', 'reach_point')
CG_TRIGGER_LABELS = {
    'map_enter': '进入地图',
    'enter_object': '进入行星或太空城',
    'quest_complete': '完成某个任务',
    'reach_point': '到达某个地点',
}
CG_LABEL_TRIGGERS = {label: kind for kind, label in CG_TRIGGER_LABELS.items()}
CG_KIND_LABELS = {'': '不限', 'any': '不限', 'planet': '行星', 'city': '太空城'}
CG_KIND_VALUES = {'不限': '', '行星': 'planet', '太空城': 'city'}
CG_DEFAULT_RADIUS = 1000.0


# ---------------------------------------------------------------------------
# 地图：读、校验、写
# ---------------------------------------------------------------------------

def _is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _vector_ok(value, limit=1e9):
    return (isinstance(value, list) and len(value) == 2
            and all(_is_number(v) and abs(v) <= limit for v in value))


def _valid_id(value):
    return isinstance(value, str) and bool(ID_PATTERN.fullmatch(value))


def validate_map(data):
    """按 map_loader.gd:read_map 的规则校验地图，失败抛 ValueError。"""
    version = data.get('version') if isinstance(data, dict) else None
    if not isinstance(data, dict) or isinstance(version, bool) or not isinstance(version, int) or version != 1:
        raise ValueError('地图需要 version 为整数 1')
    objects = data.get('objects')
    if not isinstance(objects, list) or len(objects) > 1000:
        raise ValueError('objects 必须是长度不超过 1000 的数组')
    if 'ship' in data:
        ship = data['ship']
        if not isinstance(ship, dict) or not _vector_ok(ship.get('position')) or not _vector_ok(ship.get('velocity')):
            raise ValueError('ship 的 position 和 velocity 必须是范围在 ±10 亿内的二维数字')
    if 'cg_data_path' in data:
        value = data['cg_data_path']
        if not isinstance(value, str) or len(value) > 256:
            raise ValueError('cg_data_path 必须是不超过 256 字符的字符串')
        if (not value.startswith(CG_PREFIX) or not value.endswith('.json')
                or '..' in value or '\\' in value):
            raise ValueError('cg_data_path 必须是 res://data/cg/ 下的 JSON')
        if '/' in value[len(CG_PREFIX):]:
            raise ValueError('cg_data_path 必须直接位于 res://data/cg/ 下')
    ids = set()
    for obj in objects:
        if not isinstance(obj, dict):
            raise ValueError('objects 的每一项都必须是对象')
        kind = obj.get('type')
        if not isinstance(kind, str) or kind not in FIELDS:
            raise ValueError('对象的 type 必须是 planet / city / asteroid / debris')
        object_id = obj.get('id')
        if not _valid_id(object_id):
            raise ValueError(f'{object_id}：id 必须是 1–64 位英文字母、数字、下划线或连字符')
        if object_id in ids:
            raise ValueError(f'{object_id}：id 重复')
        ids.add(object_id)
        if not _vector_ok(obj.get('position')):
            raise ValueError(f'{object_id}：position 必须是范围在 ±10 亿内的二维数字')
        fields = obj.get('fields', {})
        if not isinstance(fields, dict):
            raise ValueError(f'{object_id}：fields 必须是对象')
        for key, value in fields.items():
            if not isinstance(key, str):
                raise ValueError(f'{object_id}：fields 的键必须是字符串')
            if kind == 'asteroid' and key in LEGACY_FIELDS:
                continue
            if key not in FIELDS[kind]:
                raise ValueError(f'{object_id}：fields 不支持字段 {key}')
            if key in VECTORS:
                if not _vector_ok(value):
                    raise ValueError(f'{object_id}：{key} 必须是范围在 ±10 亿内的二维数字')
                if key == 'city_size_m' and (value[0] <= 0 or value[1] <= 0):
                    raise ValueError(f'{object_id}：city_size_m 两个分量都必须大于零')
            elif key in STRINGS:
                if not isinstance(value, str) or len(value) > 256:
                    raise ValueError(f'{object_id}：{key} 必须是不超过 256 字符的字符串')
                if key == 'interaction_data_path' and (not value.startswith(RES_PREFIX) or not value.endswith('.json')
                                                      or '..' in value or '\\' in value):
                    raise ValueError(f'{object_id}：interaction_data_path 必须是 res://data/planets/ 下的 JSON')
            elif key == 'texture_id':
                if not _is_number(value) or value != int(value) or not -1 <= value <= 8:
                    raise ValueError(f'{object_id}：texture_id 必须是 -1 到 8 的整数')
            elif key == 'rotation_degrees_m':
                if not _is_number(value) or abs(value) > 360000:
                    raise ValueError(f'{object_id}：rotation_degrees_m 必须在 ±360000 度内')
            else:
                minimum = 0 if key in ZERO_ALLOWED else 1e-6
                if not _is_number(value) or value > 1e15 or value < minimum:
                    raise ValueError(f'{object_id}：{key} 数值超出范围')
                if key == 'style_index' and (value != int(value) or value > 2):
                    raise ValueError(f'{object_id}：style_index 必须是 0–2 的整数')
                if key == 'debris_count' and (value != int(value) or value > 32):
                    raise ValueError(f'{object_id}：debris_count 必须是 0–32 的整数')


def read_map(path):
    """读取并校验地图，保留 fields 嵌套结构原样返回。"""
    with open(path, 'rb') as handle:
        raw = handle.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError('地图文件不能超过 1 MiB')
    data = json.loads(raw.decode('utf-8'))
    validate_map(data)
    return data


def map_objects(map_data):
    """只返回 type 为 planet / city 的对象。"""
    if not isinstance(map_data, dict) or not isinstance(map_data.get('objects'), list):
        return []
    return [obj for obj in map_data['objects'] if isinstance(obj, dict) and obj.get('type') in KIND_LABELS]


def _unique_paths(paths):
    seen = set()
    result = []
    for path in paths:
        if not path:
            continue
        key = os.path.abspath(path)
        if key in seen:
            continue
        seen.add(key)
        result.append(path)
    return result


def scan_event_references(extra_maps=(), map_paths=None):
    """扫描地图里的 interaction_data_path，返回「事件文件 → 引用它的对象」索引。

    结构：{res 路径: [{"map": 地图名, "path": 地图路径, "id": 对象 id}, ...]}。
    这是判断「谁在用这份数据」的唯一依据：只看字段里的路径字符串，id 与文件名不参与匹配。
    """
    if map_paths is None:
        map_paths = sorted(glob.glob(os.path.join(MAPS_DIR, '*.json')))
    refs = {}
    for path in _unique_paths(list(map_paths) + list(extra_maps)):
        try:
            data = read_map(path)
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        map_name = os.path.splitext(os.path.basename(path))[0]
        for obj in map_objects(data):
            res_path = obj.get('fields', {}).get('interaction_data_path')
            if not isinstance(res_path, str) or not res_path:
                continue
            refs.setdefault(res_path, []).append({'map': map_name, 'path': path, 'id': obj.get('id', '?')})
    return refs


def describe_other_referrers(res_path, map_path, object_id, extra_maps=()):
    """返回「同一份事件数据还被谁引用」的可读文字，用于选中对象时的提示。"""
    refs = scan_event_references(extra_maps=extra_maps, map_paths=[map_path] if map_path else None)
    others = []
    for item in refs.get(res_path, []):
        same_map = os.path.abspath(str(item.get('path'))) == os.path.abspath(str(map_path))
        if same_map and item.get('id') == object_id:
            continue
        others.append(f"{item.get('map')}:{item.get('id')}")
    return others


def object_display_names(map_data):
    """interaction_data_path → 地图对象的显示名；同一份数据被多个对象引用时取第一个。"""
    names = {}
    for obj in map_objects(map_data):
        fields = obj.get('fields') if isinstance(obj.get('fields'), dict) else {}
        res_path = fields.get('interaction_data_path')
        if not isinstance(res_path, str) or not res_path or res_path in names:
            continue
        names[res_path] = str(fields.get('display_name') or obj.get('id') or res_path)
    return names


def persons_of(data):
    """取出事件 JSON 的 diplomacy.persons，异常结构一律当空数组。"""
    diplomacy = data.get('diplomacy') if isinstance(data, dict) else None
    persons = diplomacy.get('persons') if isinstance(diplomacy, dict) else None
    return persons if isinstance(persons, list) else []


def person_registry(map_data=None, current_path=None, current_data=None):
    """全项目人物索引：id → [人物条目]。

    「与指定人物对话」允许指向别的行星上的人（先在某处接委托，再飞去别处找当事人），
    所以下拉与校验都必须看全部 data/planets/*.json；只看当前文件会让这类委托根本填不出来。
    同一个人物 id 出现在多份文件时这里会记成多条，调用方据此报「运行期无法区分」。

    current_path/current_data 用于把编辑器里正在改、可能还没保存的人物也算进来。
    """
    names = object_display_names(map_data)
    registry = {}

    def add(person, res_path, fallback, planet_id):
        if not isinstance(person, dict):
            return
        person_id = person.get('id')
        if not isinstance(person_id, str) or not person_id.strip():
            return
        location = names.get(res_path) or fallback or str(person_id)
        name = str(person.get('name') or person_id)
        # 地点显示名可能重复（两张地图都叫「行星」），所以标签里用唯一的 planet_id 做锚点。
        where = planet_id or location
        registry.setdefault(person_id, []).append({
            'id': person_id,
            'name': name,
            'planet': location,
            'planet_id': str(planet_id or ''),
            'path': res_path,
            'label': f'{name}（{where}）· {person_id}',
        })

    # 当前文件已有内存数据时不再读磁盘，否则磁盘上的旧版本会把刚改的人物盖回去。
    skip_path = os.path.abspath(current_path) if (current_path and isinstance(current_data, dict)) else None
    for path in sorted(glob.glob(os.path.join(PLANET_DIR, '*.json'))):
        if skip_path and os.path.abspath(path) == skip_path:
            continue
        try:
            data = _read_planet_raw(path)
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        res_path = RES_PREFIX + os.path.basename(path)
        fallback = os.path.splitext(os.path.basename(path))[0]
        planet_id = str(data.get('planet_id') or fallback)
        for person in persons_of(data):
            add(person, res_path, fallback, planet_id)
    if isinstance(current_data, dict):
        res_path = RES_PREFIX + os.path.basename(current_path) if current_path else ''
        fallback = os.path.splitext(os.path.basename(current_path))[0] if current_path else str(current_data.get('planet_id', ''))
        planet_id = str(current_data.get('planet_id') or fallback)
        for person in persons_of(current_data):
            add(person, res_path, fallback, planet_id)
    return registry


def quest_registry(map_data=None, current_path=None, current_data=None):
    """全项目委托索引：id → [条目]。

    运行期 `QuestManager` 的任务表**只按委托 id 建键**，两份 JSON 用同一个 id 会互相顶掉：
    接了 A 星的 `quest_1`，B 星的 `quest_1` 就会显示成「已接取」，接受按钮直接变灰。
    所以 id 必须全项目唯一，校验要看全部 data/planets/*.json，而不是只看当前文件。
    条目里的 `current` 标记当前正在编辑（内存）的那份，用于把「和别的文件撞名」单独指出来。
    """
    registry = {}

    def add(quest, res_path, planet_id, is_current):
        if not isinstance(quest, dict):
            return
        quest_id = quest.get('id')
        if not isinstance(quest_id, str) or not quest_id.strip():
            return
        registry.setdefault(quest_id, []).append({
            'id': quest_id,
            'path': res_path,
            'planet_id': str(planet_id or ''),
            'title': str(quest.get('title') or ''),
            'current': is_current,
        })

    def add_person_quests(container, res_path, planet_id, is_current):
        for person in persons_of(container):
            quests = person.get('quests') if isinstance(person, dict) else None
            if not isinstance(quests, list):
                continue
            for quest in quests:
                add(quest, res_path, planet_id, is_current)

    skip_path = os.path.abspath(current_path) if (current_path and isinstance(current_data, dict)) else None
    for path in sorted(glob.glob(os.path.join(PLANET_DIR, '*.json'))):
        if skip_path and os.path.abspath(path) == skip_path:
            continue
        try:
            data = _read_planet_raw(path)
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        res_path = RES_PREFIX + os.path.basename(path)
        fallback = os.path.splitext(os.path.basename(path))[0]
        add_person_quests(data, res_path, str(data.get('planet_id') or fallback), False)
    if isinstance(current_data, dict):
        res_path = RES_PREFIX + os.path.basename(current_path) if current_path else ''
        fallback = os.path.splitext(os.path.basename(current_path))[0] if current_path else str(current_data.get('planet_id', ''))
        add_person_quests(current_data, res_path, str(current_data.get('planet_id') or fallback), True)
    return registry


# ---------------------------------------------------------------------------
# 事件 JSON：路径、读、校验、写
# ---------------------------------------------------------------------------

def res_to_disk(res_path):
    if not isinstance(res_path, str) or not res_path.startswith(RES_PREFIX) or not res_path.endswith('.json'):
        raise ValueError('事件数据路径必须是 res://data/planets/ 下的 JSON')
    if '..' in res_path or '\\' in res_path:
        raise ValueError('事件数据路径不能包含 .. 或反斜杠')
    name = res_path[len(RES_PREFIX):]
    if not name or '/' in name:
        raise ValueError('事件数据路径必须直接位于 res://data/planets/ 下')
    return os.path.join(PLANET_DIR, name)


def disk_to_res(path):
    absolute = os.path.abspath(path)
    root = os.path.abspath(PLANET_DIR)
    try:
        relative = os.path.relpath(absolute, root)
    except ValueError as exc:
        raise ValueError('文件必须位于 ' + PLANET_DIR) from exc
    if relative.startswith('..') or os.path.isabs(relative) or os.sep in relative or '..' in relative:
        raise ValueError('文件必须位于 ' + PLANET_DIR)
    if not absolute.lower().endswith('.json'):
        raise ValueError('事件数据文件必须以 .json 结尾')
    return RES_PREFIX + relative.replace(os.sep, '/')


def _non_empty_text(value, limit=TEXT_LIMIT):
    return isinstance(value, str) and 0 < len(value.strip()) and len(value) <= limit


def _integer(value):
    return isinstance(value, int) and not isinstance(value, bool) or _is_number(value) and value == int(value)


def when_errors(when, item, quests_index=None):
    """when 字典的键白名单与值类型校验；quests_index 传了就顺带查引用的委托是否存在。"""
    errors = []
    if not isinstance(when, dict):
        return [f'{item}：when 必须是对象']
    for key, value in when.items():
        if key not in WHEN_KEYS:
            errors.append(f'{item}：when 含有未知条件键「{key}」（可用：{"、".join(WHEN_KEYS)}）')
            continue
        if key in WHEN_LIST_KEYS:
            if not isinstance(value, list) or not value:
                errors.append(f'{item}：when.{key} 必须是非空数组')
                continue
            for entry_id in value:
                if not isinstance(entry_id, str) or not entry_id.strip():
                    errors.append(f'{item}：when.{key} 里必须是非空字符串')
                elif key.startswith('quests_') and quests_index is not None and entry_id not in quests_index:
                    errors.append(f'{item}：when.{key} 引用了不存在的委托「{entry_id}」')
        elif key in WHEN_NUMBER_KEYS:
            if not isinstance(value, int) or isinstance(value, bool):
                errors.append(f'{item}：when.{key} 必须是整数')
        elif key in WHEN_BOOL_KEYS:
            if not isinstance(value, bool):
                errors.append(f'{item}：when.{key} 必须是 true 或 false')
        elif key == WHEN_FLAG_KEY:
            if not isinstance(value, dict) or not value:
                errors.append(f'{item}：when.flags 必须是非空对象')
                continue
            for name, flag in value.items():
                if not isinstance(name, str) or not name.strip():
                    errors.append(f'{item}：when.flags 的标记名必须是非空字符串')
                elif not isinstance(flag, bool):
                    errors.append(f'{item}：when.flags[{name}] 必须是 true 或 false')
        else:
            if not _non_empty_text(value):
                errors.append(f'{item}：when.{key} 必须是非空字符串')
    return errors


def collect_speech_errors(person, label, person_id, quests_index=None):
    """台词候选 speech 的结构校验，规则与运行期 port_session._validate_speech 同源。"""
    where = f'{label}（{person_id}）'
    speech = person.get('speech')
    if 'speech' not in person:
        return []
    if not isinstance(speech, list):
        return [f'{where}：speech 必须是数组']
    if not speech:
        return [f'{where}：speech 不能是空数组（没有候选就删掉该字段）']
    errors = []
    used = set()
    for index, entry in enumerate(speech):
        item = f'{where} speech[{index}]'
        if not isinstance(entry, dict):
            errors.append(f'{item} 必须是对象')
            continue
        for key in entry:
            if key not in SPEECH_FIELDS:
                errors.append(f'{item} 含有未知字段「{key}」（可用：{" / ".join(SPEECH_FIELDS)}）')
        identifier = entry.get('id')
        if identifier is not None:
            if not _non_empty_text(identifier) or ID_PATTERN.fullmatch(str(identifier)) is None:
                errors.append(f'{item}：id 只能是 1–64 位字母、数字、下划线或连字符')
            elif identifier in used:
                errors.append(f'{item}：同一人物下 id 重复（{identifier}）')
            else:
                used.add(identifier)
        lines = entry.get('lines')
        if isinstance(lines, str):
            lines = [lines]
        if not isinstance(lines, list) or not lines:
            errors.append(f'{item}：lines 必须是非空字符串数组')
        else:
            for line_index, line in enumerate(lines):
                if not isinstance(line, str) or not line.strip():
                    errors.append(f'{item}：lines[{line_index}] 必须是非空字符串')
                elif len(line) > TEXT_LIMIT:
                    errors.append(f'{item}：lines[{line_index}] 不能超过 4000 字符')
        if 'when' in entry:
            errors.extend(when_errors(entry['when'], item, quests_index))
        if 'once' in entry and not isinstance(entry['once'], bool):
            errors.append(f'{item}：once 必须是 true 或 false')
        if 'set_flags' in entry:
            flags = entry['set_flags']
            if not isinstance(flags, dict):
                errors.append(f'{item}：set_flags 必须是对象')
            else:
                for name, flag in flags.items():
                    if not isinstance(name, str) or not name.strip():
                        errors.append(f'{item}：set_flags 的标记名必须是非空字符串')
                    elif not isinstance(flag, bool):
                        errors.append(f'{item}：set_flags[{name}] 必须是 true 或 false')
    return errors


def collect_planet_errors(data, map_data=None, registry=None, quests_index=None):
    """收集事件 JSON 的全部错误，中文描述，最多 50 条。

    registry 是 person_registry() 的结果：传了它就允许「与指定人物对话」指向别的
    行星上的人；不传则退回只认同文件人物（CLI 自检与老测试用的就是这条路）。
    quests_index 是 quest_registry() 的结果：传了就额外检查委托 id 是否与别的行星撞名。
    """
    errors = []

    def add(message):
        if len(errors) < 50:
            errors.append(message)

    if not isinstance(data, dict):
        return ['事件数据根节点必须是对象']
    if not _integer(data.get('schema_version')) or data.get('schema_version') != 1:
        add('schema_version 必须是整数 1')
    if not _non_empty_text(data.get('planet_id')):
        add('planet_id 必须是非空字符串（不超过 4000 字符）')
    if not _non_empty_text(data.get('name')):
        add('name 必须是非空字符串（不超过 4000 字符）')

    events = data.get('events')
    if not isinstance(events, list):
        add('events 必须是数组')
        events = []
    else:
        seen = set()
        for index, event in enumerate(events):
            label = f'events[{index}]'
            if not isinstance(event, dict):
                add(f'{label} 必须是对象')
                continue
            event_id = event.get('id')
            if not _non_empty_text(event_id):
                add(f'{label}：id 必须是非空字符串')
            elif not ID_PATTERN.fullmatch(event_id):
                add(f'{label}：id 只能是 1–64 位字母、数字、下划线或连字符')
            elif event_id in seen:
                add(f'{label}：事件 id 重复（{event_id}）')
            else:
                seen.add(event_id)
            for key in ('title', 'body'):
                if not _non_empty_text(event.get(key)):
                    add(f'{label}（{event_id}）：{key} 必须是非空字符串且不超过 4000 字符')

    diplomacy = data.get('diplomacy')
    persons = diplomacy.get('persons') if isinstance(diplomacy, dict) else None
    if not isinstance(diplomacy, dict):
        add('diplomacy 必须是对象')
        persons = []
    elif not isinstance(persons, list):
        add('diplomacy.persons 必须是数组')
        persons = []

    person_ids = set()
    for index, person in enumerate(persons):
        label = f'persons[{index}]'
        if not isinstance(person, dict):
            add(f'{label} 必须是对象')
            continue
        person_id = person.get('id')
        if not _non_empty_text(person_id):
            add(f'{label}：id 必须是非空字符串')
        elif not ID_PATTERN.fullmatch(person_id):
            add(f'{label}：id 只能是 1–64 位字母、数字、下划线或连字符')
        elif person_id in person_ids:
            add(f'{label}：人物 id 重复（{person_id}）')
        else:
            person_ids.add(person_id)
        for key in ('name', 'role', 'description'):
            if not _non_empty_text(person.get(key)):
                add(f'{label}（{person_id}）：{key} 必须是非空字符串且不超过 4000 字符')
        if not isinstance(person.get('portrait'), str) or len(person.get('portrait', '')) > TEXT_LIMIT:
            add(f'{label}（{person_id}）：portrait 必须是字符串（允许空串）')
        for key in ('dialogue', 'quest_greeting'):
            if key not in person:
                continue
            entries = person[key]
            if not isinstance(entries, list):
                add(f'{label}（{person_id}）：{key} 必须是字符串数组')
            else:
                for line_index, line in enumerate(entries):
                    if not isinstance(line, str):
                        add(f'{label}（{person_id}）：{key}[{line_index}] 必须是字符串')
                    elif len(line) > TEXT_LIMIT:
                        add(f'{label}（{person_id}）：{key}[{line_index}] 不能超过 4000 字符')
        errors.extend(collect_speech_errors(person, label, person_id, quests_index))

    object_ids = set()
    city_ids = set()
    if isinstance(map_data, dict):
        for obj in map_objects(map_data):
            object_ids.add(obj.get('id'))
            if obj.get('type') == 'city':
                city_ids.add(obj.get('id'))

    quest_ids = set()
    for index, person in enumerate(persons):
        if not isinstance(person, dict) or 'quests' not in person:
            continue
        quests = person['quests']
        label = f'persons[{index}]（{person.get("id", "")}）'
        if not isinstance(quests, list):
            add(f'{label}：quests 必须是数组')
            continue
        for quest_index, quest in enumerate(quests):
            item = f'{label}.quests[{quest_index}]'
            if not isinstance(quest, dict):
                add(f'{item} 必须是对象')
                continue
            quest_id = quest.get('id')
            if not _non_empty_text(quest_id):
                add(f'{item}：id 必须是非空字符串')
            elif not ID_PATTERN.fullmatch(quest_id):
                add(f'{item}：id 只能是 1–64 位字母、数字、下划线或连字符')
            elif quest_id in quest_ids:
                add(f'{item}：委托 id 必须全局唯一（{quest_id} 重复）')
            else:
                quest_ids.add(quest_id)
                item = f'委托 {quest_id}'
                if quests_index is not None:
                    # 同一份数据的副本（临时文件、换绑路径）planet_id 相同，不算撞名。
                    planet_key = str(data.get('planet_id') or '')
                    others = [entry for entry in (quests_index.get(quest_id) or [])
                              if not entry.get('current') and str(entry.get('planet_id') or '') != planet_key]
                    if others:
                        where = '、'.join(sorted({str(entry.get('planet_id') or entry.get('path', '')) for entry in others}))
                        add(f'{item}：委托 id 与其它行星撞名（{where}），运行期按 id 建任务表会互相顶掉，请改成全项目唯一')
            for key in ('title', 'description'):
                if not _non_empty_text(quest.get(key)):
                    add(f'{item}：{key} 必须是非空字符串且不超过 4000 字符')
            kind = quest.get('type')
            if not isinstance(kind, str) or not kind.strip():
                add(f'{item}：type 必须是非空字符串')
                continue
            if kind not in QUEST_TYPES:
                add(f'{item}：type 必须是 {", ".join(QUEST_TYPES)} 之一')
                continue
            if not _integer(quest.get('count')) or quest.get('count') < 1:
                add(f'{item}：count 必须是 ≥1 的整数')
            if not _integer(quest.get('reward_credits')) or quest.get('reward_credits') < 0:
                add(f'{item}：reward_credits 必须是 ≥0 的整数')
            unlock = quest.get('reward_unlock')
            if unlock is not None:
                if not isinstance(unlock, str):
                    add(f'{item}：reward_unlock 必须是装备 id 字符串或留空')
                elif unlock.strip() and unlock.strip() not in UNLOCKABLE_IDS:
                    add(f'{item}：reward_unlock 必须是可由任务解锁的装备（{", ".join(UNLOCKABLE_IDS) or "无"}）')
            needs_return = quest.get('requires_return')
            if needs_return is not None and not isinstance(needs_return, bool):
                add(f'{item}：requires_return 必须是布尔值 true/false')
            return_line = quest.get('return_line')
            if return_line is not None:
                if not isinstance(return_line, str) or not return_line.strip():
                    add(f'{item}：return_line 必须是非空字符串')
                elif len(return_line) > TEXT_LIMIT:
                    add(f'{item}：return_line 不能超过 {TEXT_LIMIT} 个字符')
                elif needs_return is not True:
                    add(f'{item}：return_line 只有 requires_return=true 时才会被使用')
            if kind == 'arrive_point':
                if not _vector_ok(quest.get('position'), 1e12):
                    add(f'{item}：position 必须是 [x, y] 米制坐标')
                if not _is_number(quest.get('radius_m')) or quest.get('radius_m') <= 0:
                    add(f'{item}：radius_m 必须是正数')
            elif kind == 'arrive_target':
                target = quest.get('target')
                if not isinstance(target, str) or not target.strip():
                    add(f'{item}：target 必须是地图对象 id')
                elif map_data is not None and target not in object_ids:
                    add(f'{item}：target 必须是地图上存在的 planet 或 city（{target}）')
                if not _is_number(quest.get('radius_m')) or quest.get('radius_m') < 0:
                    add(f'{item}：radius_m 必须是 ≥0 的数字')
            elif kind == 'talk_to_person':
                target = quest.get('target')
                target_planet_id = quest.get('target_planet_id')
                if not isinstance(target, str) or not target.strip():
                    add(f'{item}：target 必须是人物 id')
                elif registry is None:
                    if target not in person_ids:
                        add(f'{item}：target 必须是同一文件里存在的人物（{target}）')
                else:
                    hits = registry.get(target) or []
                    if not hits:
                        add(f'{item}：target 必须是项目里存在的人物 id；人物可以在其它行星上（{target}）')
                    elif isinstance(target_planet_id, str) and target_planet_id.strip():
                        # 人物 id 允许跨行星重名，用 target_planet_id 指明是哪一颗星上的那个人。
                        if not any(entry.get('planet_id') == target_planet_id for entry in hits):
                            add(f'{item}：target_planet_id 指向的行星上没有人物 {target}（{target_planet_id}）')
                # 这三个字段只给界面提示与跨行星定位，不参与旧的 id 匹配。
                for key in ('target_name', 'target_planet', 'target_planet_id'):
                    hint = quest.get(key)
                    if hint is not None and (not isinstance(hint, str) or len(hint) > TEXT_LIMIT):
                        add(f'{item}：{key} 必须是字符串且不超过 {TEXT_LIMIT} 字符（仅用于界面提示）')
            elif kind == 'dock_city':
                target = quest.get('target')
                if target is not None and not isinstance(target, str):
                    add(f'{item}：target 必须是字符串或留空')
                elif isinstance(target, str) and target.strip():
                    if map_data is not None and target not in city_ids:
                        add(f'{item}：target 必须是地图上存在的太空城（{target}）')
            elif kind == 'install_upgrade':
                target = quest.get('target')
                if target is not None and not isinstance(target, str):
                    add(f'{item}：target 必须是装备 id 或留空')
                elif isinstance(target, str) and target.strip() and target.strip() not in UPGRADE_IDS:
                    add(f'{item}：target 必须是 {", ".join(UPGRADE_IDS)} 之一（留空表示任意装备）')
            elif kind == 'recycle_mass':
                mass = quest.get('target_mass_kg')
                if not _is_number(mass) or float(mass) <= 0:
                    add(f'{item}：target_mass_kg 必须是大于 0 的数字（单位 kg）')
    return errors[:50]


def validate_planet(data, map_data=None, registry=None, quests_index=None):
    """registry 为空时只接受同文件人物（旧行为）；传入全项目索引后允许跨行星目标。"""
    errors = collect_planet_errors(data, map_data, registry, quests_index)
    if errors:
        raise ValueError('；'.join(errors))


def _read_planet_raw(path):
    """只做大小与 JSON 语法检查，不做业务校验。

    人物索引要先读全部行星文件才能校验「目标人物是否存在」，所以索引不能反过来
    依赖带人物校验的 read_planet，否则会自己套自己。
    """
    with open(path, 'rb') as handle:
        raw = handle.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError('事件 JSON 不能超过 1 MiB')
    return json.loads(raw.decode('utf-8'))


def read_planet(path, map_data=None, registry=None):
    data = _read_planet_raw(path)
    # 默认按全项目校验：委托目标可能是别的行星上的人，同文件校验会把合法文件判成坏的。
    if registry is None:
        registry = person_registry(map_data)
    # 传 current_path/data 是为了让本文件的委托条目带上 current 标记，否则会被自己撞名。
    quests_index = quest_registry(map_data, path, data)
    validate_planet(data, map_data, registry, quests_index)
    return data


def write_json(path, data):
    """原子写入 UTF-8 JSON，保持 2 空格缩进与结尾换行。"""
    raw = (json.dumps(data, ensure_ascii=False, indent=JS_INDENT, allow_nan=False) + '\n').encode('utf-8')
    if len(raw) > MAX_BYTES:
        raise ValueError('JSON 文件不能超过 1 MiB')
    directory = os.path.dirname(os.path.abspath(path))
    if not os.path.isdir(directory):
        raise ValueError('目标目录不存在：' + directory)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='wb', dir=directory, delete=False) as handle:
            temporary = handle.name
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None and os.path.exists(temporary):
            os.unlink(temporary)


def write_map(path, data):
    validate_map(data)
    write_json(path, data)


def default_planet_data(object_id, display_name):
    return {
        'schema_version': 1,
        'planet_id': object_id,
        'name': display_name,
        'events': [],
        'diplomacy': {'persons': []},
    }


# ---------------------------------------------------------------------------
# CG 配置：路径、读、校验、写（与 scripts/progression/cg_controller.gd 同源）
# ---------------------------------------------------------------------------

def cg_res_to_disk(res_path):
    if not isinstance(res_path, str) or not res_path.startswith(CG_PREFIX) or not res_path.endswith('.json'):
        raise ValueError('CG 配置路径必须是 res://data/cg/ 下的 JSON')
    if '..' in res_path or '\\' in res_path:
        raise ValueError('CG 配置路径不能包含 .. 或反斜杠')
    name = res_path[len(CG_PREFIX):]
    if not name or '/' in name:
        raise ValueError('CG 配置必须直接位于 res://data/cg/ 下')
    return os.path.join(CG_DIR, name)


def cg_disk_to_res(path):
    absolute = os.path.abspath(path)
    root = os.path.abspath(CG_DIR)
    try:
        relative = os.path.relpath(absolute, root)
    except ValueError as exc:
        raise ValueError('文件必须位于 ' + CG_DIR) from exc
    if relative.startswith('..') or os.path.isabs(relative) or os.sep in relative or '..' in relative:
        raise ValueError('文件必须位于 ' + CG_DIR)
    if not absolute.lower().endswith('.json'):
        raise ValueError('CG 配置文件必须以 .json 结尾')
    return CG_PREFIX + relative.replace(os.sep, '/')


def default_cg_data(map_id):
    return {'version': 1, 'map': map_id, 'cgs': []}


def _map_object_ids(map_data, kinds=None):
    if not isinstance(map_data, dict):
        return []
    ids = []
    for obj in map_data.get('objects', []) or []:
        if not isinstance(obj, dict):
            continue
        if kinds is not None and obj.get('type') not in kinds:
            continue
        if isinstance(obj.get('id'), str):
            ids.append(obj['id'])
    return ids


def _load_json_quiet(path):
    try:
        with open(path, 'rb') as handle:
            raw = handle.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            return None
        return json.loads(raw.decode('utf-8'))
    except (OSError, ValueError):
        return None


def cg_quest_ids(map_data):
    """扫描地图内各 planet/city 的事件 JSON，收集所有委托 id，供 CG 的 quest_complete 下拉用。"""
    found = set()
    for obj in map_objects(map_data or {}):
        res_path = obj.get('fields', {}).get('interaction_data_path')
        if not res_path:
            continue
        try:
            data = _load_json_quiet(res_to_disk(res_path))
        except ValueError:
            continue
        if not isinstance(data, dict):
            continue
        diplomacy = data.get('diplomacy')
        persons = diplomacy.get('persons') if isinstance(diplomacy, dict) else None
        for person in persons if isinstance(persons, list) else []:
            quests = person.get('quests') if isinstance(person, dict) else None
            for quest in quests if isinstance(quests, list) else []:
                if isinstance(quest, dict) and isinstance(quest.get('id'), str) and quest['id']:
                    found.add(quest['id'])
    return sorted(found)


def cg_image_disk(res_path):
    """把 res:// 图片路径映射到磁盘，仅用于「文件是否存在」的提示，不参与硬校验。"""
    if not isinstance(res_path, str) or not res_path.startswith('res://') or '..' in res_path or '\\' in res_path:
        return None
    return os.path.join(PROJECT_ROOT, res_path[len('res://'):].replace('/', os.sep))


def _cg_trigger_errors(trigger, where, map_data=None, owner=''):
    errors = []
    if not isinstance(trigger, dict):
        return [f'{where}：trigger 必须是对象']
    kind = trigger.get('type')
    if kind not in CG_TRIGGERS:
        return [f'{where}：trigger.type 必须是 ' + ', '.join(CG_TRIGGERS) + ' 之一']
    if kind == 'map_enter':
        value = trigger.get('map')
        if not isinstance(value, str) or not value.strip():
            errors.append(f'{where}：进入地图需要 map（地图文件名，* 表示任意地图）')
        elif owner and value != '*' and os.path.splitext(os.path.basename(value))[0] != owner:
            errors.append(f'{where}：trigger.map 必须是 {owner} 或 *（本文件归属 {owner}）')
    elif kind == 'enter_object':
        value = trigger.get('object')
        if not isinstance(value, str) or not value.strip():
            errors.append(f'{where}：进入行星/太空城需要 object（地图对象 id，* 表示任意）')
        elif value != '*' and map_data is not None:
            if value not in _map_object_ids(map_data, ('planet', 'city')):
                errors.append(f'{where}：object {value} 不是本图里的行星/太空城 id')
        kind_value = trigger.get('kind', '')
        if kind_value not in ('', 'any', 'planet', 'city'):
            errors.append(f'{where}：kind 必须是 不限 / planet / city')
    elif kind == 'quest_complete':
        value = trigger.get('quest')
        if not isinstance(value, str) or not value.strip():
            errors.append(f'{where}：完成委托需要 quest（委托 id）')
    else:
        point = trigger.get('position')
        if not (isinstance(point, list) and len(point) == 2 and all(_is_number(v) for v in point)):
            errors.append(f'{where}：到达地点需要 position（[x, y] 米）')
        elif any(abs(v) > 1e9 for v in point):
            errors.append(f'{where}：position 分量绝对值不超过 1e9')
        radius = trigger.get('radius_m')
        if not _is_number(radius) or radius <= 0 or radius > 1e9:
            errors.append(f'{where}：到达地点需要 radius_m（大于 0 的米数）')
    return errors


def collect_cg_errors(data, map_data=None):
    """收集 CG 配置的全部错误，中文描述，最多 50 条。"""
    errors = []
    if not isinstance(data, dict):
        return ['CG 配置根必须是 JSON 对象']
    version = data.get('version')
    if isinstance(version, bool) or not isinstance(version, int) or version != 1:
        errors.append('version 必须是整数 1')
    owner = data.get('map')
    if owner is not None:
        if not isinstance(owner, str) or len(owner) > 256:
            errors.append('map 必须是不超过 256 字符的字符串')
        else:
            owner = os.path.splitext(os.path.basename(owner))[0]
    else:
        owner = ''
    cgs = data.get('cgs')
    if not isinstance(cgs, list):
        errors.append('cgs 必须是数组')
        return errors
    seen = set()
    for index, item in enumerate(cgs):
        where = f'第 {index + 1} 条'
        if not isinstance(item, dict):
            errors.append(f'{where}：必须是对象')
            continue
        cg_id = item.get('id')
        if not isinstance(cg_id, str) or not cg_id.strip():
            errors.append(f'{where}：id 必须是非空字符串')
        elif not _valid_id(cg_id):
            errors.append(f'{where}：id 只能包含字母、数字、下划线和连字符，且不超过 64 字符')
        elif cg_id in seen:
            errors.append(f'{where}：id {cg_id} 重复')
        else:
            seen.add(cg_id)
            where = f'{where}（{cg_id}）'
        image = item.get('image')
        if not isinstance(image, str) or not image.strip():
            errors.append(f'{where}：image 必须是非空字符串')
        elif (not image.startswith('res://') or '..' in image or '\\' in image
              or os.path.splitext(image)[1].lower().lstrip('.') not in CG_IMAGE_EXTENSIONS):
            errors.append(f'{where}：image 必须是 res:// 下的图片（' + ', '.join(CG_IMAGE_EXTENSIONS) + '）')
        text = item.get('text')
        if not isinstance(text, str):
            errors.append(f'{where}：text 必须是字符串')
        elif len(text) > TEXT_LIMIT:
            errors.append(f'{where}：text 不超过 {TEXT_LIMIT} 字符')
        duration = item.get('duration')
        if not _is_number(duration) or duration <= 0 or duration > 3600:
            errors.append(f'{where}：duration 必须是 0–3600 之间的正数（现实秒）')
        for flag in ('once', 'skippable', 'enabled'):
            if flag in item and not isinstance(item[flag], bool):
                errors.append(f'{where}：{flag} 必须是 true 或 false')
        errors.extend(_cg_trigger_errors(item.get('trigger'), where, map_data, owner))
        if len(errors) >= 50:
            errors.append('错误过多，已截断')
            break
    return errors


def collect_cg_warnings(data, map_data=None):
    """不阻断保存、但值得提醒的问题：图片未交付、委托 id 写错、未声明归属。"""
    warnings = []
    if not isinstance(data, dict) or not isinstance(data.get('cgs'), list):
        return warnings
    owner = data.get('map') if isinstance(data.get('map'), str) else ''
    if not owner:
        warnings.append('本文件没有声明 map，运行时不做归属校验（建议填地图名）')
    quests = set(cg_quest_ids(map_data)) if map_data is not None else set()
    for item in data['cgs']:
        if not isinstance(item, dict):
            continue
        cg_id = str(item.get('id', '?'))
        disk = cg_image_disk(item.get('image'))
        if disk and not os.path.isfile(disk):
            warnings.append(f'{cg_id}：图片不存在（{item.get("image")}）')
        trigger = item.get('trigger')
        if isinstance(trigger, dict) and trigger.get('type') == 'quest_complete' and quests:
            quest_id = trigger.get('quest')
            if isinstance(quest_id, str) and quest_id and quest_id not in quests:
                warnings.append(f'{cg_id}：quest {quest_id} 不在本图任何事件 JSON 里')
        if len(warnings) >= 20:
            warnings.append('提示过多，已截断')
            break
    return warnings


def validate_cg(data, map_data=None):
    errors = collect_cg_errors(data, map_data)
    if errors:
        raise ValueError('；'.join(errors))


def read_cg(path):
    with open(path, 'rb') as handle:
        raw = handle.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError('CG JSON 不能超过 1 MiB')
    data = json.loads(raw.decode('utf-8'))
    validate_cg(data)
    return data


def _format_number(value):
    if value is None:
        return ''
    return repr(float(value))


def _parse_int(text, label):
    stripped = str(text).strip()
    if not stripped:
        raise ValueError(f'{label}必须是整数')
    try:
        value = float(stripped)
    except ValueError as exc:
        raise ValueError(f'{label}必须是整数') from exc
    if not math.isfinite(value) or value != int(value):
        raise ValueError(f'{label}必须是整数')
    return int(value)


def _parse_float(text, label):
    stripped = str(text).strip()
    if not stripped:
        raise ValueError(f'{label}必须是数字')
    try:
        value = float(stripped)
    except ValueError as exc:
        raise ValueError(f'{label}必须是数字') from exc
    if not math.isfinite(value):
        raise ValueError(f'{label}必须是有限数字')
    return value


# ---------------------------------------------------------------------------
# 图形界面
# ---------------------------------------------------------------------------

class Editor:
    def __init__(self, root):
        self.root = root
        root.title('行星 / 太空城 事件与委托编辑器')
        root.geometry('1280x800')
        self.map_data = None
        self.map_path = None
        self.map_saved = None
        self.object_id = None
        self.planet_data = None
        self.planet_path = None
        self.planet_res = None
        self.planet_saved = None
        self.planet_message = ''
        self.event_index = None
        self.person_index = None
        self.quest_index = None
        self.quest_person_index = None
        self.speech_index = None
        self.speech_person_index = None
        self.cg_data = None
        self.cg_path = None
        self.cg_res = None
        self.cg_saved = None
        self.cg_message = ''
        self.cg_index = None
        self._syncing = False
        self._sash_placed = False
        self._build()
        root.protocol('WM_DELETE_WINDOW', self.close)
        self.refresh_map_tree()
        self.refresh_all_tabs()
        self.set_control_state()
        self.update_status()

    # -- 构建界面 ---------------------------------------------------------
    def _build(self):
        root = self.root
        bar = ttk.Frame(root, padding=5)
        bar.pack(fill='x')
        self.open_button = ttk.Button(bar, text='打开地图 JSON', command=self.open_map)
        self.save_button = ttk.Button(bar, text='保存全部', command=self.save_all)
        self.check_button = ttk.Button(bar, text='校验', command=self.check_current)
        self.close_button = ttk.Button(bar, text='关闭', command=self.close)
        for button in (self.open_button, self.save_button, self.check_button, self.close_button):
            button.pack(side='left', padx=2)

        ttk.Label(
            root,
            foreground='#555555',
            text='① 打开地图 JSON　② 左侧选择行星或太空城　③ 编辑事件 / 人物 / 委托；「CG 剧情」页是地图级 CG 配置（保存全部会写回地图、事件与 CG 三份 JSON）',
        ).pack(anchor='w', padx=8)

        paned = ttk.PanedWindow(root, orient='horizontal')
        paned.pack(fill='both', expand=True, pady=(4, 0))
        self.paned = paned

        left = ttk.Frame(paned, padding=6, width=340)
        ttk.Label(left, text='地图对象', font=('', 11, 'bold')).pack(anchor='w')
        tree_frame = ttk.Frame(left)
        tree_frame.pack(fill='both', expand=True, pady=(4, 6))
        self.tree = ttk.Treeview(
            tree_frame,
            columns=('id', 'kind', 'name', 'data'),
            show='headings',
            selectmode='browse',
        )
        for column, text, width, anchor in (
            ('id', 'id', 92, 'w'),
            ('kind', '类型', 48, 'w'),
            ('name', '名称', 78, 'w'),
            ('data', '事件数据', 92, 'w'),
        ):
            self.tree.heading(column, text=text)
            self.tree.column(column, width=width, anchor=anchor, stretch=(column in ('name', 'data')))
        tree_scroll = ttk.Scrollbar(tree_frame, orient='vertical', command=self.tree.yview)
        self.tree.configure(yscrollcommand=tree_scroll.set)
        self.tree.pack(side='left', fill='both', expand=True)
        tree_scroll.pack(side='right', fill='y')
        self.tree.bind('<<TreeviewSelect>>', self.on_tree_select)

        first = ttk.Frame(left)
        first.pack(fill='x')
        second = ttk.Frame(left)
        second.pack(fill='x', pady=(4, 0))
        self.create_button = ttk.Button(first, text='创建事件 JSON', command=self.create_planet_file)
        self.choose_button = ttk.Button(first, text='选择已有 JSON', command=self.choose_planet_file)
        self.copy_button = ttk.Button(second, text='复制为新文件', command=self.copy_planet_file)
        self.explore_button = ttk.Button(second, text='在资源管理器中打开', command=self.open_planet_dir)
        self.create_button.pack(side='left', padx=(0, 2))
        self.choose_button.pack(side='left', padx=2)
        self.copy_button.pack(side='left', padx=(0, 2))
        self.explore_button.pack(side='left', padx=2)

        right = ttk.Frame(paned, padding=6)
        self.object_label = ttk.Label(right, text='未选择对象', font=('', 11, 'bold'), wraplength=860, justify='left')
        self.object_label.pack(anchor='w', pady=(0, 4))
        self.notebook = ttk.Notebook(right)
        self.notebook.pack(fill='both', expand=True)
        self._build_event_tab()
        self._build_person_tab()
        self._build_quest_tab()
        self._build_speech_tab()
        self._build_cg_tab()

        paned.add(left, weight=0)
        paned.add(right, weight=1)

        self.status = ttk.Label(root, text='', anchor='w', padding=(8, 3))
        self.status.pack(fill='x')
        root.bind('<KeyRelease>', lambda event: self.update_status())
        paned.bind('<Configure>', self.place_sash)

    def place_sash(self, event=None):
        """窗口真正映射后再把左栏定到约 340 像素，避免初始化时被压成 0。"""
        if self._sash_placed or self.paned.winfo_width() < 400:
            return
        self._sash_placed = True
        try:
            self.paned.sashpos(0, 340)
        except tk.TclError:
            self._sash_placed = False

    def _text_box(self, parent, row, label, height):
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky='nw', pady=2)
        frame = ttk.Frame(parent)
        frame.grid(row=row, column=1, sticky='nsew', padx=(6, 0), pady=2)
        text = tk.Text(frame, height=height, width=42, wrap='word', undo=True)
        scroll = ttk.Scrollbar(frame, orient='vertical', command=text.yview)
        text.configure(yscrollcommand=scroll.set)
        text.pack(side='left', fill='both', expand=True)
        scroll.pack(side='right', fill='y')
        return text

    def _list_column(self, parent):
        frame = ttk.Frame(parent)
        frame.pack(side='left', fill='y')
        listing = tk.Listbox(frame, width=30, exportselection=False, height=16)
        scroll = ttk.Scrollbar(frame, orient='vertical', command=listing.yview)
        listing.configure(yscrollcommand=scroll.set)
        listing.pack(side='left', fill='both', expand=True)
        scroll.pack(side='right', fill='y')
        return listing

    def _build_event_tab(self):
        tab = ttk.Frame(self.notebook, padding=6)
        self.notebook.add(tab, text='事件')
        self.event_hint = ttk.Label(tab, text='', foreground='#a33b3b', wraplength=820)
        self.event_hint.pack(fill='x')
        body = ttk.Frame(tab)
        body.pack(fill='both', expand=True, pady=(2, 0))
        self.event_list = self._list_column(body)
        self.event_list.bind('<<ListboxSelect>>', self.on_event_select)
        self.event_form = ttk.Frame(body)
        self.event_form.pack(side='left', fill='both', expand=True, padx=(8, 0))
        self.event_form.columnconfigure(1, weight=1)
        self.event_id_var = tk.StringVar()
        self.event_title_var = tk.StringVar()
        ttk.Label(self.event_form, text='id').grid(row=0, column=0, sticky='w', pady=2)
        ttk.Entry(self.event_form, textvariable=self.event_id_var).grid(row=0, column=1, sticky='ew', padx=(6, 0), pady=2)
        ttk.Label(self.event_form, text='title').grid(row=1, column=0, sticky='w', pady=2)
        ttk.Entry(self.event_form, textvariable=self.event_title_var).grid(row=1, column=1, sticky='ew', padx=(6, 0), pady=2)
        self.event_body = self._text_box(self.event_form, 2, 'body', 8)
        self.event_form.rowconfigure(2, weight=1)
        buttons = ttk.Frame(tab)
        buttons.pack(fill='x', pady=(6, 0))
        for text, command in (
            ('新增', self.add_event),
            ('删除', self.delete_event),
            ('上移', lambda: self.move_event(-1)),
            ('下移', lambda: self.move_event(1)),
            ('应用', self.apply_event),
        ):
            ttk.Button(buttons, text=text, command=command).pack(side='left', padx=2)

    def _build_person_tab(self):
        tab = ttk.Frame(self.notebook, padding=6)
        self.notebook.add(tab, text='人物')
        self.person_hint = ttk.Label(tab, text='', foreground='#a33b3b', wraplength=820)
        self.person_hint.pack(fill='x')
        body = ttk.Frame(tab)
        body.pack(fill='both', expand=True, pady=(2, 0))
        self.person_list = self._list_column(body)
        self.person_list.bind('<<ListboxSelect>>', self.on_person_select)
        self.person_form = ttk.Frame(body)
        self.person_form.pack(side='left', fill='both', expand=True, padx=(8, 0))
        self.person_form.columnconfigure(1, weight=1)
        self.person_id_var = tk.StringVar()
        self.person_name_var = tk.StringVar()
        self.person_role_var = tk.StringVar()
        self.person_portrait_var = tk.StringVar()
        rows = (
            ('id', self.person_id_var),
            ('name', self.person_name_var),
            ('role', self.person_role_var),
        )
        for row, (label, var) in enumerate(rows):
            ttk.Label(self.person_form, text=label).grid(row=row, column=0, sticky='w', pady=2)
            ttk.Entry(self.person_form, textvariable=var).grid(row=row, column=1, sticky='ew', padx=(6, 0), pady=2)
        ttk.Label(self.person_form, text='portrait').grid(row=3, column=0, sticky='w', pady=2)
        portrait_row = ttk.Frame(self.person_form)
        portrait_row.grid(row=3, column=1, sticky='ew', padx=(6, 0), pady=2)
        ttk.Entry(portrait_row, textvariable=self.person_portrait_var).pack(side='left', fill='x', expand=True)
        ttk.Button(portrait_row, text='浏览…', command=self.browse_portrait).pack(side='left', padx=(4, 0))
        self.person_description = self._text_box(self.person_form, 4, 'description', 4)
        self.person_dialogue = self._text_box(self.person_form, 5, 'dialogue（每行一句）', 5)
        self.person_quest_greeting = self._text_box(
            self.person_form, 6, 'quest_greeting（有可接委托时才说，每行一句）', 3)
        self.person_form.rowconfigure(5, weight=1)
        self.person_form.rowconfigure(6, weight=1)
        buttons = ttk.Frame(tab)
        buttons.pack(fill='x', pady=(6, 0))
        for text, command in (
            ('新增', self.add_person),
            ('删除', self.delete_person),
            ('上移', lambda: self.move_person(-1)),
            ('下移', lambda: self.move_person(1)),
            ('应用', self.apply_person),
        ):
            ttk.Button(buttons, text=text, command=command).pack(side='left', padx=2)

    def _build_quest_tab(self):
        tab = ttk.Frame(self.notebook, padding=6)
        self.notebook.add(tab, text='委托')
        self.quest_hint = ttk.Label(tab, text='', foreground='#a33b3b', wraplength=820)
        self.quest_hint.pack(fill='x')
        owner_row = ttk.Frame(tab)
        owner_row.pack(fill='x', pady=(2, 4))
        ttk.Label(owner_row, text='人物').pack(side='left')
        self.quest_person_var = tk.StringVar()
        self.quest_person_combo = ttk.Combobox(owner_row, textvariable=self.quest_person_var, state='readonly', width=34)
        self.quest_person_combo.pack(side='left', padx=(6, 0))
        self.quest_person_combo.bind('<<ComboboxSelected>>', self.on_quest_person_change)

        body = ttk.Frame(tab)
        body.pack(fill='both', expand=True)
        self.quest_list = self._list_column(body)
        self.quest_list.bind('<<ListboxSelect>>', self.on_quest_select)
        self.quest_form = ttk.Frame(body)
        self.quest_form.pack(side='left', fill='both', expand=True, padx=(8, 0))
        self.quest_form.columnconfigure(1, weight=1)
        self.quest_id_var = tk.StringVar()
        self.quest_title_var = tk.StringVar()
        self.quest_type_var = tk.StringVar()
        self.quest_target_var = tk.StringVar()
        # 「与指定人物对话」的目标下拉显示「名字（行星）· 人物id」，两个方向都要能翻。
        self._person_label_to_id = {}
        self._person_label_to_entry = {}
        self._person_id_to_label = {}
        self._person_id_planet_to_label = {}
        self.quest_count_var = tk.StringVar()
        self.quest_reward_var = tk.StringVar()
        self.quest_unlock_var = tk.StringVar()
        self.quest_requires_return_var = tk.BooleanVar(value=False)
        self.quest_return_line_var = tk.StringVar()
        self.quest_x_var = tk.StringVar()
        self.quest_y_var = tk.StringVar()
        self.quest_radius_var = tk.StringVar()
        ttk.Label(self.quest_form, text='id').grid(row=0, column=0, sticky='w', pady=2)
        ttk.Entry(self.quest_form, textvariable=self.quest_id_var).grid(row=0, column=1, sticky='ew', padx=(6, 0), pady=2)
        ttk.Label(self.quest_form, text='title').grid(row=1, column=0, sticky='w', pady=2)
        ttk.Entry(self.quest_form, textvariable=self.quest_title_var).grid(row=1, column=1, sticky='ew', padx=(6, 0), pady=2)
        self.quest_description = self._text_box(self.quest_form, 2, 'description', 3)
        ttk.Label(self.quest_form, text='type').grid(row=3, column=0, sticky='w', pady=2)
        self.quest_type_combo = ttk.Combobox(
            self.quest_form,
            textvariable=self.quest_type_var,
            state='readonly',
            values=list(QUEST_LABELS.values()),
        )
        self.quest_type_combo.grid(row=3, column=1, sticky='ew', padx=(6, 0), pady=2)
        self.quest_type_combo.bind('<<ComboboxSelected>>', self.on_quest_type_change)
        ttk.Label(self.quest_form, text='target').grid(row=4, column=0, sticky='w', pady=2)
        self.quest_target_combo = ttk.Combobox(self.quest_form, textvariable=self.quest_target_var)
        self.quest_target_combo.grid(row=4, column=1, sticky='ew', padx=(6, 0), pady=2)
        ttk.Label(self.quest_form, text='count').grid(row=5, column=0, sticky='w', pady=2)
        self.quest_count_entry = ttk.Entry(self.quest_form, textvariable=self.quest_count_var)
        self.quest_count_entry.grid(row=5, column=1, sticky='ew', padx=(6, 0), pady=2)
        ttk.Label(self.quest_form, text='reward_credits').grid(row=6, column=0, sticky='w', pady=2)
        ttk.Entry(self.quest_form, textvariable=self.quest_reward_var).grid(row=6, column=1, sticky='ew', padx=(6, 0), pady=2)
        ttk.Label(self.quest_form, text='reward_unlock（解锁装备）').grid(row=7, column=0, sticky='w', pady=2)
        self.quest_unlock_combo = ttk.Combobox(
            self.quest_form,
            textvariable=self.quest_unlock_var,
            state='readonly',
            values=list(UNLOCK_LABELS.keys()),
        )
        self.quest_unlock_combo.grid(row=7, column=1, sticky='ew', padx=(6, 0), pady=2)
        ttk.Label(self.quest_form, text='position（x, y）').grid(row=8, column=0, sticky='w', pady=2)
        position_row = ttk.Frame(self.quest_form)
        position_row.grid(row=8, column=1, sticky='ew', padx=(6, 0), pady=2)
        self.quest_x_entry = ttk.Entry(position_row, textvariable=self.quest_x_var, width=16)
        self.quest_y_entry = ttk.Entry(position_row, textvariable=self.quest_y_var, width=16)
        self.quest_x_entry.pack(side='left')
        ttk.Label(position_row, text=',').pack(side='left', padx=4)
        self.quest_y_entry.pack(side='left')
        ttk.Label(self.quest_form, text='radius_m').grid(row=9, column=0, sticky='w', pady=2)
        self.quest_radius_entry = ttk.Entry(self.quest_form, textvariable=self.quest_radius_var)
        self.quest_radius_entry.grid(row=9, column=1, sticky='ew', padx=(6, 0), pady=2)
        self.quest_return_check = ttk.Checkbutton(
            self.quest_form,
            text='需要返回复命（目标完成后回到委托人处交谈才算完成、才发奖励）',
            variable=self.quest_requires_return_var,
            command=self.on_quest_return_toggle,
        )
        self.quest_return_check.grid(row=10, column=0, columnspan=2, sticky='w', pady=(6, 2))
        ttk.Label(self.quest_form, text='return_line（复命台词，可留空）').grid(row=11, column=0, sticky='w', pady=2)
        self.quest_return_line_entry = ttk.Entry(self.quest_form, textvariable=self.quest_return_line_var)
        self.quest_return_line_entry.grid(row=11, column=1, sticky='ew', padx=(6, 0), pady=2)
        buttons = ttk.Frame(tab)
        buttons.pack(fill='x', pady=(6, 0))
        for text, command in (('新增', self.add_quest), ('删除', self.delete_quest), ('应用', self.apply_quest)):
            ttk.Button(buttons, text=text, command=command).pack(side='left', padx=2)

    def _build_speech_tab(self):
        """台词候选页：一个人可以有多套台词，每套带条件，运行期按顺序取第一条成立的。"""
        tab = ttk.Frame(self.notebook, padding=6)
        self.notebook.add(tab, text='台词')
        self.speech_hint = ttk.Label(tab, text='', foreground='#a33b3b', wraplength=860)
        self.speech_hint.pack(fill='x')
        owner_row = ttk.Frame(tab)
        owner_row.pack(fill='x', pady=(2, 4))
        ttk.Label(owner_row, text='人物').pack(side='left')
        self.speech_person_var = tk.StringVar()
        self.speech_person_combo = ttk.Combobox(owner_row, textvariable=self.speech_person_var, state='readonly', width=34)
        self.speech_person_combo.pack(side='left', padx=(6, 0))
        self.speech_person_combo.bind('<<ComboboxSelected>>', self.on_speech_person_change)

        body = ttk.Frame(tab)
        body.pack(fill='both', expand=True)
        self.speech_list = self._list_column(body)
        self.speech_list.bind('<<ListboxSelect>>', self.on_speech_select)
        form = ttk.Frame(body)
        form.pack(side='left', fill='both', expand=True, padx=(8, 0))
        form.columnconfigure(1, weight=1)
        self.speech_form = form
        self.speech_id_var = tk.StringVar()
        self.speech_once_var = tk.BooleanVar(value=False)
        ttk.Label(form, text='id').grid(row=0, column=0, sticky='w', pady=2)
        ttk.Entry(form, textvariable=self.speech_id_var).grid(row=0, column=1, sticky='ew', padx=(6, 0), pady=2)
        self.speech_when = self._text_box(form, 1, 'when（每行 key = 值，留空=无条件）', 6)
        self.speech_lines = self._text_box(form, 2, 'lines（每行一句）', 5)
        self.speech_flags = self._text_box(form, 3, 'set_flags（name=true，逗号分隔）', 2)
        ttk.Checkbutton(form, text='once（只播一次，播过记入存档）', variable=self.speech_once_var).grid(
            row=4, column=0, columnspan=2, sticky='w', pady=(4, 2))
        ttk.Label(form, text='条件键：' + '、'.join(WHEN_KEYS), foreground='#666').grid(
            row=5, column=0, columnspan=2, sticky='w')
        form.rowconfigure(1, weight=1)
        form.rowconfigure(2, weight=1)
        buttons = ttk.Frame(tab)
        buttons.pack(fill='x', pady=(6, 0))
        for text, command in (
            ('新增', self.add_speech),
            ('删除', self.delete_speech),
            ('上移', lambda: self.move_speech(-1)),
            ('下移', lambda: self.move_speech(1)),
            ('应用', self.apply_speech),
        ):
            ttk.Button(buttons, text=text, command=command).pack(side='left', padx=2)

    def _build_cg_tab(self):
        tab = ttk.Frame(self.notebook, padding=6)
        self.notebook.add(tab, text='CG 剧情')
        self.cg_hint = ttk.Label(tab, text='', foreground='#a33b3b', wraplength=860)
        self.cg_hint.pack(fill='x')
        bar = ttk.Frame(tab)
        bar.pack(fill='x', pady=(4, 0))
        self.cg_create_button = ttk.Button(bar, text='创建 CG 配置', command=self.create_cg_file)
        self.cg_choose_button = ttk.Button(bar, text='选择已有 CG 配置', command=self.choose_cg_file)
        self.cg_copy_button = ttk.Button(bar, text='复制为新文件', command=self.copy_cg_file)
        self.cg_explore_button = ttk.Button(bar, text='在资源管理器中打开', command=self.open_cg_dir)
        for button in (self.cg_create_button, self.cg_choose_button, self.cg_copy_button, self.cg_explore_button):
            button.pack(side='left', padx=2)

        body = ttk.Frame(tab)
        body.pack(fill='both', expand=True, pady=(6, 0))
        self.cg_list = self._list_column(body)
        self.cg_list.bind('<<ListboxSelect>>', self.on_cg_select)
        form = ttk.Frame(body)
        form.pack(side='left', fill='both', expand=True, padx=(8, 0))
        form.columnconfigure(1, weight=1)
        self.cg_form = form

        self.cg_id_var = tk.StringVar()
        self.cg_image_var = tk.StringVar()
        self.cg_duration_var = tk.StringVar()
        self.cg_once_var = tk.BooleanVar(value=True)
        self.cg_skippable_var = tk.BooleanVar(value=True)
        self.cg_enabled_var = tk.BooleanVar(value=True)
        self.cg_trigger_var = tk.StringVar()
        self.cg_map_var = tk.StringVar()
        self.cg_object_var = tk.StringVar()
        self.cg_kind_var = tk.StringVar(value='不限')
        self.cg_quest_var = tk.StringVar()
        self.cg_x_var = tk.StringVar()
        self.cg_y_var = tk.StringVar()
        self.cg_radius_var = tk.StringVar()

        ttk.Label(form, text='id').grid(row=0, column=0, sticky='w', pady=2)
        ttk.Entry(form, textvariable=self.cg_id_var).grid(row=0, column=1, sticky='ew', padx=(6, 0), pady=2)
        ttk.Label(form, text='image').grid(row=1, column=0, sticky='w', pady=2)
        image_row = ttk.Frame(form)
        image_row.grid(row=1, column=1, sticky='ew', padx=(6, 0), pady=2)
        ttk.Entry(image_row, textvariable=self.cg_image_var).pack(side='left', fill='x', expand=True)
        ttk.Button(image_row, text='浏览…', command=self.browse_cg_image).pack(side='left', padx=(4, 0))
        self.cg_text = self._text_box(form, 2, 'text', 6)
        ttk.Label(form, text='duration（秒）').grid(row=3, column=0, sticky='w', pady=2)
        ttk.Entry(form, textvariable=self.cg_duration_var).grid(row=3, column=1, sticky='ew', padx=(6, 0), pady=2)
        ttk.Label(form, text='播放选项').grid(row=4, column=0, sticky='w', pady=2)
        flags = ttk.Frame(form)
        flags.grid(row=4, column=1, sticky='w', padx=(6, 0), pady=2)
        ttk.Checkbutton(flags, text='只播一次', variable=self.cg_once_var).pack(side='left')
        ttk.Checkbutton(flags, text='可跳过', variable=self.cg_skippable_var).pack(side='left', padx=(10, 0))
        ttk.Checkbutton(flags, text='启用', variable=self.cg_enabled_var).pack(side='left', padx=(10, 0))
        ttk.Label(form, text='trigger').grid(row=5, column=0, sticky='w', pady=2)
        self.cg_trigger_combo = ttk.Combobox(
            form, textvariable=self.cg_trigger_var, state='readonly',
            values=[CG_TRIGGER_LABELS[kind] for kind in CG_TRIGGERS],
        )
        self.cg_trigger_combo.grid(row=5, column=1, sticky='ew', padx=(6, 0), pady=2)
        self.cg_trigger_combo.bind('<<ComboboxSelected>>', self.on_cg_type_change)

        self.cg_map_row = ttk.Frame(form)
        self.cg_map_row.grid(row=6, column=0, columnspan=2, sticky='ew', pady=2)
        ttk.Label(self.cg_map_row, text='map（地图名）').pack(side='left')
        ttk.Entry(self.cg_map_row, textvariable=self.cg_map_var).pack(side='left', fill='x', expand=True, padx=(6, 0))

        self.cg_object_row = ttk.Frame(form)
        self.cg_object_row.grid(row=7, column=0, columnspan=2, sticky='ew', pady=2)
        ttk.Label(self.cg_object_row, text='object（对象 id）').pack(side='left')
        self.cg_object_combo = ttk.Combobox(self.cg_object_row, textvariable=self.cg_object_var, values=['*'])
        self.cg_object_combo.pack(side='left', fill='x', expand=True, padx=(6, 0))
        ttk.Label(self.cg_object_row, text='kind').pack(side='left', padx=(8, 0))
        self.cg_kind_combo = ttk.Combobox(
            self.cg_object_row, textvariable=self.cg_kind_var, state='readonly',
            values=['不限', '行星', '太空城'], width=8,
        )
        self.cg_kind_combo.pack(side='left', padx=(6, 0))

        self.cg_quest_row = ttk.Frame(form)
        self.cg_quest_row.grid(row=8, column=0, columnspan=2, sticky='ew', pady=2)
        ttk.Label(self.cg_quest_row, text='quest（委托 id）').pack(side='left')
        self.cg_quest_combo = ttk.Combobox(self.cg_quest_row, textvariable=self.cg_quest_var)
        self.cg_quest_combo.pack(side='left', fill='x', expand=True, padx=(6, 0))

        self.cg_point_row = ttk.Frame(form)
        self.cg_point_row.grid(row=9, column=0, columnspan=2, sticky='ew', pady=2)
        ttk.Label(self.cg_point_row, text='position（米）').pack(side='left')
        ttk.Entry(self.cg_point_row, textvariable=self.cg_x_var, width=12).pack(side='left', padx=(6, 2))
        ttk.Entry(self.cg_point_row, textvariable=self.cg_y_var, width=12).pack(side='left', padx=(0, 8))
        ttk.Label(self.cg_point_row, text='radius_m').pack(side='left')
        ttk.Entry(self.cg_point_row, textvariable=self.cg_radius_var, width=10).pack(side='left', padx=(6, 0))
        form.rowconfigure(2, weight=1)

        buttons = ttk.Frame(tab)
        buttons.pack(fill='x', pady=(6, 0))
        for text, command in (
            ('新增', self.add_cg),
            ('删除', self.delete_cg),
            ('上移', lambda: self.move_cg(-1)),
            ('下移', lambda: self.move_cg(1)),
            ('应用', self.apply_cg),
        ):
            ttk.Button(buttons, text=text, command=command).pack(side='left', padx=2)
        self._enable_tree(form, False)

    # -- 通用小工具 -------------------------------------------------------
    def _enable_tree(self, widget, enabled):
        try:
            if isinstance(widget, ttk.Widget):
                widget.state(['!disabled'] if enabled else ['disabled'])
            elif isinstance(widget, (tk.Listbox, tk.Text, tk.Entry)):
                widget.configure(state='normal' if enabled else 'disabled')
        except tk.TclError:
            pass
        for child in widget.winfo_children():
            self._enable_tree(child, enabled)

    def _text_value(self, widget):
        return widget.get('1.0', 'end-1c')

    def _set_text(self, widget, value):
        widget.configure(state='normal')
        widget.delete('1.0', 'end')
        widget.insert('1.0', value)

    def current_object(self):
        if self.map_data is None or self.object_id is None:
            return None
        for obj in map_objects(self.map_data):
            if obj.get('id') == self.object_id:
                return obj
        return None

    def events(self):
        if self.planet_data is None:
            return []
        events = self.planet_data.get('events')
        return events if isinstance(events, list) else []

    def persons(self):
        if self.planet_data is None:
            return []
        persons = self.planet_data.get('diplomacy', {}).get('persons') if isinstance(self.planet_data.get('diplomacy'), dict) else None
        return persons if isinstance(persons, list) else []

    def person_registry(self):
        """全项目人物索引；当前文件用内存数据，其它文件读磁盘，因此未保存的新人物也能选。"""
        return person_registry(self.map_data, self.planet_path, self.planet_data)

    def quest_registry(self):
        """全项目委托索引；运行期任务表按 id 建键，撞名会互相顶掉，保存前必须拦下。"""
        return quest_registry(self.map_data, self.planet_path, self.planet_data)

    def _person_choice_labels(self):
        """把人物索引摊平成下拉用的标签列表，并记住标签 ↔ 人物条目的双向映射。

        人物 id 允许在不同行星重复（老数据就是每颗星都有 person_1），所以标签必须带
        唯一的 planet_id；真正写进 JSON 的是 target（id）+ target_planet_id（行星）。
        """
        entries = [item for bucket in self.person_registry().values() for item in bucket]
        # 同一份数据可能被读两次（编辑器里换绑路径、临时副本），按 (行星, id) 去重。
        unique = {}
        for item in entries:
            unique.setdefault((item['planet_id'], item['id']), item)
        entries = list(unique.values())
        entries.sort(key=lambda item: (item['planet'], item['name'], item['id']))
        self._person_label_to_entry = {item['label']: item for item in entries}
        self._person_label_to_id = {item['label']: item['id'] for item in entries}
        self._person_id_to_label = {}
        self._person_id_planet_to_label = {}
        for item in entries:
            key = (item['id'], item['planet_id'])
            self._person_id_planet_to_label.setdefault(key, item['label'])
            self._person_id_to_label.setdefault(item['id'], item['label'])
        # 重名 id 未指定行星时，优先显示当前正在编辑的行星上那个人（历史数据没有 target_planet_id）。
        current = str((self.planet_data or {}).get('planet_id', '')).strip()
        if current:
            for item in entries:
                if item['planet_id'] == current:
                    self._person_id_to_label[item['id']] = item['label']
        return [item['label'] for item in entries]

    def quest_person(self):
        persons = self.persons()
        if not persons or self.quest_person_index is None or not 0 <= self.quest_person_index < len(persons):
            return None
        return persons[self.quest_person_index]

    def quests(self):
        person = self.quest_person()
        if person is None:
            return []
        quests = person.get('quests')
        return quests if isinstance(quests, list) else []

    def map_dirty(self):
        return self.map_saved is not None and self.map_data != self.map_saved

    def planet_dirty(self):
        return self.planet_saved is not None and self.planet_data != self.planet_saved

    # -- 状态栏与左侧列表 -------------------------------------------------
    def update_status(self):
        map_text = self.map_path or '未载入'
        if self.planet_path:
            planet_text = self.planet_path
        elif self.planet_res:
            planet_text = self.planet_res + '（未载入）'
        else:
            planet_text = '未选择'
        if self.cg_path:
            cg_text = self.cg_path
        elif self.cg_res:
            cg_text = self.cg_res + '（未载入）'
        else:
            cg_text = '未绑定'
        dirty = '有未保存修改' if self.has_unsaved() else '已保存'
        self.status.config(text=f'地图：{map_text}　｜　事件数据：{planet_text}　｜　CG：{cg_text}　｜　{dirty}')

    def update_object_label(self):
        obj = self.current_object()
        if obj is None:
            self.object_label.config(text='未选择对象')
            return
        name = obj.get('fields', {}).get('display_name') or ''
        text = f"{obj['id']} · {KIND_LABELS[obj['type']]}" + (f' · {name}' if name else '')
        if self.planet_data is not None:
            text += f"　｜　事件数据 {self.planet_data.get('planet_id', '')} · {self.planet_data.get('name', '')}"
        # 绑定只看 field 里的路径：把「同一份数据还被谁引用」直接显示出来，避免误以为改的是独立数据。
        res_path = obj.get('fields', {}).get('interaction_data_path')
        if isinstance(res_path, str) and res_path and self.map_path:
            others = describe_other_referrers(res_path, self.map_path, obj['id'])
            if others:
                shown = '、'.join(others[:3]) + (f' 等 {len(others)} 个' if len(others) > 3 else '')
                text += f"\n⚠ 同一份数据还被引用：{shown}（改一处这些对象全变）"
        self.object_label.config(text=text)

    def _object_status(self, obj, counts):
        res_path = obj.get('fields', {}).get('interaction_data_path')
        if not res_path:
            return '未配置'
        shared = counts.get(res_path, 0)
        if shared > 1:
            return f'共用 {shared} 个对象'
        try:
            disk = res_to_disk(res_path)
        except ValueError:
            return '文件缺失'
        return '已有' if os.path.isfile(disk) else '文件缺失'

    def refresh_map_tree(self):
        self._syncing = True
        try:
            self.tree.delete(*self.tree.get_children())
            if self.map_data is None:
                return
            objects = map_objects(self.map_data)
            counts = Counter(obj.get('fields', {}).get('interaction_data_path') for obj in objects)
            for obj in objects:
                name = obj.get('fields', {}).get('display_name') or obj.get('id', '')
                self.tree.insert(
                    '', 'end', iid=obj['id'],
                    values=(obj['id'], KIND_LABELS[obj['type']], name, self._object_status(obj, counts)),
                )
            if self.object_id and self.tree.exists(self.object_id):
                self.tree.selection_set(self.object_id)
                self.tree.see(self.object_id)
        finally:
            self._syncing = False

    def set_control_state(self):
        loaded = self.map_data is not None
        selected = self.current_object() is not None
        for button in (self.save_button, self.check_button):
            button.state(['!disabled'] if loaded else ['disabled'])
        for button in (self.create_button, self.choose_button, self.copy_button):
            button.state(['!disabled'] if selected else ['disabled'])
        # CG 页是地图级的，只受「是否载入地图」控制，与左侧选中哪个对象无关。
        for button in (self.cg_create_button, self.cg_choose_button):
            button.state(['!disabled'] if loaded else ['disabled'])
        self.cg_copy_button.state(['!disabled'] if isinstance(self.cg_data, dict) else ['disabled'])
        self.cg_explore_button.state(['!disabled'] if loaded else ['disabled'])
        self.explore_button.state(['!disabled'] if loaded else ['disabled'])
        try:
            self.notebook.state(['!disabled'] if loaded else ['disabled'])
        except tk.TclError:
            pass

    # -- 打开地图 ---------------------------------------------------------
    def open_map(self):
        path = filedialog.askopenfilename(
            initialdir=MAPS_DIR,
            filetypes=[('JSON 地图', '*.json'), ('所有文件', '*')],
        )
        if not path:
            return
        if not self._confirm_leave():
            return
        try:
            self.load_map_path(path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            messagebox.showerror('打开地图失败', str(exc), parent=self.root)

    def load_map_path(self, path):
        data = read_map(path)
        self.map_data = data
        self.map_path = path
        self.map_saved = copy.deepcopy(data)
        self.object_id = None
        self.planet_data = None
        self.planet_path = None
        self.planet_res = None
        self.planet_saved = None
        self.planet_message = ''
        self._load_cg_for_map()
        self.refresh_map_tree()
        self.refresh_all_tabs()
        self.set_control_state()
        self.update_status()

    # -- 选中对象 ---------------------------------------------------------
    def on_tree_select(self, event=None):
        if self._syncing:
            return
        selection = self.tree.selection()
        if not selection or selection[0] == self.object_id:
            return
        if not self.select_object(selection[0]):
            self._syncing = True
            try:
                if self.object_id and self.tree.exists(self.object_id):
                    self.tree.selection_set(self.object_id)
                else:
                    self.tree.selection_remove(*selection)
            finally:
                self._syncing = False

    def select_object(self, object_id):
        obj = None
        for item in map_objects(self.map_data or {}):
            if item.get('id') == object_id:
                obj = item
                break
        if obj is None:
            return False
        if object_id == self.object_id:
            return True
        if not self._confirm_leave():
            return False
        self.object_id = object_id
        self.planet_message = ''
        self._load_planet_for_object()
        self.refresh_map_tree()
        self.refresh_all_tabs()
        self.set_control_state()
        self.update_status()
        return True

    def _load_planet_for_object(self):
        self.planet_data = None
        self.planet_path = None
        self.planet_res = None
        self.planet_saved = None
        self.planet_message = ''
        obj = self.current_object()
        if obj is None:
            return
        res_path = obj.get('fields', {}).get('interaction_data_path')
        if not res_path:
            self.planet_message = '该对象还没有事件 JSON，请先创建或选择'
            return
        self.planet_res = res_path
        try:
            disk = res_to_disk(res_path)
        except ValueError as exc:
            self.planet_message = f'事件数据路径不可用：{exc}'
            return
        self.planet_path = disk
        if not os.path.isfile(disk):
            self.planet_message = f'事件 JSON 文件缺失：{disk}，请重新创建或选择'
            return
        try:
            data = read_planet(disk)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            self.planet_message = f'事件 JSON 读取失败：{exc}'
            return
        self.planet_data = data
        self.planet_saved = copy.deepcopy(data)

    def reload_planet_for_object(self):
        self._load_planet_for_object()
        self.refresh_all_tabs()
        self.update_status()

    def has_unsaved(self):
        if self.map_dirty() or self.planet_dirty() or self.cg_dirty():
            return True
        return (self.event_form_dirty() or self.person_form_dirty()
                or self.quest_form_dirty() or self.speech_form_dirty() or self.cg_form_dirty())

    def _confirm_leave(self):
        """切换对象前：应用当前表单、处理未保存修改。返回 False 表示中止。"""
        if not self.apply_forms():
            return False
        if not self.has_unsaved():
            return True
        answer = messagebox.askyesnocancel(
            '未保存的修改',
            '当前修改尚未保存。\n是：保存并继续　否：放弃修改　取消：留在当前对象',
            parent=self.root,
        )
        if answer is None:
            return False
        if answer:
            return self.save_all(silent=True)
        if self.map_saved is not None:
            self.map_data = copy.deepcopy(self.map_saved)
        if self.cg_saved is not None:
            self.cg_data = copy.deepcopy(self.cg_saved)
        if self.object_id is not None:
            self.reload_planet_for_object()
        self.refresh_map_tree()
        self.refresh_cg_list()
        self.update_status()
        return True

    # -- 右侧三页刷新 -----------------------------------------------------
    def refresh_all_tabs(self):
        message = self.planet_message
        self.update_object_label()
        self.event_hint.config(text=message)
        self.person_hint.config(text=message)
        self.quest_hint.config(text=message)
        self.speech_hint.config(text=message)

        events = self.events()
        self._syncing = True
        try:
            self.event_list.delete(0, 'end')
            for event in events:
                self.event_list.insert('end', f"{event.get('id', '?')} · {event.get('title', '')}")
            if events and (self.event_index is None or not 0 <= self.event_index < len(events)):
                self.event_index = 0
            if not events:
                self.event_index = None
            if self.event_index is not None:
                self.event_list.selection_set(self.event_index)
                self.event_list.see(self.event_index)
        finally:
            self._syncing = False
        if not message and not events and self.planet_data is not None:
            self.event_hint.config(text='还没有事件，点击「新增」创建第一条。')
        self.fill_event_form()

        persons = self.persons()
        self._syncing = True
        try:
            self.person_list.delete(0, 'end')
            for person in persons:
                self.person_list.insert('end', f"{person.get('id', '?')} · {person.get('name', '')}")
            if persons and (self.person_index is None or not 0 <= self.person_index < len(persons)):
                self.person_index = 0
            if not persons:
                self.person_index = None
            if self.person_index is not None:
                self.person_list.selection_set(self.person_index)
                self.person_list.see(self.person_index)
        finally:
            self._syncing = False
        if not message and not persons and self.planet_data is not None:
            self.person_hint.config(text='还没有人物，点击「新增」创建第一位。')
        self.fill_person_form()

        self.refresh_quest_person_combo()
        self.refresh_quest_list()
        self.update_quest_hint(message)
        self.refresh_speech_person_combo()
        self.refresh_speech_list()
        self.update_speech_hint(message)
        self.refresh_cg_list()
        self.update_cg_hint(self.cg_message)

    def refresh_quest_person_combo(self):
        persons = self.persons()
        values = [f"{person.get('id', '?')} · {person.get('name', '')}" for person in persons]
        self._syncing = True
        try:
            self.quest_person_combo.config(values=values)
            if persons and (self.quest_person_index is None or not 0 <= self.quest_person_index < len(persons)):
                self.quest_person_index = 0
            if not persons:
                self.quest_person_index = None
                self.quest_person_var.set('')
            else:
                self.quest_person_var.set(values[self.quest_person_index])
        finally:
            self._syncing = False
        self.quest_person_combo.state(['!disabled'] if persons else ['disabled'])

    def refresh_quest_list(self):
        quests = self.quests()
        self._syncing = True
        try:
            self.quest_list.delete(0, 'end')
            for quest in quests:
                marker = ' · 需复命' if bool(quest.get('requires_return', False)) else ''
                self.quest_list.insert('end', f"{quest.get('id', '?')} · {quest.get('title', '')}{marker}")
            if quests and (self.quest_index is None or not 0 <= self.quest_index < len(quests)):
                self.quest_index = 0
            if not quests:
                self.quest_index = None
            if self.quest_index is not None:
                self.quest_list.selection_set(self.quest_index)
                self.quest_list.see(self.quest_index)
        finally:
            self._syncing = False
        self.fill_quest_form()

    def update_quest_hint(self, message):
        if message:
            self.quest_hint.config(text=message)
        elif self.planet_data is None:
            self.quest_hint.config(text='')
        elif not self.persons():
            self.quest_hint.config(text='还没有人物，请先在「人物」页新增人物，委托挂在人物下。')
        elif not self.quests():
            self.quest_hint.config(text='该人物还没有委托，点击「新增」创建。')
        else:
            self.quest_hint.config(text='')

    # -- 事件页 -----------------------------------------------------------
    def fill_event_form(self):
        events = self.events()
        if self.event_index is None or not 0 <= self.event_index < len(events):
            self.event_index = None
            self.event_id_var.set('')
            self.event_title_var.set('')
            self._set_text(self.event_body, '')
            self._enable_tree(self.event_form, False)
            return
        event = events[self.event_index]
        self._enable_tree(self.event_form, True)
        self.event_id_var.set(str(event.get('id', '')))
        self.event_title_var.set(str(event.get('title', '')))
        self._set_text(self.event_body, str(event.get('body', '')))

    def event_form_values(self):
        if self.event_index is None or not 0 <= self.event_index < len(self.events()):
            return None
        return {
            'id': self.event_id_var.get().strip(),
            'title': self.event_title_var.get().strip(),
            'body': self._text_value(self.event_body).strip(),
        }

    def event_form_dirty(self):
        values = self.event_form_values()
        events = self.events()
        if values is None or not 0 <= (self.event_index or 0) < len(events):
            return False
        event = events[self.event_index]
        return any(str(event.get(key, '')).strip() != values[key] for key in ('id', 'title', 'body'))

    def on_event_select(self, event=None):
        if self._syncing:
            return
        selection = self.event_list.curselection()
        if not selection:
            return
        index = selection[0]
        if index == self.event_index:
            return
        if self.event_index is not None and not self.apply_event():
            self._syncing = True
            try:
                self.event_list.selection_clear(0, 'end')
                if self.event_index is not None:
                    self.event_list.selection_set(self.event_index)
            finally:
                self._syncing = False
            return
        self.event_index = index
        self.fill_event_form()
        self.update_status()

    def apply_event(self):
        if self.planet_data is None or self.event_index is None:
            return True
        events = self.events()
        if not 0 <= self.event_index < len(events):
            return True
        try:
            values = self.event_form_values()
            if not ID_PATTERN.fullmatch(values['id']):
                raise ValueError('事件 ID 只能是 1–64 位字母、数字、下划线或连字符')
            for key in ('title', 'body'):
                if not values[key]:
                    raise ValueError(f'事件 {key} 不能为空')
                if len(values[key]) > TEXT_LIMIT:
                    raise ValueError(f'事件 {key} 不能超过 {TEXT_LIMIT} 个字符')
            for index, event in enumerate(events):
                if index != self.event_index and event.get('id') == values['id']:
                    raise ValueError(f'事件 ID 重复：{values["id"]}')
        except ValueError as exc:
            messagebox.showerror('属性错误', str(exc), parent=self.root)
            return False
        events[self.event_index].update(values)
        return True

    def add_event(self):
        if self.planet_data is None:
            return
        if not self.apply_event():
            return
        events = self.events()
        events.append({
            'id': self._unique_id('event', [str(event.get('id', '')) for event in events]),
            'title': '新事件',
            'body': '在此填写事件正文。',
        })
        self.planet_data['events'] = events
        self.event_index = len(events) - 1
        self.refresh_all_tabs()
        self.update_status()

    def delete_event(self):
        if self.planet_data is None or self.event_index is None:
            return
        events = self.events()
        if not 0 <= self.event_index < len(events):
            return
        if not messagebox.askyesno('删除事件', f'删除事件 {events[self.event_index].get("id", "")}？', parent=self.root):
            return
        del events[self.event_index]
        self.event_index = None if not events else min(self.event_index, len(events) - 1)
        self.refresh_all_tabs()
        self.update_status()

    def move_event(self, step):
        if not self.apply_event():
            return
        events = self.events()
        if self.event_index is None:
            return
        target = self.event_index + step
        if not 0 <= target < len(events):
            return
        events[self.event_index], events[target] = events[target], events[self.event_index]
        self.event_index = target
        self.refresh_all_tabs()
        self.update_status()

    # -- 人物页 -----------------------------------------------------------
    def fill_person_form(self):
        persons = self.persons()
        if self.person_index is None or not 0 <= self.person_index < len(persons):
            self.person_index = None
            for var in (self.person_id_var, self.person_name_var, self.person_role_var, self.person_portrait_var):
                var.set('')
            self._set_text(self.person_description, '')
            self._set_text(self.person_dialogue, '')
            self._set_text(self.person_quest_greeting, '')
            self._enable_tree(self.person_form, False)
            return
        person = persons[self.person_index]
        self._enable_tree(self.person_form, True)
        self.person_id_var.set(str(person.get('id', '')))
        self.person_name_var.set(str(person.get('name', '')))
        self.person_role_var.set(str(person.get('role', '')))
        self.person_portrait_var.set(str(person.get('portrait', '')))
        self._set_text(self.person_description, str(person.get('description', '')))
        dialogue = person.get('dialogue')
        lines = [str(line) for line in dialogue] if isinstance(dialogue, list) else []
        self._set_text(self.person_dialogue, '\n'.join(lines))
        greeting = person.get('quest_greeting')
        greet_lines = [str(line) for line in greeting] if isinstance(greeting, list) else []
        self._set_text(self.person_quest_greeting, '\n'.join(greet_lines))

    def person_form_values(self):
        if self.person_index is None or not 0 <= self.person_index < len(self.persons()):
            return None
        lines = [line.strip() for line in self._text_value(self.person_dialogue).splitlines() if line.strip()]
        greet = [line.strip() for line in self._text_value(self.person_quest_greeting).splitlines() if line.strip()]
        return {
            'id': self.person_id_var.get().strip(),
            'name': self.person_name_var.get().strip(),
            'role': self.person_role_var.get().strip(),
            'portrait': self.person_portrait_var.get().strip(),
            'description': self._text_value(self.person_description).strip(),
            'dialogue': lines,
            'quest_greeting': greet,
        }

    def person_form_dirty(self):
        values = self.person_form_values()
        if values is None:
            return False
        person = self.persons()[self.person_index]
        stored = {
            'id': str(person.get('id', '')).strip(),
            'name': str(person.get('name', '')).strip(),
            'role': str(person.get('role', '')).strip(),
            'portrait': str(person.get('portrait', '')).strip(),
            'description': str(person.get('description', '')).strip(),
            'dialogue': [str(line).strip() for line in person.get('dialogue', [])
                         if isinstance(person.get('dialogue'), list) and str(line).strip()],
            'quest_greeting': [str(line).strip() for line in person.get('quest_greeting', [])
                               if isinstance(person.get('quest_greeting'), list) and str(line).strip()],
        }
        return values != stored

    def on_person_select(self, event=None):
        if self._syncing:
            return
        selection = self.person_list.curselection()
        if not selection:
            return
        index = selection[0]
        if index == self.person_index:
            return
        if self.person_index is not None and not self.apply_person():
            self._syncing = True
            try:
                self.person_list.selection_clear(0, 'end')
                if self.person_index is not None:
                    self.person_list.selection_set(self.person_index)
            finally:
                self._syncing = False
            return
        self.person_index = index
        self.fill_person_form()
        self.update_status()

    def apply_person(self):
        if self.planet_data is None or self.person_index is None:
            return True
        persons = self.persons()
        if not 0 <= self.person_index < len(persons):
            return True
        try:
            values = self.person_form_values()
            if not ID_PATTERN.fullmatch(values['id']):
                raise ValueError('人物 ID 只能是 1–64 位字母、数字、下划线或连字符')
            for key, label in (('name', 'name'), ('role', 'role'), ('description', 'description')):
                if not values[key]:
                    raise ValueError(f'人物 {label} 不能为空')
            for key in ('name', 'role', 'description', 'portrait'):
                if len(values[key]) > TEXT_LIMIT:
                    raise ValueError(f'人物 {key} 不能超过 {TEXT_LIMIT} 个字符')
            for line in values['dialogue']:
                if len(line) > TEXT_LIMIT:
                    raise ValueError(f'人物台词不能超过 {TEXT_LIMIT} 个字符')
            for line in values['quest_greeting']:
                if len(line) > TEXT_LIMIT:
                    raise ValueError(f'人物委托台词不能超过 {TEXT_LIMIT} 个字符')
            for index, person in enumerate(persons):
                if index != self.person_index and person.get('id') == values['id']:
                    raise ValueError(f'人物 ID 重复：{values["id"]}')
        except ValueError as exc:
            messagebox.showerror('属性错误', str(exc), parent=self.root)
            return False
        person = persons[self.person_index]
        portrait = values.pop('portrait')
        dialogue = values.pop('dialogue')
        greeting = values.pop('quest_greeting')
        person.update(values)
        if portrait or 'portrait' in person:
            person['portrait'] = portrait
        if dialogue:
            person['dialogue'] = dialogue
        else:
            person.pop('dialogue', None)
        if greeting:
            person['quest_greeting'] = greeting
        else:
            person.pop('quest_greeting', None)
        return True

    def add_person(self):
        if self.planet_data is None:
            return
        if not self.apply_person():
            return
        persons = self.persons()
        persons.append({
            'id': self._unique_id('person', [str(person.get('id', '')) for person in persons]),
            'name': '新人物',
            'role': '角色',
            'portrait': '',
            'description': '在此填写人物说明。',
        })
        self.planet_data.setdefault('diplomacy', {})
        if not isinstance(self.planet_data['diplomacy'], dict):
            self.planet_data['diplomacy'] = {}
        self.planet_data['diplomacy']['persons'] = persons
        self.person_index = len(persons) - 1
        self.refresh_all_tabs()
        self.update_status()

    def delete_person(self):
        if self.planet_data is None or self.person_index is None:
            return
        persons = self.persons()
        if not 0 <= self.person_index < len(persons):
            return
        person = persons[self.person_index]
        message = f'删除人物 {person.get("id", "")}？'
        if person.get('quests'):
            message += '\n该人物名下的委托会一并删除。'
        if not messagebox.askyesno('删除人物', message, parent=self.root):
            return
        del persons[self.person_index]
        self.person_index = None if not persons else min(self.person_index, len(persons) - 1)
        self.quest_person_index = None
        self.quest_index = None
        self.refresh_all_tabs()
        self.update_status()

    def move_person(self, step):
        if not self.apply_person():
            return
        persons = self.persons()
        if self.person_index is None:
            return
        target = self.person_index + step
        if not 0 <= target < len(persons):
            return
        persons[self.person_index], persons[target] = persons[target], persons[self.person_index]
        self.person_index = target
        self.refresh_all_tabs()
        self.update_status()

    def browse_portrait(self):
        path = filedialog.askopenfilename(
            initialdir=os.path.join(PROJECT_ROOT, 'assets', 'ui'),
            filetypes=[('图片', '*.png *.jpg *.jpeg *.webp'), ('所有文件', '*')],
        )
        if not path:
            return
        try:
            relative = os.path.relpath(os.path.abspath(path), PROJECT_ROOT).replace(os.sep, '/')
        except ValueError:
            messagebox.showerror('路径不可用', '头像必须位于项目目录内。', parent=self.root)
            return
        if relative.startswith('..'):
            messagebox.showerror('路径不可用', '头像必须位于项目目录内。', parent=self.root)
            return
        self.person_portrait_var.set('res://' + relative)
        self.update_status()

    # -- 委托页 -----------------------------------------------------------
    def on_quest_person_change(self, event=None):
        if self._syncing:
            return
        if not self.apply_quest():
            self.refresh_quest_person_combo()
            return
        index = self.quest_person_combo.current()
        if index < 0:
            return
        self.quest_person_index = index
        self.quest_index = None
        self.refresh_quest_list()
        self.update_quest_hint(self.planet_message)
        self.update_status()

    def fill_quest_form(self):
        quests = self.quests()
        if self.quest_index is None or not 0 <= self.quest_index < len(quests):
            self.quest_index = None
            for var in (self.quest_id_var, self.quest_title_var, self.quest_type_var, self.quest_target_var,
                        self.quest_count_var, self.quest_reward_var, self.quest_unlock_var,
                        self.quest_return_line_var, self.quest_x_var,
                        self.quest_y_var, self.quest_radius_var):
                var.set('')
            self.quest_unlock_var.set(UNLOCK_NO_CHOICE)
            self.quest_requires_return_var.set(False)
            self._set_text(self.quest_description, '')
            self._enable_tree(self.quest_form, False)
            return
        quest = quests[self.quest_index]
        self._enable_tree(self.quest_form, True)
        self.quest_id_var.set(str(quest.get('id', '')))
        self.quest_title_var.set(str(quest.get('title', '')))
        self._set_text(self.quest_description, str(quest.get('description', '')))
        kind = quest.get('type')
        self.quest_type_var.set(QUEST_LABELS.get(kind, ''))
        if kind == 'recycle_mass':
            self.quest_target_var.set(str(quest.get('target_mass_kg', '')))
        elif kind == 'talk_to_person':
            # 存的是人物 id（可能属于别的行星），下拉里显示「名字（行星）· id」。
            self._person_choice_labels()
            target_id = str(quest.get('target', ''))
            target_planet_id = str(quest.get('target_planet_id', '')).strip()
            label = self._person_id_planet_to_label.get((target_id, target_planet_id), '') if target_planet_id else ''
            if not label:
                label = self._person_id_to_label.get(target_id, target_id)
            self.quest_target_var.set(label)
        else:
            self.quest_target_var.set(str(quest.get('target', '')))
        self.quest_count_var.set(str(quest.get('count', 1)))
        self.quest_reward_var.set(str(quest.get('reward_credits', 0)))
        unlock_id = str(quest.get('reward_unlock', ''))
        unlock_label = next((name for name, key in UNLOCK_LABELS.items() if key == unlock_id), UNLOCK_NO_CHOICE)
        self.quest_unlock_var.set(unlock_label)
        self.quest_requires_return_var.set(bool(quest.get('requires_return', False)))
        self.quest_return_line_var.set(str(quest.get('return_line', '')))
        position = quest.get('position')
        if isinstance(position, list) and len(position) == 2:
            self.quest_x_var.set(_format_number(position[0]))
            self.quest_y_var.set(_format_number(position[1]))
        else:
            self.quest_x_var.set('')
            self.quest_y_var.set('')
        self.quest_radius_var.set(_format_number(quest.get('radius_m')) if quest.get('radius_m') is not None else '')
        self._sync_quest_fields()

    def quest_type(self):
        return LABEL_QUESTS.get(self.quest_type_var.get())

    def _sync_quest_fields(self):
        kind = self.quest_type()
        enabled = self.quest_index is not None
        target_state = 'normal'
        if kind == 'arrive_point':
            target_state = 'disabled'
            values = []
        elif kind == 'arrive_target':
            values = [obj['id'] for obj in self._map_kinds(('planet', 'city'))]
        elif kind == 'talk_to_person':
            # 列全项目的人物：可以指向别的行星上的人，标签里带地点，避免选错同名人物。
            values = self._person_choice_labels()
        elif kind == 'dock_city':
            values = [obj['id'] for obj in self._map_kinds(('city',))]
        elif kind == 'install_upgrade':
            values = list(UPGRADE_IDS)
        elif kind == 'recycle_mass':
            target_state = 'normal'
            values = []
        else:
            target_state = 'disabled'
            values = []
        self.quest_target_combo.config(values=values)
        try:
            self.quest_target_combo.configure(state=target_state if enabled else 'disabled')
        except tk.TclError:
            pass
        geometry = kind == 'arrive_point' and enabled
        for widget in (self.quest_x_entry, self.quest_y_entry):
            widget.configure(state='normal' if geometry else 'disabled')
        radius_enabled = enabled and kind in ('arrive_point', 'arrive_target')
        self.quest_radius_entry.configure(state='normal' if radius_enabled else 'disabled')
        # 返命台词跟着勾选框走：没勾“需要返回”就没有复命这一步，输入框也不该能填。
        try:
            self.quest_return_check.state(['!disabled'] if enabled else ['disabled'])
        except tk.TclError:
            pass
        line_enabled = enabled and bool(self.quest_requires_return_var.get())
        self.quest_return_line_entry.configure(state='normal' if line_enabled else 'disabled')

    def on_quest_return_toggle(self):
        self._sync_quest_fields()
        self.update_status()

    def _map_kinds(self, kinds):
        if self.map_data is None:
            return []
        return [obj for obj in map_objects(self.map_data) if obj.get('type') in kinds]

    def on_quest_type_change(self, event=None):
        kind = self.quest_type()
        if kind in ('arrive_point', 'arrive_target') and not self.quest_radius_var.get().strip():
            self.quest_radius_var.set('1000')
        if kind == 'arrive_point':
            if not self.quest_x_var.get().strip():
                self.quest_x_var.set('0')
            if not self.quest_y_var.get().strip():
                self.quest_y_var.set('0')
        self._sync_quest_fields()
        self.update_status()

    def quest_target_value(self, kind):
        """下拉里选中的文本 → 真正写进 JSON 的 target。"""
        raw = self.quest_target_var.get().strip()
        if kind != 'talk_to_person':
            return raw
        if not self._person_label_to_id:
            # 还没同步过（例如刚打开文件就点了保存），现算一份再翻。
            self._person_choice_labels()
        # 选的是下拉项就翻成人物 id；手输的文本原样当作 id，交给校验判断是否存在。
        return self._person_label_to_id.get(raw, raw)

    def quest_target_person(self):
        """当前选中的人物条目（id / 名字 / 所在地 / 行星 id）；选不出时返回 None。

        下拉项直接对应唯一一条人物条目；手输人物 id 时按「当前行星优先」解析，
        这样老数据里重名的 person_1 也能落到正在编辑的那颗行星上。
        """
        raw = self.quest_target_var.get().strip()
        if not raw:
            return None
        if not self._person_label_to_entry:
            self._person_choice_labels()
        entry = self._person_label_to_entry.get(raw)
        if entry is not None:
            return entry
        target_id = self._person_label_to_id.get(raw, raw)
        hits = self.person_registry().get(target_id) or []
        if not hits:
            return None
        current = str((self.planet_data or {}).get('planet_id', '')).strip()
        for item in hits:
            if current and item.get('planet_id') == current:
                return item
        return hits[0]

    def quest_form_values(self):
        if self.quest_index is None or not 0 <= self.quest_index < len(self.quests()):
            return None
        kind = self.quest_type()
        values = {
            'id': self.quest_id_var.get().strip(),
            'title': self.quest_title_var.get().strip(),
            'description': self._text_value(self.quest_description).strip(),
            'type': kind,
            'reward_unlock': UNLOCK_LABELS.get(self.quest_unlock_var.get().strip(), ''),
            'requires_return': bool(self.quest_requires_return_var.get()),
            'return_line': self.quest_return_line_var.get().strip(),
        }
        if kind in ('arrive_target', 'talk_to_person', 'dock_city', 'install_upgrade', 'recycle_mass'):
            values['target'] = self.quest_target_value(kind)
        if kind in ('arrive_point', 'arrive_target'):
            values['radius_m'] = self.quest_radius_var.get().strip()
        if kind == 'arrive_point':
            values['position'] = (self.quest_x_var.get().strip(), self.quest_y_var.get().strip())
        return values

    def quest_form_dirty(self):
        values = self.quest_form_values()
        if values is None:
            return False
        quest = self.quests()[self.quest_index]
        kind = quest.get('type')
        if values['type'] != kind:
            return True
        if values['id'] != str(quest.get('id', '')).strip():
            return True
        if values['title'] != str(quest.get('title', '')).strip():
            return True
        if values['description'] != str(quest.get('description', '')).strip():
            return True
        if values['reward_unlock'] != str(quest.get('reward_unlock', '')):
            return True
        if values['requires_return'] != bool(quest.get('requires_return', False)):
            return True
        if values['requires_return'] and values['return_line'] != str(quest.get('return_line', '')).strip():
            return True
        if 'target' in values and values['target'] != str(quest.get('target', '')).strip():
            return True
        if 'radius_m' in values:
            stored = quest.get('radius_m')
            if not stored or values['radius_m'] != _format_number(stored):
                try:
                    if float(values['radius_m']) != float(stored):
                        return True
                except (TypeError, ValueError):
                    return True
        if 'position' in values:
            stored = quest.get('position')
            x, y = values['position']
            if not isinstance(stored, list) or len(stored) != 2:
                return True
            try:
                if float(x) != float(stored[0]) or float(y) != float(stored[1]):
                    return True
            except (TypeError, ValueError):
                return True
        return False

    def on_quest_select(self, event=None):
        if self._syncing:
            return
        selection = self.quest_list.curselection()
        if not selection:
            return
        index = selection[0]
        if index == self.quest_index:
            return
        if self.quest_index is not None and not self.apply_quest():
            self._syncing = True
            try:
                self.quest_list.selection_clear(0, 'end')
                if self.quest_index is not None:
                    self.quest_list.selection_set(self.quest_index)
            finally:
                self._syncing = False
            return
        self.quest_index = index
        self.fill_quest_form()
        self.update_status()

    def apply_quest(self):
        if self.planet_data is None or self.quest_index is None:
            return True
        person = self.quest_person()
        if person is None:
            return True
        quests = self.quests()
        if not 0 <= self.quest_index < len(quests):
            return True
        try:
            values = self.quest_form_values()
            kind = values['type']
            if kind is None or kind not in QUEST_TYPES:
                raise ValueError('委托类型必须是 ' + ' / '.join(QUEST_TYPES) + ' 之一')
            if not ID_PATTERN.fullmatch(values['id']):
                raise ValueError('委托 ID 只能是 1–64 位字母、数字、下划线或连字符')
            for key in ('title', 'description'):
                if not values[key]:
                    raise ValueError(f'委托 {key} 不能为空')
                if len(values[key]) > TEXT_LIMIT:
                    raise ValueError(f'委托 {key} 不能超过 {TEXT_LIMIT} 个字符')
            count = _parse_int(self.quest_count_var.get(), 'count')
            if count < 1:
                raise ValueError('count 必须 ≥ 1')
            reward = _parse_int(self.quest_reward_var.get(), 'reward_credits')
            if reward < 0:
                raise ValueError('reward_credits 必须 ≥ 0')
            result = {
                'id': values['id'],
                'title': values['title'],
                'description': values['description'],
                'type': kind,
                'count': count,
                'reward_credits': reward,
            }
            # 只有选了具体装备才写字段；选“不解锁”就彻底不落盘，保持旧文件干净。
            if values['reward_unlock']:
                result['reward_unlock'] = values['reward_unlock']
            # 同样的原则：不勾“需要返回”就不写 requires_return / return_line。
            if values['requires_return']:
                if len(values['return_line']) > TEXT_LIMIT:
                    raise ValueError(f'return_line 不能超过 {TEXT_LIMIT} 个字符')
                result['requires_return'] = True
                if values['return_line']:
                    result['return_line'] = values['return_line']
            map_ids = {obj['id'] for obj in map_objects(self.map_data or {})}
            city_ids = {obj['id'] for obj in self._map_kinds(('city',))}
            if kind == 'arrive_point':
                x = _parse_float(self.quest_x_var.get(), 'position x')
                y = _parse_float(self.quest_y_var.get(), 'position y')
                if abs(x) > 1e12 or abs(y) > 1e12:
                    raise ValueError('position 分量绝对值不能大于 10 的 12 次方')
                radius = _parse_float(self.quest_radius_var.get(), 'radius_m')
                if radius <= 0:
                    raise ValueError('arrive_point 的 radius_m 必须大于零')
                result['position'] = [x, y]
                result['radius_m'] = radius
            elif kind == 'arrive_target':
                target = values['target']
                if not target:
                    raise ValueError('arrive_target 的 target 不能为空')
                if self.map_data is not None and target not in map_ids:
                    raise ValueError(f'target 必须是地图上存在的 planet 或 city：{target}')
                radius = _parse_float(self.quest_radius_var.get(), 'radius_m')
                if radius < 0:
                    raise ValueError('arrive_target 的 radius_m 不能为负')
                result['target'] = target
                result['radius_m'] = radius
            elif kind == 'talk_to_person':
                target = values['target']
                if not target:
                    raise ValueError('talk_to_person 的 target 不能为空')
                hits = self.person_registry().get(target) or []
                if not hits:
                    raise ValueError(f'target 必须是项目里存在的人物 id（可以选其它行星上的人）：{target}')
                # 人物 id 允许跨行星重名：条目唯一，写进 JSON 的就是 (target, target_planet_id)。
                entry = self.quest_target_person()
                if entry is None or entry.get('id') != target:
                    current = str((self.planet_data or {}).get('planet_id', '')).strip()
                    entry = next((item for item in hits if item.get('planet_id') == current), hits[0])
                result['target'] = target
                # 顺带存一份可读提示，任务清单 tooltip 直接用它，运行期不必再查数据文件。
                result['target_name'] = entry['name']
                result['target_planet'] = entry['planet']
                if entry.get('planet_id'):
                    result['target_planet_id'] = entry['planet_id']
            elif kind == 'dock_city':
                target = values['target']
                if target and self.map_data is not None and target not in city_ids:
                    raise ValueError(f'target 必须是地图上存在的太空城：{target}')
                result['target'] = target
            elif kind == 'install_upgrade':
                target = values['target']
                if target and target not in UPGRADE_IDS:
                    raise ValueError(f'target 必须是船坞里存在的装备 id（留空表示任意装备）：{target}')
                result['target'] = target
            elif kind == 'recycle_mass':
                mass = _parse_float(values['target'], 'target_mass_kg')
                if mass <= 0:
                    raise ValueError('recycle_mass 的目标质量必须大于 0（单位 kg）')
                result['target_mass_kg'] = mass
                # 进度条直接用质量当 required，count 与目标质量保持一致，JSON 自解释。
                result['count'] = max(1, int(round(mass)))
            for other in self.persons():
                for quest in other.get('quests', []) if isinstance(other.get('quests'), list) else []:
                    if quest is quests[self.quest_index]:
                        continue
                    if quest.get('id') == result['id']:
                        raise ValueError(f'委托 ID 必须全局唯一：{result["id"]}')
            # 跨文件撞名更隐蔽：运行期任务表按 id 建键，接了 A 星的，B 星同 id 会显示成「已接取」。
            planet_key = str((self.planet_data or {}).get('planet_id', ''))
            clashes = [entry for entry in (self.quest_registry().get(result['id']) or [])
                       if not entry.get('current') and str(entry.get('planet_id') or '') != planet_key]
            if clashes:
                where = '、'.join(sorted({str(entry.get('planet_id') or entry.get('path', '')) for entry in clashes}))
                raise ValueError(f'委托 ID 与其它行星撞名（{where}），运行期会互相顶掉：{result["id"]}')
        except ValueError as exc:
            messagebox.showerror('属性错误', str(exc), parent=self.root)
            return False
        quests[self.quest_index].clear()
        quests[self.quest_index].update(result)
        return True

    def add_quest(self):
        if self.planet_data is None:
            return
        person = self.quest_person()
        if person is None:
            messagebox.showinfo('委托', '请先在「人物」页新增人物，委托挂在人物下。', parent=self.root)
            return
        if not self.apply_quest():
            return
        used = [str(quest.get('id', '')) for quest in self.quests()]
        for other in self.persons():
            for quest in other.get('quests', []) if isinstance(other.get('quests'), list) else []:
                used.append(str(quest.get('id', '')))
        # 自动生成的 id 也要避开别的行星已经用掉的，否则一存就被撞名校验顶回来。
        used.extend(self.quest_registry().keys())
        quest = {
            'id': self._unique_id('quest', used),
            'title': '新委托',
            'description': '在此填写委托说明。',
            'type': 'dock_city',
            'target': '',
            'count': 1,
            'reward_credits': 0,
        }
        if not isinstance(person.get('quests'), list):
            person['quests'] = []
        person['quests'].append(quest)
        self.quest_index = len(person['quests']) - 1
        self.refresh_quest_list()
        self.update_quest_hint(self.planet_message)
        self.update_status()

    def delete_quest(self):
        person = self.quest_person()
        if person is None or self.quest_index is None:
            return
        quests = self.quests()
        if not 0 <= self.quest_index < len(quests):
            return
        if not messagebox.askyesno('删除委托', f'删除委托 {quests[self.quest_index].get("id", "")}？', parent=self.root):
            return
        del quests[self.quest_index]
        if not quests:
            person.pop('quests', None)
        self.quest_index = None if not quests else min(self.quest_index, len(quests) - 1)
        self.refresh_quest_list()
        self.update_quest_hint(self.planet_message)
        self.update_status()

    # -- 台词候选（speech）--------------------------------------------------
    def speech_person(self):
        persons = self.persons()
        if self.speech_person_index is None or not 0 <= self.speech_person_index < len(persons):
            return None
        return persons[self.speech_person_index]

    def speeches(self):
        person = self.speech_person()
        if person is None:
            return []
        speech = person.get('speech')
        return speech if isinstance(speech, list) else []

    def refresh_speech_person_combo(self):
        persons = self.persons()
        values = [f"{person.get('id', '?')} · {person.get('name', '')}" for person in persons]
        self._syncing = True
        try:
            self.speech_person_combo.config(values=values)
            if persons and (self.speech_person_index is None or not 0 <= self.speech_person_index < len(persons)):
                self.speech_person_index = 0
            if not persons:
                self.speech_person_index = None
                self.speech_person_var.set('')
            else:
                self.speech_person_var.set(values[self.speech_person_index])
        finally:
            self._syncing = False
        self.speech_person_combo.state(['!disabled'] if persons else ['disabled'])

    def refresh_speech_list(self):
        speeches = self.speeches()
        self._syncing = True
        try:
            self.speech_list.delete(0, 'end')
            for entry in speeches:
                if not isinstance(entry, dict):
                    self.speech_list.insert('end', '（格式错误，不是对象）')
                    continue
                identifier = str(entry.get('id', '（无 id）'))
                marker = ' · 一次性' if bool(entry.get('once', False)) else ''
                self.speech_list.insert('end', f'{identifier} · {format_when_summary(entry.get("when", {}))}{marker}')
            if speeches and (self.speech_index is None or not 0 <= self.speech_index < len(speeches)):
                self.speech_index = 0
            if not speeches:
                self.speech_index = None
            if self.speech_index is not None:
                self.speech_list.selection_set(self.speech_index)
                self.speech_list.see(self.speech_index)
        finally:
            self._syncing = False
        self.fill_speech_form()

    def fill_speech_form(self):
        speeches = self.speeches()
        self._syncing = True
        try:
            if self.speech_index is None or not 0 <= self.speech_index < len(speeches):
                self.speech_id_var.set('')
                self.speech_once_var.set(False)
                self._set_text(self.speech_when, '')
                self._set_text(self.speech_lines, '')
                self._set_text(self.speech_flags, '')
                self._enable_tree(self.speech_form, False)
                return
            entry = speeches[self.speech_index]
            if not isinstance(entry, dict):
                entry = {}
            self.speech_id_var.set(str(entry.get('id', '')))
            self.speech_once_var.set(bool(entry.get('once', False)))
            self._set_text(self.speech_when, format_when_text(entry.get('when', {})))
            lines = entry.get('lines')
            if isinstance(lines, str):
                lines = [lines]
            self._set_text(self.speech_lines, '\n'.join(str(line) for line in lines) if isinstance(lines, list) else '')
            self._set_text(self.speech_flags, format_flag_text(entry.get('set_flags', {})))
            self._enable_tree(self.speech_form, True)
        finally:
            self._syncing = False

    def speech_form_values(self):
        """返回 (values, errors)。values 只含将写进 JSON 的字段。"""
        if self.speech_person() is None or self.speech_index is None:
            return None, []
        speeches = self.speeches()
        if not 0 <= self.speech_index < len(speeches):
            return None, []
        when, errors = parse_when_text(self._text_value(self.speech_when))
        flags, flag_errors = parse_flag_text(self._text_value(self.speech_flags))
        errors = errors + flag_errors
        lines = [line.strip() for line in self._text_value(self.speech_lines).splitlines() if line.strip()]
        values = {
            'id': self.speech_id_var.get().strip(),
            'when': when,
            'lines': lines,
            'once': bool(self.speech_once_var.get()),
            'set_flags': flags,
        }
        return values, errors

    def speech_form_dirty(self):
        values, errors = self.speech_form_values()
        if values is None:
            return False
        if errors:
            return True
        stored = self.speeches()[self.speech_index]
        if not isinstance(stored, dict):
            return True
        stored_lines = stored.get('lines')
        if isinstance(stored_lines, str):
            stored_lines = [stored_lines]
        normalized = {
            'id': str(stored.get('id', '')).strip(),
            'when': stored.get('when', {}) if isinstance(stored.get('when'), dict) else {},
            'lines': [str(line).strip() for line in stored_lines] if isinstance(stored_lines, list) else [],
            'once': bool(stored.get('once', False)),
            'set_flags': stored.get('set_flags', {}) if isinstance(stored.get('set_flags'), dict) else {},
        }
        return values != normalized

    def apply_speech(self):
        person = self.speech_person()
        if person is None or self.speech_index is None:
            return True
        speeches = self.speeches()
        if not 0 <= self.speech_index < len(speeches):
            return True
        values, errors = self.speech_form_values()
        if errors:
            self.show_errors('台词条件', errors)
            return False
        identifier = values['id']
        if identifier and ID_PATTERN.fullmatch(identifier) is None:
            messagebox.showerror('台词', '台词 id 只能是 1–64 位字母、数字、下划线或连字符', parent=self.root)
            return False
        for index, other in enumerate(speeches):
            if index == self.speech_index or not isinstance(other, dict):
                continue
            if identifier and str(other.get('id', '')) == identifier:
                messagebox.showerror('台词', f'同一人物下台词 id 重复：{identifier}', parent=self.root)
                return False
        if not values['lines']:
            messagebox.showerror('台词', 'lines 至少要有一句台词', parent=self.root)
            return False
        for line in values['lines']:
            if len(line) > TEXT_LIMIT:
                messagebox.showerror('台词', f'单句台词不能超过 {TEXT_LIMIT} 个字符', parent=self.root)
                return False
        entry = {}
        if identifier:
            entry['id'] = identifier
        if values['when']:
            entry['when'] = values['when']
        entry['lines'] = values['lines']
        if values['once']:
            entry['once'] = True
        if values['set_flags']:
            entry['set_flags'] = values['set_flags']
        speeches[self.speech_index] = entry
        person['speech'] = speeches
        # 列表里显示的是 id 与条件摘要，改完要立刻反映，否则会以为没保存成功。
        self.refresh_speech_list()
        return True

    def on_speech_person_change(self, event=None):
        if self._syncing:
            return
        if not self.apply_speech():
            self.refresh_speech_person_combo()
            return
        index = self.speech_person_combo.current()
        if index < 0:
            return
        self.speech_person_index = index
        self.speech_index = None
        self.refresh_speech_list()
        self.update_speech_hint(self.planet_message)
        self.update_status()

    def on_speech_select(self, event=None):
        if self._syncing:
            return
        selection = self.speech_list.curselection()
        if not selection:
            return
        index = selection[0]
        if index == self.speech_index:
            return
        if not self.apply_speech():
            self._syncing = True
            try:
                if self.speech_index is not None:
                    self.speech_list.selection_clear(0, 'end')
                    self.speech_list.selection_set(self.speech_index)
            finally:
                self._syncing = False
            return
        self.speech_index = index
        self._syncing = True
        try:
            self.speech_list.selection_clear(0, 'end')
            self.speech_list.selection_set(index)
        finally:
            self._syncing = False
        self.fill_speech_form()
        self.update_status()

    def add_speech(self):
        person = self.speech_person()
        if person is None:
            messagebox.showinfo('台词', '请先在「人物」页新增人物，台词挂在人物下。', parent=self.root)
            return
        if not self.apply_speech():
            return
        speeches = self.speeches()
        used = [str(entry.get('id', '')) for entry in speeches if isinstance(entry, dict)]
        speeches.append({
            'id': self._unique_id('speech', used),
            'lines': ['在这里填写台词。'],
        })
        person['speech'] = speeches
        self.speech_index = len(speeches) - 1
        self.refresh_speech_list()
        self.update_speech_hint(self.planet_message)
        self.update_status()

    def delete_speech(self):
        person = self.speech_person()
        if person is None or self.speech_index is None:
            return
        speeches = self.speeches()
        if not 0 <= self.speech_index < len(speeches):
            return
        target = speeches[self.speech_index]
        identifier = str(target.get('id', '')) if isinstance(target, dict) else ''
        if not messagebox.askyesno('删除台词', f'删除台词 {identifier}？', parent=self.root):
            return
        del speeches[self.speech_index]
        if not speeches:
            person.pop('speech', None)
        self.speech_index = None if not speeches else min(self.speech_index, len(speeches) - 1)
        self.refresh_speech_list()
        self.update_speech_hint(self.planet_message)
        self.update_status()

    def move_speech(self, delta):
        if not self.apply_speech():
            return
        speeches = self.speeches()
        if self.speech_index is None or not 0 <= self.speech_index < len(speeches):
            return
        target = self.speech_index + delta
        if not 0 <= target < len(speeches):
            return
        speeches[self.speech_index], speeches[target] = speeches[target], speeches[self.speech_index]
        self.speech_index = target
        self.refresh_speech_list()
        self.update_status()

    def update_speech_hint(self, message):
        if message:
            self.speech_hint.config(text=message)
        elif self.planet_data is None:
            self.speech_hint.config(text='')
        elif not self.persons():
            self.speech_hint.config(text='还没有人物，请先在「人物」页新增人物。')
        elif not self.speeches():
            self.speech_hint.config(
                text='该人物还没有台词候选，点击「新增」。顺序即优先级：条件最具体的放最上面，无条件兜底放最后。')
        else:
            self.speech_hint.config(text='')

    # -- CG 页 -------------------------------------------------------------
    def cg_items(self):
        if not isinstance(self.cg_data, dict):
            return []
        cgs = self.cg_data.get('cgs')
        return cgs if isinstance(cgs, list) else []

    def cg_dirty(self):
        return self.cg_saved is not None and self.cg_data != self.cg_saved

    def current_cg(self):
        items = self.cg_items()
        if self.cg_index is None or not 0 <= self.cg_index < len(items):
            return None
        return items[self.cg_index]

    def update_cg_hint(self, message=''):
        if message:
            self.cg_hint.config(text=message)
            return
        if self.map_data is None:
            self.cg_hint.config(text='')
            return
        bound = self.map_data.get('cg_data_path')
        if not bound:
            self.cg_hint.config(text='该地图还没有 CG 配置，点「创建 CG 配置」生成 data/cg/<地图名>.json 并绑定到这张地图。')
        elif self.cg_data is None:
            self.cg_hint.config(text=f'已绑定 {bound}，但文件不存在或无法读取，请重新选择。')
        elif not self.cg_items():
            self.cg_hint.config(text='还没有 CG，点「新增」创建第一条。')
        else:
            self.cg_hint.config(text='')

    def refresh_cg_candidates(self):
        object_ids = _map_object_ids(self.map_data, ('planet', 'city')) if self.map_data else []
        self.cg_object_combo.config(values=['*'] + object_ids)
        quests = cg_quest_ids(self.map_data) if self.map_data else []
        current = str(self.cg_quest_var.get()).strip()
        if current and current not in quests:
            quests = [current] + quests
        self.cg_quest_combo.config(values=quests)

    def refresh_cg_list(self):
        items = self.cg_items()
        self._syncing = True
        try:
            self.cg_list.delete(0, 'end')
            for item in items:
                preview = str(item.get('text', '')).replace('\n', ' ')
                if len(preview) > 18:
                    preview = preview[:18] + '…'
                self.cg_list.insert('end', f"{item.get('id', '?')} · {preview}")
            if items and (self.cg_index is None or not 0 <= self.cg_index < len(items)):
                self.cg_index = 0
            if not items:
                self.cg_index = None
            if self.cg_index is not None:
                self.cg_list.selection_set(self.cg_index)
                self.cg_list.see(self.cg_index)
        finally:
            self._syncing = False
        self.refresh_cg_candidates()
        self.fill_cg_form()
        self.update_cg_hint()

    def fill_cg_form(self):
        item = self.current_cg()
        if item is None:
            for var in (self.cg_id_var, self.cg_image_var, self.cg_duration_var, self.cg_map_var,
                        self.cg_object_var, self.cg_quest_var, self.cg_x_var, self.cg_y_var, self.cg_radius_var):
                var.set('')
            self.cg_trigger_var.set('')
            self._set_text(self.cg_text, '')
            self._enable_tree(self.cg_form, False)
            return
        self._enable_tree(self.cg_form, True)
        self.cg_id_var.set(str(item.get('id', '')))
        self.cg_image_var.set(str(item.get('image', '')))
        self._set_text(self.cg_text, str(item.get('text', '')))
        self.cg_duration_var.set(_format_number(item.get('duration', 1.0)))
        self.cg_once_var.set(bool(item.get('once', True)))
        self.cg_skippable_var.set(bool(item.get('skippable', True)))
        self.cg_enabled_var.set(bool(item.get('enabled', True)))
        trigger = item.get('trigger') if isinstance(item.get('trigger'), dict) else {}
        kind = str(trigger.get('type', ''))
        self.cg_trigger_var.set(CG_TRIGGER_LABELS.get(kind, ''))
        self.cg_map_var.set(str(trigger.get('map', '')))
        self.cg_object_var.set(str(trigger.get('object', '')))
        self.cg_kind_var.set(CG_KIND_LABELS.get(str(trigger.get('kind', '')), '不限'))
        self.cg_quest_var.set(str(trigger.get('quest', '')))
        point = trigger.get('position') if isinstance(trigger.get('position'), list) else []
        self.cg_x_var.set(_format_number(point[0]) if len(point) == 2 else '')
        self.cg_y_var.set(_format_number(point[1]) if len(point) == 2 else '')
        self.cg_radius_var.set(_format_number(trigger.get('radius_m')) if trigger.get('radius_m') is not None else '')
        self._sync_cg_fields(kind)

    def _sync_cg_fields(self, kind, fill_defaults=False):
        map_id = os.path.splitext(os.path.basename(self.map_path or ''))[0]
        if fill_defaults:
            if kind == 'map_enter':
                self.cg_map_var.set(map_id)
            elif kind == 'enter_object':
                candidates = _map_object_ids(self.map_data, ('planet', 'city')) if self.map_data else []
                self.cg_object_var.set(str(self.cg_object_var.get()).strip() or ('*' if not candidates else candidates[0]))
                self.cg_kind_var.set(self.cg_kind_var.get() or '不限')
            elif kind == 'quest_complete':
                values = list(self.cg_quest_combo.cget('values'))
                self.cg_quest_var.set(str(self.cg_quest_var.get()).strip() or (values[0] if values else ''))
            elif kind == 'reach_point':
                self.cg_x_var.set(self.cg_x_var.get() or '0')
                self.cg_y_var.set(self.cg_y_var.get() or '0')
                self.cg_radius_var.set(self.cg_radius_var.get() or _format_number(CG_DEFAULT_RADIUS))
        for row, active in (
            (self.cg_map_row, kind == 'map_enter'),
            (self.cg_object_row, kind == 'enter_object'),
            (self.cg_quest_row, kind == 'quest_complete'),
            (self.cg_point_row, kind == 'reach_point'),
        ):
            self._enable_tree(row, active)

    def on_cg_type_change(self, event=None):
        kind = CG_LABEL_TRIGGERS.get(self.cg_trigger_var.get(), '')
        self._sync_cg_fields(kind, fill_defaults=True)

    def cg_form_values(self):
        trigger_label = self.cg_trigger_var.get()
        if trigger_label not in CG_LABEL_TRIGGERS:
            raise ValueError('trigger 必须选择一个播放条件')
        kind = CG_LABEL_TRIGGERS[trigger_label]
        trigger = {'type': kind}
        if kind == 'map_enter':
            value = self.cg_map_var.get().strip()
            if not value:
                raise ValueError('进入地图必须填 map')
            trigger['map'] = value
        elif kind == 'enter_object':
            value = self.cg_object_var.get().strip()
            if not value:
                raise ValueError('进入行星/太空城必须填 object')
            trigger['object'] = value
            trigger['kind'] = CG_KIND_VALUES.get(self.cg_kind_var.get(), '')
        elif kind == 'quest_complete':
            value = self.cg_quest_var.get().strip()
            if not value:
                raise ValueError('完成委托必须填 quest')
            trigger['quest'] = value
        else:
            trigger['position'] = [
                _parse_float(self.cg_x_var.get(), 'position x'),
                _parse_float(self.cg_y_var.get(), 'position y'),
            ]
            trigger['radius_m'] = _parse_float(self.cg_radius_var.get(), 'radius_m')
        item = {
            'id': self.cg_id_var.get().strip(),
            'image': self.cg_image_var.get().strip(),
            'text': self._text_value(self.cg_text),
            'duration': _parse_float(self.cg_duration_var.get(), 'duration'),
            'once': bool(self.cg_once_var.get()),
            'skippable': bool(self.cg_skippable_var.get()),
            'enabled': bool(self.cg_enabled_var.get()),
            'trigger': trigger,
        }
        return item

    def cg_form_dirty(self):
        item = self.current_cg()
        if item is None:
            return False
        try:
            values = self.cg_form_values()
        except ValueError:
            return True
        return any(item.get(key) != values[key] for key in values)

    def on_cg_select(self, event=None):
        if self._syncing:
            return
        selection = self.cg_list.curselection()
        if not selection:
            return
        if self.cg_index is not None and selection[0] == self.cg_index:
            return
        if not self.apply_cg():
            self._syncing = True
            try:
                if self.cg_index is not None:
                    self.cg_list.selection_clear(0, 'end')
                    self.cg_list.selection_set(self.cg_index)
            finally:
                self._syncing = False
            return
        self.cg_index = selection[0]
        self.fill_cg_form()
        self.update_status()

    def apply_cg(self):
        item = self.current_cg()
        if item is None:
            return True
        try:
            values = self.cg_form_values()
        except ValueError as exc:
            messagebox.showerror('属性错误', str(exc), parent=self.root)
            return False
        item.clear()
        item.update(values)
        self.refresh_cg_list()
        return True

    def add_cg(self):
        if not isinstance(self.cg_data, dict):
            messagebox.showinfo('新增 CG', '请先创建或选择这份地图的 CG 配置。', parent=self.root)
            return
        if not self.apply_cg():
            return
        items = self.cg_items()
        used = {str(item.get('id')) for item in items if isinstance(item, dict)}
        new_id = self._unique_id('cg', used)
        map_id = os.path.splitext(os.path.basename(self.map_path or ''))[0]
        items.append({
            'id': new_id,
            'image': 'res://assets/cg/' + new_id + '.png',
            'text': '',
            'duration': 3.0,
            'once': True,
            'skippable': True,
            'enabled': True,
            'trigger': {'type': 'map_enter', 'map': map_id},
        })
        self.cg_index = len(items) - 1
        self.refresh_cg_list()
        self.update_status()

    def delete_cg(self):
        item = self.current_cg()
        if item is None:
            return
        if not messagebox.askyesno('删除 CG', f"删除 {item.get('id', '')}？", parent=self.root):
            return
        items = self.cg_items()
        index = self.cg_index
        items.pop(index)
        self.cg_index = None if not items else min(index, len(items) - 1)
        self.refresh_cg_list()
        self.update_status()

    def move_cg(self, step):
        item = self.current_cg()
        if item is None:
            return
        items = self.cg_items()
        target = self.cg_index + step
        if not 0 <= target < len(items):
            return
        if not self.apply_cg():
            return
        items[self.cg_index], items[target] = items[target], items[self.cg_index]
        self.cg_index = target
        self.refresh_cg_list()
        self.update_status()

    def browse_cg_image(self):
        initial = os.path.join(PROJECT_ROOT, 'assets', 'cg')
        path = filedialog.askopenfilename(
            initialdir=initial if os.path.isdir(initial) else os.path.join(PROJECT_ROOT, 'assets'),
            filetypes=[('图片', '*.png *.jpg *.jpeg *.webp *.svg *.bmp *.tres'), ('所有文件', '*')],
            parent=self.root,
        )
        if not path:
            return
        relative = os.path.relpath(os.path.abspath(path), PROJECT_ROOT).replace(os.sep, '/')
        self.cg_image_var.set('res://' + relative)

    def _set_cg_path(self, res_path):
        self.map_data['cg_data_path'] = res_path
        self.cg_res = res_path
        self.cg_path = cg_res_to_disk(res_path)
        try:
            self.cg_data = read_cg(self.cg_path)
            self.cg_message = ''
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            self.cg_data = None
            self.cg_message = f'CG 配置无法读取：{exc}'
        self.cg_saved = copy.deepcopy(self.cg_data)
        self.cg_index = None
        return True

    def create_cg_file(self):
        if self.map_data is None:
            return
        map_id = os.path.splitext(os.path.basename(self.map_path or ''))[0]
        if not map_id:
            return
        if not os.path.isdir(CG_DIR):
            os.makedirs(CG_DIR, exist_ok=True)
        default_path = os.path.join(CG_DIR, map_id + '.json')
        if os.path.isfile(default_path):
            if not messagebox.askyesno('已存在', f'{default_path} 已存在，覆盖为空配置？', parent=self.root):
                return
        try:
            write_json(default_path, default_cg_data(map_id))
            self._set_cg_path(cg_disk_to_res(default_path))
        except (OSError, ValueError) as exc:
            messagebox.showerror('创建失败', str(exc), parent=self.root)
            return
        self.refresh_cg_list()
        self.set_control_state()
        self.update_status()

    def choose_cg_file(self):
        if self.map_data is None:
            return
        os.makedirs(CG_DIR, exist_ok=True)
        path = filedialog.askopenfilename(
            initialdir=CG_DIR,
            filetypes=[('CG 配置', '*.json'), ('所有文件', '*')],
            parent=self.root,
        )
        if not path:
            return
        try:
            self._set_cg_path(cg_disk_to_res(path))
        except (OSError, ValueError) as exc:
            messagebox.showerror('选择失败', str(exc), parent=self.root)
            return
        self.refresh_cg_list()
        self.set_control_state()
        self.update_status()

    def copy_cg_file(self):
        if not isinstance(self.cg_data, dict):
            messagebox.showinfo('复制 CG 配置', '当前没有可复制的 CG 配置。', parent=self.root)
            return
        path = filedialog.asksaveasfilename(
            initialdir=CG_DIR, defaultextension='.json',
            filetypes=[('CG 配置', '*.json')], parent=self.root,
        )
        if not path:
            return
        data = copy.deepcopy(self.cg_data)
        map_id = os.path.splitext(os.path.basename(self.map_path or ''))[0]
        data['map'] = map_id
        try:
            write_json(path, data)
            self._set_cg_path(cg_disk_to_res(path))
        except (OSError, ValueError) as exc:
            messagebox.showerror('复制失败', str(exc), parent=self.root)
            return
        self.refresh_cg_list()
        self.set_control_state()
        self.update_status()

    def open_cg_dir(self):
        try:
            os.makedirs(CG_DIR, exist_ok=True)
            os.startfile(CG_DIR)
        except OSError as exc:
            messagebox.showerror('打开失败', str(exc), parent=self.root)

    def _load_cg_for_map(self):
        self.cg_data = None
        self.cg_path = None
        self.cg_res = None
        self.cg_saved = None
        self.cg_message = ''
        self.cg_index = None
        bound = self.map_data.get('cg_data_path') if isinstance(self.map_data, dict) else None
        if not bound:
            return
        self.cg_res = bound
        try:
            self.cg_path = cg_res_to_disk(bound)
        except ValueError as exc:
            self.cg_message = str(exc)
            return
        if not os.path.isfile(self.cg_path):
            self.cg_message = f'CG 配置不存在：{self.cg_path}'
            return
        try:
            self.cg_data = read_cg(self.cg_path)
            self.cg_saved = copy.deepcopy(self.cg_data)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            self.cg_message = f'CG 配置无法读取：{exc}'

    def write_cg_data(self):
        """只写 CG JSON，供保存与自检复用。"""
        validate_cg(self.cg_data, self.map_data)
        write_json(self.cg_path, self.cg_data)
        self.cg_saved = copy.deepcopy(self.cg_data)

    # -- 地图路径与事件文件 -----------------------------------------------
    def _unique_id(self, prefix, used):
        index = 1
        while f'{prefix}_{index}' in used:
            index += 1
        return f'{prefix}_{index}'

    def _set_object_path(self, res_path):
        obj = self.current_object()
        if obj is None:
            return False
        fields = obj.setdefault('fields', {})
        fields['interaction_data_path'] = res_path
        self.planet_res = res_path
        self.planet_path = res_to_disk(res_path)
        self.refresh_map_tree()
        self.update_status()
        return True

    def create_planet_file(self):
        obj = self.current_object()
        if obj is None:
            return
        default_name = f"{obj['id']}.json"
        path = filedialog.asksaveasfilename(
            parent=self.root,
            initialdir=PLANET_DIR,
            initialfile=default_name,
            defaultextension='.json',
            filetypes=[('事件 JSON', '*.json')],
        )
        if not path:
            return
        try:
            res_path = disk_to_res(path)
        except ValueError as exc:
            messagebox.showerror('路径不可用', str(exc), parent=self.root)
            return
        if os.path.isfile(path) and not messagebox.askyesno(
                '文件已存在', f'{os.path.basename(path)} 已存在，覆盖它？', parent=self.root):
            return
        stem = os.path.splitext(os.path.basename(path))[0]
        name = obj.get('fields', {}).get('display_name') or stem
        data = default_planet_data(stem, name)
        try:
            write_json(path, data)
        except (OSError, ValueError) as exc:
            messagebox.showerror('创建失败', str(exc), parent=self.root)
            return
        self._set_object_path(res_path)
        self.object_id = obj['id']
        self._load_planet_for_object()
        self.refresh_all_tabs()
        self.set_control_state()
        self.update_status()

    def choose_planet_file(self):
        obj = self.current_object()
        if obj is None:
            return
        path = filedialog.askopenfilename(
            parent=self.root,
            initialdir=PLANET_DIR,
            filetypes=[('事件 JSON', '*.json'), ('所有文件', '*')],
        )
        if not path:
            return
        try:
            res_path = disk_to_res(path)
            data = read_planet(path, self.map_data)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            messagebox.showerror('无法使用该文件', str(exc), parent=self.root)
            return
        self._set_object_path(res_path)
        self.object_id = obj['id']
        self.planet_data = data
        self.planet_saved = copy.deepcopy(data)
        self.planet_path = path
        self.planet_res = res_path
        self.planet_message = ''
        self.refresh_all_tabs()
        self.set_control_state()
        self.update_status()

    def copy_planet_file(self):
        obj = self.current_object()
        if obj is None or self.planet_data is None:
            messagebox.showinfo('复制为新文件', '请先选择带有事件 JSON 的对象。', parent=self.root)
            return
        stem = os.path.splitext(os.path.basename(self.planet_path or 'planet.json'))[0]
        path = filedialog.asksaveasfilename(
            parent=self.root,
            initialdir=PLANET_DIR,
            initialfile=f'{stem}_copy.json',
            defaultextension='.json',
            filetypes=[('事件 JSON', '*.json')],
        )
        if not path:
            return
        try:
            res_path = disk_to_res(path)
        except ValueError as exc:
            messagebox.showerror('路径不可用', str(exc), parent=self.root)
            return
        if os.path.isfile(path) and not messagebox.askyesno(
                '文件已存在', f'{os.path.basename(path)} 已存在，覆盖它？', parent=self.root):
            return
        data = copy.deepcopy(self.planet_data)
        data['planet_id'] = os.path.splitext(os.path.basename(path))[0]
        try:
            write_json(path, data)
        except (OSError, ValueError) as exc:
            messagebox.showerror('复制失败', str(exc), parent=self.root)
            return
        self._set_object_path(res_path)
        self.object_id = obj['id']
        self._load_planet_for_object()
        self.refresh_all_tabs()
        self.set_control_state()
        self.update_status()

    def open_planet_dir(self):
        try:
            os.startfile(PLANET_DIR)
        except OSError as exc:
            messagebox.showerror('打开失败', str(exc), parent=self.root)

    # -- 校验与保存 -------------------------------------------------------
    def apply_forms(self):
        for apply in (self.apply_event, self.apply_person, self.apply_quest, self.apply_speech, self.apply_cg):
            if not apply():
                return False
        return True

    def show_errors(self, title, errors):
        shown = errors[:20]
        text = '\n'.join(shown)
        if len(errors) > len(shown):
            text += f'\n…等 {len(errors)} 条'
        messagebox.showerror(title, text, parent=self.root)

    def check_current(self):
        if not self.apply_forms():
            return
        errors = []
        warnings = []
        if self.planet_data is not None:
            errors.extend(collect_planet_errors(self.planet_data, self.map_data, self.person_registry(), self.quest_registry()))
        if isinstance(self.cg_data, dict):
            errors.extend(collect_cg_errors(self.cg_data, self.map_data))
            warnings.extend(collect_cg_warnings(self.cg_data, self.map_data))
        if self.planet_data is None and not isinstance(self.cg_data, dict):
            messagebox.showinfo('校验', '当前没有可校验的数据。', parent=self.root)
            return
        if errors:
            self.show_errors('校验未通过', errors)
            return
        if warnings:
            messagebox.showwarning('校验通过（有提示）', '\n'.join(warnings[:20]), parent=self.root)
            return
        messagebox.showinfo('校验', '校验通过。', parent=self.root)

    def save_all(self, silent=False):
        if not self.apply_forms():
            return False
        has_cg = isinstance(self.cg_data, dict)
        if self.planet_data is None and not has_cg and not self.map_dirty():
            if not silent:
                messagebox.showinfo('保存全部', '没有需要写入的内容。', parent=self.root)
            return True
        if self.planet_data is not None:
            errors = collect_planet_errors(self.planet_data, self.map_data, self.person_registry(), self.quest_registry())
            if errors:
                self.show_errors('无法保存', errors)
                return False
            try:
                write_json(self.planet_path, self.planet_data)
            except (OSError, ValueError) as exc:
                messagebox.showerror('保存失败', str(exc), parent=self.root)
                return False
            self.planet_saved = copy.deepcopy(self.planet_data)
        if has_cg:
            errors = collect_cg_errors(self.cg_data, self.map_data)
            if errors:
                self.show_errors('无法保存 CG 配置', errors)
                return False
            try:
                write_json(self.cg_path, self.cg_data)
            except (OSError, ValueError) as exc:
                messagebox.showerror('保存 CG 配置失败', str(exc), parent=self.root)
                return False
            self.cg_saved = copy.deepcopy(self.cg_data)
        if self.map_dirty():
            try:
                write_map(self.map_path, self.map_data)
            except (OSError, ValueError) as exc:
                messagebox.showerror('保存地图失败', str(exc), parent=self.root)
                return False
            self.map_saved = copy.deepcopy(self.map_data)
        self.refresh_map_tree()
        self.refresh_quest_person_combo()
        self.refresh_cg_list()
        self.update_status()
        if not silent:
            messagebox.showinfo(
                '保存成功',
                f'事件数据：{self.planet_path or "（无）"}\nCG 配置：{self.cg_path or "（无）"}\n地图：{self.map_path}',
                parent=self.root,
            )
        return True

    def write_planet_data(self):
        """只写事件 JSON，供自检复用。"""
        validate_planet(self.planet_data, self.map_data, self.person_registry(), self.quest_registry())
        write_json(self.planet_path, self.planet_data)
        self.planet_saved = copy.deepcopy(self.planet_data)

    def close(self):
        if self.has_unsaved():
            if not messagebox.askyesno('未保存的修改', '有未保存的修改，确定关闭？', parent=self.root):
                return
        self.root.destroy()


# ---------------------------------------------------------------------------
# 命令行
# ---------------------------------------------------------------------------

def check_cli(paths, user_map=None):
    if not paths:
        paths = sorted(glob.glob(os.path.join(MAPS_DIR, '*.json')))
    extra_maps = [user_map] if user_map else []
    if not paths and not extra_maps:
        print('没有找到地图文件：' + MAPS_DIR)
        return 1
    failed = 0
    for path in _unique_paths(list(paths) + extra_maps):
        try:
            relative = os.path.relpath(path, PROJECT_ROOT)
        except ValueError:
            relative = path
        try:
            data = read_map(path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f'FAIL {relative}: {exc}')
            failed += 1
            continue
        print(f'OK {relative}')
        for obj in map_objects(data):
            res_path = obj.get('fields', {}).get('interaction_data_path')
            try:
                if not res_path:
                    raise ValueError('未配置 interaction_data_path')
                disk = res_to_disk(res_path)
                if not os.path.isfile(disk):
                    raise ValueError(f'事件 JSON 不存在：{disk}')
                planet = read_planet(disk, data)
                validate_planet(planet, data, person_registry(data), quest_registry(data, disk, planet))
            except (OSError, ValueError, json.JSONDecodeError) as exc:
                print(f'  - {obj["id"]}: {exc}')
                failed += 1
            else:
                print(f'  - {obj["id"]}: OK')
        bound = data.get('cg_data_path')
        if not bound:
            print('  - CG: 未绑定')
            continue
        map_id = os.path.splitext(os.path.basename(path))[0]
        try:
            disk = cg_res_to_disk(bound)
            if not os.path.isfile(disk):
                raise ValueError(f'CG 配置不存在：{disk}')
            cg_data = read_cg(disk)
            owner = cg_data.get('map')
            if isinstance(owner, str) and owner and os.path.splitext(os.path.basename(owner))[0] != map_id:
                raise ValueError(f'CG 配置归属 {owner} 与地图 {map_id} 不一致')
            errors = collect_cg_errors(cg_data, data)
            if errors:
                raise ValueError('；'.join(errors))
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f'  - CG({bound}): {exc}')
            failed += 1
        else:
            print(f'  - CG({bound}): OK')
            for warning in collect_cg_warnings(cg_data, data):
                print(f'    WARN: {warning}')
    print('')
    print('事件数据引用（只看 interaction_data_path 里写的路径，与对象 id / 文件名无关）')
    refs = scan_event_references(extra_maps=extra_maps, map_paths=paths)
    if not refs:
        print('  （没有对象绑定事件数据）')
    for res_path in sorted(refs):
        referrers = refs[res_path]
        names = '、'.join(f"{item['map']}:{item['id']}" for item in referrers)
        print(f'  {res_path} -> {names}')
    known = set(refs)
    for disk_path in sorted(glob.glob(os.path.join(PLANET_DIR, '*.json'))):
        res_path = RES_PREFIX + os.path.basename(disk_path)
        if res_path not in known:
            print(f'  WARN {res_path} 没有被任何地图引用')
    return 0 if failed == 0 else 1


def refs_cli(target, user_map=None):
    """列出某份事件 JSON 被哪些地图对象引用。"""
    if not target:
        print('用法：quest_editor.py --refs <文件名|res://…json> [--with-user-map <用户地图>]')
        return 1
    if target.startswith('res://'):
        res_path = target
    else:
        name = target if target.endswith('.json') else target + '.json'
        res_path = RES_PREFIX + os.path.basename(name)
    extra_maps = [user_map] if user_map else []
    referrers = scan_event_references(extra_maps=extra_maps).get(res_path, [])
    if not referrers:
        print(f'{res_path}：没有被任何地图引用（改了也不会出现在游戏里）')
        return 1
    print(f'{res_path} 被 {len(referrers)} 个对象引用：')
    for item in referrers:
        print(f"  - {item['map']} / {item['id']}")
    return 0


def selftest():
    checks = []

    def check(condition, message):
        if not condition:
            raise AssertionError(message)
        checks.append(message)

    def raises(call):
        try:
            call()
        except ValueError:
            return True
        return False

    import shutil
    temporary = tempfile.mkdtemp(prefix='quest_editor_selftest_')
    root = None
    try:
        root = tk.Tk()
        root.withdraw()
        editor = Editor(root)

        map_path = os.path.join(MAPS_DIR, 'default_map.json')
        check(os.path.isfile(map_path), 'default_map.json 存在')
        editor.load_map_path(map_path)
        check(editor.map_data is not None, '地图已载入')
        objects = map_objects(editor.map_data)
        check(bool(objects), '地图里有 planet / city 对象')
        check(len(editor.tree.get_children()) == len(objects), '左侧列表行数等于对象数')

        for obj in objects:
            check(editor.select_object(obj['id']), f"选中对象 {obj['id']}")
            if editor.planet_data is None:
                check(bool(editor.planet_message), f"{obj['id']} 未载入事件数据时给出提示")
                check(editor.event_list.size() == 0, f"{obj['id']} 事件列表为空")
                check(editor.person_list.size() == 0, f"{obj['id']} 人物列表为空")
                check(editor.quest_list.size() == 0, f"{obj['id']} 委托列表为空")
                continue
            check(editor.event_list.size() == len(editor.planet_data.get('events', [])),
                  f"{obj['id']} 事件列表填充")
            persons = editor.planet_data.get('diplomacy', {}).get('persons', [])
            check(editor.person_list.size() == len(persons), f"{obj['id']} 人物列表填充")
            expected = 0
            for person in persons:
                quests = person.get('quests')
                if isinstance(quests, list):
                    expected += len(quests)
            total = 0
            for index, person in enumerate(persons):
                editor.quest_person_index = index
                editor.refresh_quest_list()
                total += editor.quest_list.size()
            check(total == expected, f"{obj['id']} 委托列表填充")
            for index in range(editor.event_list.size()):
                text = editor.event_list.get(index)
                check(' · ' in text, f"{obj['id']} 事件第 {index} 行格式")

        source = os.path.join(PLANET_DIR, 'planet_a.json')
        check(os.path.isfile(source), 'planet_a.json 存在')
        copied = os.path.join(temporary, 'roundtrip.json')
        shutil.copyfile(source, copied)
        data = read_planet(copied)
        check(bool(data.get('events')), '往返样例里有事件')
        editor.planet_data = data
        editor.planet_path = copied
        editor.planet_saved = copy.deepcopy(data)
        editor.planet_message = ''
        editor.event_index = 0
        editor.quest_person_index = 0
        editor.refresh_all_tabs()
        check(editor.event_title_var.get() == str(data['events'][0]['title']), '表单已填充标题')
        editor.event_title_var.set('往返测试标题')
        check(editor.apply_event(), '应用事件修改')
        check(editor.planet_data['events'][0]['title'] == '往返测试标题', '内存里的标题已更新')
        editor.write_planet_data()
        again = read_planet(copied)
        check(again['events'][0]['title'] == '往返测试标题', '重新读取后标题一致')
        check(again['events'][0]['body'] == data['events'][0]['body'], '正文保持一致')
        check(again['diplomacy'] == data['diplomacy'], '人物结构保持一致')

        bad = copy.deepcopy(again)
        bad['events'][0]['title'] = ''
        check(bool(collect_planet_errors(bad)), '空标题能被校验拦下')
        bad_quest = copy.deepcopy(again)
        for person in bad_quest['diplomacy']['persons']:
            for quest in person.get('quests', []) if isinstance(person.get('quests'), list) else []:
                quest['type'] = 'unknown_type'
        check(bool(collect_planet_errors(bad_quest)), '未知委托类型能被校验拦下')

        # CG：地图级配置在临时目录里往返，绝不写项目内真实数据
        map_id = os.path.splitext(os.path.basename(map_path))[0]
        editor.load_map_path(map_path)
        check(editor.cg_data is None and not editor.cg_path, '未绑定 CG 的地图 CG 页为空')
        cg_dir = os.path.join(temporary, 'cg')
        os.makedirs(cg_dir, exist_ok=True)
        cg_file = os.path.join(cg_dir, map_id + '.json')
        write_json(cg_file, default_cg_data(map_id))
        editor.map_data['cg_data_path'] = CG_PREFIX + map_id + '.json'
        editor.cg_res = CG_PREFIX + map_id + '.json'
        editor.cg_path = cg_file
        editor.cg_data = read_cg(cg_file)
        editor.cg_saved = copy.deepcopy(editor.cg_data)
        editor.refresh_cg_list()
        check(editor.cg_list.size() == 0, '新建 CG 配置初始为空')
        editor.add_cg()
        check(len(editor.cg_data['cgs']) == 1, '新增一条 CG')
        editor.cg_id_var.set('map_open')
        editor.cg_image_var.set('res://assets/cg/map_open.png')
        editor.cg_duration_var.set('4')
        editor.cg_trigger_var.set(CG_TRIGGER_LABELS['enter_object'])
        editor.on_cg_type_change()
        editor.cg_object_var.set('*')
        editor._set_text(editor.cg_text, '地图开场')
        check(editor.apply_cg(), '应用 CG 表单')
        item = editor.cg_data['cgs'][0]
        check(item['trigger']['type'] == 'enter_object' and item['trigger']['object'] == '*', 'CG 触发条件写入')
        check(editor.cg_dirty(), '编辑后标记为未保存')
        check(not collect_cg_errors(editor.cg_data, editor.map_data), 'CG 校验通过')
        editor.write_cg_data()
        again_cg = read_cg(cg_file)
        check(again_cg['cgs'][0]['id'] == 'map_open', 'CG 往返保存后 id 一致')
        check(again_cg['map'] == map_id, 'CG 文件声明了所属地图')
        bad_cg = copy.deepcopy(again_cg)
        bad_cg['cgs'][0]['duration'] = 0
        check(bool(collect_cg_errors(bad_cg, editor.map_data)), 'duration=0 被拦下')
        bad_cg = copy.deepcopy(again_cg)
        bad_cg['cgs'][0]['trigger'] = {'type': 'nope'}
        check(bool(collect_cg_errors(bad_cg)), '未知 CG 触发类型被拦下')
        bad_cg = copy.deepcopy(again_cg)
        bad_cg['cgs'][0]['trigger'] = {'type': 'enter_object', 'object': 'nope'}
        check(bool(collect_cg_errors(bad_cg, editor.map_data)), 'CG 指向不存在的对象被拦下')
        bad_map = copy.deepcopy(editor.map_data)
        bad_map['cg_data_path'] = 'res://data/planets/planet_a.json'
        check(raises(lambda: validate_map(bad_map)), '非法 cg_data_path 被地图校验拦下')
        check(bool(collect_cg_warnings(again_cg, editor.map_data)), '缺图给出提示而不是错误')
    except Exception as exc:  # noqa: BLE001 - 自检需要报告所有失败
        print(f'SELFTEST FAIL: {exc}')
        return 1
    finally:
        if root is not None:
            try:
                root.destroy()
            except tk.TclError:
                pass
        shutil.rmtree(temporary, ignore_errors=True)
    print(f'SELFTEST PASS {len(checks)} checks')
    return 0


def main(argv):
    if argv and argv[0] == '--check':
        return check_cli(argv[1:])
    if argv and argv[0] == '--selftest':
        return selftest()
    root = tk.Tk()
    Editor(root)
    root.mainloop()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
