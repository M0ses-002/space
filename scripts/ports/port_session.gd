extends RefCounted
## 港口会话管理舰队共享信用点、事件与人物、装备解锁状态；改装保留在各飞船槽位。
## 装备的名称/说明/价格/数值全部来自 data/equipment.json（EquipmentCatalog），这里不写死数据。

const PLAYER_PATH := "res://data/player_start.json"
const MAX_NUMBER := 1000000000000.0
const UPGRADE_COST := 100
## 人物 speech 条目允许的字段；多写一个字段就意味着拼错，直接拒绝比静默忽略强。
const SPEECH_FIELDS: Array[String] = ["id", "when", "lines", "once", "set_flags"]
## 兼容既有引用（存档校验、任务目标、编辑器）：运行时由目录生成的 id -> 定义。
static var UPGRADES: Dictionary = EquipmentCatalog.entries()

var _initial_player: Dictionary = {}
var _player_error := ""
var _credits := 0
var _planets: Dictionary = {}
var _planet: Dictionary = {}
## 已用任务奖励解锁的装备 id 集合；无需解锁的装备不入此表。
var _unlocked: Dictionary = {}
var _tab := "events"
var _event_id := ""
var _person_id := ""
var _error := ""


func _init() -> void:
	var result := _read_json(PLAYER_PATH)
	if not result.error.is_empty():
		_player_error = result.error
	else:
		_player_error = _validate_player(result.data)
		if _player_error.is_empty():
			_initial_player = result.data.duplicate(true)
	reset_session()


func reset_session() -> void:
	_credits = int(_initial_player.get("credits", 0))
	_unlocked.clear()
	_planets.clear()
	_clear_port()
	_error = _player_error


## 装备是否可用：无需解锁的直接可用，需要解锁的必须已由任务奖励解锁。
func is_unlocked(id: String) -> bool:
	if not UPGRADES.has(id):
		return false
	return not bool(UPGRADES[id].get("requires_unlock", false)) or _unlocked.has(id)


## 任务奖励入口：只接受目录里 requires_unlock=true 的装备；重复解锁返回 false。
func unlock_equipment(id: String) -> bool:
	if not UPGRADES.has(id) or not bool(UPGRADES[id].get("requires_unlock", false)):
		return false
	if _unlocked.has(id):
		return false
	_unlocked[id] = true
	return true


func get_unlocked_equipment() -> Array[String]:
	var result: Array[String] = []
	for id: String in _unlocked:
		result.append(id)
	result.sort()
	return result


## 读档恢复：只接受目录里存在且需要解锁的 id，未知/多余条目直接忽略。
func restore_unlocked(ids: Variant) -> void:
	_unlocked.clear()
	if not ids is Array:
		return
	for raw: Variant in ids:
		if not raw is String:
			continue
		var id := str(raw)
		if UPGRADES.has(id) and bool(UPGRADES[id].get("requires_unlock", false)):
			_unlocked[id] = true


func get_credits() -> int:
	return _credits


## 当前港口所在行星的 planet_id（事件 JSON 里的 planet_id）。
## 人物 id 允许跨行星重名，任务系统靠它区分「说的是哪颗星上那个人」。
func planet_id() -> String:
	return str(_planet.get("planet_id", "")).strip_edges()


func set_credits(amount: Variant) -> bool:
	if not _is_integer(amount) or amount < 0:
		return false
	_credits = int(amount)
	return true


func add_credits(amount: Variant) -> bool:
	if not _is_integer(amount):
		return false
	return set_credits(_credits + int(amount))


