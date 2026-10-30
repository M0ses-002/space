extends CanvasLayer
## 航行与港口的适配层：负责场景生命周期和信号转发，UI 不访问游戏实体。
## PortSession 管理舰队共享信用点、每船独立货舱与各港库存，PortView 只渲染快照。
const Session = preload("res://scripts/port_session.gd")
var session = Session.new()
var active := false
var game: Node
var docked_ship: Node2D
var starting_ship: Node2D
var saved_nodes: Array[Dictionary] = []
var shipyard_slot := 0
var shipyard_notice := "请选择槽位和改装。"
@onready var view = $PortView

func _ready() -> void:
	visible = false
	view.depart_requested.connect(_request_departure)
	view.tab_requested.connect(_change_tab)
	view.trade_quantity_changed.connect(_change_quantity)
	view.trade_confirmed.connect(_confirm_trade)
	view.fuel_quantity_changed.connect(_change_fuel_quantity)
	view.fuel_purchase_requested.connect(_buy_fuel)
	view.supply_settlement_requested.connect(_settle_supply)
	view.event_selected.connect(_select_event)
	view.person_selected.connect(_select_person)
	view.shipyard_slot_selected.connect(_select_shipyard_slot)
	view.upgrade_requested.connect(_install_upgrade)

func bind_game(owner_game: Node) -> void:
	game = owner_game
	if not is_instance_valid(starting_ship):
		starting_ship = game.ship
	_register_fleet()

func _register_fleet() -> void:
	# 始终先注册起始船，完整重置时不将初始货物转给后来选中的船。
	if is_instance_valid(starting_ship):
		register_ship(starting_ship)
	for vessel in game.ships:
		register_ship(vessel)

func register_ship(vessel: Node2D) -> void:
	if not is_instance_valid(vessel):
		return
	if not is_instance_valid(starting_ship):
		starting_ship = game.ships[0] if is_instance_valid(game) and not game.ships.is_empty() else vessel
	session.register_ship(vessel.get_instance_id())
	vessel.cargo_mass = session.get_ship_cargo_mass(vessel.get_instance_id())

func add_mined_cargo(vessel: Node2D, id: String, units: int, unit_mass: float) -> int:
	if not is_instance_valid(vessel):
		return 0
	register_ship(vessel)
	var accepted: int = session.collect_mineral(vessel.get_instance_id(), id, unit_mass, units)
	vessel.cargo_mass = session.get_ship_cargo_mass(vessel.get_instance_id())
	return accepted


func reset_fleet() -> void:
	leave_port()
	session.reset_session()
	_register_fleet()

func enter_port(source: Node2D, vessel: Node2D) -> void:
	if active:
		return
	docked_ship = vessel
	shipyard_slot = 0
	shipyard_notice = "请选择槽位和改装。"
	register_ship(vessel)
	session.select_ship(vessel.get_instance_id())
	session.open_planet(source.interaction_data_path)
	# 保留航行树及其他舰船模拟；屏蔽隐藏界面的处理与所有相机快捷键。
	for path in ["World", "HUD", "StarMapView", "StarMapView/HUD", "NavigationCamera"]:
		var node: Node = game.get_node(path)
		var entry: Dictionary = {"node": node, "process_mode": node.process_mode}
		if node is CanvasItem or node is CanvasLayer:
			entry["visible"] = node.visible
			node.hide()
		if path != "World":
			node.process_mode = Node.PROCESS_MODE_DISABLED
		saved_nodes.append(entry)
	active = true
	visible = true
	refresh()

func leave_port() -> void:
	visible = false
	active = false
	docked_ship = null
	for entry in saved_nodes:
		var node = entry.node
		if is_instance_valid(node):
			node.process_mode = entry.process_mode
			if entry.has("visible"):
				node.visible = entry.visible
	saved_nodes.clear()

func refresh() -> void:
	if active:
		view.render(_get_state())

func _is_docked() -> bool:
	return active and is_instance_valid(docked_ship) and docked_ship.voyage_finished

