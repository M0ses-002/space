extends SceneTree
## 行星入轨教程 + 教程编排器回归：行星教程 → 城市教程 → 世界地图。

var failures := 0
var checks := 0

class StageTutorial extends Node:
	signal tutorial_finished(skipped: bool)
	signal orbit_tutorial_finished(skipped: bool)
	var starts := 0
	func start_new_game() -> void:
		starts += 1
	func start() -> void:
		starts += 1

class StageGame extends Node:
	var load_succeeds := false
	var ships: Array = []
	func load_map_file(_path: String) -> bool:
		return load_succeeds
	func load_world_map() -> bool:
		return load_succeeds

class StageProgression extends "res://scripts/progression/progression_manager.gd":
	var saves := 0
	func _save_progress() -> void:
		saves += 1

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func step(game: Node, count: int = 1) -> void:
	for index in range(count):
		game.accumulator = 0.0
		game._physics_process(game.SIM_STEP / game.TIME_SCALE)

func wait_step(controller: Node, target: String) -> bool:
	var deadline := Time.get_ticks_msec() + 8000
	while (not controller.active or controller.current_step_id() != target) and Time.get_ticks_msec() < deadline:
		var dialogue: Node = controller.get_parent().get_node("DialogueWindow")
		if dialogue.phase == dialogue.Phase.WAITING_CONFIRM:
			dialogue.confirm_button.pressed.emit()
		await process_frame
	var reached: bool = controller.active and controller.current_step_id() == target
	check(reached, "等待真实教程步骤：" + target)
	if not reached:
		quit(1)
	return reached

func confirm_message(game: Node) -> void:
	var dialogue: Node = game.get_node("DialogueWindow")
	var deadline := Time.get_ticks_msec() + 2000
	while dialogue.phase != dialogue.Phase.WAITING_CONFIRM and Time.get_ticks_msec() < deadline:
		await process_frame
	check(dialogue.phase == dialogue.Phase.WAITING_CONFIRM, "当前消息等待手动确认")
	dialogue.confirm_button.pressed.emit()
	await process_frame
	await process_frame

func check_flight_restored(game: Node, label: String) -> void:
	var port: Node = game.get_node("PortController")
	check(not port.active and not port.visible and port.docked_ship == null and port.saved_nodes.is_empty(), label + "：港口状态与缓存已清空")
	check(game.get_node("World").visible and game.get_node("HUD").visible, label + "：世界与航行HUD可见")
	for path: String in ["HUD", "StarMapView", "StarMapView/HUD", "NavigationCamera"]:
		check(game.get_node(path).process_mode != Node.PROCESS_MODE_DISABLED and game.get_node(path).can_process(), label + "：恢复处理 " + path)
	check(game.selected and game.ship == game.ships[0] and game.ship.get_node("SelectionRing").visible, label + "：当前飞船已选中")

func check_failed_stages() -> void:
	var stub := StageGame.new()
	var city := StageTutorial.new()
	city.name = "TutorialController"
	stub.add_child(city)
	var orbit := StageTutorial.new()
	orbit.name = "OrbitTutorialController"
	stub.add_child(orbit)
	var progression := StageProgression.new()
	stub.add_child(progression)
	root.add_child(stub)
	progression.bind_game(stub)
	progression.start_new_game()
	check(progression.stage == progression.Stage.NONE and orbit.starts == 0 and progression.saves == 0, "行星加载失败不推进、不启动、不保存")
	progression.stage = progression.Stage.ORBIT
	progression._on_orbit_finished(false)
	check(progression.stage == progression.Stage.ORBIT and city.starts == 0 and progression.saves == 0, "城市加载失败不推进、不启动、不保存")
	progression.stage = progression.Stage.CITY
	progression._on_city_finished(false)
	check(progression.stage == progression.Stage.CITY and progression.saves == 0, "世界加载失败不推进、不保存")
	check(not progression.prepare_for_restore({"version": 1, "stage": progression.Stage.WORLD}) and progression.stage == progression.Stage.CITY, "读档切图失败保留原阶段并返回失败")
	stub.free()

