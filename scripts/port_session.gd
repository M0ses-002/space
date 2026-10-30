extends RefCounted
## 港口原型的纯数据模型：只在本次运行中保留资金、货舱与各星库存，不写存档。
## 扩展港口内容请修改 JSON；事件暂只供阅读，人物关系按无向边解释。

const PLAYER_PATH := "res://data/player_start.json"
const MAX_NUMBER := 1000000000000.0
var _initial_player: Dictionary = {}
var _player_error := ""
var _credits := 0
var _capacity := 0.0
var _cargo: Dictionary = {}
var _masses: Dictionary = {}
var _planets: Dictionary = {}
var _planet: Dictionary = {}
var _tab := "events"
var _event_id := ""
var _person_id := ""
var _cart: Dictionary = {}
var _error := ""
var _trade_notice := ""
var _input_error := ""
var _fleet_cargo: Dictionary = {}
var _fuel_supply: Dictionary = {}
var _fuel_quantity: Variant = 100
var _fuel_notice := ""
var _settled_voyages: Dictionary = {}


func _init() -> void:
	var result := _read_json(PLAYER_PATH)
	if not result.error.is_empty():
		_player_error = result.error
	else:
		_player_error = _validate_player(result.data)
		if _player_error.is_empty():
			_initial_player = result.data.duplicate(true)
	reset_session()


## 重置为首次读取的玩家配置，同时清除本次运行的行星库存缓存。
func reset_session() -> void:
	_credits = int(_initial_player.get("credits", 0))
	_capacity = float(_initial_player.get("cargo_capacity", 0))
	_cargo = _initial_player.get("cargo", {}).duplicate(true)
	_masses = _initial_player.get("cargo_masses", {}).duplicate(true)
	_fleet_cargo.clear()
	_settled_voyages.clear()
	_planets.clear()
	_clear_port()
	_error = _player_error


## 失败时清空展示，不回退到另一颗星球；已有成功交易仍保留。
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
		var candidate: Dictionary = result.data
		for item in candidate.trade.items:
			if not _masses.has(item.id) or float(_masses[item.id]) != float(item.unit_mass):
				_error = "商品质量必须与玩家配置 cargo_masses 严格一致：" + item.id
				return false
		_planets[path] = candidate.duplicate(true)
	_planet = _planets[path]
	_fuel_supply = _planet.trade.get("fuel_supply", {})
	_fuel_quantity = int(_fuel_supply.get("default_quantity_kg", 0))
	if not _planet.events.is_empty():
		_event_id = _planet.events[0].id
	if not _planet.diplomacy.persons.is_empty():
		_person_id = _planet.diplomacy.persons[0].id
	return true


## 默认货舱供独立模型使用；舰队只给首次注册的船分配初始货物。
func register_ship(ship_id: int) -> void:
	if not _fleet_cargo.has(ship_id):
		if _fleet_cargo.is_empty():
			# 转交默认货舱，不复制另一份可交易的初始物资。
			_fleet_cargo[ship_id] = _cargo
			_cargo = _fleet_cargo[ship_id]
		else:
			_fleet_cargo[ship_id] = {}


func select_ship(ship_id: int) -> void:
	register_ship(ship_id)
	_cargo = _fleet_cargo[ship_id]
	_cart.clear()
	_trade_notice = ""
	_input_error = ""


func collect_mineral(ship_id: int, id: String, unit_mass: float, max_units: int) -> int:
	if not _fleet_cargo.has(ship_id) or not _masses.has(id) or not _number(unit_mass) or unit_mass <= 0 or float(_masses[id]) != unit_mass or max_units <= 0:
		return 0
	var cargo: Dictionary = _fleet_cargo[ship_id]
	var remaining := maxf(0.0, _capacity - get_ship_cargo_mass(ship_id))
	var units := mini(max_units, int(floor(remaining / unit_mass)))
	if units > 0:
		cargo[id] = int(cargo.get(id, 0)) + units
	return units


func get_ship_cargo_mass(ship_id: int) -> float:
	var used := 0.0
	for id in _fleet_cargo.get(ship_id, {}):
		used += int(_fleet_cargo[ship_id][id]) * float(_masses[id])
	return used


