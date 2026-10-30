"""独立二维地图编辑器，仅依赖 Python 标准库。"""
import copy
import json
import math
import os
import re
import tempfile
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

DEFAULTS = {
    'planet': {'display_name': '行星', 'radius_m': 50000.0, 'field_height_m': 3000.0, 'surface_gravity': 9.81, 'max_gravity_radius_m': 250000.0, 'interaction_data_path': 'res://data/planets/planet_a.json'},
    'city': {'display_name': '平面核城市', 'rotation_degrees_m': 0.0, 'city_size_m': [100000.0, 20000.0], 'gravity_height_m': 30000.0, 'port_offset_m': [60000.0, 0.0], 'docking_radius_m': 20000.0, 'dock_offset_m': [0.0, -5000.0], 'interaction_data_path': 'res://data/planets/flat_nuclear_city.json'},
    'asteroid': {'initial_velocity': [550.0, 0.0], 'radius_m': 1000.0, 'mass_kg': 1000000.0, 'mineral_id': '', 'mineral_unit_mass': 1.0, 'style_index': 0},
    'debris': {'initial_velocity': [600.0, 0.0], 'radius_m': 500.0, 'debris_count': 24, 'debris_size_m': 40.0, 'minimum_fragment_pixels': 4.0},
    'ship': {'initial_velocity': [0.0, 0.0]},
}
LABELS = {'id': 'ID', 'position': '位置 X, Y（米）', 'display_name': '名称', 'radius_m': '半径（米）', 'field_height_m': '恒强引力层高度（米）', 'surface_gravity': '表面重力（m/s²）', 'max_gravity_radius_m': '最大引力半径（米）', 'interaction_data_path': '交互数据路径', 'rotation_degrees_m': '旋转角度（度，顺时针为正）', 'city_size_m': '城市宽, 高（米）', 'gravity_height_m': '重力区高度（米）', 'port_offset_m': '港口偏移 X, Y（米）', 'docking_radius_m': '泊船半径（米）', 'dock_offset_m': '泊位偏移 X, Y（米）', 'initial_velocity': '初速度 X, Y（m/s）', 'mass_kg': '质量（kg）', 'mineral_id': '矿物 ID', 'mineral_unit_mass': '单位矿物质量（kg）', 'style_index': '外观索引（0–2）', 'debris_count': '碎片数（0–32）', 'debris_size_m': '碎片尺寸（米）', 'minimum_fragment_pixels': '最小碎片像素'}
COLORS = {'planet': '#5688d4', 'city': '#50c3aa', 'asteroid': '#c5a277', 'debris': '#df6969', 'ship': '#ffe17a'}
NAMES = {'planet': '行星', 'city': '城市', 'asteroid': '小行星', 'debris': '碎片', 'ship': '飞船起点'}


