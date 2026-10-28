extends SceneTree
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(value: bool, text: String) -> void:
	if not value:
		failures += 1
		push_error(text)
func mouse_at(position: Vector2, pressed: bool) -> void:
	var move := InputEventMouseMotion.new()
	move.position = position
	root.push_input(move, true)
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = position
	event.pressed = pressed
	root.push_input(event, true)
func click(position: Vector2) -> void:
	mouse_at(position, true)
	mouse_at(position, false)
func _run() -> void:
	root.size = Vector2i(1200, 720)
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	for i in range(5): await process_frame
	check(game.ships.size() == 1 and game.ship_buttons.size() == 1, "初始一船一按钮")
	var first = game.ship
	click(game.ship_buttons[first].get_global_rect().get_center())
	await process_frame
	check(game.selected and not game.accelerate_button.disabled, "顶部按钮可选择飞船")
	var second = load("res://scenes/ship.tscn").instantiate()
	second.display_name = "轻艇"
	second.initial_position = Vector2(62000, 0)
	second.initial_velocity = Vector2(0, 655)
	game.get_node("World").add_child(second)
	for i in range(5): await process_frame
	check(game.ship_buttons.size() == 2, "新增实例自动新增按钮")
	click(game.ship_buttons[second].get_global_rect().get_center())
	await process_frame
	check(game.ship == second and game.selected, "选择第二艘船")
	check(not game.ship_buttons[first].button_pressed and game.ship_buttons[second].button_pressed, "单选高亮")
	var first_fuel: float = first.fuel
	var second_fuel: float = second.fuel
	var gravities: Dictionary = {}
	for source in game.planets:
		gravities[source] = source.surface_gravity
		source.surface_gravity = 0.0
	mouse_at(game.accelerate_button.get_global_rect().get_center(), true)
	check(is_equal_approx(second.flight_velocity.length(), 655.0) and second.fuel == second_fuel, "按下推进不立即改速扣油")
	for step in range(4):
		game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	mouse_at(game.accelerate_button.get_global_rect().get_center(), false)
	await process_frame
	var delta_v: float = second.max_acceleration * game.SIM_STEP * 4
	check(absf(second.flight_velocity.length() - 655.0 - delta_v) < 0.01, "长按仅为控制目标持续加速")
	check(absf(second_fuel - second.fuel - delta_v * second.propulsion_fuel_per_delta_v) < 0.001, "控制目标按实际速度增量独立扣油")
	check(first.fuel == first_fuel and absf(first.flight_velocity.length() - 655) < 0.01, "未选船不接受手动推力")
	var released_fuel: float = second.fuel
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(second.fuel == released_fuel and is_zero_approx(second.manual_thrust), "松开后控制目标停止耗油")
	for source in game.planets:
		source.surface_gravity = gravities[source]
	click(first.get_global_transform_with_canvas().origin)
	await process_frame
	check(game.ship == first and game.selected, "场景内拾取恢复")
	game._select_target(second)
	second.queue_free()
	for i in range(5): await process_frame
	check(game.ship_buttons.size() == 1 and not game.selected, "移除当前船自动清理按钮与选中态")
	first.queue_free()
	for i in range(5): await process_frame
	check(game.ship_buttons.is_empty() and game.accelerate_button.disabled, "空舰队安全")
	var third = load("res://scenes/ship.tscn").instantiate()
	game.get_node("World").add_child(third)
	for i in range(5): await process_frame
	check(game.ship_buttons.size() == 1, "空舰队重新添加")
	for i in range(12):
		var extra = load("res://scenes/ship.tscn").instantiate()
		game.get_node("World").add_child(extra)
	for i in range(5): await process_frame
	check(game.ship_buttons.size() == 13, "多船数量动态生成")
	var bar: Control = game.get_node("HUD/Root/FleetBar")
	check(bar.get_global_rect().end.x <= game.panel.get_global_rect().position.x, "多船列表不挤压右侧 UI")
	var scroll: ScrollContainer = game.get_node("HUD/Root/FleetBar/Margin/Row/Scroll")
	check(scroll.get_h_scroll_bar().visible, "多船超宽时显示横向滚动条")
	var camera = game.get_node("NavigationCamera")
	var zoom_before: float = camera.zoom_level
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.position = bar.get_global_rect().get_center()
	wheel.pressed = true
	root.push_input(wheel, true)
	check(camera.zoom_level == zoom_before, "顶部 UI 上滚轮不得缩放场景")
	print("FLEET_SELECTION_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