func _get_state() -> Dictionary:
	var state: Dictionary = session.get_state()
	if is_instance_valid(docked_ship):
		state.merge(session.get_fuel_state(docked_ship.fuel, docked_ship.get_fuel_capacity(), _is_docked()))
		state.merge(session.get_supply_state(docked_ship.get_instance_id(), docked_ship.completed_voyage_count, docked_ship.last_voyage_distance_m, _is_docked()))
		state["ship_name"] = docked_ship.display_name
		state["total_mass"] = docked_ship.get_total_mass()
		state["fuel_delta_v"] = docked_ship.fuel_to_delta_v(docked_ship.fuel)
		state["fuel_capacity_delta_v"] = docked_ship.fuel_to_delta_v(docked_ship.get_fuel_capacity())
		# 仅对通过交易校验的输入给出购买后预算；预览不修改油箱、资金或库存。
		state["fuel_preview_delta_v"] = docked_ship.fuel_to_delta_v(docked_ship.fuel + float(state.fuel_quantity)) if state.can_buy_fuel else state.fuel_delta_v
		state["departure_warning"] = "零燃料仍可起航，但无法推进；请先在贸易页购买燃料。" if docked_ship.fuel <= 0 else "起航不补油；请核对燃料与当前船载重。"
	state["can_trade"] = state.can_trade and _is_docked()
	state["shipyard_available"] = _is_docked() and game.cities.has(docked_ship.arrival_source)
	state["shipyard_slot"] = shipyard_slot
	state["shipyard_notice"] = shipyard_notice
	state["upgrades"] = Session.UPGRADES
	if is_instance_valid(docked_ship):
		state["upgrade_slots"] = docked_ship.upgrade_slots.duplicate()
		state["shield_ready"] = docked_ship.shield_ready
	return state

func _select_shipyard_slot(slot: int) -> void:
	if is_instance_valid(docked_ship) and slot >= 0 and slot < docked_ship.upgrade_slots.size():
		shipyard_slot = slot
		refresh()

func _install_upgrade(id: String) -> void:
	if not _get_state().shipyard_available:
		return
	if session.install_upgrade(docked_ship, shipyard_slot, id, true):
		docked_ship.cargo_mass = session.get_ship_cargo_mass(docked_ship.get_instance_id())
		shipyard_notice = "改装已安装；消耗品不返还。"
	else:
		shipyard_notice = "无法安装：槽位已占用、同类已安装或材料、信用点不足。"
	refresh()

## 每次起航均需检查本船上一航次账单；港口数据错误时不能静默跳过。
func can_depart(vessel: Node2D) -> bool:
	if not is_instance_valid(vessel):
		return false
	if vessel.completed_voyage_count <= 0:
		return true
	if not active or docked_ship != vessel or not _is_docked():
		return false
	var state: Dictionary = session.get_supply_state(vessel.get_instance_id(), vessel.completed_voyage_count, vessel.last_voyage_distance_m, true)
	return bool(state.supply_settled)

func _request_departure() -> void:
	if not active or not is_instance_valid(docked_ship):
		return
	# 港口期间不可切船；所有起航资格仍由航行模型校验。
	game._depart()
	if active:
		var state: Dictionary = _get_state()
		state["error"] = game.flight_message
		view.render(state)

func _change_tab(tab: String) -> void:
	session.set_tab(tab)
	refresh()

func _change_quantity(id: String, quantity: int) -> void:
	session.set_trade_quantity(id, quantity)
	refresh()

func _confirm_trade() -> void:
	if not _is_docked():
		return
	if session.confirm_trade():
		docked_ship.cargo_mass = session.get_ship_cargo_mass(docked_ship.get_instance_id())
	refresh()

func _change_fuel_quantity(quantity: float) -> void:
	session.set_fuel_quantity(quantity)
	refresh()

func _buy_fuel() -> void:
	if not _is_docked():
		return
	var result: Dictionary = session.buy_fuel(docked_ship.fuel, docked_ship.get_fuel_capacity(), true)
	if result.ok:
		docked_ship.fuel = result.fuel_after
	refresh()

func _settle_supply() -> void:
	if not _is_docked():
		return
	session.settle_supply(docked_ship.get_instance_id(), docked_ship.completed_voyage_count, docked_ship.last_voyage_distance_m, true)
	refresh()


func _select_event(id: String) -> void:
	session.select_event(id)
	refresh()

func _select_person(id: String) -> void:
	session.select_person(id)
	refresh()
