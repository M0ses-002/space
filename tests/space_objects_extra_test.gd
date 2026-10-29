extends SceneTree

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func step(game, count: int = 1) -> void:
	for i in range(count):
		game._physics_process(game.SIM_STEP / game.TIME_SCALE)

func _run() -> void:
	root.size = Vector2i(1200, 720)
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	var world = game.get_node("World")
	var existing_obstacles: Array = game.obstacles.duplicate()
	for object in existing_obstacles:
		object.flight_position = Vector2(1000000, 1000000)
		object.flight_velocity = Vector2.ZERO
	var debris = load("res://scenes/space_debris.tscn").instantiate()
	debris.initial_position = Vector2(0, -62000)
	debris.initial_velocity = Vector2(100, 0)
	debris.radius_m = 100.0
	world.add_child(debris)
	var asteroid = load("res://scenes/asteroid.tscn").instantiate()
	asteroid.initial_position = debris.initial_position
	asteroid.initial_velocity = debris.initial_velocity
	asteroid.radius_m = 200.0
	world.add_child(asteroid)
	await process_frame
	await process_frame
	check(game.obstacles.has(debris) and game.obstacles.has(asteroid), "动态添加障碍物应注册")
	var start: Vector2 = debris.flight_position
	var velocity: Vector2 = debris.flight_velocity
	var acceleration: Vector2 = game._gravity_at(start)
	asteroid.mass_kg = 1.0
	step(game)
	check(debris.flight_velocity.distance_to(velocity + acceleration * game.SIM_STEP) < 0.001, "垃圾受行星引力一步速度")
	check(debris.flight_position.distance_to(start + debris.flight_velocity * game.SIM_STEP) < 0.01, "垃圾受引力一步位置")
	check(asteroid.flight_velocity.distance_to(debris.flight_velocity) < 0.001, "小行星与垃圾受相同引力加速度")
	asteroid.mass_kg = 1.0e12
	asteroid.flight_position = start
	asteroid.flight_velocity = velocity
	debris.flight_position = start
	debris.flight_velocity = velocity
	var before_gravity: Vector2 = game._gravity_at(start)
	step(game)
	check(asteroid.flight_velocity.distance_to(debris.flight_velocity) < 0.001, "小行星质量变化不改变引力加速度")
	check(game._gravity_at(start).distance_to(before_gravity) < 0.0001, "小行星不产生引力")
	debris.flight_position = Vector2(0, -400000)
	debris.flight_velocity = Vector2(100, 40)
	step(game)
	check(debris.flight_position.distance_to(Vector2(25, -399990)) < 0.01 and debris.flight_velocity == Vector2(100, 40), "自由空间垃圾匀速一步")
	var paused_position: Vector2 = debris.flight_position
	game.simulation_paused = true
	step(game, 2)
	check(debris.flight_position == paused_position, "暂停冻结障碍物")
	game.simulation_paused = false
	game._set_simulation_speed(2.0)
	step(game)
	check(debris.flight_position.distance_to(paused_position + Vector2(50, 20)) < 0.01, "二倍速推进两个固定步")
	game._set_simulation_speed(1.0)
	debris.flight_position = Vector2(-1000, -400000)
	debris.flight_velocity = Vector2(8000, 0)
	game.ship.crashed = false
	game.ship.flight_position = Vector2(1000, -400000)
	game.ship.flight_velocity = Vector2(-8000, 0)
	var other = load("res://scenes/ship.tscn").instantiate()
	other.initial_position = Vector2(1000, -410000)
	world.add_child(other)
	await process_frame
	await process_frame
	other.flight_position = Vector2(1000, -410000)
	other.flight_velocity = Vector2(-4000, 0)
	step(game)
	check(game.ship.crashed and game.ship.flight_velocity == Vector2.ZERO, "垃圾和飞船高速相对穿越应命中")
	check(not other.crashed, "垃圾命中不影响远处其他船")
	game.ship.crashed = false
	game.ship.voyage_finished = true
	game.ship.flight_position = Vector2(0, -400000)
	debris.flight_position = Vector2(0, -400000)
	debris.flight_velocity = Vector2.ZERO
	step(game)
	check(not game.ship.crashed, "泊港飞船免于障碍物碰撞")
	game.ship.voyage_finished = false
	game.ship.flight_position = Vector2(-1000, -420000)
	game.ship.flight_velocity = Vector2(8000, 0)
	asteroid.flight_position = Vector2(0, -420000)
	asteroid.flight_velocity = Vector2.ZERO
	step(game)
	check(not game.ship.crashed and game.ship.flight_position.x > 0, "飞船可穿行小行星")
	game._reset()
	check(debris.flight_position == debris.initial_position and debris.flight_velocity == debris.initial_velocity, "重置恢复垃圾运动")
	check(asteroid.flight_position == asteroid.initial_position and asteroid.flight_velocity == asteroid.initial_velocity, "重置恢复小行星运动")
	var view = game.get_node("StarMapView")
	view.set_map_mode(false)
	game._sync_visuals()
	check(debris.get_node("Visual").visible and not debris.get_node("MapArea").visible, "垃圾普通视图显示素材")
	check(asteroid.get_node("Visual").visible and not asteroid.get_node("MapOutline").visible, "小行星普通视图显示素材")
	for index in range(3):
		asteroid.style_index = index
		for child_index in range(3):
			check(asteroid.get_node("Visual").get_child(child_index).visible == (index == child_index), "小行星样式只显示所选素材")
	view.set_map_mode(true)
	game._sync_visuals()
	check(debris.global_position.distance_to(world.to_global(game._to_screen(debris.flight_position))) < 0.01, "垃圾星图位置对应模拟坐标")
	check(asteroid.global_position.distance_to(world.to_global(game._to_screen(asteroid.flight_position))) < 0.01, "小行星星图位置对应模拟坐标")
	check(absf(asteroid.scale.x * 100.0 - asteroid.radius_m * game._view_scale()) < 0.001, "小行星星图缩放对应半径")
	var outline: Line2D = asteroid.get_node("MapOutline")
	var visual: Node2D = asteroid.get_node("Visual")
	var minimum_radius := INF
	for i in range(outline.points.size()):
		var a: Vector2 = outline.points[i]
		var b: Vector2 = outline.points[(i + 1) % outline.points.size()]
		minimum_radius = minf(minimum_radius, Geometry2D.get_closest_point_to_segment(Vector2.ZERO, a, b).length())
	check(visual.scale.x * 100.0 < minimum_radius and visual.scale.y * 100.0 < minimum_radius, "三种素材的100单位圆包络位于星图多边形内")
	check(not debris.get_node("Visual").visible and debris.get_node("MapArea").visible, "垃圾地图显示范围")
	check(not asteroid.get_node("Visual").visible and asteroid.get_node("MapOutline").visible, "小行星地图显示轮廓")
	var red: Color = debris.get_node("MapArea/Fill").color
	var yellow: Color = asteroid.get_node("MapOutline").default_color
	check(red.r > red.g and red.r > red.b, "垃圾地图范围为红色")
	check(yellow.r > yellow.b and yellow.g > yellow.b, "小行星地图轮廓为黄色")
	for point in debris.get_node("MapArea/Outline").points:
		check(absf(point.length() * debris.scale.x - debris.radius_m * game._view_scale()) < 0.001, "垃圾范围与半径一致")
	for point in asteroid.get_node("MapOutline").points:
		check(absf(point.length() * asteroid.scale.x - asteroid.radius_m * game._view_scale()) < 0.001, "小行星轮廓与半径一致")
	debris.queue_free()
	asteroid.queue_free()
	await process_frame
	await process_frame
	check(game.obstacles.size() == existing_obstacles.size(), "删除动态障碍物不影响主场景对象")
	for object in existing_obstacles:
		check(game.obstacles.has(object), "原有障碍物仍然注册")
	game.queue_free()
	await process_frame
	print("SPACE_OBJECTS_EXTRA_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
