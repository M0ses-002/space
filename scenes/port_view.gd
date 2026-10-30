extends Control

signal depart_requested()
signal tab_requested(tab: String)
signal trade_quantity_changed(item_id: String, quantity: int)
signal trade_confirmed()
signal fuel_quantity_changed(quantity: float)
signal fuel_purchase_requested()
signal supply_settlement_requested()
signal event_selected(id: String)
signal person_selected(id: String)
signal shipyard_slot_selected(slot: int)
signal upgrade_requested(id: String)

const TRADE_ROW = preload("res://scenes/trade_row.tscn")
const PERSON_ICON = preload("res://scenes/person_icon.tscn")
const RELATION_EDGE = preload("res://scenes/relation_edge.tscn")
const EVENT_CARD = preload("res://scenes/event_card.tscn")

var _state: Dictionary = {}
var _trade_nodes: Dictionary = {}
var _event_nodes: Dictionary = {}
var _person_nodes: Dictionary = {}
var _edge_nodes: Array[Line2D] = []

func _ready() -> void:
	%DepartButton.pressed.connect(func(): depart_requested.emit())
	%EventsButton.pressed.connect(func(): tab_requested.emit("events"))
	%TradeButton.pressed.connect(func(): tab_requested.emit("trade"))
	%RelationsButton.pressed.connect(func(): tab_requested.emit("relations"))
	%ShipyardButton.pressed.connect(func(): tab_requested.emit("shipyard"))
	for i in %Slots.get_child_count():
		%Slots.get_child(i).pressed.connect(func(): shipyard_slot_selected.emit(i))
	for id in ["computer", "fuel", "shield", "thruster"]:
		%Candidates.get_node(id.capitalize()).pressed.connect(func(): upgrade_requested.emit(id))
	%ConfirmTrade.pressed.connect(func(): trade_confirmed.emit())
	%FuelQuantity.value_changed.connect(func(value: float): fuel_quantity_changed.emit(value))
	%BuyFuel.pressed.connect(func(): fuel_purchase_requested.emit())
	%SettleSupply.pressed.connect(func(): supply_settlement_requested.emit())
	%GraphArea.resized.connect(_layout_graph)
	render(_state)

# 唯一渲染入口。视图不计算交易可行性、库存变化或人物关系。
# 可以在入树之前传入状态；空字典用于独立运行场景时展示空态。
func render(state: Dictionary) -> void:
	_state = state.duplicate(true)
	if not is_node_ready():
		return
	%PlanetName.text = str(state.get("planet_name", "港口"))
	%PlanetName.tooltip_text = %PlanetName.text
	var current_tab := str(state.get("tab", "events"))
	%EventsPage.visible = current_tab == "events"
	%TradePage.visible = current_tab == "trade"
	%RelationsPage.visible = current_tab == "relations"
	%ShipyardPage.visible = current_tab == "shipyard" and bool(state.get("shipyard_available", false))
	%ShipyardButton.visible = bool(state.get("shipyard_available", false))
	%ShipyardButton.set_pressed_no_signal(current_tab == "shipyard")
	%EventsButton.set_pressed_no_signal(current_tab == "events")
	%TradeButton.set_pressed_no_signal(current_tab == "trade")
	%RelationsButton.set_pressed_no_signal(current_tab == "relations")
	%Error.text = str(state.get("error", ""))
	%Error.visible = not %Error.text.is_empty()
	%ShipStatus.text = "%s · 总质量（干重+货物）%.1f kg · 货重 %.1f / %.1f kg · 燃料 Δv %.1f / %.1f m/s" % [str(state.get("ship_name", "当前船")), float(state.get("total_mass", 0)), float(state.get("cargo_used", 0)), float(state.get("cargo_capacity", 0)), float(state.get("fuel_delta_v", 0)), float(state.get("fuel_capacity_delta_v", 0))]
	%Status.text = str(state.get("departure_warning", "港口停泊中"))
	_render_events()
	_render_trade()
	_render_people()
	if current_tab == "shipyard":
		_render_shipyard()
	_layout_graph.call_deferred()

