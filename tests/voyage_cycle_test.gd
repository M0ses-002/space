extends SceneTree
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)
func _run() -> void:
	root.size = Vector2i(1200, 720)
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	game._select_ship()
	var ship = game.ship
	var source = game.planets[0]
	var confirm: Button = source.get_node("ConfirmArrival")
	var depart: Button = game.get_node("HUD/Root/FlightPanel/Margin/Content/DepartButton")
	check(not confirm.visible and not depart.visible, "开始没有确认和起航按钮")
	game._confirm_arrival(source)
	check(not ship.voyage_finished, "未满足稳定条件不可确认")
	ship.flight_position = source.flight_position + Vector2(0, -62000)
	ship.flight_velocity = Vector2(sqrt(source.acceleration_at(ship.flight_position).length() * 62000), 0)
	ship.reset_orbit()
	for index in range(120):
		var next: Array = game._integrate(ship.flight_position, ship.flight_velocity, game.SIM_STEP)
		ship.flight_position = next[0]
		ship.flight_velocity = next[1]
		game._update_orbit_eligibility(ship, game.SIM_STEP)
		if index == 118:
			game._update_ui()
			check(not confirm.visible, "不足三十模拟秒不显示确认")
	game._update_ui()
	check(confirm.visible, "稳定三十秒且通过预演显示行星按钮")
	var circular_velocity: Vector2 = ship.flight_velocity
	ship.flight_velocity = circular_velocity * 1.1
	game._update_orbit_eligibility(ship, 0.0, true)
	check(ship.stay_available, "闭合椭圆轨道不应被近圆限制排除")
	ship.flight_velocity = circular_velocity * 2.0
	game._update_orbit_eligibility(ship, 30.0)
	check(not ship.stay_available, "世界状态不变时定期撤销失效资格")
	ship.flight_velocity = circular_velocity
	game._update_orbit_eligibility(ship, 30.0)
	check(ship.stay_available, "世界状态不变时定期重试失败的验证")
	var stable_time: float = ship.orbit_stable_time
	ship.orbit_stable_time = 29.99
	check(not game._can_confirm_arrival(source), "确认入口必须独立检查三十秒门槛")
	ship.orbit_stable_time = stable_time
	var original_limit: float = source.max_gravity_radius_m
	var saved_velocity: Vector2 = ship.flight_velocity
	ship.flight_velocity += (ship.flight_position - source.flight_position).normalized() * 30.0
	source.max_gravity_radius_m = ship.flight_position.distance_to(source.flight_position) + 1.0
	game._confirm_arrival(source)
	check(not ship.voyage_finished and not ship.stay_available, "确认时重新预演，拒绝飞出引力范围")
	source.max_gravity_radius_m = original_limit
	ship.flight_velocity = saved_velocity
	game._update_orbit_eligibility(ship, 0.0)
	check(ship.stay_available, "环境恢复后重新验证资格")
	var original_velocity: Vector2 = ship.flight_velocity
	ship.flight_velocity = (ship.flight_position - source.flight_position).normalized() * original_velocity.length()
	game._confirm_arrival(source)
	check(not ship.voyage_finished and ship.orbit_stable_time == 0.0, "确认时复核径向运动并重置稳定计时")
	ship.flight_velocity = original_velocity
	for index in range(120):
		var next: Array = game._integrate(ship.flight_position, ship.flight_velocity, game.SIM_STEP)
		ship.flight_position = next[0]
		ship.flight_velocity = next[1]
		game._update_orbit_eligibility(ship, game.SIM_STEP)
	check(ship.stay_available, "恢复后须重新稳定三十秒")
	if not game.cities.is_empty():
		var city = game.cities[0]
		var old_city_position: Vector2 = city.flight_position
		city.flight_position = ship.flight_position + Vector2(0, city.city_size_m.y * 0.5 + city.gravity_height_m * 0.5)
		game._confirm_arrival(source)
		check(not ship.voyage_finished and not ship.stay_available, "城市重力干扰变化时拒绝确认")
		city.flight_position = old_city_position
		for index in range(120):
			var next: Array = game._integrate(ship.flight_position, ship.flight_velocity, game.SIM_STEP)
			ship.flight_position = next[0]
			ship.flight_velocity = next[1]
			game._update_orbit_eligibility(ship, game.SIM_STEP)
		check(ship.stay_available, "城市干扰消失后重新稳定")
	var position: Vector2 = ship.flight_position
	var velocity: Vector2 = ship.flight_velocity
	ship.fuel = 123.0
	ship.current_voyage_distance_m = 4567.0
	game._sync_visuals()
	await process_frame
	game._confirm_arrival(source)
	check(ship.voyage_finished and not confirm.visible and not depart.visible, "确认后结束航行并隐藏旧起航入口")
	var port = game.get_node("PortController")
	check(port.active and port.visible and not game.get_node("HUD").visible and not game.get_node("World").visible, "切换纯交互场景且隐藏航行画面")
	check(not game.has_node("ArrivalWindow"), "不再创建弹出窗口")
	check(ship.fuel == 123, "确认时不提前补油")
	check(ship.last_voyage_distance_m == 4567.0 and ship.completed_voyage_count == 1, "入港结算航程与次数")
	game._accelerate()
	game._set_throttle(1.0)
	game._begin_orbit_selection()
	check(ship.manual_thrust == 0 and ship.thrust_throttle == 0 and not game.selecting_orbit, "结束航行后所有驾驶入口禁用")
	game._physics_process(1.0)
	check(ship.flight_position == position and ship.fuel == 123, "结束后本船不积分不耗油")
	var other = load("res://scenes/ship.tscn").instantiate()
	game.get_node("World").add_child(other)
	await process_frame
	await process_frame
	game._select_target(other)
	check(game.ship == ship, "港口界面屏蔽隐藏舰队切换")
	var other_position: Vector2 = other.flight_position
	game._physics_process(0.1)
	check(other.flight_position != other_position and ship.flight_position == position, "其他飞船继续航行")
	game._select_target(ship)
	port.view.depart_requested.emit()
	check(ship.voyage_finished and port.active, "未结算生活补给不可起航")
	port.view.supply_settlement_requested.emit()
	port.view.depart_requested.emit()
	check(not ship.voyage_finished and not port.active and not port.visible and game.get_node("World").visible and game.get_node("HUD").visible, "起航退出交互场景并恢复航行")
	check(ship.flight_position == position and ship.flight_velocity == velocity, "恢复原轨道相位速度和方向")
	check(ship.fuel == 123.0 and not ship.stay_available, "起航保留剩余燃料并重新计圈")
	check(ship.current_voyage_distance_m == 0.0 and ship.last_voyage_distance_m == 4567.0, "起航清空本航程并保留上航程")
	game._physics_process(0.1)
	check(ship.flight_position != position, "起航重新运行物理")
	# 原参考被删除后不能从不存在的轨道起航。
	ship.voyage_finished = true
	ship.arrival_source = source
	ship.departure_position = position
	source.queue_free()
	await process_frame
	game._depart()
	check(ship.voyage_finished, "原行星失效拒绝起航")
	game._reset()
	check(not ship.voyage_finished and not depart.visible, "重置清理航行结束状态")
	print("VOYAGE_CYCLE_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