func open_planet(path: String) -> bool:
	_clear_port()
	if not _player_error.is_empty():
		_error = _player_error
		return false
	if not _valid_json_path(path):
		_error = "行星数据路径无效：只接受 res:// 或 user:// 下无越级路径的 JSON。"
		return false
	if not _planets.has(path):
		var result := _read_json(path)
		if not result.error.is_empty():
			_error = result.error
			return false
		_error = _validate_planet(result.data)
		if not _error.is_empty():
			return false
		_planets[path] = result.data.duplicate(true)
	_planet = _planets[path]
	if not _planet.events.is_empty():
		_event_id = _planet.events[0].id
	if not _planet.diplomacy.persons.is_empty():
		_person_id = _planet.diplomacy.persons[0].id
	return true


## 某个槽位当前可安装的装备：只列已解锁的，未解锁装备在船坞里根本不出现。
func get_slot_upgrades(slot: int) -> Dictionary:
	var result := {}
	for id in UPGRADES:
		if not is_unlocked(id):
			continue
		var upgrade: Dictionary = UPGRADES[id]
		var allowed: Array = upgrade.get("slots", [])
		if allowed.is_empty() or allowed.has(slot):
			result[id] = upgrade.duplicate(true)
	return result


func install_upgrade(vessel: Node, slot: int, id: String, docked: bool) -> bool:
	if not docked or not is_instance_valid(vessel) or not _error.is_empty() or _planet.is_empty():
		return false
	if not get_slot_upgrades(slot).has(id) or slot < 0 or slot >= vessel.upgrade_slots.size():
		return false
	var definition: Dictionary = UPGRADES.get(id, {})
	var rearm: bool = id == "shield" and vessel.upgrade_slots[slot] == "shield" and not vessel.shield_ready
	# 捕捉网可装到多个槽位，其它堆叠型装备由目录的 stackable 决定；默认禁止同类重复。
	var stackable: bool = bool(definition.get("stackable", false))
	if not rearm and (not vessel.upgrade_slots[slot].is_empty() or (not stackable and vessel.upgrade_slots.has(id))):
		return false
	var price: int = int(definition.get("credits", UPGRADE_COST))
	if id == "shield" and rearm:
		price = int(EquipmentCatalog.number(id, "recharge_credits", float(UPGRADE_COST)))
	if _credits < price:
		return false
	_credits -= price
	vessel.upgrade_slots[slot] = id
	if id == "shield":
		vessel.shield_ready = true
	return true


## 拆除槽位上的装备：免费、不返还信用点。拆除只改槽位本身，
## 护盾随之失效、燃料按新的油箱容量截断；航行中的功能清理由 PortController 转给 main。
func remove_upgrade(vessel: Node, slot: int, docked: bool) -> bool:
	if not docked or not is_instance_valid(vessel) or not _error.is_empty() or _planet.is_empty():
		return false
	if slot < 0 or slot >= vessel.upgrade_slots.size():
		return false
	var id := str(vessel.upgrade_slots[slot])
	if id.is_empty():
		return false
	vessel.upgrade_slots[slot] = ""
	if id == "shield":
		vessel.shield_ready = false
	if id == "fuel" and vessel.has_method("clamp_fuel_to_capacity"):
		vessel.clamp_fuel_to_capacity()
	return true


func set_tab(tab: String) -> void:
	if tab in ["events", "relations", "shipyard"]:
		_tab = tab


func select_event(id: String) -> void:
	for event in _planet.get("events", []):
		if event.id == id:
			_event_id = id
			return


func select_person(id: String) -> void:
	for person in _planet.get("diplomacy", {}).get("persons", []):
		if person.id == id:
			_person_id = id
			return


func get_state() -> Dictionary:
	var state := {
		"planet_name": _planet.get("name", "港口数据不可用"), "tab": _tab,
		"error": _error, "events": _planet.get("events", []).duplicate(true),
		"selected_event": _event_id, "credits": _credits, "persons": [],
		"selected_person": _person_id, "person_detail": "",
	}
	for person in _planet.get("diplomacy", {}).get("persons", []):
		var view: Dictionary = person.duplicate(true)
		state.persons.append(view)
		if person.id == _person_id:
			state.person_detail = "%s · %s\n\n%s" % [view.name, view.role, view.description]
	return state