func get_supply_state(ship_id: int, voyage_id: int, distance_m: float, docked: bool) -> Dictionary:
	var rate := float(_initial_player.get("living_supply", {}).get("distance_per_credit_m", 1000000))
	var valid := _number(distance_m) and distance_m >= 0 and voyage_id >= 0
	var settled := voyage_id > 0 and int(_settled_voyages.get(ship_id, 0)) >= voyage_id
	var cost := int(ceil(distance_m / rate)) if valid else 0
	var message := ""
	if not docked or not _error.is_empty() or _planet.is_empty():
		message = "港口不可用或当前船未停靠。"
	elif not valid:
		message = "航程数据无效。"
	elif voyage_id == 0:
		message = "尚无已完成航程，无需结算。"
	elif settled:
		message = "本航程生活补给已结算。"
	elif cost > _credits:
		message = "信用点不足，可出售货物后结算。"
	else:
		message = "待结算：生活补给不占货舱，燃料需另购。"
	return {"supply_distance_m": distance_m if valid else 0.0, "supply_cost": cost,
		"supply_rate_m": rate, "supply_message": message,
		"supply_pending": valid and voyage_id > 0 and not settled,
		"supply_settled": valid and settled and docked and _error.is_empty() and not _planet.is_empty(),
		"can_settle_supply": docked and _error.is_empty() and not _planet.is_empty() and valid and voyage_id > 0 and not settled and cost <= _credits}


func settle_supply(ship_id: int, voyage_id: int, distance_m: float, docked: bool) -> bool:
	var state := get_supply_state(ship_id, voyage_id, distance_m, docked)
	if not state.can_settle_supply:
		return false
	_credits -= int(state.supply_cost)
	_settled_voyages[ship_id] = voyage_id
	return true


func set_fuel_quantity(quantity: Variant) -> void:
	_fuel_quantity = quantity
	_fuel_notice = ""


func get_fuel_state(fuel: float, capacity: float, docked: bool) -> Dictionary:
	var result := _evaluate_fuel(fuel, capacity, docked)
	return {
		"fuel": fuel, "fuel_capacity": capacity,
		"fuel_quantity": _fuel_quantity if _number(_fuel_quantity) else 0,
		"fuel_pack_kg": _fuel_supply.get("pack_kg", 10),
		"fuel_pack_price": _fuel_supply.get("pack_price", 0),
		"fuel_service_available": not _fuel_supply.is_empty(),
		"fuel_stock": _fuel_supply.get("stock_kg", 0),
		"fuel_total": result.total, "can_buy_fuel": result.ok,
		"fuel_message": _fuel_notice if not _fuel_notice.is_empty() else result.message,
	}


## 同步调用中先完整校验再扣款；适配层收到成功结果立即写入停靠船油箱。
func buy_fuel(fuel: float, capacity: float, docked: bool) -> Dictionary:
	var result := _evaluate_fuel(fuel, capacity, docked)
	if result.ok:
		_credits -= int(result.total)
		_fuel_supply.stock_kg -= int(_fuel_quantity)
		result["fuel_after"] = fuel + int(_fuel_quantity)
		_fuel_notice = "已购买 %d kg 油箱燃料；不占货舱，不可卖回。" % int(_fuel_quantity)
		_fuel_quantity = 0
	else:
		_fuel_notice = result.message
	return result


func _evaluate_fuel(fuel: float, capacity: float, docked: bool) -> Dictionary:
	var result := {"ok": false, "total": 0, "message": ""}
	if not docked:
		result.message = "只有当前停靠船可以购买燃料。"
	elif not _error.is_empty() or _planet.is_empty():
		result.message = "港口数据不可用，无法购买燃料。"
	elif _fuel_supply.is_empty():
		result.message = "当前港口没有燃料补给。"
	elif not _number(fuel) or not _number(capacity) or fuel < 0 or capacity < fuel:
		result.message = "油箱状态无效。"
	elif not _is_integer(_fuel_quantity) or _fuel_quantity <= 0:
		result.message = "燃料购买量必须为正整数 kg。"
	elif int(_fuel_quantity) % int(_fuel_supply.pack_kg) != 0:
		result.message = "燃料仅按 %d kg 整包购买，不赠送不足一包的余量。" % int(_fuel_supply.pack_kg)
	else:
		var total: float = float(_fuel_quantity) / float(_fuel_supply.pack_kg) * float(_fuel_supply.pack_price)
		if not _number(total):
			result.message = "燃料交易金额超出有效范围。"
		else:
			result.total = int(total)
			if int(_fuel_quantity) > int(_fuel_supply.stock_kg):
				result.message = "港口燃料库存不足。"
			elif float(_fuel_quantity) > capacity - fuel:
				result.message = "油箱容量不足；请减少整包数量。"
			elif result.total > _credits:
				result.message = "游戏信用点不足。"
			else:
				result.ok = true
				result.message = "[PLACEHOLDER] 每 %d kg / %d 信用点；仅加油箱，不占货舱。" % [int(_fuel_supply.pack_kg), int(_fuel_supply.pack_price)]
	return result


