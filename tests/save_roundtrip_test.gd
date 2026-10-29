extends SceneTree

const Manager = preload("res://scripts/save_manager.gd")
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
	var first = load("res://star_map_demo.tscn").instantiate()
	first.allow_builtin_map = false
	root.add_child(first)
	first.set_physics_process(false)
	await process_frame
	await process_frame
	var vessel = first.ships[0]
	first.simulation_paused = true
	first.simulation_speed = 2.0
	first.accumulator = 0.125
	vessel.flight_position = Vector2(12345, -45678)
	vessel.flight_velocity = Vector2(-33, 88)
	vessel.fuel = 432
	vessel.current_voyage_distance_m = 123456
	vessel.completed_voyage_count = 3
	vessel.arrival_source = first.planets[0]
	var session = first.get_node("PortController").session
	session._credits = 777
	session._fleet_cargo[vessel.get_instance_id()]["gray_ore"] = 7
	session._settled_voyages[vessel.get_instance_id()] = 2
	check(session.open_planet("res://data/planets/planet_a.json"), "港口数据加载")
	session._planet.trade.items[0].stock = 3
	session._planet.trade.fuel_supply.stock_kg = 200
	var obstacle = first.obstacles[0]
	obstacle.flight_position = Vector2(12, 34)
	obstacle.destroyed = true
	first.stopped_obstacles[obstacle] = true
	if obstacle.has_method("get_mineral_id"):
		obstacle.mass_kg = 12
		obstacle.radius_m = 5
	var expected: Dictionary = manager.make_snapshot(first)
	var file := FileAccess.open("user://save_roundtrip_test.tmp", FileAccess.WRITE)
	file.store_var(expected, false)
	file.close()
	file = FileAccess.open("user://save_roundtrip_test.tmp", FileAccess.READ)
	var saved: Dictionary = file.get_var(false)
	file.close()
	DirAccess.remove_absolute("user://save_roundtrip_test.tmp")
	first.queue_free()
	await process_frame
	var second = load("res://star_map_demo.tscn").instantiate()
	second.allow_builtin_map = false
	root.add_child(second)
	second.set_physics_process(false)
	await process_frame
	await process_frame
	check(manager.restore_snapshot(second, saved), "恢复存档")
	var restored: Dictionary = manager.make_snapshot(second)
	check(restored == saved, "场景销毁重建后所有快照字段一致")
	var legacy: Dictionary = saved.duplicate(true)
	legacy.docking = {"失效的旧飞船路径": "失效的旧城市路径"}
	check(manager.restore_snapshot(second, legacy), "忽略旧自动入泊状态及失效路径")
	check(not manager.make_snapshot(second).has("docking"), "新存档不保存自动入泊状态")
	var loaded = second.ships[0]
	var loaded_session = second.get_node("PortController").session
	check(loaded.flight_position == Vector2(12345, -45678) and loaded.flight_velocity == Vector2(-33, 88) and loaded.fuel == 432, "位置速度燃料恢复")
	check(loaded_session._credits == 777 and loaded_session._fleet_cargo[loaded.get_instance_id()]["gray_ore"] == 7 and loaded_session._settled_voyages[loaded.get_instance_id()] == 2, "资金货舱航次结算按新实例恢复")
	check(loaded_session.open_planet("res://data/planets/planet_a.json") and loaded_session._planet.trade.items[0].stock == 3 and loaded_session._fuel_supply.stock_kg == 200, "港口商品及燃料库存恢复")
	check(second.obstacles[0].destroyed and second.stopped_obstacles.has(second.obstacles[0]), "障碍物变化恢复")
	var invalid: Dictionary = saved.duplicate(true)
	invalid.version = 999
	check(not manager.restore_snapshot(second, invalid), "拒绝不兼容版本")
	var ship_path = saved.ships.keys()[0]
	invalid = saved.duplicate(true)
	invalid.cargo[ship_path]["invalid_item"] = 1
	check(not manager.restore_snapshot(second, invalid), "拒绝未知货物")
	invalid = saved.duplicate(true)
	invalid.planets["res://data/planets/planet_a.json"] = {}
	check(not manager.restore_snapshot(second, invalid), "拒绝损坏港口")
	invalid = saved.duplicate(true)
	invalid.ships[ship_path].fuel = INF
	check(not manager.restore_snapshot(second, invalid), "拒绝无效燃料")
	invalid = saved.duplicate(true)
	invalid.ships[ship_path].navigation_planet = ship_path
	check(not manager.restore_snapshot(second, invalid), "拒绝错误引用")
	second.queue_free()
	manager.queue_free()
	await process_frame
	print("SAVE_ROUNDTRIP_TEST: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)