func _clear_port() -> void:
	_planet = {}
	_tab = "events"
	_event_id = ""
	_person_id = ""
	_error = ""


func _valid_json_path(path: String) -> bool:
	if not (path.begins_with("res://") or path.begins_with("user://")) or not path.ends_with(".json"):
		return false
	var relative := path.substr(path.find("://") + 3)
	return not relative.is_empty() and not relative.contains("\\") and not relative.contains(":") and not relative.begins_with("/") and not relative.contains("//") and not relative.split("/").has("..") and not relative.split("/").has(".")


func _read_json(path: String) -> Dictionary:
	var result := {"data": {}, "error": ""}
	if not _valid_json_path(path) or not FileAccess.file_exists(path):
		result.error = "JSON 文件不存在或路径非法：" + path
		return result
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		result.error = "无法读取 JSON：" + path
		return result
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK:
		result.error = "JSON 解析失败（第 %d 行）：%s" % [parser.get_error_line(), parser.get_error_message()]
	elif not parser.data is Dictionary:
		result.error = "JSON 根节点必须是对象。"
	else:
		result.data = parser.data
	return result


func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and absf(float(value)) <= MAX_NUMBER


func _is_integer(value: Variant) -> bool:
	return _number(value) and float(value) == floor(float(value))


func _text_fields(value: Dictionary, fields: Array, allow_empty: bool = false) -> bool:
	for field in fields:
		if not value.get(field) is String or (not allow_empty and value[field].strip_edges().is_empty()):
			return false
	return true


func _validate_player(data: Dictionary) -> String:
	if not _is_integer(data.get("schema_version")) or data.schema_version != 1:
		return "玩家配置版本必须为 schema_version=1。"
	if not _is_integer(data.get("credits")) or data.credits < 0:
		return "玩家配置的信用点必须为非负整数。"
	return ""


func _validate_planet(data: Dictionary) -> String:
	if not _is_integer(data.get("schema_version")) or data.schema_version != 1:
		return "行星数据版本必须为 schema_version=1。"
	if not _text_fields(data, ["planet_id", "name"]):
		return "行星缺少有效 planet_id 或 name。"
	if not data.get("events") is Array or not data.get("diplomacy") is Dictionary:
		return "行星 events 或 diplomacy 类型错误。"
	if not data.diplomacy.get("persons") is Array:
		return "人物必须是数组。"
	var ids: Dictionary = {}
	for event in data.events:
		if not event is Dictionary or not _text_fields(event, ["id", "title", "body"]):
			return "事件缺少有效 id、title 或 body。"
		if ids.has(event.id):
			return "事件 id 重复：" + event.id
		ids[event.id] = true
	ids.clear()
	for person in data.diplomacy.persons:
		if not person is Dictionary or not _text_fields(person, ["id", "name", "role", "description"]) or not _text_fields(person, ["portrait"], true):
			return "人物缺少有效资料字段。"
		if ids.has(person.id):
			return "人物 id 重复：" + person.id
		ids[person.id] = true
		var error := _validate_person_extras(person)
		if not error.is_empty():
			return error
	return ""


