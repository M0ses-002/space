extends SceneTree

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func key_event(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func scroll(position: Vector2, button: MouseButton) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	root.push_input(motion, true)
	var event := InputEventMouseButton.new()
	event.position = position
	event.button_index = button
	event.pressed = true
	root.push_input(event, true)

func _run() -> void:
	var game = load("res://scenes/game/main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	var camera = game.get_node("NavigationCamera")
	camera.set_process(false)
	await process_frame
	# 场景里可能已勾选「视角始终跟随」；前半段验证自由视角语义，先显式关闭。
	game.ship.camera_always_follow = false
	var start: Vector2 = camera.position
	var ship_position: Vector2 = game.ship_position
	for key in [KEY_W, KEY_A, KEY_S, KEY_D]:
		var before: Vector2 = camera.position
		key_event(key, true)
		camera._process(0.1)
		var direction: Vector2 = {KEY_W: Vector2.UP, KEY_A: Vector2.LEFT, KEY_S: Vector2.DOWN, KEY_D: Vector2.RIGHT}[key]
		check(camera.position.distance_to(before + direction * camera.pan_speed * 0.1) < 0.01, "WASD direction")
		key_event(key, false)
		var stopped: Vector2 = camera.position
		camera._process(0.1)
		check(camera.position == stopped, "Key release stops motion")
	check(camera.position.distance_to(start) < 0.01, "Equal speed in four directions")
	key_event(KEY_W, true)
	key_event(KEY_D, true)
	camera._process(0.1)
	key_event(KEY_W, false)
	key_event(KEY_D, false)
	check(absf(camera.position.distance_to(start) - camera.pan_speed * 0.1) < 0.01, "Diagonal normalization")
	camera.zoom_level = 2.0
	camera.zoom = Vector2.ONE * 2.0
	var before_zoom: Vector2 = camera.position
	key_event(KEY_D, true)
	camera._process(0.1)
	key_event(KEY_D, false)
	check(absf(camera.position.distance_to(before_zoom) * 2.0 - camera.pan_speed * 0.1) < 0.01, "Screen speed stays constant when zoomed")
	check(game.ship_position == ship_position, "Camera does not affect simulation")
	camera.reset_view()
	check(camera.position.distance_to(camera.get_viewport_rect().size * 0.5) < 0.01, "Reset restores view")
	await process_frame
	var view = game.get_node("StarMapView")
	view._return_to_ship()
	var screen_anchor: Vector2 = game.ship.get_global_transform_with_canvas().origin
	var saved_velocity: Vector2 = game.ship.flight_velocity
	var saved_fuel: float = game.ship.fuel
	var cursor := Vector2(420, 240)
	check(camera.following, "回船开启跟随")
	var initial_zoom: float = camera.zoom_level
	scroll(cursor, MOUSE_BUTTON_WHEEL_UP)
	check(camera.following and camera.zoom_level > initial_zoom, "真实滚轮放大不解除跟随")
	check(game.ship.get_global_transform_with_canvas().origin.distance_to(screen_anchor) < 0.01, "跟随缩放立即保持船的屏幕锚点，不使用光标锚定")
	var followed_position: Vector2 = camera.position
	await process_frame
	check(camera.position.distance_to(followed_position) < 0.01, "后续跟随帧不与滚轮锚点冲突抖动")
	game.ship.flight_position += Vector2(3000, -2000)
	game._sync_visuals()
	view._process(0.0)
	check(game.ship.get_global_transform_with_canvas().origin.distance_to(screen_anchor) < 0.01, "缩放后船移动仍持续跟随")
	scroll(cursor, MOUSE_BUTTON_WHEEL_DOWN)
	check(camera.following and is_equal_approx(camera.zoom_level, initial_zoom), "滚轮缩小仍保持跟随")
	key_event(KEY_D, true)
	camera._process(0.1)
	key_event(KEY_D, false)
	check(not camera.following, "真实WASD平移解除跟随")
	var free_anchor: Vector2 = game.get_canvas_transform().affine_inverse() * cursor
	scroll(cursor, MOUSE_BUTTON_WHEEL_UP)
	check(not camera.following and (game.get_canvas_transform().affine_inverse() * cursor).distance_to(free_anchor) < 0.01, "自由视角滚轮仍保持光标下世界位置")
	check(game.ship.flight_velocity == saved_velocity and game.ship.fuel == saved_fuel, "缩放与跟随切换不改变速度或燃油")
	view.set_map_mode(true)
	view._return_to_ship()
	screen_anchor = game.ship.get_global_transform_with_canvas().origin
	scroll(cursor, MOUSE_BUTTON_WHEEL_UP)
	check(camera.following and game.ship.get_global_transform_with_canvas().origin.distance_to(screen_anchor) < 0.01, "星图滚轮同样保持跟随与船锚点")

	# --- 飞船开关 camera_always_follow：开启后视角始终跟随 ---
	game.ship.camera_always_follow = false
	view.set_map_mode(false)
	view._return_to_ship()
	view._process(0.0)
	key_event(KEY_D, true)
	camera._process(0.1)
	key_event(KEY_D, false)
	check(not camera.following, "开关关闭时 WASD 仍可解除跟随")
	view._return_to_ship()
	view._process(0.0)
	screen_anchor = game.ship.get_global_transform_with_canvas().origin
	game.ship.camera_always_follow = true
	key_event(KEY_D, true)
	camera._process(0.1)
	key_event(KEY_D, false)
	check(camera.following, "锁定跟随时 WASD 不解除跟随")
	view._process(0.0)
	check(game.ship.get_global_transform_with_canvas().origin.distance_to(screen_anchor) < 0.01, "锁定跟随时船仍在原屏幕锚点")
	game.ship.flight_position += Vector2(-4000, 2500)
	game._sync_visuals()
	view._process(0.0)
	check(game.ship.get_global_transform_with_canvas().origin.distance_to(screen_anchor) < 0.01, "飞船移动后视角自动跟上")
	view.set_map_mode(true)
	check(view.map_mode and camera.following, "锁定跟随时星图仍可正常进入并保持跟随")
	view._process(0.0)
	check(game.ship.get_global_transform_with_canvas().origin.distance_to(screen_anchor) < 0.01, "星图模式下视角仍以船为中心")
	game.ship.flight_position += Vector2(2000, -1500)
	game._sync_visuals()
	view._process(0.0)
	check(game.ship.get_global_transform_with_canvas().origin.distance_to(screen_anchor) < 0.01, "星图模式下飞船移动视角继续跟随")
	key_event(KEY_D, true)
	camera._process(0.1)
	key_event(KEY_D, false)
	check(camera.following, "星图模式下 WASD 不解除跟随")
	view.set_map_mode(false)
	view._process(0.0)
	check(not view.map_mode and camera.following, "退出星图恢复近域跟随")
	check(game.ship.get_global_transform_with_canvas().origin.distance_to(screen_anchor) < 0.01, "退出星图后船回到原屏幕锚点")
	camera.reset_view()
	view._process(0.0)
	var viewport: Vector2 = camera.get_viewport_rect().size
	var ship_anchor := Vector2(maxf(viewport.x - 320.0, 100.0) * 0.5, viewport.y * 0.5)
	check(camera.following and game.ship.get_global_transform_with_canvas().origin.distance_to(ship_anchor) < 0.01, "锁定跟随时重置视角仍以船为中心")
	game.ship.camera_always_follow = false
	key_event(KEY_D, true)
	camera._process(0.1)
	key_event(KEY_D, false)
	check(not camera.following, "关闭开关后 WASD 重新解除跟随")
	print("CAMERA_PAN_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