func _render_shipyard() -> void:
	%ShipyardTitle.text = "%s · 船坞 · 信用点 %d" % [str(_state.get("ship_name", "当前船")), int(_state.get("credits", 0))]
	%ShipyardNotice.text = str(_state.get("shipyard_notice", "")) + "  护盾耗尽后可选择原槽位，支付合金板重新充能。"
	var slots: Array = _state.get("upgrade_slots", [])
	var upgrades: Dictionary = _state.get("upgrades", {})
	var selected := int(_state.get("shipyard_slot", 0))
	for i in %Slots.get_child_count():
		var button: Button = %Slots.get_child(i)
		button.visible = i < slots.size()
		if not button.visible:
			continue
		var id: String = slots[i]
		var name_text := str(upgrades.get(id, {}).get("name", "空"))
		if id == "shield":
			name_text += "（可用）" if bool(_state.get("shield_ready", false)) else "（耗尽）"
		button.text = "槽位 %d\n%s" % [i + 1, name_text]
		button.set_pressed_no_signal(i == selected)
	for id in upgrades:
		var data: Dictionary = upgrades[id]
		var cost := "%d 信用点" % int(data.credits)
		for material in data.materials:
			cost += " · %s × %d" % ["精密电路" if material == "circuits" else "合金板", int(data.materials[material])]
		var button: Button = %Candidates.get_node(id.capitalize())
		button.text = "%s  |  %s  |  %s" % [data.name, cost, data.description]
		button.tooltip_text = data.description

func _render_events() -> void:
	var events: Array = _state.get("events", [])
	var selected := str(_state.get("selected_event", ""))
	var present: Array[String] = []
	%EventsEmpty.visible = events.is_empty()
	%EventTitle.text = "等待选择事件"
	%EventBody.text = "当前没有选中的事件。"
	for data: Dictionary in events:
		var id := str(data.get("id", ""))
		present.append(id)
		if not _event_nodes.has(id):
			var card = EVENT_CARD.instantiate()
			%EventList.add_child(card)
			# 每个新实例只连接一次；重复 render 复用控件，避免重复触发。
			card.event_pressed.connect(_on_event_selected)
			_event_nodes[id] = card
		var card = _event_nodes[id]
		card.render(data, id == selected)
		%EventList.move_child(card, -1)
		if id == selected:
			%EventTitle.text = str(data.get("title", ""))
			%EventBody.text = str(data.get("body", ""))
	_remove_missing(_event_nodes, present)

func _render_trade() -> void:
	%TradeWallet.text = "舰队共享信用点 %d    ·    当前船独立货舱 %s / %s kg" % [int(_state.get("credits", 0)), str(_state.get("cargo_used", 0.0)), str(_state.get("cargo_capacity", 0.0))]
	%SupplySummary.text = "生活补给 · 上次航程 %.2f km\n费用 %d 信用点 · 每 %.2f km / 1 信用点（占位）\n%s" % [float(_state.get("supply_distance_m", 0)) / 1000.0, int(_state.get("supply_cost", 0)), float(_state.get("supply_rate_m", 1000000)) / 1000.0, str(_state.get("supply_message", "暂无航程"))]
	%SettleSupply.disabled = not bool(_state.get("can_settle_supply", false))
	%FuelSummary.text = "油箱燃料 · %d kg / %d 信用点\n库存 %d kg · 本次 %d 信用点" % [int(_state.get("fuel_pack_kg", 10)), int(_state.get("fuel_pack_price", 0)), int(_state.get("fuel_stock", 0)), int(_state.get("fuel_total", 0))] if bool(_state.get("fuel_service_available", false)) else "当前港口无燃料补给服务"
	var current_delta_v := float(_state.get("fuel_delta_v", 0.0))
	var capacity_delta_v := float(_state.get("fuel_capacity_delta_v", 0.0))
	var preview_delta_v := float(_state.get("fuel_preview_delta_v", current_delta_v))
	%FuelDeltaV.text = "Δv %.1f → %.1f / %.1f m/s" % [current_delta_v, preview_delta_v, capacity_delta_v] if bool(_state.get("can_buy_fuel", false)) else "Δv %.1f / %.1f m/s · 不可购买" % [current_delta_v, capacity_delta_v]
	%FuelDeltaV.tooltip_text = "按当前船体及已装货物质量和推进耗油系数换算，不是飞船当前速度。预计值仅作预览，确认购买前不会增加燃料。"
	%FuelQuantity.step = float(_state.get("fuel_pack_kg", 10))
	%FuelQuantity.set_value_no_signal(float(_state.get("fuel_quantity", 100)))
	%FuelMessage.text = str(_state.get("fuel_message", "仅停靠船可以购买油箱燃料。"))
	%BuyFuel.disabled = not bool(_state.get("can_buy_fuel", false))
	var total := int(_state.get("trade_total", 0))
	%TradeTotal.text = ("净支出 %d 信用点" % total) if total >= 0 else ("净收入 %d 信用点" % -total)
	%TradeMessage.text = str(_state.get("trade_message", "调整数量后确认交易。"))
	%ConfirmTrade.disabled = not bool(_state.get("can_trade", false))
	var rows: Array = _state.get("trade_rows", [])
	var present: Array[String] = []
	%TradeEmpty.visible = rows.is_empty()
	for data: Dictionary in rows:
		var id := str(data.get("id", ""))
		present.append(id)
		if not _trade_nodes.has(id):
			var row = TRADE_ROW.instantiate()
			%TradeRows.add_child(row)
			row.quantity_changed.connect(_on_quantity_changed)
			_trade_nodes[id] = row
		var row = _trade_nodes[id]
		row.render(data)
		%TradeRows.move_child(row, -1)
	_remove_missing(_trade_nodes, present)

