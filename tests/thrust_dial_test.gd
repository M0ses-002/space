extends SceneTree
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)
func mouse(position: Vector2, pressed: bool) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	Input.parse_input_event(motion)
	var button := InputEventMouseButton.new()
	button.position = position
	button.button_index = MOUSE_BUTTON_LEFT
	button.pressed = pressed
	Input.parse_input_event(button)
	Input.flush_buffered_events()
func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1200, 720)
	var game = load("res://star_map_demo.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	var view = game.get_node("StarMapView")
	var dial = game.get_node("HUD/Root/ThrustDial")
	var vessel = game.ship
	vessel.upgrade_slots[0] = "thruster"
	vessel.cargo_mass = 0.0
	game._set_throttle(0.5)
	dial.sync_state()
	check(is_equal_approx(dial.slider.max_value, 15.0) and is_equal_approx(dial.slider.value, 7.5) and dial.output.text.contains("7.5 / 15.0 m/s²"), "改装后油门量程符合实际")
	vessel.cargo_mass = vessel.dry_mass
	dial.sync_state()
	check(is_equal_approx(dial.slider.max_value, 7.5) and is_equal_approx(dial.slider.value, 3.75) and is_equal_approx(vessel.thrust_throttle, 0.5), "载重变化时更新油门量程并保持油门比例")
	vessel.flight_position = Vector2(0, -2000000)
	vessel.flight_velocity = Vector2.ZERO
	game._set_thrust_direction(Vector2.RIGHT)
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(absf(vessel.flight_velocity.x - 3.75 * game.SIM_STEP) < 0.001, "改装载重后方向推进实际按油门积分")
	vessel.upgrade_slots[0] = ""
	vessel.cargo_mass = 0.0
	game._stop_thrust()
	dial.sync_state()
	for window_size in [Vector2i(1200, 720), Vector2i(1600, 900), Vector2i(960, 640)]:
		root.size = window_size
		await process_frame
		await process_frame
		var bounds: Rect2 = dial.get_global_rect()
		check(bounds.position.x >= 0 and bounds.end.x <= window_size.x - 320 and bounds.end.y <= window_size.y, "仪表在可用视口内")
		check(not bounds.intersects(view.map_panel.get_global_rect()), "仪表与信息面板不重叠")
	root.size = Vector2i(1200, 720)
	await process_frame
	await process_frame
	game._clear_navigation_target()
	var center: Vector2 = dial.dial.get_global_rect().position + Vector2(76, 76)
	mouse(center + Vector2(0, -60), true)
	mouse(center + Vector2(0, -60), false)
	await process_frame
	check(vessel.thrust_direction.distance_to(Vector2.UP) < 0.001, "实际鼠标点击圆盘设定上方推力")
	check(vessel.thrust_throttle == 0 and not vessel.steering, "转针本身不点火")
	check(not vessel.has_navigation_target, "仪表点击不能穿透星图设置目标")
	dial.slider.value = dial.slider.max_value * 0.5
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	game._input(release)
	check(vessel.steering and vessel.thrust_throttle == 0.5, "滑条松手保持油门且无目标也能推进")
	# 隔离推力测试，不依赖用户在演示场景中调整的引力范围。
	vessel.flight_position = Vector2(0, -2000000)
	var before: Vector2 = vessel.flight_velocity
	var fuel: float = vessel.fuel
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	var delta_v: float = vessel.get_effective_steering_acceleration() * 0.5 * game.SIM_STEP
	check(absf(vessel.flight_velocity.y - before.y + delta_v) < 0.001 and vessel.flight_velocity.x == before.x, "50%出力有限侧推保留横向速度")
	check(absf(fuel - vessel.fuel - delta_v * vessel.get_effective_propulsion_fuel_per_delta_v()) < 0.001, "按实际施加Δv耗油")
	# 拖动时改变角度而不改变油门。
	mouse(center + Vector2(0, -60), true)
	var motion := InputEventMouseMotion.new()
	motion.position = center + Vector2(-60, 0)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	mouse(center + Vector2(-60, 0), false)
	check(vessel.thrust_direction.distance_to(Vector2.LEFT) < 0.001 and vessel.thrust_throttle == 0.5, "实际拖动指针改变推力方向且油门不变")
	var direction: Vector2 = vessel.thrust_direction
	game._set_navigation_target(Vector2(999999, 999999))
	check(vessel.thrust_direction == direction and vessel.thrust_throttle == 0.5, "导航点独立于手动推力")
	game.get_window().focus_exited.emit()
	check(not vessel.steering and vessel.thrust_throttle == 0 and not dial.dragging, "失焦自动收油并停止拖动")
	game._set_throttle(0.75)
	game._toggle_pause()
	game._toggle_pause()
	check(vessel.thrust_throttle == 0, "暂停继续不会自动重新点火")
	view.set_map_mode(false)
	game._set_throttle(0.5)
	check(vessel.steering, "近域也可手动方向推进")
	dial._cutoff()
	check(vessel.thrust_throttle == 0 and dial.slider.value == 0, "收油按钮同步滑条")
	vessel.flight_velocity = Vector2.ZERO
	dial.sync_state()
	check(not dial.velocity_needle.visible, "零速度隐藏无定义方向针")
	game._set_thrust_direction(Vector2.DOWN)
	game._set_throttle(1)
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(vessel.flight_velocity.y > 0, "静止时能沿指定方向起步")
	game._set_throttle(2)
	check(vessel.thrust_throttle == 1, "油门限制100%")
	game._set_throttle(-1)
	check(vessel.thrust_throttle == 0, "负油门归零")
	var camera = game.get_node("NavigationCamera")
	check(camera._over_ui(center), "仪表区域屏蔽世界缩放")
	await process_frame
	await process_frame
	# 两块面板仅由标题拖动；操作不得穿透世界或修改指针/油门。
	for panel in [dial, view.map_panel]:
		var handle: Label = panel.get_node("Layout/Title") if panel == dial else panel.get_node("Margin/Content/Title")
		var start: Vector2 = panel.global_position
		var pointer := handle.get_global_rect().get_center()
		var target_before: Vector2 = vessel.navigation_target
		var aim_before: Vector2 = vessel.thrust_direction
		mouse(pointer, true)
		var drag := InputEventMouseMotion.new()
		drag.position = pointer + Vector2(20, -90)
		drag.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(drag)
		Input.flush_buffered_events()
		mouse(drag.position, false)
		var expected := Vector2(clampf(start.x + 20, 0, root.size.x - panel.size.x), clampf(start.y - 90, 0, root.size.y - panel.size.y))
		check(panel.global_position.distance_to(expected) < 1, "标题拖动正确移动面板")
		check(not handle.moving, "松手结束面板拖动")
		check(vessel.navigation_target == target_before and vessel.thrust_direction == aim_before and vessel.thrust_throttle == 0, "移动面板不改变航行控制或目标")
		check(camera._over_ui(panel.get_global_rect().get_center()), "移动后的面板仍屏蔽世界缩放")
		mouse(handle.get_global_rect().get_center(), true)
		game.get_window().focus_exited.emit()
		check(not handle.moving, "失焦结束面板拖动")
		mouse(handle.get_global_rect().get_center(), false)
		panel.global_position = Vector2(-500, 9000)
		handle._clamp_panel()
		check(panel.global_position.x >= 0 and panel.get_global_rect().end.y <= root.size.y, "面板限制在窗口内 %s %s / %s" % [panel.name, panel.get_global_rect(), root.size])
		panel.global_position = start
	check(not view.has_node("HUD/Root/ThrustDial"), "仪表已脱离星图场景")
	game._reset()
	await process_frame
	check(game.ship.thrust_throttle == 0 and game.ship.thrust_direction == Vector2.RIGHT, "重置恢复方向与零油门")
	print("THRUST_DIAL_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
