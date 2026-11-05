extends SceneTree
var failures := 0
var assertions := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		push_error(message)

func mouse_at(point: Vector2, pressed: bool) -> void:
	var move := InputEventMouseMotion.new()
	move.position = point
	root.push_input(move, true)
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = point
	event.pressed = pressed
	root.push_input(event, true)

func click(point: Vector2) -> void:
	mouse_at(point, true)
	mouse_at(point, false)

func place_at_screen(game: Node2D, object: Node2D, point: Vector2) -> void:
	var canvas: Vector2 = game.get_node("World").to_local(game.get_canvas_transform().affine_inverse() * point)
	object.flight_position = (canvas - game._screen_center()) / game._view_scale()
	game._sync_visuals()

func _run() -> void:
	root.size = Vector2i(1200, 720)
	# 本专项不验证音频，避免 headless dummy 后端退出时残留播放引用。
	root.get_node("BackgroundMusic").stop_music()
	root.get_node("UIClickSound").stream = null
	var game = load("res://scenes/game/main.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	for i in range(3): await process_frame
	var asteroid = load("res://scenes/world/asteroid.tscn").instantiate()
	asteroid.mass_kg = 100.125
	asteroid.radius_m = 10.0
	asteroid.initial_position = Vector2(400000, 0)
	var debris = load("res://scenes/world/space_debris.tscn").instantiate()
	debris.radius_m = 10.0
	debris.initial_position = Vector2(500000, 0)
	game.get_node("World").add_child(asteroid)
	game.get_node("World").add_child(debris)
	for i in range(5): await process_frame
	var info = game.get_node("HUD/Root/SpaceObjectInfo")
	var camera = game.get_node("NavigationCamera")
	var map = game.get_node("StarMapView")
	var vessel = game.ship
	click(game.ship_buttons[vessel].get_global_rect().get_center())
	await process_frame
	place_at_screen(game, asteroid, Vector2(520, 210))
	place_at_screen(game, debris, Vector2(650, 210))
	vessel.steering = true
	vessel.thrust_throttle = 0.3
	vessel.thrust_direction = Vector2.UP
	vessel.has_navigation_target = true
	vessel.navigation_target = Vector2(123456, 654321)
	var fuel: float = vessel.fuel
	var velocity: Vector2 = vessel.flight_velocity
	click(Vector2(529, 210))
	await process_frame
	check(game.inspected_object == asteroid and info.panel.visible, "近域真实点击小目标含12像素容差")
	check(info.category.text == "类别：小行星" and info.mass.text == "质量：100.125 kg", "小行星类别及真实质量：%s / %s 实际质量=%s" % [info.category.text, info.mass.text, asteroid.mass_kg])
	check(info.ring_radius >= 12.0 and info.ring_center.distance_to(Vector2(520, 210)) < 0.1, "选中环使用屏幕像素坐标")
	check(game.ship == vessel and game.selected and vessel.steering and vessel.thrust_throttle == 0.3, "物体选择不替换受控船或中断持续推进")
	check(vessel.fuel == fuel and vessel.flight_velocity == velocity and vessel.navigation_target == Vector2(123456, 654321), "物体查看不更改速度燃料导航")
	click(Vector2(650, 210))
	await process_frame
	check(game.inspected_object == debris and info.category.text == "类别：太空垃圾", "近域真实点击区分垃圾")
	check(info.mass.text == "质量：%s / %s kg" % [String.num(debris.remaining_mass_kg), String.num(debris.mass_kg)] and info.mass.tooltip_text.contains("剩余质量"), "垃圾显示剩余/固定总质量，不从危险区域推导：%s / %s 实际质量=%s" % [info.mass.text, info.mass.tooltip_text, debris.mass_kg])
	var before_position: Vector2 = debris.flight_position
	var panel_point: Vector2 = info.panel.get_global_rect().get_center()
	place_at_screen(game, asteroid, panel_point)
	click(panel_point)
	await process_frame
	check(game.inspected_object == debris and vessel.navigation_target == Vector2(123456, 654321), "面板背景点击不穿透选择或导航")
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = panel_point
	var previous_zoom: float = camera.zoom.x
	root.push_input(wheel, true)
	wheel.pressed = false
	root.push_input(wheel, true)
	check(camera.zoom.x == previous_zoom, "信息面板滚轮不穿透缩放")
	click(info.get_node("Panel/Margin/Content/Header/Close").get_global_rect().get_center())
	await process_frame
	check(game.inspected_object == null and not info.panel.visible and game.selected, "关闭只取消物体查看")
	check(debris.flight_position == before_position, "查看不改变垃圾物理位置")
	for zoom in [0.025, 4.0]:
		map._set_zoom(zoom)
		place_at_screen(game, asteroid, Vector2(520, 210))
		click(Vector2(529, 210))
		await process_frame
		check(game.inspected_object == asteroid, "近域缩放%.3f真实点击容差" % zoom)
	map.set_map_mode(true)
	for zoom in [0.025, 0.25, 4.0]:
		map._set_zoom(zoom)
		place_at_screen(game, asteroid, Vector2(520, 210))
		click(Vector2(529, 210))
		await process_frame
		check(game.inspected_object == asteroid, "星图缩放%.3f真实点击容差" % zoom)
		check(vessel.navigation_target == Vector2(123456, 654321), "星图查看不覆写导航%.3f" % zoom)
	map._set_zoom(1.0)
	place_at_screen(game, asteroid, Vector2(520, 210))
	asteroid.mass_kg = 96.125
	game.simulation_paused = true
	await process_frame
	check(info.mass.text == "质量：96.125 kg", "物体质量变化时所选信息实时刷新：%s 实际质量=%s" % [info.mass.text, asteroid.mass_kg])
	check(not game.has_method("_mining_step"), "物体查看不再包含采集入口")
	asteroid.destroyed = true
	await process_frame
	check(game.inspected_object == null and not info.panel.visible and info.ring_radius == 0.0, "原位销毁清除引用及高亮")
	click(Vector2(520, 210))
	check(game.inspected_object == null, "销毁目标不能再次选中")
	asteroid.destroyed = false
	game._sync_visuals()
	click(Vector2(520, 210))
	await process_frame
	asteroid.queue_free()
	for i in range(3): await process_frame
	check(game.inspected_object == null and not info.panel.visible, "释放所选节点安全清除引用")
	place_at_screen(game, debris, Vector2(650, 210))
	click(Vector2(650, 210))
	await process_frame
	check(game.inspected_object == debris, "星图垃圾仍能选择")
	vessel.shield_ready = true
	debris.hit_ship(vessel)
	await process_frame
	check(game.inspected_object == null and not info.panel.visible, "护盾销毁垃圾清除查看")
	game._reset()
	game.set_physics_process(false)
	place_at_screen(game, debris, Vector2(650, 210))
	click(Vector2(650, 210))
	await process_frame
	check(game.inspected_object == debris and not game.selected, "未选船时也能查看垃圾")
	game._reset()
	check(game.inspected_object == null and not info.panel.visible, "航行重置清除查看")
	place_at_screen(game, debris, Vector2(650, 210))
	click(Vector2(650, 210))
	click(game.ship_buttons[vessel].get_global_rect().get_center())
	await process_frame
	check(game.inspected_object == null and game.selected, "飞船GUI选择优先且清除物体查看")
	click(Vector2(650, 210))
	await process_frame
	game.get_node("PortController").enter_port(game.planets[0], vessel)
	check(game.inspected_object == null and not info.panel.visible, "进入港口立即清除查看")
	game.get_node("PortController").leave_port()
	check(not info.panel.visible, "离港不恢复过期选择")
	map.set_map_mode(true)
	map._set_zoom(1.0)
	place_at_screen(game, debris, Vector2(650, 210))
	click(Vector2(650, 210))
	click(Vector2(720, 210))
	check(game.inspected_object == null and vessel.has_navigation_target, "星图空白点击保留既有导航逻辑")
	var planet = game.planets[0]
	var world_position: Vector2 = game.get_node("World").to_global(game._to_screen(planet.flight_position))
	camera.global_position += world_position - game.get_canvas_transform().affine_inverse() * Vector2(520, 210)
	camera.force_update_scroll()
	place_at_screen(game, debris, Vector2(520, 210))
	click(Vector2(520, 210))
	check(game.inspected_object == null and vessel.navigation_planet == planet, "行星与物体重叠时保留行星导航优先级")
	map.set_map_mode(false)
	game.selecting_orbit = true
	place_at_screen(game, debris, Vector2(650, 210))
	click(Vector2(650, 210))
	check(game.inspected_object == null and game.selecting_orbit, "入轨选星不被物体拾取抢占")
	game.selecting_orbit = false
	game._reset()
	game.set_physics_process(false)
	place_at_screen(game, debris, Vector2(650, 210))
	click(Vector2(650, 210))
	await process_frame
	for width in [960, 1200, 1600]:
		root.size = Vector2i(width, 720)
		for i in range(3): await process_frame
		var rect: Rect2 = info.panel.get_global_rect()
		check(rect.position.x >= 0.0 and rect.end.x <= game.panel.get_global_rect().position.x, "窗口%d信息面板不遮挡右侧航行面板" % width)
		check(not rect.intersects(map.navigation_buttons.get_global_rect()), "窗口%d信息面板不遮挡星图面板" % width)
		check(rect.size.x <= 248.0 and not rect.intersects(game.get_node("HUD/Root/ThrustDial").get_global_rect()), "窗口%d信息面板窄于248且不遮挡推力仪表" % width)
	root.remove_child(game)
	await process_frame
	check(game.inspected_object == null, "整场景退出清理物体引用")
	print("SPACE_OBJECT_SELECTION_TEST: %s (%d assertions, %d failures)" % ["PASS" if failures == 0 else "FAIL", assertions, failures])
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
