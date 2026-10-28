extends SceneTree
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func click(button: Button) -> void:
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion, true)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)

func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1200, 720)
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	check(not game.hover_button.visible and not game.stay_button.visible, "未选中隐藏悬停和停留")
	game._select_ship()
	await process_frame
	check(game.hover_button.visible, "选船后出现悬停")
	var start: Vector2 = game.ship_position
	click(game.hover_button)
	await process_frame
	check(game.ship.hovering and game.ship_velocity == Vector2.ZERO, "实际点击悬停固定当前点并归零速度")
	var rate: float = game._hover_rate(start, game.ship.gravity_threshold, game.ship.hover_fuel_per_delta_v)
	var fuel: float = game.fuel_mass
	game._physics_process(1.0 / game.TIME_SCALE)
	check(game.ship_position == start, "悬停位置不变")
	check(absf(game.fuel_mass - fuel + rate) < 0.001, "按合引力扣每模拟秒燃料")
	check(game.accelerate_button.disabled and game.brake_button.disabled, "悬停时调速禁用")
	check(is_equal_approx(game._hover_rate(start, 1000, 2), 0.0), "忽略全部引力不耗悬停燃料")
	check(is_equal_approx(game._hover_rate(start, 0, 4), 2 * game._hover_rate(start, 0, 2)), "耗油系数按比例")
	game.fuel_mass = rate * 0.5
	game._refresh_preview()
	var prediction: PackedVector2Array = game.preview_points.duplicate()
	game._physics_process(1.0 / game.TIME_SCALE)
	check(not game.ship.hovering and is_zero_approx(game.fuel_mass), "油尽退出悬停")
	check(game.ship_position.distance_to(start) > 0.0, "油尽恢复引力运动")
	check(game.ship_position.distance_to(prediction[1]) < 0.01, "悬停耗尽预演实飞一致")
	for direction in [1.0, -1.0]:
		game._reset()
		game._select_ship()
		game.ship_velocity *= direction
		var initial_velocity: Vector2 = game.ship_velocity
		click(game.hover_button)
		await process_frame
		var reference = game.ship.hover_source
		var radial: Vector2 = game.ship_position - reference.flight_position
		var circular_speed: float = sqrt(reference.acceleration_at(game.ship_position).length() * radial.length())
		var orbit_direction: float = signf(radial.cross(initial_velocity))
		fuel = game.fuel_mass
		click(game.hover_button)
		await process_frame
		check(not game.ship.hovering, "再次点击付费解除悬停")
		check(absf(game.ship_velocity.length() - circular_speed) < 0.001, "解除悬停立即获得参考行星的圆轨道速度")
		check(absf(radial.normalized().dot(game.ship_velocity.normalized())) < 0.0001, "解除悬停速度沿切向")
		check(signf(radial.cross(game.ship_velocity)) == orbit_direction, "解除悬停保留原顺逆时针方向")
		check(absf(fuel - game.fuel_mass - circular_speed * game.ship.propulsion_fuel_per_delta_v) < 0.001, "圆轨道起步按速度增量付费")
	game._reset()
	game._select_ship()
	click(game.hover_button)
	await process_frame
	game.fuel_mass = 0.1
	fuel = game.fuel_mass
	click(game.hover_button)
	check(game.ship.hovering and game.ship_velocity == Vector2.ZERO and game.fuel_mass == fuel, "燃料不足不能解除悬停且不预扣油")
	click(game.pause_button)
	check(game.simulation_paused and game.hover_button.disabled, "暂停时悬停按钮禁用")
	game._toggle_hover()
	check(game.ship.hovering and game.fuel_mass == fuel, "暂停时直接调用也不能切换悬停")
	game._reset()
	# 同样状态不同燃料，纯飞行轨迹完全一致。
	var low: Dictionary = game._advance_flight(start, Vector2(655, 0), 10, false, 0.25, 0, 2)
	var high: Dictionary = game._advance_flight(start, Vector2(655, 0), 10000, false, 0.25, 0, 2)
	check(low.position == high.position and low.velocity == high.velocity, "轨道不使用燃料质量")
	# 对照实际时间倍率：悬停位置一致、耗油按倍率变化。
	for index in range(4):
		game._reset()
		game._select_ship()
		game._toggle_hover()
		await process_frame
		click(game.speed_row.get_child(index))
		await process_frame
		var multiplier: float = [0.5, 1.0, 1.5, 2.0][index]
		check(game.simulation_speed == multiplier, "倍率按钮实际点击")
		fuel = game.fuel_mass
		game._physics_process(0.1)
		check(absf(fuel - game.fuel_mass - rate * 2 * multiplier) < 0.01, "倍率影响模拟秒与耗油")
	game._reset()
	# 单行星真实积分绕行，提前不得出现停留。
	for planet in game.planets.duplicate():
		if planet != game.get_node("World/Planet"):
			planet.queue_free()
	await process_frame
	var source = game.get_node("World/Planet")
	var vessel = game.ship
	vessel.flight_position = Vector2(0, -62000)
	vessel.flight_velocity = Vector2(sqrt(source.acceleration_at(vessel.flight_position).length() * 62000), 0)
	game._select_ship()
	for index in range(3000):
		var next: Array = game._integrate(vessel.flight_position, vessel.flight_velocity, game.SIM_STEP)
		vessel.flight_position = next[0]
		vessel.flight_velocity = next[1]
		vessel.track_orbit(source, game._gravity_at(vessel.flight_position))
		if index == 1000:
			check(not vessel.stay_available, "未满一圈不解锁")
	check(vessel.stay_available, "实际近圆轨道绕满一圈解锁")
	game._update_ui()
	await process_frame
	check(game.stay_button.visible, "选中稳定绕行船显示停留")
	start = game.ship_position
	fuel = game.fuel_mass
	click(game.stay_button)
	check(game.ship_position == start and game.fuel_mass == fuel and not game.ship.hovering, "停留按钮无效果")
	# 同时显示悬停、停留时检查最小窗口布局。
	for size in [Vector2i(900, 640), Vector2i(1200, 720), Vector2i(1600, 900)]:
		root.size = size
		for frame in range(5):
			await process_frame
		var bounds := Rect2(Vector2.ZERO, Vector2(size))
		var controls: Array = [game.accelerate_button, game.brake_button, game.hover_button, game.stay_button, game.orbit_button, game.pause_button, game.speed_row, game.panel.get_node("Margin/Content/ResetButton")]
		for index in range(controls.size()):
			check(bounds.encloses(controls[index].get_global_rect()), "悬停、停留、暂停与入轨按钮完整位于屏幕内")
			for other_index in range(index + 1, controls.size()):
				check(not controls[index].get_global_rect().intersects(controls[other_index].get_global_rect()), "同时显示的飞行面板控件不得重叠")
	var before_thrust: Vector2 = vessel.flight_velocity
	fuel = vessel.fuel
	game._accelerate()
	check(not vessel.stay_available, "开始点火重置稳定绕行")
	check(vessel.flight_velocity == before_thrust and vessel.fuel == fuel, "开始点火不立即修改速度或燃料")
	game._stop_thrust()
	# 径向运动、强多体扰动、反向、悬停不算稳定绕行。
	vessel.flight_velocity = vessel.flight_position.normalized() * 650
	vessel.track_orbit(source, game._gravity_at(vessel.flight_position))
	check(vessel.orbit_source == null, "径向运动不计为轨道")
	vessel.hovering = true
	vessel.track_orbit(source, game._gravity_at(vessel.flight_position))
	check(not vessel.stay_available, "悬停不算绕行")
	# 多船状态独立。
	var other = load("res://scenes/ship.tscn").instantiate()
	game.get_node("World").add_child(other)
	await process_frame
	await process_frame
	game._select_target(other)
	check(not other.hovering and not game.stay_button.visible, "新船不继承悬停与停留资格")
	game._reset()
	check(not vessel.hovering and game.simulation_speed == 1.0, "重置恢复全部状态与倍率")
	print("HOVER_ORBIT_SPEED_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