const UPGRADES := {
	"computer": {"name": "航行电脑 Lv1", "description": "算力更强大的航行电脑。预演时间 +50%。", "credits": 0, "materials": {"circuits": 1}},
	"fuel": {"name": "燃料仓 Lv1", "description": "改进燃料仓，让飞船可以装载压力更高的燃料。容量 +20%。", "credits": 100, "materials": {}},
	"shield": {"name": "霍普尔盾 Lv1", "description": "常见的防御小型碎片的装置，往往能在关键时刻救命。可防御一次太空垃圾。", "credits": 0, "materials": {"alloy": 1}},
	"thruster": {"name": "加力喷口 Lv1", "description": "空载额定加速、减速及方向推进加速度各 +5 m/s²，载货后按质量降低。", "credits": 0, "materials": {"circuits": 1, "alloy": 1}},
}

func install_upgrade(vessel: Node, slot: int, id: String, docked: bool) -> bool:
	if not docked or not _error.is_empty() or _planet.is_empty() or not UPGRADES.has(id) or slot < 0 or slot >= vessel.upgrade_slots.size():
		return false
	var rearm: bool = id == "shield" and vessel.upgrade_slots[slot] == "shield" and not vessel.shield_ready
	if not rearm and (not vessel.upgrade_slots[slot].is_empty() or vessel.upgrade_slots.has(id)):
		return false
	var upgrade: Dictionary = UPGRADES[id]
	if _credits < upgrade.credits:
		return false
	for material in upgrade.materials:
		if int(_cargo.get(material, 0)) < upgrade.materials[material]:
			return false
	_credits -= upgrade.credits
	for material in upgrade.materials:
		_cargo[material] -= upgrade.materials[material]
	vessel.upgrade_slots[slot] = id
	if id == "shield":
		vessel.shield_ready = true
	return true

func set_tab(tab: String) -> void:
	if tab in ["events", "trade", "relations", "shipyard"]:
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


## 调用方应传整数；保留 Variant 边界以拒绝脚本调用传入的小数而非悄悄截断。
func set_trade_quantity(id: String, quantity: Variant) -> void:
	_trade_notice = ""
	_input_error = ""
	if not _is_integer(quantity):
		_input_error = "交易数量必须是有效整数。"
		return
	for item in _planet.get("trade", {}).get("items", []):
		if item.id == id:
			_cart[id] = int(quantity)
			return
	_input_error = "当前港口没有此商品。"


## 先验证完整购物车，再一次性提交；失败不会改动资金、货舱或任何港口库存。
func confirm_trade() -> bool:
	var result := _evaluate_trade()
	if not result.ok:
		_trade_notice = result.message
		return false
	for item in _planet.trade.items:
		var quantity := int(_cart.get(item.id, 0))
		item.stock = int(item.stock) - quantity
		_cargo[item.id] = int(_cargo.get(item.id, 0)) + quantity
	_credits -= int(result.total)
	_cart.clear()
	_trade_notice = "交易已确认；本次运行内保留库存和货舱，不写入存档。"
	return true


