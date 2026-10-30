extends SceneTree
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)
func _run() -> void:
	root.size = Vector2i(1200, 720)
	var game = load("res://star_map_demo.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	var city = game.get_node("World/FlatNuclearCity")
	var vessel = game.ship
	var port = game.get_node("PortController")
	var button: Button = city.get_node("DockButton")
	game._select_ship()
	game.simulation_paused = true
	vessel.flight_position = city.get_dock_position() + Vector2(-1000, 0)
	vessel.flight_velocity = Vector2(0.11, 0)
	game._update_ui()
	check(not button.visible, "速度超过容差时隐藏按钮")
	vessel.flight_velocity = Vector2(0.05, 0)
	game._update_ui()
	check(button.visible, "范围内低速显示按钮")
	vessel.flight_velocity = Vector2(1, 0)
	button.pressed.emit()
	check(not vessel.voyage_finished and not port.active, "点击时复核速度")
	vessel.flight_velocity = Vector2.ZERO
	game._update_ui()
	game._sync_visuals()
	var camera = game.get_node("NavigationCamera")
	camera.position = city.global_position
	camera.force_update_scroll()
	await process_frame
	await process_frame
	var point: Vector2 = button.get_global_transform_with_canvas() * (button.size * 0.5)
	check(Rect2(Vector2.ZERO, Vector2(root.size)).has_point(point), "按钮位于屏幕内")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = point
	click.global_position = point
	click.pressed = true
	root.push_input(click)
	click = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = point
	click.global_position = point
	click.pressed = false
	root.push_input(click)
	await process_frame
	var position: Vector2 = vessel.flight_position
	check(vessel.voyage_finished and port.active and port.docked_ship == vessel, "实际鼠标点击立即打开港口")
	check(position == city.get_dock_position() + Vector2(-1000, 0) and vessel.completed_voyage_count == 1, "泊船不瞬移且记录一次航次")
	port.view.supply_settlement_requested.emit()
	port.view.depart_requested.emit()
	check(not vessel.voyage_finished and vessel.flight_position == position, "离港不瞬移")
	game._dock_city(city)
	check(not vessel.voyage_finished and vessel.completed_voyage_count == 1, "离港后范围内不能重复计航次")
	vessel.flight_position = city.flight_position + city.port_offset_m + Vector2(city.docking_radius_m + 1000, 0)
	game.simulation_paused = false
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	vessel.flight_position = position
	vessel.flight_velocity = Vector2.ZERO
	game._dock_city(city)
	check(vessel.voyage_finished and vessel.completed_voyage_count == 2, "离开范围后可再次泊船")
	var center: Vector2 = city.flight_position
	var hit: Array = game._integrate(center + Vector2(-60000, 0), Vector2(500000, 0), 0.25)
	check(hit[1] == Vector2.ZERO and absf(hit[0].x - (center.x - 50000)) < 1.0, "高速扫掠不能穿透城市")
	var crossing: Array = game._integrate(center + Vector2(-60000, -20000), Vector2(480000, 0), 0.25)
	check(absf(crossing[1].y - 9.81 * (100000.0 / 480000.0)) < 0.15, "横穿重力区只积分区内重力")
	port.view.supply_settlement_requested.emit()
	port.view.depart_requested.emit()
	city.port_offset_m = Vector2.ZERO
	vessel.departed_city = null
	vessel.flight_position = center + Vector2(0, -15000)
	vessel.flight_velocity = Vector2.ZERO
	game._dock_city(city)
	check(vessel.voyage_finished and vessel.flight_position == center + Vector2(0, -15000), "重力区内低速泊船固定当前位置")
	city.rotation_degrees_m = 90.0
	var angle := deg_to_rad(city.rotation_degrees_m)
	var rotated_hit: Array = game._integrate(center + Vector2(-60000, 0).rotated(angle), Vector2(500000, 0).rotated(angle), 0.25)
	check(rotated_hit[1] == Vector2.ZERO and rotated_hit[0].distance_to(center + Vector2(-50000, 0).rotated(angle)) < 1.0, "旋转城市高速扫掠不能穿透")
	var rotated_crossing: Array = game._integrate(center + Vector2(-60000, -20000).rotated(angle), Vector2(480000, 0).rotated(angle), 0.25)
	check(rotated_crossing[1].distance_to(Vector2(480000, 9.81 * (100000.0 / 480000.0)).rotated(angle)) < 0.2, "旋转重力区跨边界积分")
	city.rotation_degrees_m = 37.0
	angle = deg_to_rad(city.rotation_degrees_m)
	rotated_hit = game._integrate(center + Vector2(-60000, 0).rotated(angle), Vector2(500000, 0).rotated(angle), 0.25)
	check(rotated_hit[1] == Vector2.ZERO and rotated_hit[0].distance_to(center + Vector2(-50000, 0).rotated(angle)) < 1.0, "任意角城市高速扫掠不能穿透")
	rotated_crossing = game._integrate(center + Vector2(-60000, -20000).rotated(angle), Vector2(480000, 0).rotated(angle), 0.25)
	check(rotated_crossing[1].distance_to(Vector2(480000, 9.81 * (100000.0 / 480000.0)).rotated(angle)) < 0.2, "任意角重力区跨边界积分")
	var world_state: Array = game._preview_world_state()
	city.rotation_degrees_m = 45.0
	check(game._preview_world_state() != world_state, "城市角度变化使预览状态失效")
	game._sync_city_buttons()
	var button_center: Vector2 = button.position + (button.size * button.scale * 0.5).rotated(button.rotation)
	check(button_center.distance_to((city.port_offset_m + city.dock_offset_m) * city.pixels_per_meter) < 0.01, "旋转后泊船按钮中心对齐停靠点")
	check(absf(button.get_global_transform().get_rotation()) < 0.001, "泊船按钮保持水平")
	game.queue_free()
	await process_frame
	if failures == 0:
		print("city_docking_test: PASS")
	quit(1 if failures else 0)
