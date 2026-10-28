extends SceneTree

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func mouse_at(position: Vector2, pressed: bool) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	root.push_input(motion, true)
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = position
	event.pressed = pressed
	root.push_input(event, true)

func click_at(position: Vector2) -> void:
	mouse_at(position, true)
	mouse_at(position, false)

func scroll_at(position: Vector2, button: MouseButton) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	root.push_input(motion, true)
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.position = position
	event.pressed = true
	root.push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event, true)

func check_coasting_preview(game: Node) -> void:
	var position: Vector2 = game.ship_position
	var velocity: Vector2 = game.ship_velocity
	var expected := PackedVector2Array([position])
	for index in range(int(game.PREVIEW_SECONDS / game.SIM_STEP)):
		var state: Array = game._integrate(position, velocity, game.SIM_STEP, game.ship.gravity_threshold)
		position = state[0]
		velocity = state[1]
		if game._touches_planet(position):
			expected.append(position)
			break
		if (index + 1) % game.PREVIEW_SAMPLE_STEPS == 0:
			expected.append(position)
	check(game.preview_points == expected, "长按中的每个预览采样点应等于当前状态停止推力后的重力滑行轨迹")

func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1200, 720)
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	for index in range(5):
		await process_frame
	var accel: Button = game.accelerate_button
	var brake: Button = game.brake_button
	check(game.orbit_preview.points.size() > 100, "预览 Line2D 应包含航迹")
	check(accel.disabled and brake.disabled, "未选中时按钮应置灰而非隐藏")
	for size in [Vector2i(1200, 720), Vector2i(900, 640), Vector2i(1600, 900)]:
		root.size = size
		for index in range(5):
			await process_frame
		var screen := Rect2(Vector2.ZERO, Vector2(size))
		for button in [accel, brake]:
			check(button.is_visible_in_tree(), "按钮必须可见")
			check(screen.encloses(button.get_global_rect()), "按钮必须完整位于窗口内: %s" % size)
		check(not accel.get_global_rect().intersects(brake.get_global_rect()), "按钮不应重叠")
		check(absf(game.panel.get_global_rect().end.x - size.x) < 1.0, "面板必须贴右边界")
	click_at(game.ship.global_position)
	await process_frame
	check(game.selected and not accel.disabled and not brake.disabled, "鼠标点击飞船后按钮应启用")
	var speed: float = game.ship_velocity.length()
	var fuel: float = game.fuel_mass
	var threshold: float = game.ship.gravity_threshold
	game.ship.gravity_threshold = 1000.0
	check(is_equal_approx(game.ship.max_acceleration, 10.0) and is_equal_approx(game.ship.max_deceleration, 10.0), "默认加减速度均为 10m/s²")
	var previous_points: PackedVector2Array = game.orbit_preview.points.duplicate()
	mouse_at(accel.get_global_rect().get_center(), true)
	await process_frame
	check(is_equal_approx(game.ship_velocity.length(), speed) and game.fuel_mass == fuel, "按下只开始持续推进，不瞬间改速扣油")
	for step in range(4):
		game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	var delta_v: float = game.ship.max_acceleration * game.SIM_STEP * 4
	check(absf(game.ship_velocity.length() - speed - delta_v) < 0.01, "长按加速按模拟时间积分")
	check(absf(fuel - game.fuel_mass - delta_v * game.ship.propulsion_fuel_per_delta_v) < 0.001, "推进按速度增量乘耗油系数扣油")
	check(previous_points != game.orbit_preview.points, "持续推进应更新预览")
	mouse_at(accel.get_global_rect().get_center(), false)
	var released_speed: float = game.ship_velocity.length()
	var released_fuel: float = game.fuel_mass
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(is_equal_approx(game.ship_velocity.length(), released_speed) and game.fuel_mass == released_fuel, "松开停止推进与耗油")
	mouse_at(brake.get_global_rect().get_center(), true)
	check(is_equal_approx(game.ship_velocity.length(), released_speed), "按下减速不瞬间改速")
	for step in range(4):
		game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	mouse_at(brake.get_global_rect().get_center(), false)
	await process_frame
	check(absf(game.ship_velocity.length() - speed) < 0.01, "等时长减速恢复原速度")
	check(absf(released_fuel - game.fuel_mass - delta_v * game.ship.propulsion_fuel_per_delta_v) < 0.001, "减速也按速度增量耗油")
	game.ship.gravity_threshold = threshold
	for button in [accel, brake]:
		game._refresh_preview()
		var before_press: PackedVector2Array = game.preview_points.duplicate()
		mouse_at(button.get_global_rect().get_center(), true)
		check(game.preview_points == before_press, "仅按下、不推进时间时，轨迹不得因未来长按假设而改变")
		check_coasting_preview(game)
		# 跨过预览刷新周期，验证实际推进时自动从最新状态重新预测。
		var frames := int(ceil(game.PREVIEW_REFRESH_INTERVAL * game.TIME_SCALE / game.SIM_STEP)) + 1
		for frame in range(frames):
			game._physics_process(game.SIM_STEP / game.TIME_SCALE)
		check(game.preview_points != before_press, "长按过程中轨迹应自动随实际位置与速度变化")
		game._refresh_preview()
		check_coasting_preview(game)
		var before_release: PackedVector2Array = game.preview_points.duplicate()
		mouse_at(button.get_global_rect().get_center(), false)
		game._refresh_preview()
		check(game.preview_points == before_release, "同一状态下松手前后的滑行预览应一致")
	check(game.selected, "点击 UI 不应丢失选中状态")
	for size in [Vector2i(900, 640), Vector2i(1200, 720), Vector2i(1600, 900)]:
		root.size = size
		for frame in range(5):
			await process_frame
		var bounds := Rect2(Vector2.ZERO, Vector2(size))
		var buttons: Array = [accel, brake, game.hover_button, game.orbit_button, game.pause_button, game.speed_row, game.panel.get_node("Margin/Content/ResetButton")]
		for index in range(buttons.size()):
			check(bounds.encloses(buttons[index].get_global_rect()), "选船后新增控件完整位于窗口内: %s" % size)
			for other in range(index + 1, buttons.size()):
				check(not buttons[index].get_global_rect().intersects(buttons[other].get_global_rect()), "飞行面板控件不重叠")
	click_at(game.pause_button.get_global_rect().get_center())
	check(game.simulation_paused and accel.disabled and brake.disabled and game.hover_button.disabled, "暂停禁用推进与悬停")
	click_at(game.pause_button.get_global_rect().get_center())
	check(not game.simulation_paused and not game.hover_button.disabled, "继续后恢复操作")
	click_at(Vector2(20, 160))
	await process_frame
	check(not game.selected and accel.disabled, "点击空白应取消选中")
	game._select_ship()
	game.fuel_mass = 0.0
	game._update_ui()
	check(accel.disabled and brake.disabled, "无燃料应禁用按钮")
	game._reset()
	check(not game.selected and game.fuel_mass == game.INITIAL_FUEL, "重置应恢复初始状态")
	var camera = game.get_node("NavigationCamera")
	var cursor := Vector2(400, 300)
	var world_before: Vector2 = game.get_canvas_transform().affine_inverse() * cursor
	var panel_before: Rect2 = game.panel.get_global_rect()
	scroll_at(cursor, MOUSE_BUTTON_WHEEL_UP)
	await process_frame
	check(camera.zoom_level > 1.0, "非 UI 区滚轮向上放大")
	var world_after: Vector2 = game.get_canvas_transform().affine_inverse() * cursor
	check(world_before.distance_to(world_after) < 0.1, "缩放应保持鼠标下世界位置")
	check(game.panel.get_global_rect() == panel_before, "UI 不随相机缩放")
	var zoom_before: float = camera.zoom_level
	for ui_position in [accel.get_global_rect().get_center(), brake.get_global_rect().get_center(), game.panel.get_global_rect().position + Vector2(8, 8)]:
		scroll_at(ui_position, MOUSE_BUTTON_WHEEL_UP)
		await process_frame
		check(is_equal_approx(camera.zoom_level, zoom_before), "按钮和面板空白上不得缩放")
	scroll_at(cursor, MOUSE_BUTTON_WHEEL_DOWN)
	await process_frame
	check(is_equal_approx(camera.zoom_level, 1.0), "滚轮向下缩小")
	scroll_at(cursor, MOUSE_BUTTON_WHEEL_UP)
	await process_frame
	var ship_screen: Vector2 = game.ship.get_global_transform_with_canvas().origin
	click_at(ship_screen)
	await process_frame
	check(game.selected, "缩放后仍能点击飞船")
	scroll_at(ship_screen, MOUSE_BUTTON_WHEEL_UP)
	await process_frame
	check(camera.zoom_level > zoom_before, "飞船拾取按钮不应被误判为 HUD")
	for index in range(80):
		scroll_at(cursor, MOUSE_BUTTON_WHEEL_UP)
	check(is_equal_approx(camera.zoom_level, camera.maximum_zoom), "缩放上限")
	for index in range(80):
		scroll_at(cursor, MOUSE_BUTTON_WHEEL_DOWN)
	check(is_equal_approx(camera.zoom_level, camera.minimum_zoom), "缩放下限")
	game._reset()
	check(is_equal_approx(camera.zoom_level, 1.0), "重置航行恢复视图")
	camera.set_process(false)
	var pan_start: Vector2 = camera.position
	var simulation_position: Vector2 = game.ship_position
	var panel_rect: Rect2 = game.panel.get_global_rect()
	for key in [KEY_W, KEY_A, KEY_S, KEY_D]:
		var before: Vector2 = camera.position
		var press := InputEventKey.new()
		press.physical_keycode = key
		press.pressed = true
		Input.parse_input_event(press)
		Input.flush_buffered_events()
		camera._process(0.1)
		var expected: Vector2 = {KEY_W: Vector2.UP, KEY_A: Vector2.LEFT, KEY_S: Vector2.DOWN, KEY_D: Vector2.RIGHT}[key]
		check(camera.position.distance_to(before + expected * camera.pan_speed * 0.1) < 0.01, "WASD 应按对应方向平移")
		var release := InputEventKey.new()
		release.physical_keycode = key
		release.pressed = false
		Input.parse_input_event(release)
		Input.flush_buffered_events()
		var stopped: Vector2 = camera.position
		camera._process(0.1)
		check(camera.position == stopped, "松开按键应停止")
	check(camera.position.distance_to(pan_start) < 0.01, "四个方向移动距离一致")
	var before_diagonal: Vector2 = camera.position
	camera._pan(Vector2(1, 1), 0.1)
	check(absf(camera.position.distance_to(before_diagonal) - camera.pan_speed * 0.1) < 0.01, "斜向速度不应更快")
	camera.zoom_level = 2.0
	camera.zoom = Vector2.ONE * 2.0
	var before_zoom_pan: Vector2 = camera.position
	camera._pan(Vector2.RIGHT, 0.1)
	check(absf(camera.position.distance_to(before_zoom_pan) * 2.0 - camera.pan_speed * 0.1) < 0.01, "缩放下屏幕平移速度一致")
	check(game.ship_position == simulation_position, "移动相机不得改变物理位置")
	check(game.panel.get_global_rect() == panel_rect, "平移不得移动 HUD")
	game._reset()
	check(camera.position.distance_to(Vector2(root.size) * 0.5) < 0.01, "重置恢复相机位置")
	print("PAN_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	print("ZOOM_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	print("FLIGHT_UI_TEST: %s (three window sizes, real mouse input, acceleration/braking/fuel/preview/reset)" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
