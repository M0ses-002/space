extends SceneTree
## 运行真实渲染验证导航面板边界、点击坐标和自动视角切换，并保存试玩截图。
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
	var game = load("res://star_map_demo.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	var view = game.get_node("StarMapView")
	var camera = game.get_node("NavigationCamera")
	for window_size in [Vector2i(1200, 720), Vector2i(1600, 900), Vector2i(960, 640)]:
		root.size = window_size
		await process_frame
		await process_frame
		game._sync_visuals()
		var panel_rect: Rect2 = view.map_panel.get_global_rect()
		check(panel_rect.position.x >= 0 and panel_rect.position.y >= 32 and panel_rect.end.x <= window_size.x - 320 and panel_rect.end.y <= window_size.y, "星图面板不能越界或遮挡右栏")
	root.size = Vector2i(1200, 720)
	await process_frame
	await process_frame
	view.set_map_mode(false)
	view.set_map_mode(true)
	# 点击世界位置，以事件position而非全局鼠标位置换算。
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(400, 220)
	var expected: Vector2 = (game.get_canvas_transform().affine_inverse() * click.position - game._screen_center()) / game._view_scale()
	game._unhandled_input(click)
	check(game.ship.navigation_target.distance_to(expected) < 1.0, "缩放后的点击坐标正确")
	# UI命中不应透传，滚轮不影响UI上相机。
	var previous_zoom: float = camera.zoom.x
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = view.map_panel.get_global_rect().get_center()
	camera._input(wheel)
	check(camera.zoom.x == previous_zoom, "星图面板上滚轮不缩放世界")
	# 自动切换防抖通过模拟计时值验证，不等待真实航程。
	game.ship.flight_position = Vector2(0, -240000)
	game._update_region(game.ship, Vector2(0, -260000))
	view._observe_region()
	view.pending_since_msec = Time.get_ticks_msec() - 600
	view._observe_region()
	check(not view.map_mode, "进入引力区稳定后自动近域")
	game.ship.flight_position = Vector2(0, -260000)
	game._update_region(game.ship, Vector2(0, -240000))
	view._observe_region()
	view.pending_since_msec = Time.get_ticks_msec() - 600
	view._observe_region()
	check(view.map_mode, "离开引力区稳定后自动星图")
	# 恢复初始演示画面输出截图。
	game._reset()
	await process_frame
	await process_frame
	game._sync_visuals()
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var arguments := OS.get_cmdline_user_args()
	var screenshot_path: String = arguments[0] if not arguments.is_empty() else "user://space-star-map.png"
	var error := image.save_png(screenshot_path)
	check(error == OK, "保存真实星图截图")
	print("STAR_MAP_VISUAL_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
