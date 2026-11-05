extends SceneTree
const Advisor = preload("res://scripts/navigation/circular_velocity_advisor.gd")
const Loader = preload("res://scripts/navigation/map_loader.gd")
var failures := 0
var assertions := 0

class MovingPlanet:
	extends "res://scripts/world/planet.gd"
	var flight_velocity := Vector2(30, -20)

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	assertions += 1
	if not ok:
		failures += 1
		push_error(message)

func _run() -> void:
	root.get_node("BackgroundMusic").stop_music()
	root.get_node("UIClickSound").stream = null
	var planet = Loader.SCENES.planet.instantiate()
	planet.flight_position = Vector2(12345, -6789)
	var sources: Array = [planet]
	for distance in [51000.0, 53000.0, 80000.0, 249000.0, 250000.0]:
		for direction in [true, false]:
			var point: Vector2 = planet.flight_position + Vector2(0.6, -0.8) * distance
			var result := Advisor.suggest(planet, point, direction, sources)
			check(result.ok, "恒强层/层顶/衰减层/最大边界建议有效")
			var outward: Vector2 = (point - planet.flight_position).normalized()
			var velocity: Vector2 = result.velocity
			check(absf(velocity.dot(outward)) < 0.001, "速度严格切向，无径向速度")
			check(is_equal_approx(velocity.length_squared() / distance, -planet.acceleration_at(point).dot(outward)), "向心加速度直接匹配真实 acceleration_at")
			check((point - planet.flight_position).cross(velocity) > 0.0 if direction else (point - planet.flight_position).cross(velocity) < 0.0, "Y向下的顺逆时针方向正确")
	for distance in [0.0, 0.0005, 50000.0, 250001.0]:
		check(not Advisor.suggest(planet, planet.flight_position + Vector2(distance, 0), true).ok, "拒绝中心/表面/引力范围外")
	planet.surface_gravity = 0.0
	check(not Advisor.suggest(planet, planet.flight_position + Vector2(80000, 0), true).ok, "拒绝零向心场")
	planet.surface_gravity = 9.81
	var other = Loader.SCENES.planet.instantiate()
	other.flight_position = planet.flight_position + Vector2(120000, 0)
	var point: Vector2 = planet.flight_position + Vector2(80000, 0)
	var single := Advisor.suggest(planet, point, true)
	var multiple := Advisor.suggest(planet, point, true, [planet, other])
	check(multiple.velocity == single.velocity and multiple.other_source_count == 1 and multiple.perturbation_ratio > 0.0, "多源不伪造合力圆轨道，只报告扰动")
	var moving := MovingPlanet.new()
	moving.flight_position = planet.flight_position
	var moving_result := Advisor.suggest(moving, point, true)
	check((moving_result.velocity - moving.flight_velocity).distance_to(single.velocity) < 0.001, "移动行星使用参考系速度")
	moving.free()
	other.free()
	# 用游戏实际积分器跑完整一圈，覆盖恒强层与平方反比区。
	var game = load("res://scenes/game/main.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	game.planets.clear()
	game.planets.append(planet)
	game.cities.clear()
	for distance in [51500.0, 80000.0]:
		var start: Vector2 = planet.flight_position + Vector2(distance, 0)
		var result := Advisor.suggest(planet, start, true)
		var position := start
		var velocity: Vector2 = result.velocity
		var steps := int(ceil(TAU * distance / result.relative_speed / game.SIM_STEP))
		var max_error := 0.0
		for i in steps:
			var next: Array[Vector2] = game._integrate(position, velocity, game.SIM_STEP)
			position = next[0]
			velocity = next[1]
			max_error = maxf(max_error, absf(position.distance_to(planet.flight_position) - distance) / distance)
		check(max_error < 0.002 and position.distance_to(start) / distance < 0.005, "真实积分器一圈近圆稳定 r=%s 最大偏差=%s" % [distance, max_error])
		print("CIRCULAR_ORBIT r=%s steps=%s max_relative_radius_error=%s" % [distance, steps, max_error])
	game.queue_free()
	await process_frame
	planet.free()
	print("CIRCULAR_VELOCITY_TEST: %s (%d assertions, %d failures)" % ["PASS" if failures == 0 else "FAIL", assertions, failures])
	quit(0 if failures == 0 else 1)
