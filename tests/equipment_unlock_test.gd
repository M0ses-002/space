extends SceneTree
## 装备目录与解锁：data/equipment.json 是唯一数据源；机库必须由任务奖励解锁，
## 装上后才展开工程机 / 近卫机两格快捷栏，两种舰载机各自按配置作业。

var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _find_debris(game: Node) -> Node2D:
	for object in game.obstacles:
		if is_instance_valid(object) and object.is_in_group("space_debris") and not object.destroyed:
			return object
	return null

## 默认场景不一定带太空垃圾；测试自己放一团，位置远离行星避免立刻坠毁。
func _ensure_debris(game: Node) -> Node2D:
	var found := _find_debris(game)
	if found != null:
		return found
	var debris = load("res://scenes/world/space_debris.tscn").instantiate()
	debris.mass_kg = 1000.0
	debris.starting_mass_kg = 1000.0
	debris.remaining_mass_kg = 1000.0
	debris.radius_m = 500.0
	debris.debris_count = 8
	debris.flight_position = Vector2(400000, 0)
	debris.flight_velocity = Vector2.ZERO
	game.get_node("World").add_child(debris)
	game.obstacles.append(debris)
	return debris

func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1200, 720)
	var game = load("res://scenes/game/main.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame

	# 1. 目录本身：能读、能列出可解锁项、数值可被读取。
	check(EquipmentCatalog.error().is_empty(), "装备目录 data/equipment.json 读取通过")
	check(EquipmentCatalog.has("hangar"), "目录包含机库")
	check(EquipmentCatalog.requires_unlock("hangar"), "机库需要任务解锁")
	check(not EquipmentCatalog.requires_unlock("capture_net"), "捕捉网默认可用")
	var unlockable: Array = EquipmentCatalog.unlockable()
	var unlockable_ids: Array[String] = []
	for item: Dictionary in unlockable:
		unlockable_ids.append(str(item.id))
	check(unlockable_ids.has("hangar"), "任务编辑器能读到可解锁装备清单")
	check(is_equal_approx(EquipmentCatalog.number("capture_net", "launch_speed", 0.0), 60.0), "装备数值从 JSON 读取")
	check(EquipmentCatalog.drone_def("engineer").get("recycle_radius_m", 0.0) > 0.0, "工程机数值挂在机库条目下")

	# 2. 未解锁时船坞不出货。
	var game_ship = game.ships[0]
	var session = game.get_node("PortController").session
	session.set_credits(5000)
	check(session.open_planet("res://data/planets/flat_nuclear_city.json"), "城市数据加载")
	check(not session.is_unlocked("hangar"), "新会话里机库未解锁")
	check(not session.get_slot_upgrades(0).has("hangar"), "未解锁的机库不出现在船坞候选里")
	check(not session.install_upgrade(game_ship, 0, "hangar", true), "未解锁时装不上机库")

	# 3. 任务奖励解锁后可安装。
	game.quest_manager._settle_reward({"reward_credits": 0, "reward_unlock": "hangar"})
	check(session.is_unlocked("hangar"), "任务奖励解锁了机库")
	check(session.get_slot_upgrades(0).has("hangar"), "解锁后船坞出现机库")
	check(session.install_upgrade(game_ship, 0, "hangar", true), "解锁后可以安装机库")
	check(session.install_upgrade(game_ship, 1, "capture_net", true), "其它装备照常安装")

	# 4. 机库展开成两格快捷栏，工程机只在引力区可用。
	var loadout: Array = game_ship.skill_loadout()
	check(loadout == ["drone_engineer", "drone_guard", "capture_net"], "机库展开为工程机 + 近卫机两格")
	game._select_target(game_ship)
	game._update_ui()
	var panel = game.skill_panel
	check(panel.buttons[1].text == "释放工程机", "工程机占用第 2 格")
	check(panel.buttons[2].text == "释放近卫机", "近卫机占用第 3 格")
	check(panel.buttons[3].text == "捕捉网 1", "捕捉网顺延到第 4 格")

	var planet = game.planets[0]
	game_ship.flight_position = planet.flight_position + Vector2(0, -95000)
	game_ship.flight_velocity = Vector2(200, 0)
	game._update_ui()
	check(not panel.buttons[1].disabled, "引力区内工程机按钮可用")
	game_ship.flight_position = planet.flight_position + Vector2(planet.max_gravity_radius_m * 2.0, 0)
	game._update_ui()
	check(panel.buttons[1].disabled, "引力区外工程机按钮禁用")
	check(panel.buttons[1].text.contains("需引力区"), "禁用时按钮上直接写清原因，避免看起来像没解锁")
	check(not panel.buttons[2].disabled, "近卫机不要求引力区，随时可放")

	# 5. 工程机：释放即入圆轨道，并在作业半径内回收碎片。
	game_ship.flight_position = planet.flight_position + Vector2(0, -95000)
	game_ship.flight_velocity = Vector2(200, 0)
	game_ship.heading = Vector2.RIGHT
	game._update_ui()
	game._toggle_drone("engineer")
	check(game.drones.size() == 1, "释放了一架工程机")
	var engineer = game.drones[0]
	var expected_speed: float = game._circular_velocity_at(game_ship.flight_position).length()
	check(absf(engineer.flight_velocity.length() - expected_speed) < 0.5, "工程机释放速度等于该半径的圆轨道速度")
	var radial: Vector2 = (engineer.flight_position - planet.flight_position).normalized()
	check(absf(engineer.flight_velocity.normalized().dot(radial)) < 0.05, "工程机圆轨道速度沿切向")

	var debris = _ensure_debris(game)
	check(debris != null, "场景里有可回收的太空碎片")
	if debris != null:
		engineer.flight_position = debris.flight_position
		engineer.flight_velocity = Vector2.ZERO
		engineer.definition["recycle_radius_m"] = 5000.0
		var before: float = debris.remaining_mass_kg
		var recovered_before: float = game.recovered_mass_kg
		for step in range(24):
			game._update_drones(0.25)
		check(debris.remaining_mass_kg < before, "工程机擦掉了作业半径内的碎片质量")
		check(game.recovered_mass_kg > recovered_before, "工程机回收的质量计入已回收物资")
	game._toggle_drone("engineer")
	check(game.drones.is_empty(), "再次点击回收工程机")

	# 6. 近卫机：清除飞船前方扇形内的碎片。
	game._toggle_drone("guard")
	check(game.drones.size() == 1, "释放了一架近卫机")
	var guard = game.drones[0]
	if debris != null and not debris.destroyed:
		debris.flight_position = game_ship.flight_position + Vector2(1000, 0)
		debris.flight_velocity = Vector2.ZERO
		var guard_before: float = debris.remaining_mass_kg
		var guard_checks := 0
		for step in range(24):
			if debris.destroyed:
				break
			game._update_drones(0.25)
			guard_checks += 1
		check(guard_checks > 0 and (debris.destroyed or debris.remaining_mass_kg < guard_before), "近卫机削减前方扇形内的碎片")
		check(guard.flight_position.distance_to(game_ship.flight_position) > 0.0, "近卫机跟随母船并在前方占位")
	game._toggle_drone("guard")
	check(game.drones.is_empty(), "再次点击回收近卫机")

	# 7. 解锁状态进存档且读档不丢。
	var manager = load("res://scripts/persistence/save_manager.gd").new()
	var snapshot: Dictionary = manager.make_snapshot(game)
	check(snapshot.get("unlocked_equipment", []).has("hangar"), "存档记录已解锁的机库")
	check(manager._compatible(game, snapshot), "含解锁字段的存档通过兼容校验")
	session.restore_unlocked([])
	check(not session.is_unlocked("hangar"), "清空解锁后机库重新变为未解锁")
	session.restore_unlocked(snapshot.unlocked_equipment)
	check(session.is_unlocked("hangar"), "读档恢复解锁状态")

	game._reset()
	check(game.drones.is_empty(), "重置航行清空在轨舰载机")

	if failures == 0:
		print("EQUIPMENT_UNLOCK_TEST: PASS (%d checks)" % checks)
	else:
		print("EQUIPMENT_UNLOCK_TEST: FAIL (%d/%d)" % [failures, checks])
	quit(0)