## 人物的可选项：dialogue 台词与 quests 委托。缺省即无对话、无委托。
## quest_greeting 是「这次能领到新委托」时才补播的台词，接完/办完之后不会再说。
func _validate_person_extras(person: Dictionary) -> String:
	if person.has("dialogue"):
		if not person.dialogue is Array:
			return "人物 dialogue 必须是数组。"
		for line in person.dialogue:
			if not line is String:
				return "人物台词必须是字符串。"
	if person.has("quest_greeting"):
		if not person.quest_greeting is Array:
			return "人物 quest_greeting 必须是数组。"
		for line in person.quest_greeting:
			if not line is String:
				return "人物 quest_greeting 台词必须是字符串。"
	# speech 一旦出现就完全接管台词，因此校验也最严：条件键拼错在入港时就报，别等到某个人再也不说话。
	if person.has("speech"):
		var speech_error := _validate_speech(person.speech)
		if not speech_error.is_empty():
			return speech_error
	if person.has("quests"):
		if not person.quests is Array:
			return "人物 quests 必须是数组。"
		for quest in person.quests:
			if not quest is Dictionary or not _text_fields(quest, ["id", "title", "description", "type"]):
				return "委托缺少有效 id、title、description 或 type。"
			if not _is_integer(quest.get("count")) or int(quest.count) < 1:
				return "委托 count 必须是正整数。"
			if not _is_integer(quest.get("reward_credits")) or int(quest.reward_credits) < 0:
				return "委托 reward_credits 必须是非负整数。"
			# 可选：完成时解锁某件装备；只接受目录里 requires_unlock=true 的 id。
			var unlock := str(quest.get("reward_unlock", "")).strip_edges()
			if not unlock.is_empty() and (not EquipmentCatalog.has(unlock) or not EquipmentCatalog.requires_unlock(unlock)):
				return "委托 reward_unlock 必须是可由任务解锁的装备 id：" + unlock
			# 可选：需要回到委托人处复命。return_line 是复命时补播的台词，留空则用默认台词。
			if quest.has("requires_return") and not quest.requires_return is bool:
				return "委托 requires_return 必须是布尔值。"
			if quest.has("return_line") and not quest.return_line is String:
				return "委托 return_line 必须是字符串。"
			# 跨行星交谈目标的可读提示与定位：target_planet_id 参与匹配，其余仅用于界面。
			for key in ["target_name", "target_planet", "target_planet_id"]:
				if quest.has(key) and not quest.get(key) is String:
					return "委托 %s 必须是字符串（仅用于界面提示）。" % key
	return ""

## 台词候选表的结构校验。字段白名单 + 条件键白名单，两处都不接受「随手多写」。
func _validate_speech(speech: Variant) -> String:
	if not speech is Array:
		return "人物 speech 必须是数组。"
	if (speech as Array).is_empty():
		return "人物 speech 不能是空数组（没有候选就删掉该字段）。"
	var used := {}
	for index in range((speech as Array).size()):
		var where := "人物 speech[%d]" % index
		var item: Variant = speech[index]
		if not item is Dictionary:
			return "%s 必须是对象。" % where
		var entry: Dictionary = item
		for key: Variant in entry.keys():
			if not str(key) in SPEECH_FIELDS:
				return "%s 含有未知字段「%s」（可用字段：id / when / lines / once / set_flags）。" % [where, str(key)]
		var id := str(entry.get("id", "")).strip_edges()
		if not id.is_empty():
			if used.has(id):
				return "%s 的 id 与前面的条目重复：%s" % [where, id]
			used[id] = true
		var lines: Variant = entry.get("lines", [])
		if lines is String:
			lines = [lines]
		if not lines is Array or (lines as Array).is_empty():
			return "%s 的 lines 必须是非空字符串数组。" % where
		for line: Variant in lines:
			if not line is String or str(line).strip_edges().is_empty():
				return "%s 的 lines 里有空台词。" % where
		if entry.has("when"):
			if not entry.get("when") is Dictionary:
				return "%s 的 when 必须是对象。" % where
			for key: Variant in (entry.get("when") as Dictionary).keys():
				if not str(key) in StoryConditions.KEYS:
					return "%s 的 when 含有未知条件键「%s」。" % [where, str(key)]
		if entry.has("once") and not entry.get("once") is bool:
			return "%s 的 once 必须是布尔值。" % where
		if entry.has("set_flags"):
			if not entry.get("set_flags") is Dictionary:
				return "%s 的 set_flags 必须是对象。" % where
			for key: Variant in (entry.get("set_flags") as Dictionary).keys():
				if not entry.get("set_flags")[key] is bool:
					return "%s 的 set_flags[%s] 必须是布尔值。" % [where, str(key)]
	return ""
