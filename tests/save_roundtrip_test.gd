extends SceneTree

const Manager = preload("res://scripts/persistence/save_manager.gd")
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _run() -> void:
	var manager = Manager.new()
	root.add_child(manager)
	var first = load("res://scenes/game/star_map_demo.tscn").instantiate()
	first.allow_builtin_map = false
	root.add_child(first)
	# 开局 CG 会在第 2 帧暂停模拟并把 previous_pause 记成 true，干扰快照一致性比较。
	first.get_node("CgController").set_process(false)
	first.set_physics_process(false)
	await process_frame
	await process_frame
	var vessel = first.ships[0]
	first.simulation_paused = true
	first.simulation_speed = 2.0
	first.accumulator = 0.125
	vessel.flight_position = Vector2(12345, -45678)
	vessel.flight_velocity = Vector2(-33, 88)
	vessel.thrust_lock_enabled = true
	vessel.thrust_lock_angle = -PI / 3.0
	vessel.fuel = 432
	vessel.current_voyage_distance_m = 123456
	vessel.completed_voyage_count = 3
	vessel.arrival_source = first.planets[0]
	var session = first.get_node("PortController").session
	session._credits = 777
	check(session.unlock_equipment("hangar"), "解锁机库以便验证解锁状态的存档往返")
	check(session.open_planet("res://data/planets/planet_a.json"), "港口数据加载")
	vessel.upgrade_slots = ["fuel", "computer", "thruster", "shield"]
	vessel.shield_ready = true
	var obstacle = first.obstacles[0]
	obstacle.flight_position = Vector2(12, 34)
	obstacle.destroyed = true
	first.stopped_obstacles[obstacle] = true
	var expected: Dictionary = manager.make_snapshot(first)
	check(expected.get("unlocked_equipment", []).has("hangar"), "快照记录已解锁装备")
	check(expected.version == 6, "新存档版本为v6")
	check(expected.has("story_state"), "v6 记录剧情状态")
	for removed in ["cargo", "settled_voyages", "planets"]:
		check(not expected.has(removed), "v5不保存旧经济字段：" + removed)
	for ship_state in expected.ships.values():
		check(not ship_state.has("mining_enabled") and not ship_state.has("mining_progress") and not ship_state.has("cargo_mass"), "v5不保存采集货舱状态")
	for object_state in expected.obstacles.values():
		check(not object_state.has("mass_kg") and not object_state.has("radius_m"), "v5不保存旧采集消耗")
	var file := FileAccess.open("user://save_roundtrip_test.tmp", FileAccess.WRITE)
	file.store_var(expected, false)
	file.close()
	file = FileAccess.open("user://save_roundtrip_test.tmp", FileAccess.READ)
	var saved: Dictionary = file.get_var(false)
	file.close()
	DirAccess.remove_absolute("user://save_roundtrip_test.tmp")
	first.queue_free()
	await process_frame
	var second = load("res://scenes/game/star_map_demo.tscn").instantiate()
	second.allow_builtin_map = false
	root.add_child(second)
	second.get_node("CgController").set_process(false)
	second.set_physics_process(false)
	await process_frame
	await process_frame
	check(manager.restore_snapshot(second, saved), "恢复存档")
	var restored: Dictionary = manager.make_snapshot(second)
	check(restored == saved, "场景销毁重建后所有快照字段一致")
	var legacy: Dictionary = saved.duplicate(true)
	legacy.version = 1
	legacy.docking = {"失效的旧飞船路径": "失效的旧城市路径"}
	legacy.cargo = {"失效的旧飞船路径": {"不存在的货物": -999}}
	legacy.settled_voyages = "已删除的结算状态"
	legacy.planets = {"无效旧港口": {"trade": "无效旧库存"}}
	for ship_state in legacy.ships.values():
		ship_state.mining_enabled = "无效旧状态"
		ship_state.mining_progress = INF
		ship_state.cargo_mass = -999
	for object_state in legacy.obstacles.values():
		object_state.mass_kg = -999
		object_state.radius_m = INF
	check(manager.restore_snapshot(second, legacy), "v1兼容读取并完全忽略旧经济采集消耗及自动入泊字段")
	check(manager.make_snapshot(second) == saved, "迁移后重新保存为无旧经济字段的相同v5快照")
	check(not manager.make_snapshot(second).has("docking"), "新存档不保存自动入泊状态")
	var loaded = second.ships[0]
	var loaded_session = second.get_node("PortController").session
	check(loaded.flight_position == Vector2(12345, -45678) and loaded.flight_velocity == Vector2(-33, 88) and loaded.fuel == 432, "位置速度燃料恢复")
	check(loaded.thrust_lock_enabled and is_equal_approx(loaded.thrust_lock_angle, -PI / 3.0), "文件序列化后恢复夹角锁定")
	check(loaded_session.get_credits() == 777 and loaded.completed_voyage_count == 3, "共享资金与航次统计恢复")
	check(loaded_session.is_unlocked("hangar"), "解锁的机库随存档恢复")
	check(loaded.upgrade_slots == ["fuel", "computer", "thruster", "shield"] and loaded.shield_ready, "改造槽位与护盾恢复")
	check(loaded_session.open_planet("res://data/planets/planet_a.json") and not loaded_session.get_state().has("trade_rows"), "港口按新关卡配置加载")
	check(second.obstacles[0].destroyed and second.stopped_obstacles.has(second.obstacles[0]), "障碍物变化恢复")
	var invalid: Dictionary = saved.duplicate(true)
	invalid.version = 999
	check(not manager.restore_snapshot(second, invalid), "拒绝不兼容版本")
	var ship_path = saved.ships.keys()[0]
	invalid = saved.duplicate(true)
	invalid.credits = -1
	check(not manager.restore_snapshot(second, invalid) and loaded_session.get_credits() == 777, "拒绝负信用点且不修改现有余额")
	invalid = saved.duplicate(true)
	invalid.ships[ship_path].upgrade_slots = ["fuel", "fuel", "", ""]
	check(not manager.restore_snapshot(second, invalid), "拒绝重复改造")
	invalid = saved.duplicate(true)
	invalid.ships[ship_path].fuel = INF
	check(not manager.restore_snapshot(second, invalid), "拒绝无效燃料")
	invalid = saved.duplicate(true)
	invalid.ships[ship_path].navigation_planet = ship_path
	check(not manager.restore_snapshot(second, invalid), "拒绝错误引用")
	# 已下线的回收钩：老存档里仍占着槽位时，读档放行并把该槽清空，不判成损坏存档。
	invalid = saved.duplicate(true)
	invalid.ships[ship_path].upgrade_slots = ["recycle_hook", "fuel", "recycle_hook", "shield"]
	check(manager.restore_snapshot(second, invalid), "含已下线回收钩的老存档可以读取")
	check(loaded.upgrade_slots == ["", "fuel", "", "shield"], "读档时清空已下线的回收钩槽位：%s" % [loaded.upgrade_slots])
	second.queue_free()
	manager.queue_free()
	await process_frame
	print("SAVE_ROUNDTRIP_TEST: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)
