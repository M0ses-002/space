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
	debris.minimum_fragment_pixels = 0.0
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
	game.ship.upgrade_slots[0] = "shield"
	game.ship.shield_ready = true
	game.ship.flight_position = Vector2(0, -400000)
	game.ship.flight_velocity = Vector2.ZERO
	other.flight_position = game.ship.flight_position
	other.flight_velocity = Vector2.ZERO
	debris.flight_position = game.ship.flight_position
	debris.flight_velocity = Vector2.ZERO
	step(game)
	check(debris.destroyed and not game.ship.shield_ready and not game.ship.crashed and not other.crashed, "护盾销毁垃圾后同一物理步其他飞船不会重复碰撞")
	debris.reset_motion()
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
	check(debris.get_node("Visual").visible and debris.get_node("MapArea").visible, "垃圾普通视图同时显示碎片和红色范围")
	var fragments: Array = debris.get_node("Visual").get_children()
	check(fragments.size() == 32, "垃圾场景预设 32 个碎片节点")
	debris.debris_count = 24
	var radial_sum := 0.0
	var visible_count := 0
	var quadrants := [0, 0, 0, 0]
	for fragment in fragments:
		check(fragment is Sprite2D, "碎片节点应为 Sprite2D")
		if fragment.visible:
			visible_count += 1
			var rect: Rect2 = fragment.get_rect()
			var half_diagonal: float = rect.size.length() * fragment.scale.x * 0.5
			var available_radius: float = maxf(100.0 - half_diagonal, 0.0)
			check(available_radius > 0.0, "测试碎片应小于区域半径")
			if available_radius > 0.0:
				var normalized_radius: float = fragment.position.length() / available_radius
				check(normalized_radius <= 1.0, "碎片中心应位于有效分布半径内")
				radial_sum += normalized_radius * normalized_radius
			for corner in [rect.position, rect.position + Vector2(rect.size.x, 0), rect.end, rect.position + Vector2(0, rect.size.y)]:
				var transformed_corner: Vector2 = fragment.transform * corner
				check(transformed_corner.length() <= 100.001, "碎片贴图变换后包络应位于红色圆形范围内")
			var quadrant := (1 if fragment.position.x >= 0 else 0) + (2 if fragment.position.y >= 0 else 0)
			quadrants[quadrant] += 1
	check(visible_count == 24, "垃圾显示指定数量的碎片")
	check(absf(radial_sum / 24.0 - 0.5) < 0.05, "碎片应均匀分布在圆形面积内")
	for count in quadrants:
		check(count >= 4 and count <= 8, "碎片应分布在圆形各象限")
	var fragment: Sprite2D = fragments[0]
	var width_before: float = fragment.texture.get_width() * fragment.scale.x * debris.scale.x
	debris.radius_m = 200.0
	game._sync_visuals()
	var width_after: float = fragment.texture.get_width() * fragment.scale.x * debris.scale.x
	check(absf(width_before - width_after) < 0.001, "改变区域半径不应改变碎片显示尺寸")
	debris.debris_size_m *= 2.0
	var width_larger: float = fragment.texture.get_width() * fragment.scale.x * debris.scale.x
	check(absf(width_larger - width_after * 2.0) < 0.001, "碎片显示尺寸应随独立尺寸参数变化")
	debris.debris_count = 0
	for piece in fragments:
		check(not piece.visible, "碎片数量为零时隐藏所有碎片")
	debris.debris_count = 100
	visible_count = 0
	for piece in fragments:
		if piece.visible:
			visible_count += 1
	check(visible_count == 32, "碎片显示数量不能超过预设节点上限")
	debris.debris_count = 24
	debris.debris_size_m = 1000.0
	for piece in fragments:
		check(not piece.visible, "超出区域的碎片应隐藏")
	check(debris.debris_size_m == 1000.0 and debris.debris_count == 24, "隐藏超大碎片不应改变设置")
	debris.radius_m = 2000.0
	game._sync_visuals()
	check(fragment.visible, "增大区域后可容纳的碎片应恢复显示")
	var restored_width: float = fragment.get_rect().size.x * fragment.scale.x * debris.scale.x
	debris.radius_m = 200.0
	game._sync_visuals()
	check(not fragment.visible, "缩小区域后超大碎片应重新隐藏")
	var hidden_width: float = fragment.get_rect().size.x * fragment.scale.x * debris.scale.x
	check(absf(restored_width - hidden_width) < 0.001, "隐藏碎片不应改变其物理显示尺寸")
	debris.debris_size_m = 40.0
	check(fragment.visible, "减小碎片尺寸后应恢复显示")
	debris.radius_m = 100.0
	game._sync_visuals()
	# 使用真实画布和屏幕变换复现截图比例，不修改演示场景的参数。
	debris.radius_m = 22800.01
	debris.minimum_fragment_pixels = 4.0
	var camera: Camera2D = game.get_node("NavigationCamera")
	camera.zoom = Vector2.ONE * (100.0 / (23900.0 * game._view_scale()))
	camera.force_update_scroll()
	game._sync_visuals()
	await process_frame
	var transform_to_screen: Transform2D = debris.get_viewport().get_screen_transform() * debris.get_global_transform_with_canvas()
	check(absf(transform_to_screen.x.length() * 100.0 - debris.radius_m * 100.0 / 23900.0) < 0.05, "真实变换应匹配 100px=23.9km")
	check(debris.get_node("Visual").z_index > debris.get_node("MapArea").z_index, "碎片层级必须高于红色区域")
	for piece in fragments:
		if not piece.visible:
			continue
		var screen_piece: Transform2D = transform_to_screen * piece.transform
		var rect: Rect2 = piece.get_rect()
		var longest := maxf(screen_piece.x.length() * rect.size.x, screen_piece.y.length() * rect.size.y)
		check(absf(longest - 4.0) < 0.01, "截图比例下碎片最长边应为 4 屏幕像素")
		for corner in [rect.position, rect.position + Vector2(rect.size.x, 0), rect.end, rect.position + Vector2(0, rect.size.y)]:
			check((piece.transform * corner).length() <= 100.001, "放大后的碎片必须留在红圈内")
	var radius_before: float = debris.radius_m
	var size_before: float = debris.debris_size_m
	game.simulation_paused = true
	camera.zoom *= 2.0
	camera.force_update_scroll()
	await process_frame
	await process_frame
	transform_to_screen = debris.get_viewport().get_screen_transform() * debris.get_global_transform_with_canvas()
	var transformed_fragment: Transform2D = transform_to_screen * fragment.transform
	check(absf(maxf(transformed_fragment.x.length() * fragment.get_rect().size.x, transformed_fragment.y.length() * fragment.get_rect().size.y) - 4.0) < 0.01, "暂停时缩放相机应实时更新碎片像素大小")
	check(debris.radius_m == radius_before and debris.debris_size_m == size_before, "视觉缩放不能修改物理参数")
	check(absf(debris.scale.x * 100.0 - debris.radius_m * game._view_scale()) < 0.001, "视觉缩放不能修改红圈半径")
	debris.debris_size_m = 1.0
	debris.radius_m = 10.0
	game._sync_visuals()
	check(fragment.visible, "极小区域中的物理碎片应仍然显示")
	for piece in fragments:
		if piece.visible:
			for corner in [piece.get_rect().position, piece.get_rect().position + Vector2(piece.get_rect().size.x, 0), piece.get_rect().end, piece.get_rect().position + Vector2(0, piece.get_rect().size.y)]:
				check((piece.transform * corner).length() <= 100.001, "极小区域仍须容纳碎片")
	debris.radius_m = 100.0
	debris.debris_size_m = 40.0
	game._sync_visuals()
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
