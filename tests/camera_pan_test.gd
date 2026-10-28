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

func _run() -> void:
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	var camera = game.get_node("NavigationCamera")
	camera.set_process(false)
	await process_frame
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
	print("CAMERA_PAN_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