## 返回独立快照供 UI 渲染，UI 不得承担资金、容量或关系计算。
func get_state() -> Dictionary:
	var evaluation := _evaluate_trade()
	var state := {
		"planet_name": _planet.get("name", "港口数据不可用"), "tab": _tab,
		"error": _error, "events": _planet.get("events", []).duplicate(true),
		"selected_event": _event_id, "credits": _credits, "cargo_used": _cargo_used(),
		"cargo_capacity": _capacity, "trade_rows": [], "trade_total": evaluation.total,
		"trade_message": _trade_notice if not _trade_notice.is_empty() else evaluation.message,
		"can_trade": evaluation.ok, "persons": [],
		"relations": _planet.get("diplomacy", {}).get("relations", []).duplicate(true),
		"selected_person": _person_id, "person_detail": "",
	}
	for item in _planet.get("trade", {}).get("items", []):
		var ship_stock := int(_cargo.get(item.id, 0))
		state.trade_rows.append({
			"id": item.id, "name": item.name, "description": item.description,
			"unit_mass": item.unit_mass, "station_stock": int(item.stock),
			"ship_stock": ship_stock, "buy_price": int(item.buy_price), "sell_price": int(item.sell_price),
			"quantity": int(_cart.get(item.id, 0)), "min_quantity": -ship_stock,
			"max_quantity": int(item.stock),
		})
	for person in _planet.get("diplomacy", {}).get("persons", []):
		var view: Dictionary = person.duplicate(true)
		view.relation = _relation_to(person.id)
		state.persons.append(view)
		if person.id == _person_id:
			state.person_detail = "%s · %s\n\n%s" % [view.name, view.role, view.description]
	return state


func _clear_port() -> void:
	_planet = {}
	_tab = "events"
	_event_id = ""
	_person_id = ""
	_fuel_supply = {}
	_fuel_quantity = 0
	_fuel_notice = ""
	_cart.clear()
	_error = ""
	_trade_notice = ""
	_input_error = ""


func _cargo_used() -> float:
	var used := 0.0
	for id in _cargo:
		used += int(_cargo[id]) * float(_masses.get(id, 0))
	return used


func _evaluate_trade() -> Dictionary:
	var result := {"ok": false, "total": 0, "message": "请选择买入或卖出数量。"}
	if not _error.is_empty() or _planet.is_empty():
		result.message = "港口数据不可用，仍可点击右下角起航。"
		return result
	if not _input_error.is_empty():
		result.message = _input_error
		return result
	var used := _cargo_used()
	var changed := false
	var issue := ""
	for item in _planet.trade.items:
		var quantity := int(_cart.get(item.id, 0))
		changed = changed or quantity != 0
		var price := int(item.buy_price if quantity >= 0 else item.sell_price)
		if price > 0 and absf(float(quantity)) > MAX_NUMBER / float(price):
			result.message = "交易数值超出有效范围。"
			return result
		result.total += quantity * price
		if absf(float(result.total)) > MAX_NUMBER:
			result.message = "交易数值超出有效范围。"
			return result
		used += quantity * float(item.unit_mass)
		if quantity > int(item.stock):
			issue = "港口库存不足：" + item.name
		elif -quantity > int(_cargo.get(item.id, 0)):
			issue = "货舱持有数量不足：" + item.name
	if not issue.is_empty():
		result.message = issue
	elif not changed:
		pass
	elif not is_finite(used) or float(_credits) - float(result.total) > MAX_NUMBER:
		result.message = "交易数值超出有效范围。"
	elif result.total > _credits:
		result.message = "游戏信用点不足。"
	elif used > _capacity + 0.000001:
		result.message = "货舱容量不足（kg）。"
	else:
		result.ok = true
		result.message = "购物车有效；确认后才结算信用点和库存。"
	return result


func _relation_to(id: String) -> String:
	if id == _person_id:
		return "selected"
	for relation in _planet.get("diplomacy", {}).get("relations", []):
		if (relation.from == _person_id and relation.to == id) or (relation.to == _person_id and relation.from == id):
			return relation.type
	return "neutral"


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
	if not _number(data.get("cargo_capacity")) or data.cargo_capacity < 0:
		return "玩家配置的容量必须为非负数字。"
	if not data.get("living_supply") is Dictionary or not _number(data.living_supply.get("distance_per_credit_m")) or data.living_supply.distance_per_credit_m < 1:
		return "生活补给计费距离必须为至少 1 米的有限数字。"
	if not data.get("cargo") is Dictionary:
		return "玩家配置 cargo 必须是商品 id 到整数数量的对象。"
	if not data.get("cargo_masses") is Dictionary or data.cargo_masses.is_empty():
		return "玩家配置必须提前定义 cargo_masses。"
	for id in data.cargo_masses:
		if not id is String or id.is_empty() or not _number(data.cargo_masses[id]) or data.cargo_masses[id] <= 0:
			return "商品单位质量必须为正有限数字。"
	var used := 0.0
	for id in data.cargo:
		if not id is String or id.is_empty() or not _is_integer(data.cargo[id]) or data.cargo[id] < 0 or not data.cargo_masses.has(id):
			return "玩家初始货舱含有非法商品、数量或缺失质量定义。"
		used += float(data.cargo[id]) * float(data.cargo_masses[id])
	if not _number(used) or used > float(data.cargo_capacity):
		return "初始货舱超过容量或质量范围。"
	return ""