func _run() -> void:
	check(OS.get_user_data_dir().contains("space-orbit-test"), "专项必须使用隔离用户目录")
	check(not FileAccess.file_exists("user://space_map_v1.json") and not FileAccess.file_exists("user://space_save_v1.dat"), "隔离目录不得预先存在地图或存档")
	if failures > 0:
		quit(1)
		return
	root.get_node("BackgroundMusic").stop_music()
	var game: Node = load("res://scenes/game/star_map_demo.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	current_scene = game
	game.set_physics_process(false)
	await process_frame
	await process_frame

	var orbit: Node = game.get_node("OrbitTutorialController")
	var tutorial: Node = game.get_node("TutorialController")
	var dialogue: Node = game.get_node("DialogueWindow")
	var camera: Node = game.get_node("NavigationCamera")
	orbit.duration_scale = 0.003
	tutorial.duration_scale = 0.003
	dialogue.slide_seconds = 0.0

	# —— 行星教程直接启动与起始状态 ——
	check(game.load_map_file("res://maps/plante_teach.json"), "加载行星教程地图")
	check(game.planets.size() == 1 and game.cities.is_empty() and game.obstacles.is_empty(), "行星教程地图仅含一个行星")
	orbit.start()
	check(orbit.active and orbit.current_step_id() == "observe", "行星教程启动进入观察步骤")
	var planet: Node2D = orbit.target_planet
	var ship: Node2D = orbit.tutorial_ship
	check(is_instance_valid(planet) and is_instance_valid(ship), "行星教程解析目标行星与飞船")
	var distance: float = ship.flight_position.distance_to(planet.flight_position)
	check(distance > planet.radius_m + planet.field_height_m and distance < planet.max_gravity_radius_m, "起始点在恒强层外且引力范围内")
	var accel: float = planet.acceleration_at(ship.flight_position).length()
	var circular_speed: float = sqrt(accel * distance)
	check(absf(ship.flight_velocity.length() - circular_speed * 0.9) < circular_speed * 0.01, "初始切向速度约为0.9倍圆轨道速度")
	check(camera.is_tutorial_locked() and camera.zoom.is_equal_approx(Vector2.ONE * orbit.tutorial_zoom), "行星教程锁定相机缩放")
	check(game.get_node("StarMapView").map_mode == false, "行星教程为近域视角")

	# —— observe → orbit_physics → thrust（关闭对话推进） ——
	var deadline := Time.get_ticks_msec() + 8000
	await confirm_message(game)
	check(orbit.current_step_id() == "orbit_physics", "观察说明确认后进入轨道物理科普")
	await confirm_message(game)
	check(orbit.current_step_id() == "thrust", "科普确认后进入切向加速步骤")
	await confirm_message(game)

	# —— thrust：加速到目标速度后推进 ——
	ship.flight_velocity = Vector2(0.0, -1.0) * (circular_speed * 0.96)
	ship.heading = ship.flight_velocity.normalized()
	ship.thrust_direction = ship.heading
	step(game)
	check(orbit.current_step_id() == "coast", "达到目标速度后推进到稳定绕行步骤")

	# —— coast：稳定绕行直到 stay_available ——
	await confirm_message(game)
	var coast_steps := 0
	while orbit.active and orbit.current_step_id() == "coast" and coast_steps < 4000:
		step(game)
		coast_steps += 1
	check(ship.stay_available, "稳定绕行后轨道验证通过")
	check(orbit.current_step_id() == "confirm", "稳定绕行后进入确认入轨步骤")

	# —— confirm：确认入轨完成 ——
	await confirm_message(game)
	game._confirm_arrival(planet)
	await process_frame
	await process_frame
	check(orbit.current_step_id() == "completed" or orbit.completed, "确认入轨后进入完成说明")
	if orbit.active:
		deadline = Time.get_ticks_msec() + 8000
		while orbit.active and Time.get_ticks_msec() < deadline:
			if dialogue.phase == dialogue.Phase.WAITING_CONFIRM:
				dialogue.confirm_button.pressed.emit()
			await process_frame
	check(orbit.completed and not orbit.active, "行星教程完成后停止")
	check(not camera.is_tutorial_locked(), "行星教程完成解除相机锁")

	# —— 编排器：真实行星入轨 → 城市入泊 → 世界，不以跳过代替完成 ——
	check_failed_stages()
	var progression: Node = game.get_node("ProgressionManager")
	progression.start_new_game()
	check(progression.stage == progression.Stage.ORBIT and orbit.active and orbit.current_step_id() == "observe", "新游戏先进入行星教程")
	check(game.planets.size() == 1 and game.cities.is_empty(), "行星教程地图仅含一个行星")
	var port: Node = game.get_node("PortController")
	check(not port.active and not port.visible and port.docked_ship == null, "从真实城市港口重开行星教程也清空港口")

	# 行星教程真实加速入轨：observe → orbit_physics → thrust → coast → confirm。
	await confirm_message(game)
	await confirm_message(game)
	await confirm_message(game)
	game._start_thrust(1.0)
	var thrust_steps := 0
	while orbit.current_step_id() == "thrust" and thrust_steps < 500:
		step(game)
		thrust_steps += 1
	check(orbit.current_step_id() == "coast", "行星教程真实切向加速达到目标")
	await confirm_message(game)
	coast_steps = 0
	while orbit.current_step_id() == "coast" and coast_steps < 4000:
		step(game)
		coast_steps += 1
	check(orbit.current_step_id() == "confirm" and game.ship.stay_available, "真实积分稳定绕行后可确认入轨")
	planet = orbit.target_planet
	await confirm_message(game)
	game._confirm_arrival(planet)
	check(port.active and port.docked_ship == game.ship and game.ship.arrival_source == planet, "真实 _confirm_arrival 打开行星港口")
	# 自动确认完成消息，推进到城市阶段。
	deadline = Time.get_ticks_msec() + 8000
	while progression.stage != progression.Stage.CITY and Time.get_ticks_msec() < deadline:
		if dialogue.phase == dialogue.Phase.WAITING_CONFIRM:
			dialogue.confirm_button.pressed.emit()
		await process_frame
	check(progression.stage == progression.Stage.CITY and orbit.completed and not orbit.skipped and not orbit.active and tutorial.active and tutorial.current_step_id() == "select_ship", "行星真实完成后进入城市教程")
	check(game.cities.size() == 1 and game.planets.is_empty(), "城市教程地图切换为城市")
	check(not port.active and not port.visible and port.docked_ship == null and port.saved_nodes.is_empty(), "行星入轨后切入城市教程：港口状态与缓存已清空")
	check(game.get_node("World").visible and game.get_node("HUD").visible, "行星入轨后切入城市教程：世界与航行HUD可见")
	for path: String in ["HUD", "StarMapView", "StarMapView/HUD", "NavigationCamera"]:
		check(game.get_node(path).process_mode != Node.PROCESS_MODE_DISABLED and game.get_node(path).can_process(), "行星入轨后切入城市教程：恢复处理 " + path)

	# 城市教程：选船 → 加速 → 减速 → 返港 → 泊船。
	game._select_target(game.ships[0])
	await confirm_message(game)
	await confirm_message(game)
	game._start_thrust(1.0)
	step(game, 16)
	check(tutorial.current_step_id() == "coast", "城市教程经真实正向推进达到20m/s")
	if not await wait_step(tutorial, "brake"):
		return
	await confirm_message(game)
	game._start_thrust(-1.0)
	step(game, 30)
	if not await wait_step(tutorial, "dock"):
		return
	var city: Node2D = tutorial.target_city
	var center: Vector2 = city.flight_position + city.port_offset_m.rotated(deg_to_rad(city.rotation_degrees_m))
	var travel_steps := 0
	while travel_steps < 10000 and game.ship.flight_position.distance_to(center) > city.docking_radius_m * 0.8 + game.ship.flight_velocity.length_squared() / 10.0 + 30.0:
		if game.ship.flight_velocity.length() < 100.0:
			game._set_thrust_direction((center - game.ship.flight_position).normalized())
			game._set_throttle(1.0)
		else:
			game._stop_thrust()
		step(game)
		travel_steps += 1
	game._start_thrust(-1.0)
	while game.ship.flight_velocity.length() > 0.1 and travel_steps < 10000:
		step(game)
		travel_steps += 1
	check(travel_steps < 10000 and game._can_dock_city(city), "真实模拟返回城市并停稳可泊船")
	game._dock_city(city)
	check(port.active and port.visible and port.docked_ship == game.ship, "真实 _dock_city 打开城市港口")
	check(not game.get_node("World").visible and not game.get_node("HUD").visible and camera.process_mode == Node.PROCESS_MODE_DISABLED, "真实入泊隐藏航行树并禁用相机")
	var old_hash: String = game.map_hash
	check(not game.load_map_file("res://maps/missing_port_transition_test.json"), "不存在的地图切换返回失败")
	check(port.active and port.docked_ship == game.ship and game.map_hash == old_hash and game.cities.has(city), "读图失败保留港口与原地图")

	# 仅在隔离目录生成无效地图，验证世界加载失败不会先关闭现有港口。
	var invalid_map := FileAccess.open("user://space_map_v1.json", FileAccess.WRITE)
	invalid_map.store_string("{}")
	invalid_map.close()
	check(not game.load_world_map() and port.active and port.docked_ship == game.ship, "世界地图校验失败保留现有港口")
	progression._enter_world()
	check(progression.stage == progression.Stage.CITY and port.active, "真实世界加载失败不推进阶段或退出港口")
	var failed_restore: Dictionary = root.get_node("SaveManager").make_snapshot(game)
	failed_restore.progression_state.stage = progression.Stage.WORLD
	check(not root.get_node("SaveManager").restore_snapshot(game, failed_restore) and progression.stage == progression.Stage.CITY and port.active, "读档地图加载失败中止恢复且保留港口和阶段")
	check(DirAccess.remove_absolute("user://space_map_v1.json") == OK, "移除本测试生成的隔离无效地图")

	# 泊船后进入港口界面介绍（事件/人物/船坞/起航），逐条确认后再显示完成说明。
	if not await wait_step(tutorial, "port_events"):
		return
	check(progression.stage == progression.Stage.CITY, "泊船后进入港口事件页介绍，不直接切世界")
	await confirm_message(game)
	check(tutorial.current_step_id() == "port_people", "事件页介绍确认后进入人物页介绍")
	await confirm_message(game)
	check(tutorial.current_step_id() == "port_shipyard", "人物页介绍确认后进入船坞页介绍")
	await confirm_message(game)
	check(tutorial.current_step_id() == "port_depart", "船坞页介绍确认后进入起航说明")
	await confirm_message(game)
	check(tutorial.current_step_id() == "completed" and not tutorial.skipped and progression.stage == progression.Stage.CITY, "起航说明确认后显示完成说明，不切世界")

	deadline = Time.get_ticks_msec() + 8000
	while progression.stage != progression.Stage.WORLD and Time.get_ticks_msec() < deadline:
		if dialogue.phase == dialogue.Phase.WAITING_CONFIRM:
			dialogue.confirm_button.pressed.emit()
		await process_frame
	check(progression.stage == progression.Stage.WORLD and tutorial.completed and not tutorial.skipped and not tutorial.active and not orbit.active, "城市真实完成后进入世界地图")
	check(game.planets.size() >= 1 and game.cities.size() >= 1, "世界地图包含行星与城市")
	check_flight_restored(game, "城市入泊后切入世界地图")
	check(not camera.is_tutorial_locked(), "进入世界地图解除教程相机锁")

	game.queue_free()
	await process_frame
	print("ORBIT_TUTORIAL_TEST: %s (%d checks, %d failures); isolated_user=%s" % ["PASS" if failures == 0 else "FAIL", checks, failures, OS.get_user_data_dir()])
	quit(0 if failures == 0 else 1)
