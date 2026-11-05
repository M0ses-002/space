extends SceneTree
## 完整港口流程：真实入轨资格、导航隔离、跨港共享信用点与起航补满燃料。
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
	var game = load("res://scenes/game/main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	game._select_ship()
	var ship = game.ship
	var source = game.planets[0]
	ship.flight_position = source.flight_position + Vector2(0, -62000)
	ship.flight_velocity = Vector2(sqrt(source.acceleration_at(ship.flight_position).length() * 62000), 0)
	for index in range(120):
		var next: Array = game._integrate(ship.flight_position, ship.flight_velocity, game.SIM_STEP)
		ship.flight_position = next[0]
		ship.flight_velocity = next[1]
		game._update_orbit_eligibility(ship, game.SIM_STEP)
	check(ship.stay_available, "稳定三十模拟秒且轨迹闭合后获得入轨资格")
	var previous_position: Vector2 = ship.flight_position
	var previous_velocity: Vector2 = ship.flight_velocity
	ship.fuel = 13.0
	var other_fuel: Dictionary = {}
	for vessel in game.ships:
		if vessel != ship:
			vessel.fuel = 23.0
			other_fuel[vessel] = vessel.fuel
	game._confirm_arrival(source)
	var port = game.get_node("PortController")
	check(port.active and ship.voyage_finished, "确认入轨打开独立交互场景")
	check(port.session.get_state().error.is_empty() and ship.fuel == 13.0, "加载A星成功且入港不补油")
	check(not game.get_node("HUD").visible and not game.get_node("StarMapView/HUD").visible, "隐藏全部航行UI")
	check(game.get_node("NavigationCamera").process_mode == Node.PROCESS_MODE_DISABLED, "禁用隐藏相机输入")
	for key in [KEY_R, KEY_M, KEY_F]:
		var event := InputEventKey.new()
		event.pressed = true
		event.keycode = key
		Input.parse_input_event(event)
		event = InputEventKey.new()
		event.keycode = key
		Input.parse_input_event(event)
	Input.flush_buffered_events()
	await process_frame
	check(port.active and ship.voyage_finished, "港口键盘不触发重置或切换视角")
	for tab in ["relations", "events"]:
		port.view.tab_requested.emit(tab)
		check(port.session.get_state().tab == tab, "标签信号驱动模型页面")
	for old_signal in ["trade_confirmed", "trade_quantity_changed", "fuel_purchase_requested", "fuel_quantity_changed", "supply_settlement_requested"]:
		check(not port.view.has_signal(old_signal), "删除旧经济信号：" + old_signal)
	var state: Dictionary = port.session.get_state()
	var person_id: String = str(state.persons[mini(1, state.persons.size() - 1)].id)
	port.view.person_selected.emit(person_id)
	check(port.session.get_state().selected_person == person_id, "人物选择发送到关系模型")
	var credits: int = port.session.get_credits()
	port.view.depart_requested.emit()
	check(not port.active and not ship.voyage_finished and game.get_node("HUD").visible, "无需结算直接起航返回航行场景")
	check(ship.flight_position == previous_position and ship.flight_velocity == previous_velocity, "起航恢复轨道位置速度")
	check(ship.fuel == ship.get_fuel_capacity() and port.session.get_credits() == credits, "行星成功离港免费补满实际油箱")
	for vessel in other_fuel:
		check(vessel.fuel == other_fuel[vessel], "行星离港不修改其他船燃料")
	check(game.get_node("NavigationCamera").process_mode != Node.PROCESS_MODE_DISABLED, "相机处理恢复")
	ship.fuel = 17.0
	port.view.depart_requested.emit()
	check(ship.fuel == 17.0, "隐藏港口起航信号不能赠油")
	port.session.add_credits(1000)
	ship.voyage_finished = true
	port.enter_port(source, ship)
	check(port.session.get_credits() == credits + 1000, "再访共享余额不重置")
	port.leave_port()
	var original_path: String = source.interaction_data_path
	source.interaction_data_path = "res://data/planets/planet_b.json"
	port.enter_port(source, ship)
	check(port.session.get_state().planet_name != state.planet_name and port.session.get_credits() == credits + 1000, "不同星球独立数据共享信用点")
	port.leave_port()
	source.interaction_data_path = original_path
	ship.arrival_source = source
	ship.upgrade_slots[0] = "fuel"
	port.enter_port(source, ship)
	for window_size in [Vector2i(1000, 700), Vector2i(1200, 720), Vector2i(1600, 900)]:
		root.size = window_size
		await process_frame
		await process_frame
		for id in ["ShipStatus", "DepartButton"]:
			var rect: Rect2 = port.view.get_node("%" + id).get_global_rect()
			check(Rect2(Vector2.ZERO, Vector2(window_size) + Vector2.ONE).encloses(rect), "关卡港口控件在视口内：" + id)
	ship.fuel = 0.0
	port.view.depart_requested.emit()
	check(not port.active and ship.fuel == ship.fuel_capacity * 1.2, "扩容船零燃料离港按120%实际容量补满")
	ship.fuel = 19.0
	game._depart()
	check(ship.fuel == 19.0, "未停靠起航失败不补油")
	game._reset()
	check(port.session.get_credits() == 1200, "完整重置恢复共享信用点")
	game.queue_free()
	await process_frame
	print("PORT_FLOW_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
