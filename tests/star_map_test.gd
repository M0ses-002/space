extends SceneTree

var failures := 0
func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1200, 720)
	var game = load("res://star_map_demo.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	var view = game.get_node("StarMapView")
	var vessel = game.ship
	check(game.planets.size() == 2, "演示注册双星")
	check(view.map_mode and game.selected and vessel.has_navigation_target, "演示直接进入星图并选船设置目标")
	check(game.planets[1].flight_position.distance_to(Vector2(650000, 0)) < 1.0, "第二星编辑器布景位置")
	# 固定测试夹具，不覆盖用户演示场景中的350/400km编辑值。
	for planet in game.planets:
		planet.max_gravity_radius_m = 250000.0
	# 在无引力区验证固定时长与电脑升级对两种视图的不同作用。
	var original_position: Vector2 = vessel.flight_position
	var original_velocity: Vector2 = vessel.flight_velocity
	vessel.flight_position = Vector2(-1000000, -1000000)
	vessel.flight_velocity = Vector2(10, 0)
	game._refresh_preview()
	while not game.preview_job.is_empty():
		game._advance_preview_job()
	var map_points: PackedVector2Array = game.preview_points.duplicate()
	check(map_points.size() == 1801, "星图预测1800秒")
	vessel.upgrade_slots[0] = "computer"
	game._refresh_preview()
	while not game.preview_job.is_empty():
		game._advance_preview_job()
	check(game.preview_points == map_points, "电脑升级不改变星图预测")
	view.set_map_mode(false)
	check(game.preview_points.size() == 931, "电脑升级将近域预测延长至930秒")
	vessel.upgrade_slots[0] = ""
	game._refresh_preview()
	check(game.preview_points.size() == 621, "未升级时近域预测620秒")
	vessel.flight_position = original_position
	vessel.flight_velocity = original_velocity
	view.set_map_mode(true)
	var p: Vector2 = vessel.flight_position
	var v: Vector2 = vessel.flight_velocity
	var fuel: float = vessel.fuel
	view.set_map_mode(false)
	view.set_map_mode(true)
	check(vessel.flight_position == p and vessel.flight_velocity == v and vessel.fuel == fuel, "视角切换不改变模拟")
	# 点目标不施力，修向与顺逆推互斥、按Δv扣油，松手不自动制动。
	game._set_navigation_target(p + Vector2(0, -100000))
	game._set_thrust_direction(Vector2.UP)
	check(not vessel.steering and vessel.flight_velocity == v, "点击目标不立即推进")
	game._set_throttle(1.0)
	check(vessel.steering and vessel.manual_thrust == 0, "星图可启动修向")
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(absf(vessel.flight_velocity.y + vessel.get_effective_steering_acceleration() * game.SIM_STEP) < 0.001, "有限横向加速度")
	check(absf(fuel - vessel.fuel - vessel.get_effective_steering_acceleration() * game.SIM_STEP * vessel.get_effective_propulsion_fuel_per_delta_v()) < 0.01, "修向按实际Δv扣油")
	game._stop_thrust()
	v = vessel.flight_velocity
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(vessel.flight_velocity == v, "松手后无引力区域惯性滑行")
	game._set_throttle(1.0)
	game._start_thrust(1.0)
	check(not vessel.steering and vessel.manual_thrust == 1, "推进模式不叠加")
	game._set_throttle(1.0)
	game._toggle_pause()
	check(not vessel.steering and vessel.manual_thrust == 0, "暂停停止手动施力")
	game._toggle_pause()
	# 无单次预算，油门持续保持；出力上限独立配置。
	vessel.max_steering_acceleration = 12.0
	game._set_throttle(0.5)
	v = vessel.flight_velocity
	game._physics_process(game.SIM_STEP * 2 / game.TIME_SCALE)
	check(vessel.steering and absf(vessel.flight_velocity.y - v.y + vessel.get_effective_steering_acceleration() * 0.5 * game.SIM_STEP * 2) < 0.001, "50%油门按最大出力持续作用")
	vessel.fuel = 1.0
	game._set_throttle(1.0)
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(vessel.fuel == 0 and not vessel.steering, "燃料不足仅执行可负担Δv")
	# 预览仍假设此刻松手，不预演后续手动修向。
	vessel.fuel = 1000
	vessel.max_steering_acceleration = 10.0
	game._set_throttle(1.0)
	game._refresh_preview()
	var points: PackedVector2Array = game.preview_points.duplicate()
	game._stop_thrust()
	game._refresh_preview()
	check(points == game.preview_points, "修向按住与松手的当前状态预览一致")
	# 分帧过程中保留旧轨迹，按开始时快照完成并原子替换。
	vessel.flight_position = Vector2(-1000000, -1000000)
	vessel.flight_velocity = Vector2(10, 0)
	game._refresh_preview()
	while not game.preview_job.is_empty():
		game._advance_preview_job()
	var previous: PackedVector2Array = game.preview_points.duplicate()
	vessel.flight_position += Vector2(100, 0)
	var snapshot: Vector2 = vessel.flight_position
	game._refresh_preview()
	game._advance_preview_job()
	check(game.preview_points == previous and not game.preview_job.is_empty(), "分帧计算不显示半成品")
	vessel.flight_position += Vector2(200, 0)
	while not game.preview_job.is_empty():
		game._advance_preview_job()
	check(game.preview_points.size() == 1801 and game.preview_points[0] == snapshot, "分帧按起算快照完成1800秒")
	check(game.preview_points[-1].distance_to(snapshot + Vector2(18000, 0)) < 0.1, "分帧固定步预测终点")
	# 暂停或机动发生改变时取消旧任务，改用新状态。
	game._refresh_preview()
	game._advance_preview_job()
	game.simulation_paused = not game.simulation_paused
	game._advance_preview_job()
	check(game.preview_job.index == 0 and game.preview_job.paused == game.simulation_paused, "暂停变更取消旧快照")
	game.simulation_paused = not game.simulation_paused
	game._advance_preview_job()
	vessel.maneuver_commands = [1.0]
	game._advance_preview_job()
	check(game.preview_job.index == 0 and game.preview_job.commands == vessel.maneuver_commands, "机动变更取消旧快照")
	vessel.maneuver_index += 1
	game._advance_preview_job()
	check(game.preview_job.index > 0 and game.preview_job.command_index == 0, "机动索引自然推进不重启且保留快照")
	game.simulation_paused = true
	game._advance_preview_job()
	while not game.preview_job.is_empty():
		game._process(0.016)
	check(game.preview_points.size() == 1801, "暂停状态下分帧预测仍能完成")
	game.simulation_paused = false
	vessel.maneuver_index = 0
	vessel.maneuver_commands.clear()
	vessel.flight_position = original_position
	vessel.flight_velocity = original_velocity
	game._refresh_preview()
	# 多船隔离。
	var other = load("res://scenes/ship.tscn").instantiate()
	other.initial_position = Vector2(-400000, -400000)
	game.get_node("World").add_child(other)
	await process_frame
	await process_frame
	game._set_throttle(1.0)
	game._select_target(other)
	check(game.preview_points.is_empty(), "切船后不显示其他船的旧轨迹")
	check(not vessel.steering and not other.has_navigation_target, "切船停止修向且目标不串船")
	game._select_target(vessel)
	check(vessel.has_navigation_target, "切回原船仍保留目标")
	# 区域变更不重置状态；重叠区保持显示参考，仍叠加引力。
	var first = game.planets[0]
	var second = game.planets[1]
	vessel.flight_position = Vector2(260000, 0)
	game._update_region(vessel, vessel.flight_position)
	check(vessel.region_source == null, "圈外参考为空")
	vessel.flight_position = Vector2(240000, 0)
	game._update_region(vessel, Vector2(260000, 0))
	check(vessel.region_source == first, "进入引力圈记录参考")
	second.flight_position = Vector2(300000, 0)
	game._update_region(vessel, vessel.flight_position)
	check(vessel.region_source == first, "重叠区稳定参考不反复切星")
	check(game._gravity_at(vessel.flight_position).distance_to(first.acceleration_at(vessel.flight_position) + second.acceleration_at(vessel.flight_position)) < 0.001, "显示归属不改变合引力")
	second.flight_position = Vector2(650000, 0)
	# 两端都在圈外的高速掠过：检测事件和中间引力，不穿过实体。
	var from := Vector2(-300000, -200000)
	var to := Vector2(300000, -200000)
	check(game._circle_crossings(from, to, Vector2.ZERO, 250000).size() == 2, "扫掠识别两个引力圈交点")
	vessel.region_source = null
	vessel.flight_position = to
	game._update_region(vessel, from)
	check(vessel.region_event.contains("高速掠过"), "高速完整穿越不漏事件")
	var sweep: Array = game._integrate(from, Vector2(2400000, 0), 0.25)
	check(sweep[1].y > 0, "高速穿越中间区域仍计算引力")
	# 行星目标删除时取消，不访问已释放对象。
	game._set_navigation_target(second.flight_position, second)
	second.queue_free()
	await process_frame
	await process_frame
	game._validate_navigation(vessel)
	check(not vessel.has_navigation_target and not vessel.steering, "删除行星使导航目标失效")
	game._clear_navigation_target()
	check(not vessel.has_navigation_target, "取消目标")
	game.queue_free()
	await process_frame
	print("STAR_MAP_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
