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
	check(not game.has_method("_toggle_hover") and not game.panel.has_node("Margin/Content/HoverButton"), "悬停操作和按钮均已移除")
	check(not game.stay_button.visible, "未选中隐藏停留")
	game._select_ship()
	await process_frame
	game.ship.flight_position = game.planets[0].flight_position + Vector2(0, -62000)
	game.ship.flight_velocity = Vector2(655, 0)
	var start: Vector2 = game.ship_position
	var fuel: float = game.fuel_mass
	game._refresh_preview()
	var prediction: PackedVector2Array = game.preview_points.duplicate()
	game._physics_process(game.SIM_STEP * game.PREVIEW_SAMPLE_STEPS / game.TIME_SCALE)
	check(game.ship_position != start and game.fuel_mass == fuel, "无动力飞行持续运动且不耗油")
	check(game.ship_position.distance_to(prediction[1]) < 0.01, "滑行预演与实飞一致")
	for index in range(4):
		game._reset()
		game._select_ship()
		await process_frame
		click(game.speed_row.get_child(index))
		await process_frame
		var multiplier: float = [0.5, 1.0, 1.5, 2.0][index]
		check(game.simulation_speed == multiplier, "倍率按钮实际点击")
		var expected_position: Vector2 = game.ship_position
		var expected_velocity: Vector2 = game.ship_velocity
		for step in range(int(2.0 * multiplier / game.SIM_STEP)):
			var state: Array = game._integrate(expected_position, expected_velocity, game.SIM_STEP)
			expected_position = state[0]
			expected_velocity = state[1]
		fuel = game.fuel_mass
		game._physics_process(0.1)
		check(game.ship_position.distance_to(expected_position) < 0.01 and game.fuel_mass == fuel, "倍率影响滑行模拟时间且不消耗燃料")
	game._reset()
	# 单行星真实积分绕行，提前不得出现停留。
	for planet in game.planets.duplicate():
		if planet != game.planets[0]:
			planet.queue_free()
	await process_frame
	var source = game.planets[0]
	var vessel = game.ship
	vessel.flight_position = source.flight_position + Vector2(0, -62000)
	vessel.flight_velocity = Vector2(sqrt(source.acceleration_at(vessel.flight_position).length() * 62000), 0)
	game._select_ship()
	for index in range(120):
		var next: Array = game._integrate(vessel.flight_position, vessel.flight_velocity, game.SIM_STEP)
		vessel.flight_position = next[0]
		vessel.flight_velocity = next[1]
		game._update_orbit_eligibility(vessel, game.SIM_STEP)
		if index == 118:
			check(not vessel.stay_available, "未满三十模拟秒不解锁")
	check(vessel.stay_available, "近圆轨道稳定三十秒并通过预演解锁")
	game._update_ui()
	await process_frame
	check(source.get_node("ConfirmArrival").visible and not game.stay_button.visible, "稳定绕行显示行星确认按钮，替换旧停留占位")
	start = game.ship_position
	fuel = game.fuel_mass
	check(game.ship_position == start and game.fuel_mass == fuel, "获得资格不会自动结束航行，必须确认")
	# 检查不同窗口尺寸下的控件布局。
	for size in [Vector2i(900, 640), Vector2i(1200, 720), Vector2i(1600, 900)]:
		root.size = size
		for frame in range(5):
			await process_frame
		var bounds := Rect2(Vector2.ZERO, Vector2(size))
		var controls: Array = [game.accelerate_button, game.brake_button, game.mining_button, game.stay_button, game.orbit_button, game.pause_button, game.speed_row, game.panel.get_node("Margin/Content/ResetButton")]
		for index in range(controls.size()):
			check(bounds.encloses(controls[index].get_global_rect()), "停留、暂停与入轨按钮完整位于屏幕内")
			for other_index in range(index + 1, controls.size()):
				check(not controls[index].get_global_rect().intersects(controls[other_index].get_global_rect()), "同时显示的飞行面板控件不得重叠")
	var before_thrust: Vector2 = vessel.flight_velocity
	fuel = vessel.fuel
	game._accelerate()
	check(not vessel.stay_available, "开始点火重置稳定绕行")
	check(vessel.flight_velocity == before_thrust and vessel.fuel == fuel, "开始点火不立即修改速度或燃料")
	game._stop_thrust()
	# 径向运动不算稳定绕行。
	vessel.flight_velocity = (vessel.flight_position - source.flight_position).normalized() * 650
	vessel.track_orbit(source, game._gravity_at(vessel.flight_position))
	check(vessel.orbit_source == null, "径向运动不计为轨道")
	# 多船状态独立。
	var other = load("res://scenes/ship.tscn").instantiate()
	game.get_node("World").add_child(other)
	await process_frame
	await process_frame
	game._select_target(other)
	check(not other.stay_available and not game.stay_button.visible, "新船不继承停留资格")
	game._reset()
	check(game.simulation_speed == 1.0, "重置恢复全部状态与倍率")
	# 引力范围外无动力滑行保持速度和燃料。
	game._select_target(vessel)
	vessel.flight_position = Vector2(0, -400000)
	vessel.flight_velocity = Vector2(123, 45)
	start = vessel.flight_position
	var free_velocity: Vector2 = vessel.flight_velocity
	fuel = vessel.fuel
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)
	check(vessel.flight_position != start and vessel.flight_velocity == free_velocity and vessel.fuel == fuel, "引力范围外保持匀速滑行且不耗油")
	print("HOVER_ORBIT_SPEED_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