def validate_map(data):
    if not isinstance(data, dict) or data.get('version') != 1 or not isinstance(data.get('objects'), list) or len(data['objects']) > 1000:
        raise ValueError('需要 version 为 1 且 objects 为数组的地图')
    ids = set()
    for obj in data['objects']:
        if not isinstance(obj, dict) or obj.get('type') not in DEFAULTS or obj.get('type') == 'ship' or not isinstance(obj.get('id'), str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', obj['id']) or obj['id'] in ids:
            raise ValueError('对象必须具有支持的 type 和非空且唯一的 id')
        ids.add(obj['id'])
        fields = obj.get('fields', {})
        if not isinstance(fields, dict) or any(key not in DEFAULTS[obj['type']] for key in fields):
            raise ValueError(f"{obj['id']} 的 fields 包含不支持的字段")
        values = {'position': obj.get('position'), **fields}
        for key, value in values.items():
            default = [0, 0] if key == 'position' else DEFAULTS[obj['type']][key]
            if isinstance(default, list):
                if not isinstance(value, list) or len(value) != 2 or any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or abs(v) > 1e9 for v in value):
                    raise ValueError(f"{obj['id']} 的 {key} 必须是范围在 ±10 亿内的二维数字")
                if key == 'city_size_m' and min(value) <= 0:
                    raise ValueError('城市宽高必须大于零')
            elif isinstance(default, str):
                if not isinstance(value, str) or len(value) > 256:
                    raise ValueError(f"{obj['id']} 的 {key} 必须是不超过 256 字符的字符串")
                if key == 'interaction_data_path' and (not value.startswith('res://data/planets/') or not value.endswith('.json') or '..' in value or '\\' in value):
                    raise ValueError('交互数据路径必须是 res://data/planets/ 下的 JSON 文件')
            elif key == 'rotation_degrees_m':
                if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or abs(value) > 360000:
                    raise ValueError(f"{obj['id']} 的旋转角度必须在 ±360000 度内")
            else:
                minimum = 0 if key in ('field_height_m', 'surface_gravity', 'style_index', 'debris_count', 'minimum_fragment_pixels') else 1e-6
                if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not minimum <= value <= 1e15:
                    raise ValueError(f"{obj['id']} 的 {key} 数值超出范围")
                if key in ('style_index', 'debris_count') and (value != int(value) or value > (2 if key == 'style_index' else 32)):
                    raise ValueError(f"{obj['id']} 的 {key} 数值无效")
    if 'ship' in data:
        ship = data['ship']
        if not isinstance(ship, dict) or not all(isinstance(ship.get(k), list) and len(ship[k]) == 2 and all(isinstance(n, (int, float)) and not isinstance(n, bool) and math.isfinite(n) and abs(n) <= 1e9 for n in ship[k]) for k in ('position', 'velocity')):
            raise ValueError('ship 的 position 和 velocity 必须是范围在 ±10 亿内的二维数字')


def read_map(path):
    with open(path, 'rb') as f:
        raw = f.read(1048577)
    if len(raw) > 1048576:
        raise ValueError('地图文件不能超过 1 MiB')
    data = json.loads(raw.decode('utf-8'))
    validate_map(data)
    ids = {obj['id'] for obj in data['objects']}
    for obj in data['objects']:
        fields = obj.pop('fields', {})
        obj.update(fields)
    if 'ship' in data:
        ship = data.pop('ship')
        if not isinstance(ship, dict) or not all(isinstance(ship.get(k), list) and len(ship[k]) == 2 and all(isinstance(n, (int, float)) and not isinstance(n, bool) and math.isfinite(n) and abs(n) <= 1e9 for n in ship[k]) for k in ('position', 'velocity')):
            raise ValueError('ship 的 position 和 velocity 必须是范围在 ±10 亿内的二维数字')
        ship_id = 'ship'
        while ship_id in ids:
            ship_id += '_'
        data['objects'].append({'type': 'ship', 'id': ship_id, 'position': ship['position'], 'initial_velocity': ship['velocity']})
    return data


def write_map(path, data):
    exported = copy.deepcopy(data)
    for obj in list(exported['objects']):
        if obj['type'] == 'ship':
            exported['ship'] = {'position': obj['position'], 'velocity': obj['initial_velocity']}
            exported['objects'].remove(obj)
            continue
        fields = {key: obj.pop(key) for key in list(obj) if key not in ('type', 'id', 'position')}
        obj['fields'] = fields
    validate_map(exported)
    raw = (json.dumps(exported, ensure_ascii=False, indent=2, allow_nan=False) + '\n').encode('utf-8')
    if len(raw) > 1048576:
        raise ValueError('地图文件不能超过 1 MiB')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='wb', dir=os.path.dirname(os.path.abspath(path)), delete=False) as f:
            temporary = f.name
            f.write(raw)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            os.unlink(temporary)


