extends SceneTree
## 完整港口流程：使用真实入轨资格入口，检查导航隔离及各星数据切换。
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)
func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1200, 720)
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	game._select_ship()
	var ship = game.ship
	check(ship.cargo_mass == 10, "启动即同步起始船10kg载货")
	for vessel in game.ships:
		if vessel != ship:
			check(vessel.cargo_mass == 0, "其他船启动为空货舱")
	var source = game.planets[0]
	ship.flight_position = source.flight_position + Vector2(0, -62000)
	ship.flight_velocity = Vector2(sqrt(source.acceleration_at(ship.flight_position).length() * 62000), 0)
	ship.track_orbit(source, game._gravity_at(ship.flight_position))
	ship.orbit_angle = TAU
	ship.stay_available = true
	var previous_position: Vector2 = ship.flight_position
	var previous_velocity: Vector2 = ship.flight_velocity
	game._confirm_arrival(source)
	var port = game.get_node("PortController")
	check(port.active and ship.voyage_finished, "确认入轨打开独立交互场景")
	check(port.session.get_state().error.is_empty(), "加载A星JSON成功")
	check(port._get_state().supply_pending and port._get_state().supply_cost == 0, "首个零距离航程可免费结算")
	game._depart()
	check(port.active and ship.voyage_finished and game.flight_message.contains("结清"), "直接起航也不能绕过待结算账单")
	port.view.depart_requested.emit()
	check(port.active and ship.voyage_finished, "港口起航按钮在结算前被拦截")
	var before_supply: int = port.session.get_state().credits
	port.view.supply_settlement_requested.emit()
	port.view.supply_settlement_requested.emit()
	check(not port._get_state().supply_pending and port.session.get_state().credits == before_supply, "重复结算不会收费")
	check(not game.get_node("HUD").visible and not game.get_node("StarMapView/HUD").visible, "隐藏全部航行UI")
	check(game.get_node("NavigationCamera").process_mode == Node.PROCESS_MODE_DISABLED, "禁用隐藏相机输入")
	for key in [KEY_R, KEY_M, KEY_F, KEY_ESCAPE]:
		var event := InputEventKey.new()
		event.pressed = true
		event.keycode = key
		Input.parse_input_event(event)
		event = InputEventKey.new()
		event.keycode = key
		event.pressed = false
		Input.parse_input_event(event)
	Input.flush_buffered_events()
	await process_frame
	check(port.active and ship.voyage_finished, "港口键盘不触发重置或切换视角")
	for tab in ["trade", "relations", "events"]:
		port.view.tab_requested.emit(tab)
		check(port.session.get_state().tab == tab, "标签信号驱动模型页面")
	var state: Dictionary = port.session.get_state()
	var item_id: String = state.trade_rows[0].id
	var old_credits: float = state.credits
	var delta_v_before_trade: float = port._get_state().fuel_delta_v
	port.view.trade_quantity_changed.emit(item_id, 1)
	check(port.session.get_state().credits == old_credits, "数量调整不扣款")
	port.view.trade_confirmed.emit()
	check(port.session.get_state().credits < old_credits, "确认交易后扣款")
	check(ship.cargo_mass == 20, "货物交易立即同步停靠船质量")
	check(port._get_state().fuel_delta_v < delta_v_before_trade and is_equal_approx(port._get_state().fuel_delta_v, ship.fuel / ship.get_effective_propulsion_fuel_per_delta_v()), "买货后按当前实际质量立即更新可用Δv")
	check(port.view.get_node("%FuelDeltaV").text.contains("%.1f" % port._get_state().fuel_delta_v), "港口燃料区展示当前Δv")
	ship.fuel = 0
	port.refresh()
	check(port.view.get_node("%Status").text.contains("零燃料仍可起航"), "零油允许起航但显示明确提示")
	var other_fuel: Dictionary = {}
	for vessel in game.ships:
		if vessel != ship:
			other_fuel[vessel] = vessel.fuel
	var before_fuel_credits: int = port.session.get_state().credits
	port.view.fuel_quantity_changed.emit(40)
	var preview: Dictionary = port._get_state()
	check(preview.can_buy_fuel and is_equal_approx(preview.fuel_preview_delta_v, ship.fuel_to_delta_v(40)), "输入40kg立即预览购买后Δv")
	check(ship.fuel == 0 and port.session.get_state().credits == before_fuel_credits, "预览不会改变油量或信用点")
	check(port.view.get_node("%FuelDeltaV").text.contains("%.1f" % preview.fuel_preview_delta_v), "输入数量后显示预计值")
	port.view.fuel_quantity_changed.emit(10000)
	check(not port._get_state().can_buy_fuel and port.view.get_node("%FuelDeltaV").text.contains("不可购买"), "超过容量时不展示可实现的预计值")
	port.view.fuel_quantity_changed.emit(100)
	preview = port._get_state()
	check(is_equal_approx(preview.fuel_preview_delta_v, ship.fuel_to_delta_v(100)), "修改输入实时更新预计Δv")
	port.view.fuel_purchase_requested.emit()
	check(is_equal_approx(port._get_state().fuel_delta_v, preview.fuel_preview_delta_v) and not port._get_state().can_buy_fuel, "购买后实际Δv与预览一致且清空输入")
	check(ship.fuel == 100 and port.session.get_state().credits == before_fuel_credits - 10, "单次信号只购买100kg并扣10信用点")
	check(is_equal_approx(port._get_state().fuel_delta_v, 100.0 / ship.get_effective_propulsion_fuel_per_delta_v()), "购买后Δv按当前质量实时增加")
	check(ship.cargo_mass == 20 and ship.get_total_mass() == ship.dry_mass + 20, "燃料直接入油箱，不占货舱且不改变干重加货物的载重口径")
	for vessel in other_fuel:
		check(vessel.fuel == other_fuel[vessel], "加油不修改其他船")
	var fuel_before_departure: float = ship.fuel
	var person_id: String = state.persons[1].id
	port.view.person_selected.emit(person_id)
	check(port.session.get_state().selected_person == person_id, "人物选择发送到关系模型")
	port.view.depart_requested.emit()
	check(not port.active and not ship.voyage_finished and game.get_node("HUD").visible, "起航返回航行场景")
	check(ship.flight_position == previous_position and ship.flight_velocity == previous_velocity and ship.fuel == fuel_before_departure, "起航恢复轨道但不自动补油")
	check(game.info_label.text.contains("%.1f" % ship.fuel_to_delta_v(ship.fuel)) and game.info_label.text.contains("Δv"), "航行面板燃料显示与港口一致的Δv")
	var credits_after_departure: int = port.session.get_state().credits
	port.view.fuel_purchase_requested.emit()
	port.view.trade_confirmed.emit()
	check(ship.fuel == fuel_before_departure and port.session.get_state().credits == credits_after_departure, "离港后的隐藏信号不能购买或交易")
	check(game.get_node("NavigationCamera").process_mode != Node.PROCESS_MODE_DISABLED, "相机处理恢复")
	# 同一模型再次访问保留交易，B星从自己的JSON加载。
	port.enter_port(source, ship)
	check(port.session.get_state().credits < old_credits, "再访保留本次运行经济状态")
	port.leave_port()
	var original_path: String = source.interaction_data_path
	source.interaction_data_path = "res://data/planets/planet_b.json"
	port.enter_port(source, ship)
	check(port.session.get_state().planet_name != state.planet_name, "不同星球使用独立JSON")
	port.leave_port()
	source.interaction_data_path = original_path
	# 独立货舱在多船往返中保留，完整重置不把首船初始货转给选中船。
	var extra = load("res://scenes/ship.tscn").instantiate()
	game.get_node("World").add_child(extra)
	await process_frame
	await process_frame
	check(extra.cargo_mass == 0, "动态船登记后为空货舱")
	extra.voyage_finished = true
	port.enter_port(source, extra)
	check(port.session.get_state().cargo_used == 0, "第二船入港使用自己的货舱")
	port.view.trade_quantity_changed.emit("alloy", 1)
	port.view.trade_confirmed.emit()
	check(extra.cargo_mass == 10 and ship.cargo_mass == 20, "第二船交易不污染首船货舱")
	var shared_credits: int = port.session.get_state().credits
	port.leave_port()
	ship.voyage_finished = true
	port.enter_port(source, ship)
	check(port.session.get_state().cargo_used == 20 and port.session.get_state().credits == shared_credits, "返回首船货舱保持且共享新余额")
	port._change_tab("trade")
	for window_size in [Vector2i(1000, 700), Vector2i(1200, 720), Vector2i(1600, 900)]:
		root.size = window_size
		await process_frame
		await process_frame
		for id in ["ShipStatus", "ConfirmTrade", "DepartButton"]:
			var rect: Rect2 = port.view.get_node("%" + id).get_global_rect()
			check(rect.position.x >= 0 and rect.position.y >= 0 and rect.end.x <= window_size.x + 1 and rect.end.y <= window_size.y + 1, "燃料与载重控件在视口内：" + id)
	ship.fuel = 0
	ship.arrival_source = source
	port.refresh()
	port.view.depart_requested.emit()
	check(not port.active and ship.fuel == 0, "零燃料仍可起航且不获赠燃料")
	game.ship = extra
	game._reset()
	check(ship.cargo_mass == 10 and extra.cargo_mass == 0 and port.session.get_state().credits == 1200, "完整重置恢复原始船货舱和共享信用点")
	ship.queue_free()
	await process_frame
	var replacement = load("res://scenes/ship.tscn").instantiate()
	game.get_node("World").add_child(replacement)
	await process_frame
	await process_frame
	check(replacement.cargo_mass == 0 and extra.cargo_mass == 0, "删除起始船后新增船不能重复领取10kg")
	game.queue_free()
	await process_frame
	print("PORT_FLOW_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
