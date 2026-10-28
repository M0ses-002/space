extends SceneTree

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func click_at(position: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	root.push_input(motion, true)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = position
		event.pressed = pressed
		root.push_input(event, true)

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
	var previous_points: PackedVector2Array = game.orbit_preview.points.duplicate()
	click_at(accel.get_global_rect().get_center())
	await process_frame
	check(absf(game.ship_velocity.length() - speed - 20.0) < 0.01, "点击加速必须增加 20m/s")
	check(game.fuel_mass < fuel, "加速必须扣燃料")
	check(previous_points != game.orbit_preview.points, "加速应更新预览")
	click_at(brake.get_global_rect().get_center())
	await process_frame
	check(absf(game.ship_velocity.length() - speed) < 0.01, "点击减速必须减少 20m/s")
	check(game.selected, "点击 UI 不应丢失选中状态")
	click_at(Vector2(20, 20))
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
	print("ZOOM_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	print("FLIGHT_UI_TEST: %s (three window sizes, real mouse input, acceleration/braking/fuel/preview/reset)" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