func _validate_fuel_supply(data: Dictionary) -> String:
	for key in ["pack_kg", "pack_price", "default_quantity_kg"]:
		if not _is_integer(data.get(key)) or data[key] <= 0:
			return "燃料整包质量、价格和默认购买量必须为正整数。"
	if int(data.default_quantity_kg) % int(data.pack_kg) != 0:
		return "燃料默认购买量必须为整包。"
	if not _is_integer(data.get("stock_kg")) or data.stock_kg < 0 or int(data.stock_kg) % int(data.pack_kg) != 0:
		return "燃料库存必须为非负整包 kg。"
	return ""


func _validate_planet(data: Dictionary) -> String:
	if not _is_integer(data.get("schema_version")) or data.schema_version != 1:
		return "行星数据版本必须为 schema_version=1。"
	if not _text_fields(data, ["planet_id", "name"]):
		return "行星缺少有效 planet_id 或 name。"
	if not data.get("events") is Array or not data.get("trade") is Dictionary or not data.get("diplomacy") is Dictionary:
		return "行星 events、trade 或 diplomacy 类型错误。"
	if not data.trade.get("items") is Array or not data.diplomacy.get("persons") is Array or not data.diplomacy.get("relations") is Array:
		return "商品、人物与关系必须是数组。"
	if data.trade.has("fuel_supply"):
		if not data.trade.fuel_supply is Dictionary:
			return "燃料补给配置必须是对象。"
		var fuel_error := _validate_fuel_supply(data.trade.fuel_supply)
		if not fuel_error.is_empty():
			return fuel_error
	var ids: Dictionary = {}
	for event in data.events:
		if not event is Dictionary or not _text_fields(event, ["id", "title", "body"]):
			return "事件缺少有效 id、title 或 body。"
		if ids.has(event.id):
			return "事件 id 重复：" + event.id
		ids[event.id] = true
	ids.clear()
	for item in data.trade.items:
		if not item is Dictionary or not _text_fields(item, ["id", "name", "description"]):
			return "商品缺少有效 id、name 或 description。"
		if ids.has(item.id):
			return "商品 id 重复：" + item.id
		ids[item.id] = true
		if not _number(item.get("unit_mass")) or item.unit_mass < 0:
			return "商品质量必须为非负有限数字：" + item.id
		for key in ["buy_price", "sell_price"]:
			if not _is_integer(item.get(key)) or item[key] < 0:
				return "商品价格必须为非负整数信用点：" + item.id
		if not _is_integer(item.get("stock")) or item.stock < 0:
			return "商品库存必须为非负整数：" + item.id
		if item.buy_price < item.sell_price:
			return "商品买入价不能低于卖出价：" + item.id
	ids.clear()
	for person in data.diplomacy.persons:
		if not person is Dictionary or not _text_fields(person, ["id", "name", "role", "description"]) or not _text_fields(person, ["portrait"], true):
			return "人物缺少有效资料字段。"
		if ids.has(person.id):
			return "人物 id 重复：" + person.id
		ids[person.id] = true
		if not person.get("position") is Array or person.position.size() != 2:
			return "人物 position 必须是二维坐标。"
		for coordinate in person.position:
			if not _number(coordinate) or coordinate < 0 or coordinate > 1:
				return "人物坐标必须位于 0 到 1。"
	var pairs: Dictionary = {}
	for relation in data.diplomacy.relations:
		if not relation is Dictionary or not _text_fields(relation, ["from", "to", "type"]):
			return "关系缺少有效 from、to 或 type。"
		if not ids.has(relation.from) or not ids.has(relation.to) or relation.from == relation.to:
			return "关系端点无效或指向自己。"
		if not relation.type in ["cooperation", "competition"]:
			return "关系 type 必须是 cooperation 或 competition。"
		var endpoints: Array = [relation.from, relation.to]
		endpoints.sort()
		var pair_key := JSON.stringify(endpoints)
		if pairs.has(pair_key):
			return "同一无向人物关系重复定义。"
		pairs[pair_key] = true
	return ""
