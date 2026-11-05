extends SceneTree
## 禁采集回归与保留的逐船固定步航程统计。
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)
func _run() -> void:
	var game = load("res://scenes/game/main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	game._select_ship()
	var vessel = game.ship
	check(not game.has_method("_toggle_mining") and not game.has_method("_mining_step"), "航行控制器彻底移除采集入口")
	check(not vessel.has_node("MiningRange"), "飞船场景删除采集范围")
	for property in vessel.get_property_list():
		check(not String(property.name).begins_with("mining_") and property.name != "cargo_mass", "飞船不含采集或货舱属性")
	check(not game.has_node("HUD/Root/BottomActions/MiningButton"), "快捷栏删除采集按钮")
	var asteroid = load("res://scenes/world/asteroid.tscn").instantiate()
	asteroid.initial_position = Vector2(3000500, 0)
	asteroid.initial_velocity = Vector2.ZERO
	asteroid.mass_kg = 100.0
	asteroid.radius_m = 100.0
	game.get_node("World").add_child(asteroid)
	var other = load("res://scenes/ships/ship.tscn").instantiate()
	other.initial_position = Vector2(3100000, 0)
	other.initial_velocity = Vector2(100, 0)
	game.get_node("World").add_child(other)
	await process_frame
	await process_frame
	vessel.flight_position = Vector2(3000000, 0)
	vessel.flight_velocity = Vector2(100, 0)
	var other_start: Vector2 = other.flight_position
	game._physics_process(0.025)
	check(other.current_voyage_distance_m > 0.0 and other.flight_position != other_start, "固定步累计每船实际航程")
	check(asteroid.mass_kg == 100.0 and asteroid.radius_m == 100.0, "正常模拟不会采集或缩小邻近小行星")
	game.simulation_paused = true
	var before: Vector2 = vessel.flight_position
	game._physics_process(1.0)
	check(asteroid.mass_kg == 100.0 and vessel.flight_position == before, "暂停时不采集也不推进")
	vessel.current_voyage_distance_m = 20.0
	vessel.last_voyage_distance_m = 30.0
	game._reset()
	check(asteroid.mass_kg == 100.0 and asteroid.radius_m == 100.0, "重置保留岩体原始状态")
	check(vessel.current_voyage_distance_m == 0.0 and vessel.last_voyage_distance_m == 0.0, "重置航程统计")
	vessel.flight_position = Vector2(3000000, 0)
	vessel.flight_velocity = Vector2(100, 0)
	game._set_simulation_speed(1.0)
	game._physics_process(0.05)
	var distance_one: float = vessel.current_voyage_distance_m
	vessel.current_voyage_distance_m = 0.0
	vessel.flight_position = Vector2(3000000, 0)
	vessel.flight_velocity = Vector2(100, 0)
	game.accumulator = 0.0
	game._set_simulation_speed(2.0)
	game._physics_process(0.05)
	check(is_equal_approx(vessel.current_voyage_distance_m, distance_one * 2.0), "航程随模拟倍率按固定步累计")
	print("MINING_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
