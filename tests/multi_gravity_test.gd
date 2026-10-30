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
	# 测试自己创建双星布景，不要求用户主场景始终保留第二行星。
	if not game.has_node("World/Planet2"):
		var fixture = load("res://scenes/planet.tscn").instantiate()
		fixture.name = "Planet2"
		fixture.position = Vector2(1035, 359)
		game.get_node("World").add_child(fixture)
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	check(game.planets.size() == 2, "两个场景行星应自动注册")
	var first = game.get_node("World/Planet")
	var second = game.get_node("World/Planet2")
	check(first.flight_position == Vector2.ZERO, "主行星模拟原点")
	check(second.flight_position.distance_to(Vector2(148750, -250)) < 0.1, "编辑器布景换算为米")
	check(first.max_gravity_radius_m == 250000.0 and second.max_gravity_radius_m == 250000.0, "默认引力中心距范围为250000米")
	# 恒强层标注按表面外厚度绘制，与最大引力半径独立。
	first.update_boundary()
	check(first.get_node("FieldBoundary").visible and absf(first.get_node("FieldBoundary").scale.x - 1.06) < 0.0001, "恒强层顶圈为中心距53km")
	first.field_height_m = 100000.0
	first.update_boundary()
	check(absf(first.get_node("FieldBoundary").scale.x - 3.0) < 0.0001, "100km恒强层厚度对应150km中心距")
	check(first.max_gravity_radius_m == 250000.0, "恒强层显示不改变最大引力范围")
	first.field_height_m = 3000.0
	first.update_boundary()
	var point := Vector2(0, -62000)
	var a: Vector2 = first.acceleration_at(point)
	var b: Vector2 = second.acceleration_at(point)
	check(game._gravity_at(point).distance_to(a + b) < 0.0001, "重叠范围内各引力源矢量叠加")
	check(absf(a.length() - 9.81 * pow(53000.0 / 62000.0, 2)) < 0.0001, "单星平方反比参考值")
	check(absf(first.acceleration_at(Vector2(0, -51000)).length() - 9.81) < 0.0001, "恒强层重力")
	first.max_gravity_radius_m = 62000.0
	check(first.contains_gravity_point(point) and first.acceleration_at(point) == a, "恰好位于中心距边界仍受引力")
	check(first.contains_gravity_point(Vector2(0, -61999)), "边界内一点属于引力范围")
	check(not first.contains_gravity_point(Vector2(0, -62001)), "边界外一点不属于引力范围")
	check(first.acceleration_at(Vector2(0, -62001)) == Vector2.ZERO, "边界外引力立即为零")
	first.max_gravity_radius_m = 61000.0
	check(game._gravity_at(point).distance_to(b) < 0.0001, "缩小第一星范围不影响第二星贡献")
	check(second.max_gravity_radius_m == 250000.0 and game._dominant_source(point) == second, "各星范围独立且主导源仅取有效贡献")
	second.max_gravity_radius_m = 70000.0
	check(game._gravity_at(point) == Vector2.ZERO and game._dominant_source(point) == null, "全部范围之外无引力也无参考源")
	first.max_gravity_radius_m = 250000.0
	check(game._gravity_at(point).distance_to(a) < 0.0001, "恢复第一星范围不恢复第二星贡献")
	second.max_gravity_radius_m = 250000.0
	second.flight_position = Vector2(148750, 0)
	var midpoint := Vector2(74375, 0)
	check(game._gravity_at(midpoint).length() < 0.0001, "重叠范围内等强反向引力抵消")
	check(game._dominant_source(midpoint) != null, "合力抵消不抹除有效单星参考")
	second.flight_position = first.flight_position
	check(game._gravity_at(point).distance_to(a * 2) < 0.0001, "同向重叠引力叠加")
	second.flight_position = Vector2(148750, -250)
	var fixed_position: Vector2 = second.flight_position
	root.size = Vector2i(1600, 900)
	await process_frame
	game._sync_visuals()
	check(second.flight_position == fixed_position, "窗口变化不改变行星物理坐标")
	# 同一星体范围规则对所有飞船一致，范围外飞船保持匀速。
	var other = load("res://scenes/ship.tscn").instantiate()
	other.initial_position = Vector2(0, -400000)
	game.get_node("World").add_child(other)
	await process_frame
	await process_frame
	game.ship.flight_position = point
	game.ship.flight_velocity = Vector2(655, 0)
	game._refresh_preview()
	var preview: PackedVector2Array = game.preview_points.duplicate()
	var initial_velocity: Vector2 = other.flight_velocity
	var initial_position: Vector2 = other.flight_position
	for index in range(4):
		game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(game.ship.flight_position.distance_to(preview[1]) < 0.01, "多星有限范围实飞与一秒预览一致")
	check(other.flight_velocity == initial_velocity and other.flight_position.distance_to(initial_position + initial_velocity) < 0.01, "全部范围外飞船匀速直线")
	check(second.flight_position == fixed_position, "行星间不互相吸引移动")
	# 零引力不移除实体碰撞，高速路径仍不能穿过第二行星。
	var first_gravity: float = first.surface_gravity
	var second_gravity: float = second.surface_gravity
	first.surface_gravity = 0.0
	second.surface_gravity = 0.0
	var start: Vector2 = second.flight_position + Vector2(-70000, 0)
	var hit: Array = game._integrate(start, Vector2(600000, 0), 0.25)
	check(hit[1] == Vector2.ZERO, "零引力时第二行星高速扫掠撞击停止")
	check(absf(hit[0].distance_to(second.flight_position) - second.radius_m) < 0.1, "撞击点在行星表面")
	game.ship.flight_position = start
	game.ship.flight_velocity = Vector2(600000, 0)
	game._refresh_preview()
	check(game.preview_points.size() == 2, "预演在第二行星表面终止")
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(game.ship.crashed, "实飞撞击第二行星")
	check(game.ship.flight_position.distance_to(hit[0]) < 0.1, "实飞与预演碰撞位置一致")
	first.surface_gravity = first_gravity
	second.surface_gravity = second_gravity
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
