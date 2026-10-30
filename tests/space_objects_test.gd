extends SceneTree

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _run() -> void:
	root.size = Vector2i(1200, 720)
	var game = load("res://main.tscn").instantiate()
	var debris = load("res://scenes/space_debris.tscn").instantiate()
	debris.initial_position = Vector2(400000, 0)
	debris.initial_velocity = Vector2(100, 0)
	debris.radius_m = 10.0
	game.get_node("World").add_child(debris)
	var asteroid = load("res://scenes/asteroid.tscn").instantiate()
	asteroid.initial_position = Vector2(410000, 0)
	asteroid.initial_velocity = Vector2(200, 0)
	game.get_node("World").add_child(asteroid)
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	check(game.obstacles.has(debris) and game.obstacles.has(asteroid), "启动时注册障碍物")
	var vessel = game.ship
	var planet = game.planets[0]
	vessel.flight_position = Vector2(500000, 0)
	vessel.flight_velocity = Vector2.ZERO
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(debris.flight_position.distance_to(Vector2(400025, 0)) < 0.01, "引力范围外垃圾匀速移动")
	check(asteroid.flight_position.distance_to(Vector2(410050, 0)) < 0.01, "引力范围外小行星匀速移动")
	game.simulation_paused = true
	var before: Vector2 = debris.flight_position
	game._physics_process(1.0)
	check(debris.flight_position == before, "暂停冻结障碍物")
	game.simulation_paused = false
	game.simulation_speed = 2.0
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(debris.flight_position.distance_to(before + Vector2(50, 0)) < 0.01, "倍速使用相同固定步")
	game.simulation_speed = 1.0
	debris.flight_position = Vector2(400000, 0)
	debris.flight_velocity = Vector2(800, 0)
	vessel.flight_position = Vector2(400100, 0)
	vessel.flight_velocity = Vector2.ZERO
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(vessel.crashed, "高速垃圾扫掠静止飞船")
	check(absf(vessel.flight_position.x - 400100.0) < 0.01, "碰撞位置为首次接触处")
	vessel.reset_flight()
	vessel.flight_position = Vector2(400000, 1000)
	vessel.flight_velocity = Vector2(800, 0)
	debris.flight_position = Vector2(400200, 1000)
	debris.flight_velocity = Vector2(-800, 0)
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(vessel.crashed and vessel.flight_position.x < 400100.0, "相向运动扫掠取首次接触")
	vessel.reset_flight()
	vessel.flight_position = Vector2(400000, 2000)
	vessel.flight_velocity = Vector2.ZERO
	vessel.voyage_finished = true
	debris.flight_position = vessel.flight_position
	debris.flight_velocity = Vector2.ZERO
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(not vessel.crashed, "停泊船不受碰撞")
	vessel.reset_flight()
	vessel.flight_position = Vector2(410000, 0)
	vessel.flight_velocity = Vector2.ZERO
	asteroid.flight_position = vessel.flight_position
	asteroid.flight_velocity = Vector2.ZERO
	debris.flight_position = Vector2(450000, 0)
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(not vessel.crashed, "小行星不伤船")
	var gravity: Vector2 = game._gravity_at(Vector2(0, -62000))
	asteroid.flight_position = Vector2(0, -62000)
	check(game._gravity_at(Vector2(0, -62000)) == gravity, "小行星不产生引力")
	debris.flight_position = Vector2(0, -62000)
	debris.flight_velocity = Vector2.ZERO
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(debris.flight_velocity.y > 0.0, "垃圾受行星引力")
	planet.surface_gravity = 0.0
	debris.flight_position = Vector2(-70000, 0)
	debris.flight_velocity = Vector2(600000, 0)
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(absf(debris.flight_position.distance_to(planet.flight_position) - planet.radius_m) < 0.1 and debris.flight_velocity == Vector2.ZERO, "高速垃圾撞行星表面停止")
	check(game.stopped_obstacles.has(debris), "撞星记录冻结状态")
	var impact_position: Vector2 = debris.flight_position
	debris.flight_velocity = Vector2(0, 1000)
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(debris.flight_position == impact_position, "冻结物体不沿表面运动")
	var saved: Vector2 = asteroid.flight_position
	game.get_node("StarMapView").set_map_mode(true)
	check(asteroid.flight_position == saved, "切换视角不改变物理状态")
	game._reset()
	check(debris.flight_position == debris.initial_position and asteroid.flight_velocity == asteroid.initial_velocity, "重置恢复障碍物初始状态")
	var extra = load("res://scenes/space_debris.tscn").instantiate()
	extra.initial_position = Vector2(500000, 1000)
	game.get_node("World").add_child(extra)
	await process_frame
	await process_frame
	check(game.obstacles.has(extra), "运行时注册障碍物")
	extra.queue_free()
	await process_frame
	await process_frame
	check(game.obstacles.size() == 2, "运行时删除清理障碍物")
	print("SPACE_OBJECTS_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