func _render_people() -> void:
	var persons: Array = _state.get("persons", [])
	var selected := str(_state.get("selected_person", ""))
	var present: Array[String] = []
	%PersonsEmpty.visible = persons.is_empty()
	%PersonTitle.text = "选择一位人物"
	%PersonRole.text = ""
	%PersonDetail.text = str(_state.get("person_detail", "点击人物图标查看资料与关系。"))
	for data: Dictionary in persons:
		var id := str(data.get("id", ""))
		present.append(id)
		if not _person_nodes.has(id):
			var icon = PERSON_ICON.instantiate()
			%People.add_child(icon)
			icon.person_pressed.connect(_on_person_selected)
			_person_nodes[id] = icon
		_person_nodes[id].render(data, id == selected)
		if id == selected:
			%PersonTitle.text = str(data.get("name", ""))
			%PersonRole.text = str(data.get("role", ""))
			if %PersonDetail.text.is_empty():
				%PersonDetail.text = str(data.get("description", ""))
	_remove_missing(_person_nodes, present)
	var relations: Array = _state.get("relations", [])
	while _edge_nodes.size() < relations.size():
		var edge = RELATION_EDGE.instantiate()
		%Edges.add_child(edge)
		_edge_nodes.append(edge)
	while _edge_nodes.size() > relations.size():
		var edge: Line2D = _edge_nodes.pop_back()
		edge.queue_free()

func _layout_graph() -> void:
	if not is_node_ready():
		return
	var area: Vector2 = %GraphArea.size
	for data: Dictionary in _state.get("persons", []):
		var id := str(data.get("id", ""))
		if not _person_nodes.has(id):
			continue
		var icon: Control = _person_nodes[id]
		var coordinate: Array = data.get("position", [0.5, 0.5])
		var unit := Vector2(clampf(float(coordinate[0]), 0.0, 1.0), clampf(float(coordinate[1]), 0.0, 1.0))
		# 归一化坐标映射到可用区域，预留半个图标避免边缘人物被裁剪。
		var padding := Vector2(12, 12)
		var available := (area - icon.size - padding * 2.0).max(Vector2.ZERO)
		icon.position = padding + unit * available
	var relations: Array = _state.get("relations", [])
	for index in mini(relations.size(), _edge_nodes.size()):
		var data: Dictionary = relations[index]
		var from_id := str(data.get("from", ""))
		var to_id := str(data.get("to", ""))
		var edge = _edge_nodes[index]
		edge.visible = _person_nodes.has(from_id) and _person_nodes.has(to_id)
		if edge.visible:
			var from_icon: Control = _person_nodes[from_id]
			var to_icon: Control = _person_nodes[to_id]
			edge.render(from_icon.position + from_icon.size / 2.0, to_icon.position + to_icon.size / 2.0, str(data.get("type", "cooperation")))

func _remove_missing(nodes: Dictionary, present: Array[String]) -> void:
	for id in nodes.keys():
		if not present.has(id):
			var node: Node = nodes[id]
			node.get_parent().remove_child(node)
			node.queue_free()
			nodes.erase(id)

func _on_quantity_changed(item_id: String, quantity: int) -> void:
	trade_quantity_changed.emit(item_id, quantity)

func _on_event_selected(id: String) -> void:
	event_selected.emit(id)

func _on_person_selected(id: String) -> void:
	person_selected.emit(id)
