extends SceneTree

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1200, 720)
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	check(game.planets.size() == 2, "两个场景行星应自动注册")
	var first = game.get_node("World/Planet")
	var second = game.get_node("World/Planet2")
	check(first.flight_position == Vector2.ZERO, "主行星模拟原点")
	check(second.flight_position.distance_to(Vector2(148750, -250)) < 0.1, "编辑器布景换算为米")
	var point := Vector2(0, -62000)
	var a: Vector2 = first.acceleration_at(point)
	var b: Vector2 = second.acceleration_at(point)
	check(game._gravity_at(point).distance_to(a + b) < 0.0001, "各引力源矢量叠加")
	check(absf(a.length() - 9.81 * pow(53000.0 / 62000.0, 2)) < 0.0001, "单星平方反比参考值")
	check(absf(first.acceleration_at(Vector2(0, -51000)).length() - 9.81) < 0.0001, "恒强层重力")
	check(game._gravity_at(point, (a.length() + b.length()) * 0.5).distance_to(a) < 0.0001, "只忽略较弱引力源")
	check(game._gravity_at(point, b.length()).distance_to(a + b) < 0.0001, "等于阈值仍参与")
	check(game._gravity_at(point, 100.0) == Vector2.ZERO, "全部低于阈值时无引力")
	second.flight_position = Vector2(148750, 0)
	var midpoint := Vector2(74375, 0)
	check(game._gravity_at(midpoint).length() < 0.0001, "等强反向引力抵消")
	check(game._gravity_at(midpoint, 1.0).length() < 0.0001, "阈值判断在叠加之前")
	# 两个源同方向，单源均低于阈值但合力高于阈值，仍应全部忽略。
	second.flight_position = first.flight_position
	check(game._gravity_at(point, a.length() * 1.5) == Vector2.ZERO, "不得用合力判断单源阈值")
	second.flight_position = Vector2(148750, -250)
	var fixed_position: Vector2 = second.flight_position
	root.size = Vector2i(1600, 900)
	await process_frame
	game._sync_visuals()
	check(second.flight_position == fixed_position, "窗口变化不改变行星物理坐标")
	# 两艘船使用不同阈值；不与行星碰撞的条件下核对真实物理步和预演采样。
	var other = load("res://scenes/ship.tscn").instantiate()
	other.initial_position = Vector2(0, -62000)
	other.gravity_threshold = 100.0
	game.get_node("World").add_child(other)
	await process_frame
	await process_frame
	game.ship.gravity_threshold = 2.0
	game.ship.flight_position = point
	game.ship.flight_velocity = Vector2(655, 0)
	game._refresh_preview()
	var preview: PackedVector2Array = game.preview_points.duplicate()
	var initial_velocity: Vector2 = other.flight_velocity
	for index in range(4):
		game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(game.ship.flight_position.distance_to(preview[1]) < 0.01, "多星带阈值实飞与一秒预览一致")
	check(other.flight_velocity == initial_velocity, "另一艘船独立高阈值匀速")
	check(second.flight_position == fixed_position, "行星间不互相吸引移动")
	# 即便引力全忽略，高速路径仍不能穿过第二行星。
	var start: Vector2 = second.flight_position + Vector2(-70000, 0)
	var hit: Array = game._integrate(start, Vector2(600000, 0), 0.25, 1000.0)
	check(hit[1] == Vector2.ZERO, "第二行星高速扫掠撞击停止")
	check(absf(hit[0].distance_to(second.flight_position) - second.radius_m) < 0.1, "撞击点在行星表面")
	game.ship.flight_position = start
	game.ship.flight_velocity = Vector2(600000, 0)
	game.ship.gravity_threshold = 1000.0
	game._refresh_preview()
	check(game.preview_points.size() == 2, "预演在第二行星表面终止")
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(game.ship.crashed, "实飞撞击第二行星")
	check(game.ship.flight_position.distance_to(hit[0]) < 0.1, "实飞与预演碰撞位置一致")
	# 动态增删与空引力场。
	var extra = load("res://scenes/planet.tscn").instantiate()
	extra.position = game._to_screen(Vector2(-160000, 0))
	game.get_node("World").add_child(extra)
	await process_frame
	await process_frame
	check(game.planets.size() == 3, "动态添加引力源")
	for source in game.planets.duplicate():
		source.queue_free()
	await process_frame
	await process_frame
	check(game.planets.is_empty(), "删除引力源清理注册")
	check(game._gravity_at(point) == Vector2.ZERO, "无行星不产生引力")
	var free_step: Array = game._integrate(Vector2.ZERO, Vector2(100, 0), 0.25)
	check(free_step[0] == Vector2(25, 0), "无引力匀速直线")
	print("MULTI_GRAVITY_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
