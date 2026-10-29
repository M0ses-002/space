extends SceneTree
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)
func _run() -> void:
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	game._select_ship()
	var vessel = game.ship
	var asteroid = load("res://scenes/asteroid.tscn").instantiate()
	asteroid.initial_position = vessel.flight_position
	asteroid.initial_velocity = Vector2.ZERO
	asteroid.mass_kg = 100.0
	asteroid.radius_m = 100.0
	game.get_node("World").add_child(asteroid)
	await process_frame
	await process_frame
	check(vessel.has_node("MiningRange"), "采集范围为可编辑场景节点")
	var original_mass: float = vessel.cargo_mass
	vessel.mining_rate_kg_s = 4.0
	game._toggle_mining()
	game._mining_step(vessel, 1.0)
	check(is_equal_approx(vessel.cargo_mass, original_mass + 4.0), "采集质量应入当前船货舱")
	check(is_equal_approx(asteroid.mass_kg, 96.0), "岩体应按入舱质量减少")
	check(is_equal_approx(asteroid.radius_m, 100.0 * pow(0.96, 1.0 / 3.0)), "半径应按体积缩小")
	var other = load("res://scenes/ship.tscn").instantiate()
	game.get_node("World").add_child(other)
	await process_frame
	await process_frame
	check(is_zero_approx(other.cargo_mass), "其他船货舱独立")
	other.flight_position = asteroid.flight_position
	other.mining_enabled = true
	other.mining_rate_kg_s = 4.0
	game._mining_step(other, 1.0)
	check(is_equal_approx(other.cargo_mass, 4.0) and is_equal_approx(asteroid.mass_kg, 92.0), "两船竞争时分别入舱并按总采集量扣除")
	check(is_equal_approx(vessel.cargo_mass, original_mass + 4.0), "另一艘船采集不改变本船货舱")
	var small = load("res://scenes/asteroid.tscn").instantiate()
	small.initial_position = vessel.flight_position
	small.mass_kg = 0.5
	small.radius_m = 100.0
	game.get_node("World").add_child(small)
	await process_frame
	await process_frame
	game.obstacles.erase(small)
	game.obstacles.push_front(small)
	var previous_asteroid_mass: float = asteroid.mass_kg
	game._mining_step(vessel, 1.0)
	check(small.mass_kg == 0.5 and asteroid.mass_kg < previous_asteroid_mass, "不足整件残余保留且不阻塞后续矿体")
	other.flight_position = asteroid.flight_position
	other.mining_progress = 0.0
	game._mining_step(other, 100.0)
	check(is_equal_approx(other.cargo_mass, 80.0) and not other.mining_enabled, "近满舱只接收容量内整件并停止")
	check(other.mining_progress == 0.0, "满舱清空采集进度")
	var other_start: Vector2 = other.flight_position
	game._physics_process(0.025)
	check(other.current_voyage_distance_m > 0.0 and other.flight_position != other_start, "固定步累计每船实际航程")
	game.simulation_paused = true
	var before: float = asteroid.mass_kg
	game._physics_process(1.0)
	check(asteroid.mass_kg == before, "暂停时不采集")
	vessel.current_voyage_distance_m = 20.0
	vessel.last_voyage_distance_m = 30.0
	game._reset()
	check(asteroid.mass_kg == 100.0 and asteroid.radius_m == 100.0, "重置恢复岩体")
	check(vessel.current_voyage_distance_m == 0.0 and vessel.last_voyage_distance_m == 0.0 and not vessel.mining_enabled, "重置航程和采集状态")
	vessel.flight_position = Vector2(3000000, 0)
	vessel.flight_velocity = Vector2(100, 0)
	vessel.mining_enabled = false
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
