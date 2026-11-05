extends SceneTree
var checks := 0
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(label)
func confirm(dialogue: Node) -> void:
	var deadline := Time.get_ticks_msec() + 3000
	while dialogue.phase != dialogue.Phase.WAITING_CONFIRM and Time.get_ticks_msec() < deadline:
		await process_frame
	dialogue.confirm_button.pressed.emit()
	await process_frame
	await process_frame
func _run() -> void:
	if not OS.get_user_data_dir().contains("space-tutorial-test-pause-review"):
		quit(1)
		return
	root.get_node("BackgroundMusic").stop_music()
	var game: Node = load("res://scenes/game/star_map_demo.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	var city: Node = game.get_node("TutorialController")
	var orbit: Node = game.get_node("OrbitTutorialController")
	var progression: Node = game.get_node("ProgressionManager")
	var dialogue: Node = game.get_node("DialogueWindow")
	city.duration_scale = 0.01
	orbit.duration_scale = 0.01
	dialogue.slide_seconds = 0.0
	progression.start_new_game()
	await process_frame
	check(orbit.active and orbit.current_step_id() == "observe", "新游戏先进入行星教程")
	progression._on_skip_pressed()
	await process_frame
	check(city.active and not orbit.active and city.current_step_id() == "select_ship", "跳过行星进入城市选船")
	game._select_target(game.ships[0])
	await confirm(dialogue)
	check(city.current_step_id() == "accelerate" and not game.tutorial_pause, "加速步骤运行")
	game._start_thrust(1.0)
	game._physics_process(10.0)
	check(game.ship.flight_velocity.length() >= 20.0, "真实加速达到20")
	check(game.tutorial_pause and game.simulation_paused, "达标立即暂停模拟")
	check(city.current_step_id() == "accelerate", "未确认保留当前步骤")
	var velocity: Vector2 = game.ship.flight_velocity
	var position: Vector2 = game.ship.flight_position
	var fuel: float = game.ship.fuel
	var direction: Vector2 = game.ship.thrust_direction
	game._start_thrust(1.0)
	game._set_throttle(1.0)
	game._set_thrust_direction(Vector2.DOWN)
	game._set_thrust_lock(true)
	check(game.ship.manual_thrust == 0.0 and game.ship.thrust_throttle == 0.0 and not game.ship.steering, "暂停期间无隐藏推力")
	check(game.ship.thrust_direction == direction, "暂停期间方向不被预设")
	game._physics_process(10.0)
	check(game.ship.flight_position == position and game.ship.flight_velocity == velocity and game.ship.fuel == fuel, "重复物理帧位置速度燃料冻结")
	await confirm(dialogue)
	check(city.current_step_id() == "coast" and game.tutorial_pause, "进入暂停说明")
	await confirm(dialogue)
	check(city.current_step_id() == "brake" and not game.tutorial_pause and not game.simulation_paused, "确认后下一操作步恢复")
	game._start_thrust(-1.0)
	game._physics_process(10.0)
	check(game.ship.flight_velocity.length() <= game.DOCK_SPEED_TOLERANCE and game.tutorial_pause, "减速达标同样暂停")
	progression._on_skip_pressed()
	await process_frame
	check(not city.active and progression.stage == progression.Stage.WORLD, "跳过城市进入世界")
	check(not game.tutorial_pause, "退出教程解除教学锁")
	game.queue_free()
	await process_frame
	print("TUTORIAL_PAUSE_REVIEW: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