class Editor:
    def __init__(self, root):
        self.root = root
        root.title('二维地图编辑器')
        root.geometry('1200x760')
        self.data = {'version': 1, 'objects': []}
        self.path = None
        self.selected = None
        self.scale = 0.002
        self.origin = [500.0, 360.0]
        self.drag = None
        self.fields = {}
        self.saved_data = copy.deepcopy(self.data)
        root.protocol('WM_DELETE_WINDOW', self.close)
        bar = ttk.Frame(root, padding=5)
        bar.pack(fill='x')
        for text, command in [('新建', self.new), ('打开 JSON', self.open), ('保存', self.save), ('另存为', lambda: self.save(True))]:
            ttk.Button(bar, text=text, command=command).pack(side='left', padx=2)
        for kind in DEFAULTS:
            ttk.Button(bar, text='添加' + NAMES[kind], command=lambda k=kind: self.add(k)).pack(side='left', padx=2)
        ttk.Button(bar, text='删除选中', command=self.delete).pack(side='left', padx=2)
        ttk.Label(root, text='左键选中并拖动对象；中键或右键拖动画布；滚轮缩放。坐标以米为单位，Y 向下。').pack(anchor='w', padx=8)
        game_dir = os.path.join(os.environ.get('APPDATA', ''), 'Godot', 'app_userdata', 'Space')
        ttk.Label(root, text='游戏地图路径（Windows）：' + os.path.join(game_dir, 'space_map_v1.json')).pack(anchor='w', padx=8)
        content = ttk.Frame(root)
        content.pack(fill='both', expand=True)
        self.canvas = tk.Canvas(content, background='#151c27', highlightthickness=0)
        self.canvas.pack(side='left', fill='both', expand=True)
        panel = ttk.Frame(content, width=300, padding=8)
        panel.pack(side='right', fill='y')
        panel.pack_propagate(False)
        self.title = ttk.Label(panel, text='未选择对象', font=('', 12, 'bold'))
        self.title.pack(anchor='w')
        self.form = ttk.Frame(panel)
        self.form.pack(fill='x', pady=8)
        ttk.Button(panel, text='应用属性', command=self.apply).pack(fill='x')
        self.status = ttk.Label(root, text='')
        self.status.pack(fill='x')
        self.canvas.bind('<Configure>', lambda e: self.draw())
        self.canvas.bind('<Button-1>', self.select_at)
        self.canvas.bind('<B1-Motion>', self.move_object)
        self.canvas.bind('<ButtonRelease-1>', lambda e: setattr(self, 'drag', None))
        for button in (2, 3):
            self.canvas.bind(f'<Button-{button}>', self.start_pan)
            self.canvas.bind(f'<B{button}-Motion>', self.pan)
        self.canvas.bind('<MouseWheel>', self.zoom)
        self.canvas.bind('<Button-4>', lambda e: self.zoom(e, 1))
        self.canvas.bind('<Button-5>', lambda e: self.zoom(e, -1))
        root.bind('<Delete>', self.delete_key)
        self.draw()

    def screen(self, p):
        return self.origin[0] + p[0] * self.scale, self.origin[1] + p[1] * self.scale

    def world(self, x, y):
        return [(x - self.origin[0]) / self.scale, (y - self.origin[1]) / self.scale]

    def draw(self):
        c = self.canvas
        c.delete('all')
        w, h = c.winfo_width(), c.winfo_height()
        x, y = self.screen([0, 0])
        c.create_line(x, 0, x, h, fill='#405065')
        c.create_line(0, y, w, y, fill='#405065')
        for obj in self.data['objects']:
            kind = obj['type']
            x, y = self.screen(obj.get('position', [0, 0]))
            color = COLORS[kind]
            selected = obj is self.selected
            if kind == 'ship':
                c.create_polygon(x, y-8, x+7, y+6, x-7, y+6, outline='#ffffff' if selected else color, fill='', width=2)
            elif kind == 'city':
                width, height = obj.get('city_size_m', DEFAULTS[kind]['city_size_m'])
                a, b = max(width * self.scale / 2, 5), max(height * self.scale / 2, 5)
                gravity = obj.get('gravity_height_m', DEFAULTS[kind]['gravity_height_m']) * self.scale
                angle = math.radians(obj.get('rotation_degrees_m', 0.0))
                cosine, sine = math.cos(angle), math.sin(angle)
                def point(local_x, local_y):
                    return x + local_x*cosine - local_y*sine, y + local_x*sine + local_y*cosine
                def rectangle(left, top, right, bottom):
                    return [coordinate for corner in ((left, top), (right, top), (right, bottom), (left, bottom)) for coordinate in point(*corner)]
                c.create_polygon(*rectangle(-width*self.scale/2, -height*self.scale/2-gravity, width*self.scale/2, -height*self.scale/2), fill='', outline='#6aa9ff', dash=(4, 3))
                c.create_polygon(*rectangle(-a, -b, a, b), fill='', outline='#ffffff' if selected else color, width=2)
                port_x, port_y = obj.get('port_offset_m', DEFAULTS[kind]['port_offset_m'])
                px, py = point(port_x*self.scale, port_y*self.scale)
                r = obj.get('docking_radius_m', DEFAULTS[kind]['docking_radius_m']) * self.scale
                c.create_oval(px-r, py-r, px+r, py+r, outline=color, dash=(3, 3))
                c.create_line(px-4, py, px+4, py, fill=color)
                c.create_line(px, py-4, px, py+4, fill=color)
                dx, dy = obj.get('dock_offset_m', DEFAULTS[kind]['dock_offset_m'])
                dx, dy = point((port_x+dx)*self.scale, (port_y+dy)*self.scale)
                c.create_polygon(dx, dy-5, dx+5, dy, dx, dy+5, dx-5, dy, fill='#ffe17a')
            else:
                radius = max(obj.get('radius_m', DEFAULTS[kind]['radius_m']) * self.scale, 5)
                c.create_oval(x-radius, y-radius, x+radius, y+radius, outline='#ffffff' if selected else color, width=2)
                if kind == 'planet':
                    r = obj.get('max_gravity_radius_m', DEFAULTS[kind]['max_gravity_radius_m']) * self.scale
                    c.create_oval(x-r, y-r, x+r, y+r, outline='#394f70', dash=(3, 4))
            c.create_text(x+8, y-10, text=obj.get('display_name', obj['id']), fill=color, anchor='sw')
        self.status.config(text=f"对象数：{len(self.data['objects'])}  |  缩放：{self.scale:.6g} 像素/米  |  {self.path or '未保存'}")

    def form_for_selection(self):
        for widget in self.form.winfo_children():
            widget.destroy()
        self.fields = {}
        obj = self.selected
        if obj is None:
            self.title.config(text='未选择对象')
            return
        self.title.config(text=NAMES[obj['type']] + '属性')
        defaults = {'id': '', 'position': [0.0, 0.0], **DEFAULTS[obj['type']]}
        for row, (key, default) in enumerate(defaults.items()):
            ttk.Label(self.form, text=LABELS[key]).grid(row=row, column=0, sticky='w', pady=3)
            value = obj.get(key, default)
            var = tk.StringVar(value=', '.join(map(str, value)) if isinstance(value, list) else str(value))
            ttk.Entry(self.form, textvariable=var, width=23).grid(row=row, column=1, sticky='ew', padx=(5, 0), pady=3)
            self.fields[key] = (var, default)
        self.form.columnconfigure(1, weight=1)

    def apply(self):
        if self.selected is None:
            return True
        result = {}
        try:
            for key, (var, default) in self.fields.items():
                text = var.get().strip()
                if isinstance(default, list):
                    parts = text.split(',')
                    if len(parts) != 2:
                        raise ValueError(f'{LABELS[key]}需要两个以逗号分隔的数字')
                    value = [float(x.strip()) for x in parts]
                    if not all(math.isfinite(x) for x in value):
                        raise ValueError(f'{LABELS[key]}必须是有限数字')
                elif isinstance(default, str):
                    value = text
                else:
                    value = float(text)
                    if not math.isfinite(value):
                        raise ValueError(f'{LABELS[key]}必须是有限数字')
                    if isinstance(default, int):
                        if not value.is_integer():
                            raise ValueError(f'{LABELS[key]}必须是整数')
                        value = int(value)
                result[key] = value
            if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', result['id']) or any(o is not self.selected and o['id'] == result['id'] for o in self.data['objects']):
                raise ValueError('ID 必须唯一，且为 1–64 位英文字母、数字、下划线或连字符')
            for key, value in result.items():
                if isinstance(value, list) and any(abs(x) > 1e9 for x in value):
                    raise ValueError(f'{LABELS[key]}的分量绝对值不能大于 10 亿')
                if isinstance(value, str) and len(value) > 256:
                    raise ValueError(f'{LABELS[key]}不能超过 256 个字符')
                if isinstance(value, (int, float)) and value > 1e15:
                    raise ValueError(f'{LABELS[key]}不能大于 10 的 15 次方')
            path = result.get('interaction_data_path')
            if path is not None and (not path.startswith('res://data/planets/') or not path.endswith('.json') or '..' in path or '\\' in path):
                raise ValueError('交互数据路径必须是 res://data/planets/ 下的 JSON 文件')
            for key in ('radius_m', 'mass_kg', 'mineral_unit_mass', 'gravity_height_m', 'docking_radius_m', 'debris_size_m'):
                if key in result and result[key] < 1e-6:
                    raise ValueError(f'{LABELS[key]}不得小于 0.000001')
            for key in ('field_height_m', 'surface_gravity', 'minimum_fragment_pixels'):
                if key in result and result[key] < 0:
                    raise ValueError(f'{LABELS[key]}不能为负')
            if 'max_gravity_radius_m' in result and result['max_gravity_radius_m'] < 1e-6:
                raise ValueError('最大引力半径不得小于 0.000001')
            if 'rotation_degrees_m' in result and abs(result['rotation_degrees_m']) > 360000:
                raise ValueError('旋转角度必须在 ±360000 度内')
            if 'city_size_m' in result and min(result['city_size_m']) <= 0:
                raise ValueError('城市宽高必须大于零')
            if 'style_index' in result and not 0 <= result['style_index'] <= 2:
                raise ValueError('外观索引必须在 0 到 2 之间')
            if 'debris_count' in result and not 0 <= result['debris_count'] <= 32:
                raise ValueError('碎片数必须在 0 到 32 之间')
        except ValueError as exc:
            messagebox.showerror('属性错误', str(exc), parent=self.root)
            return False
        if 'rotation_degrees_m' not in self.selected and result.get('rotation_degrees_m') == 0.0:
            result.pop('rotation_degrees_m')
        self.selected.update(result)
        self.draw()
        return True

    def add(self, kind):
        if not self.apply():
            return
        if kind == 'ship' and any(o['type'] == 'ship' for o in self.data['objects']):
            messagebox.showinfo('飞船起点', '地图最多只能设置一个飞船起点。', parent=self.root)
            return
        ids = {o['id'] for o in self.data['objects']}
        if len(self.data['objects']) - sum(o['type'] == 'ship' for o in self.data['objects']) >= 1000 and kind != 'ship':
            messagebox.showerror('对象数量', '地图最多支持 1000 个对象。', parent=self.root)
            return
        i = 1
        while f'{kind}_{i}' in ids:
            i += 1
        center = self.world(self.canvas.winfo_width()/2, self.canvas.winfo_height()/2)
        obj = {'type': kind, 'id': f'{kind}_{i}', 'position': center, **copy.deepcopy(DEFAULTS[kind])}
        self.data['objects'].append(obj)
        self.selected = obj
        self.form_for_selection()
        self.draw()

    def select_at(self, event):
        if not self.apply():
            return
        best, distance = None, float('inf')
        for obj in reversed(self.data['objects']):
            x, y = self.screen(obj.get('position', [0, 0]))
            dx, dy = abs(x-event.x), abs(y-event.y)
            if obj['type'] == 'city':
                size = obj.get('city_size_m', DEFAULTS['city']['city_size_m'])
                angle = math.radians(obj.get('rotation_degrees_m', 0.0))
                offset_x, offset_y = event.x-x, event.y-y
                local_x = offset_x*math.cos(angle) + offset_y*math.sin(angle)
                local_y = -offset_x*math.sin(angle) + offset_y*math.cos(angle)
                hit = abs(local_x) <= max(size[0]*self.scale/2, 8) and abs(local_y) <= max(size[1]*self.scale/2, 8)
            else:
                radius = 10 if obj['type'] == 'ship' else max(obj.get('radius_m', DEFAULTS[obj['type']]['radius_m'])*self.scale, 8)
                hit = math.hypot(dx, dy) <= radius
            d = math.hypot(dx, dy)
            if hit and d < distance:
                best, distance = obj, d
        self.selected = best
        self.drag = (event.x, event.y, list(best.get('position', [0, 0]))) if best else None
        self.form_for_selection()
        self.draw()

    def move_object(self, event):
        if self.drag and self.selected:
            x, y, p = self.drag
            self.selected['position'] = [p[0] + (event.x-x)/self.scale, p[1] + (event.y-y)/self.scale]
            self.form_for_selection()
            self.draw()

    def start_pan(self, event):
        self.drag = (event.x, event.y, list(self.origin))

    def pan(self, event):
        if self.drag:
            x, y, origin = self.drag
            self.origin = [origin[0]+event.x-x, origin[1]+event.y-y]
            self.draw()

    def zoom(self, event, direction=None):
        direction = direction or (1 if event.delta > 0 else -1)
        point = self.world(event.x, event.y)
        self.scale = max(1e-9, min(10.0, self.scale * (1.2 if direction > 0 else 1/1.2)))
        self.origin = [event.x-point[0]*self.scale, event.y-point[1]*self.scale]
        self.draw()

    def delete_key(self, event):
        if not isinstance(event.widget, (tk.Entry, ttk.Entry)):
            self.delete()

    def delete(self):
        if self.selected and messagebox.askyesno('删除', f"删除 {self.selected['id']}？", parent=self.root):
            self.data['objects'].remove(self.selected)
            self.selected = None
            self.form_for_selection()
            self.draw()

    def confirm_discard(self):
        pending = self.selected is not None and any(var.get().strip() != (', '.join(map(str, self.selected.get(key, default))) if isinstance(default, list) else str(self.selected.get(key, default))) for key, (var, default) in self.fields.items())
        return not (pending or self.data != self.saved_data) or messagebox.askyesno('未保存的修改', '放弃未保存的修改？', parent=self.root)

    def close(self):
        if self.confirm_discard():
            self.root.destroy()

    def new(self):
        if self.confirm_discard():
            self.data, self.path, self.selected = {'version': 1, 'objects': []}, None, None
            self.saved_data = copy.deepcopy(self.data)
            self.form_for_selection()
            self.draw()

    def open(self):
        if not self.confirm_discard():
            return
        path = filedialog.askopenfilename(filetypes=[('JSON 地图', '*.json'), ('所有文件', '*')])
        if not path:
            return
        try:
            data = read_map(path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            messagebox.showerror('打开失败', str(exc), parent=self.root)
            return
        self.data, self.path, self.selected = data, path, None
        self.saved_data = copy.deepcopy(self.data)
        self.form_for_selection()
        self.draw()

    def save(self, save_as=False):
        if not self.apply():
            return
        path = self.path if not save_as else None
        if not path:
            appdata = os.environ.get('APPDATA', '')
            default_dir = os.path.join(appdata, 'Godot', 'app_userdata', 'Space')
            options = {'initialfile': 'space_map_v1.json', 'defaultextension': '.json', 'filetypes': [('JSON 地图', '*.json')]}
            if appdata and os.path.isdir(default_dir):
                options['initialdir'] = default_dir
            path = filedialog.asksaveasfilename(**options)
        if not path:
            return
        try:
            write_map(path, self.data)
        except (OSError, ValueError) as exc:
            messagebox.showerror('保存失败', str(exc), parent=self.root)
            return
        self.path = path
        self.saved_data = copy.deepcopy(self.data)
        self.draw()
        messagebox.showinfo('保存成功', f'地图已保存至：\n{path}', parent=self.root)


if __name__ == '__main__':
    root = tk.Tk()
    Editor(root)
    root.mainloop()
