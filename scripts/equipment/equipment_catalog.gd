class_name EquipmentCatalog
extends RefCounted
## 船坞装备目录：唯一数据源 res://data/equipment.json。
## 装备的行为逻辑留在脚本里；名称、说明、价格、是否需要任务解锁，以及全部可调数值都从这里读。
## 任务编辑器（tools/quest_editor.py）读取同一份文件，给委托配置 reward_unlock。

const PATH := "res://data/equipment.json"
const MAX_NUMBER := 1000000000000.0

static var _entries: Dictionary = {}
static var _loaded := false
static var _error := ""

## 读取并校验整份目录；失败时回退到内置最小定义，保证游戏照常启动。
## 返回 true 表示用的是 JSON 配置。
static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var result := _read()
	if not result.error.is_empty():
		_error = result.error
		push_error("装备目录不可用，已回退内置定义：%s" % _error)
		_entries = _fallback_entries()
		return
	_entries = result.data

static func reload() -> void:
	_loaded = false
	_entries = {}
	_error = ""
	_ensure_loaded()

static func error() -> String:
	_ensure_loaded()
	return _error

## 全部装备：id -> {name, description, credits, requires_unlock, stackable, values}。
static func entries() -> Dictionary:
	_ensure_loaded()
	return _entries

static func has(id: String) -> bool:
	_ensure_loaded()
	return _entries.has(id)

static func get_entry(id: String) -> Dictionary:
	_ensure_loaded()
	var entry: Variant = _entries.get(id, {})
	return entry if entry is Dictionary else {}

static func values(id: String) -> Dictionary:
	var entry := get_entry(id)
	var value: Variant = entry.get("values", {})
	return value if value is Dictionary else {}

static func display_name(id: String) -> String:
	var entry := get_entry(id)
	return str(entry.get("name", id))

static func description(id: String) -> String:
	return str(get_entry(id).get("description", ""))

static func credits(id: String, fallback: int = 100) -> int:
	var entry := get_entry(id)
	if entry.is_empty():
		return fallback
	return int(entry.get("credits", fallback))

static func requires_unlock(id: String) -> bool:
	return bool(get_entry(id).get("requires_unlock", false))

static func stackable(id: String) -> bool:
	return bool(get_entry(id).get("stackable", false))

## 数值读取：缺字段、类型不对、超范围都回落到调用点给的默认值，不让配置错误变成 NaN。
static func number(id: String, key: String, fallback: float) -> float:
	return number_from(values(id), key, fallback)

static func number_from(source: Dictionary, key: String, fallback: float) -> float:
	var raw: Variant = source.get(key, null)
	if not (raw is int or raw is float):
		return fallback
	var value := float(raw)
	if not is_finite(value) or absf(value) > MAX_NUMBER:
		return fallback
	return value

static func text_from(source: Dictionary, key: String, fallback: String) -> String:
	var raw: Variant = source.get(key, null)
	if not raw is String or str(raw).strip_edges().is_empty():
		return fallback
	return str(raw).strip_edges()

static func flag_from(source: Dictionary, key: String, fallback: bool) -> bool:
	var raw: Variant = source.get(key, null)
	return bool(raw) if raw is bool else fallback

## 机库里的某型舰载机定义；kind 为 engineer / guard。
static func drone_def(kind: String, equipment_id: String = "hangar") -> Dictionary:
	var drones: Variant = values(equipment_id).get("drones", {})
	if not drones is Dictionary:
		return {}
	var entry: Variant = drones.get(kind, {})
	return entry if entry is Dictionary else {}

## 可由任务解锁的装备清单，供任务编辑器与任务奖励下拉使用。
static func unlockable() -> Array[Dictionary]:
	_ensure_loaded()
	var result: Array[Dictionary] = []
	for id: String in _entries:
		var entry: Dictionary = _entries[id]
		if not bool(entry.get("requires_unlock", false)):
			continue
		result.append({
			"id": id,
			"name": str(entry.get("name", id)),
			"description": str(entry.get("description", "")),
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.id) < str(b.id))
	return result

static func _read() -> Dictionary:
	var result := {"data": {}, "error": ""}
	if not FileAccess.file_exists(PATH):
		result.error = "文件不存在：" + PATH
		return result
	var file := FileAccess.open(PATH, FileAccess.READ)
	if file == null:
		result.error = "无法打开：" + PATH
		return result
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK:
		result.error = "JSON 解析失败（第 %d 行）：%s" % [parser.get_error_line(), parser.get_error_message()]
		return result
	if not parser.data is Dictionary:
		result.error = "根节点必须是对象。"
		return result
	var root: Dictionary = parser.data
	if not int(root.get("schema_version", 0)) == 1:
		result.error = "schema_version 必须为 1。"
		return result
	var equipment: Variant = root.get("equipment", null)
	if not equipment is Dictionary:
		result.error = "equipment 必须是对象。"
		return result
	var clean: Dictionary = {}
	for id: Variant in equipment:
		var key := str(id)
		var entry: Variant = equipment[id]
		if not entry is Dictionary:
			result.error = "装备 %s 的定义必须是对象。" % key
			return result
		var data: Dictionary = entry
		if str(data.get("name", "")).strip_edges().is_empty():
			result.error = "装备 %s 缺少 name。" % key
			return result
		if not (data.get("credits") is int or data.get("credits") is float) or int(data.credits) < 0:
			result.error = "装备 %s 的 credits 必须是非负整数。" % key
			return result
		var values: Variant = data.get("values", {})
		if not values is Dictionary:
			result.error = "装备 %s 的 values 必须是对象。" % key
			return result
		clean[key] = {
			"name": str(data.name).strip_edges(),
			"description": str(data.get("description", "")),
			"credits": int(data.credits),
			"requires_unlock": bool(data.get("requires_unlock", false)),
			"stackable": bool(data.get("stackable", false)),
			"values": (values as Dictionary).duplicate(true),
		}
	if clean.is_empty():
		result.error = "equipment 为空。"
		return result
	result.data = clean
	return result

## JSON 损坏时的兜底：只保证 5 件基础装备可安装，数值全部走脚本内的默认值。
static func _fallback_entries() -> Dictionary:
	var fallback: Dictionary = {}
	for id in ["computer", "fuel", "shield", "thruster", "capture_net"]:
		fallback[id] = {
			"name": id,
			"description": "",
			"credits": 100,
			"requires_unlock": false,
			"stackable": id == "capture_net",
			"values": {},
		}
	return fallback
