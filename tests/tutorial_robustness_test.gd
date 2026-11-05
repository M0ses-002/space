extends SceneTree
## 教程健壮性回归：启动失败可推进、重置只重做当前课、泊船门控与教程暂停起航提示。
## 与 tutorial_test.gd 相同：使用隔离 APPDATA，直接实例化真实演示场景驱动真实状态机。

var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func _run() -> void:
	check(OS.get_user_data_dir().contains("space-tutorial-robust"), "专项必须使用隔离用户目录")
	if failures > 0:
		quit(1)
		return
	root.get_node("BackgroundMusic").stop_music()
	var game: Node = load("res://scenes/game/star_map_demo.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.set_physics_process(false)
	await process_frame
	await process_frame
	var progression: Node = game.get_node("ProgressionManager")
	var tutorial: Node = game.get_node("TutorialController")
	var orbit: Node = game.get_node("OrbitTutorialController")
	var dialogue: Node = game.get_node("DialogueWindow")
	tutorial.duration_scale = 0.003
	dialogue.slide_seconds = 0.0

	# 1) 启动失败：不进入 active 也要发一次结束信号，并在航行消息里说明原因。
	var finishes: Array = []
	tutorial.tutorial_finished.connect(func(skipped: bool): finishes.append(skipped))
	tutorial.get("_steps").clear()
	tutorial.start_new_game()
	await process_frame
	await process_frame
	check(finishes == [true], "启动失败延迟发出一次结束信号")
	check(tutorial.skipped and not tutorial.active, "启动失败不进入活动状态")
	check(not game.flight_message.is_empty() and game.flight_message.contains("配置无法读取"), "启动失败以航行消息告知玩家")
	tutorial._load_config()
	check(tutorial.get("_steps").size() == 19, "恢复真实教程配置（含港口界面介绍）")

	# 2) 重置只重做当前课：阶段与地图不变，回到第 0 步，不连锁启动城市教程。
	progression.start_new_game()
	await process_frame
	var hash_before: String = game.map_hash
	check(progression.stage == progression.Stage.ORBIT and orbit.active and orbit.current_step_id() == "observe", "新游戏进入行星阶段并观察")
	game._reset()
	await process_frame
	check(progression.stage == progression.Stage.ORBIT, "重置航行不推进教程阶段")
	check(game.map_hash == hash_before, "重置航行不切换地图")
	check(orbit.active and orbit.step_index == 0 and orbit.current_step_id() == "observe", "重置后仍在当前课第 0 步")
	check(not tutorial.active, "重置不连锁启动城市教程")

	# 3) 泊船门控：减速步骤不提供泊船，入港步骤恢复（城市课独立启动）。
	orbit.cancel_for_reset()
	game.load_map_file("res://maps/city_teach.json")
	tutorial.start_new_game()
	await process_frame
	check(tutorial.active and tutorial.current_step_id() == "select_ship", "城市教程独立启动并等待选船")
	game._select_target(game.ships[0])
	var city: Node2D = tutorial.target_city
	var brake_index := -1
	var dock_index := -1
	for index in range(tutorial.get("_steps").size()):
		if tutorial.get("_steps")[index].id == "brake":
			brake_index = index
		elif tutorial.get("_steps")[index].id == "dock":
			dock_index = index
	check(brake_index >= 0 and dock_index >= 0, "教程配置包含 brake 与 dock 步骤")
	tutorial.step_index = brake_index
	tutorial._enter_step()
	game.ship.flight_position = city.get_dock_position()
	game.ship.flight_velocity = Vector2.ZERO
	game._update_ui()
	check(not game._can_dock_city(city), "减速步骤中即使停在港口也不提供泊船资格")
	check(not city.get_node("DockButton").visible, "减速步骤中泊船按钮隐藏")
	tutorial.step_index = dock_index
	tutorial._enter_step()
	game._update_ui()
	check(game._can_dock_city(city), "入港步骤恢复泊船资格")
	check(city.get_node("DockButton").visible, "入港步骤显示泊船按钮")

	# 4) 教程暂停时从港口起航：给出提示且不离开港口。
	game.set_tutorial_pause(true)
	game._dock_city(city)
	check(game.get_node("PortController").active and game.ship.voyage_finished, "入港步骤可正常泊船")
	game.flight_message = ""
	game._depart()
	check(not game.flight_message.is_empty() and game.flight_message.contains("教程进行中"), "教程暂停时起航给出可执行提示")
	check(game.get_node("PortController").active and game.ship.voyage_finished, "教程暂停时起航不离开港口")

	game.queue_free()
	await process_frame
	print("TUTORIAL_ROBUSTNESS_TEST: %s (%d checks, %d failures); isolated_user=%s" % ["PASS" if failures == 0 else "FAIL", checks, failures, OS.get_user_data_dir()])
	quit(0 if failures == 0 else 1)
