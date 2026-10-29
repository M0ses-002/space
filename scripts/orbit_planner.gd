extends RefCounted
## 有界、保守的近圆轨道捕获；只改变速率，不搜索任意转向或全局最优解。

const MAX_PLAN_STEPS := 7200
const MAX_VERIFY_STEPS := 20000
const MAX_TOTAL_STEPS := 60000
const MAX_CANDIDATES := 18
const MAX_PERTURBATION := 0.10
const MAX_RADIUS_VARIATION := 0.10


static func plan(game, vessel, target) -> Dictionary:
	if not is_instance_valid(target) or not game.planets.has(target):
		return _failure("目标引力源不存在。")
	if vessel.crashed:
		return _failure("飞船已损毁，不能规划入轨。")
	var step: float = game.SIM_STEP
	var search_radius: float = vessel.orbit_search_radius
	var horizon: float = vessel.orbit_plan_horizon
	var acceleration: float = vessel.get_effective_acceleration()
	var deceleration: float = vessel.get_effective_deceleration()
	var coefficient: float = vessel.get_effective_propulsion_fuel_per_delta_v()
	var tolerance: float = clampf(vessel.orbit_capture_tolerance, 0.001, 0.04)
	if step <= 0.0 or horizon <= 0.0 or acceleration <= 0.0 or deceleration <= 0.0 or coefficient < 0.0:
		return _failure("推进能力、规划时限或燃料系数配置无效。")
	var position: Vector2 = vessel.flight_position
	var velocity: Vector2 = vessel.flight_velocity
	var reason := _unsafe_reason(game, target, position, search_radius)
	if not reason.is_empty():
		return _failure(reason)
	var offset: Vector2 = position - target.flight_position
	var speed := velocity.length()
	if speed < 0.01 or absf(offset.normalized().cross(velocity / speed)) < 0.15:
		return _failure("速度为零或接近径向坠落，仅沿速度方向点火无法可靠建立轨道。")
	var settings := {
		"step": step, "search_radius": search_radius,
		"acceleration": acceleration, "deceleration": deceleration,
		"coefficient": coefficient, "tolerance": tolerance,
		"limit": mini(int(horizon / step), MAX_PLAN_STEPS),
		"heading": velocity.normalized(),
	}
	var budget := {"remaining": MAX_TOTAL_STEPS}
	var initial := {"position": position, "velocity": velocity}
	var starts: Array[int] = [0]
	var coast: Array[Dictionary] = [initial]
	var attempts := 0
	var least_cost := INF
	var last_reason := "有限候选未找到安全近圆轨道；可调整速度后重试。"
	# 先试即时修正，常见近圆状态无需预演整个等待时限。
	for speed_scale in [1.0, 0.99, 1.01]:
		var candidate := _candidate(game, vessel, target, settings, coast, 0, speed_scale, budget)
		attempts += 1
		if candidate.ok:
			return candidate
		last_reason = candidate.reason
		least_cost = minf(least_cost, candidate.get("required_fuel", INF))
	# 自由滑行只用于定位前两个拱点；碰撞或离开安全区域立即终止。
	var previous_radial := velocity.dot(offset.normalized())
	var apsides := 0
	for index in range(1, int(settings.limit) + 1):
		if int(budget.remaining) <= 0:
			break
		budget.remaining -= 1
		var next: Array = game._integrate(position, velocity, step)
		position = next[0]
		velocity = next[1]
		if not _unsafe_reason(game, target, position, search_radius).is_empty():
			break
		coast.append({"position": position, "velocity": velocity})
		offset = position - target.flight_position
		var radial := velocity.dot(offset.normalized())
		if radial * previous_radial < 0.0:
			var circular_speed := _circular_speed(target, position)
			var needed := circular_speed - velocity.length()
			var rate := acceleration if needed >= 0.0 else deceleration
			var half_burn_steps := int(absf(needed) / rate / step * 0.5)
			var centered := maxi(1, index - half_burn_steps)
			for start in [maxi(1, centered - 8), centered, index]:
				if not starts.has(start):
					starts.append(start)
			apsides += 1
			if apsides >= 2:
				break
		previous_radial = radial
	for start in starts:
		if start == 0:
			continue
		for speed_scale in [1.0, 0.99, 1.01]:
			if attempts >= MAX_CANDIDATES or int(budget.remaining) <= 0:
				break
			var candidate := _candidate(game, vessel, target, settings, coast, start, speed_scale, budget)
			attempts += 1
			if candidate.ok:
				return candidate
			last_reason = candidate.reason
			least_cost = minf(least_cost, candidate.get("required_fuel", INF))
	if is_finite(least_cost):
		return {"ok": false, "reason": "燃料不足：已验证的候选至少需要 %.1f m/s Δv，现有 %.1f m/s Δv。" % [vessel.fuel_to_delta_v(least_cost), vessel.fuel_to_delta_v(vessel.fuel)], "required_fuel": least_cost}
	if int(budget.remaining) <= 0:
		return _failure("达到保守规划计算上限，未能完成安全整圈验证。")
	return _failure("保守规划未找到可行方案：" + last_reason)


static func _candidate(game, vessel, target, settings: Dictionary, coast: Array[Dictionary], start: int, speed_scale: float, budget: Dictionary) -> Dictionary:
	var position: Vector2 = coast[start].position
	var velocity: Vector2 = coast[start].velocity
	var commands: Array[float] = []
	var points := PackedVector2Array()
	for index in range(start):
		commands.append(0.0)
		if index % 4 == 0:
			points.append(coast[index].position)
	points.append(position)
	var fuel_cost := 0.0
	var captured := false
	for index in range(start, int(settings.limit)):
		var desired_speed := _circular_speed(target, position) * speed_scale
		var difference := desired_speed - velocity.length()
		# 先完成有限时长速率修正，再检查径向分量，不能靠关引力锁定半径。
		if absf(difference) <= maxf(0.05, desired_speed * 0.0002):
			captured = true
			break
		if int(budget.remaining) <= 0:
			return _failure("规划计算预算耗尽。")
		var command := clampf(difference / float(settings.step), -float(settings.deceleration), float(settings.acceleration))
		budget.remaining -= 1
		# 每步提供足够燃料求完整预算；接受计划前再检查实际库存。
		var state: Dictionary = game._propulsion_step(position, velocity, 1.0e12, settings.step, command, settings.heading, settings.coefficient)
		fuel_cost += absf(command) * float(settings.step) * float(settings.coefficient)
		position = state.position
		velocity = state.velocity
		commands.append(command)
		var reason := _unsafe_reason(game, target, position, settings.search_radius)
		if not reason.is_empty():
			return _failure(reason)
		if commands.size() % 4 == 0:
			points.append(position)
	if not captured:
		return _failure("在机动时限内不能完成速率修正。")
	var offset: Vector2 = position - target.flight_position
	var speed := velocity.length()
	var circular_speed := _circular_speed(target, position)
	if speed <= 0.01 or absf(velocity.dot(offset.normalized())) / speed > float(settings.tolerance) or absf(speed / circular_speed - 1.0) > float(settings.tolerance):
		return _failure("修正后径向速度或圆轨道速度误差过大。")
	points.append(position)
	var verification := _verify_orbit(game, target, position, velocity, settings, budget)
	if not verification.ok:
		return verification
	if fuel_cost > float(vessel.fuel) + 0.000001:
		return {"ok": false, "reason": "燃料不足。", "required_fuel": fuel_cost}
	points.append_array(verification.points)
	return {
		"ok": true, "reason": "已通过整圈无推力安全验证；有限候选保守方案，非全局最优。",
		"commands": commands, "fuel_cost": fuel_cost,
		"duration": commands.size() * float(settings.step),
		"final_radius": offset.length(), "points": points,
		"validation_duration": verification.duration,
		"radius_variation": verification.radius_variation,
	}


static func _verify_orbit(game, target, position: Vector2, velocity: Vector2, settings: Dictionary, budget: Dictionary) -> Dictionary:
	var offset: Vector2 = position - target.flight_position
	var initial_radius := offset.length()
	var minimum_radius := initial_radius
	var maximum_radius := initial_radius
	var direction := signf(offset.cross(velocity))
	if direction == 0.0:
		return _failure("没有足够的切向速度完成一圈。")
	var previous_angle := offset.angle()
	var swept_angle := 0.0
	var estimated_period := TAU * initial_radius / _circular_speed(target, position)
	var steps := mini(int(ceil(estimated_period * 1.5 / float(settings.step))), MAX_VERIFY_STEPS)
	var points := PackedVector2Array()
	for index in range(steps):
		if int(budget.remaining) <= 0:
			return _failure("整圈验证超过规划计算预算。")
		budget.remaining -= 1
		var next: Array = game._integrate(position, velocity, settings.step)
		position = next[0]
		velocity = next[1]
		var reason := _unsafe_reason(game, target, position, settings.search_radius)
		if not reason.is_empty():
			return _failure("滑行验证失败：" + reason)
		offset = position - target.flight_position
		minimum_radius = minf(minimum_radius, offset.length())
		maximum_radius = maxf(maximum_radius, offset.length())
		if (maximum_radius - minimum_radius) / initial_radius > MAX_RADIUS_VARIATION:
			return _failure("无推力滑行的轨道半径波动超过10%。")
		var angle := offset.angle()
		var increment := wrapf(angle - previous_angle, -PI, PI) * direction
		if increment <= 0.0 or signf(offset.cross(velocity)) != direction:
			return _failure("滑行轨迹不能保持同向绕行。")
		swept_angle += increment
		previous_angle = angle
		if index % 4 == 0:
			points.append(position)
		if swept_angle >= TAU:
			points.append(position)
			return {"ok": true, "points": points, "duration": (index + 1) * float(settings.step), "radius_variation": (maximum_radius - minimum_radius) / initial_radius}
	return _failure("在有界验证时限内未完成一整圈安全滑行。")


static func _unsafe_reason(game, target, position: Vector2, search_radius: float) -> String:
	if game._touches_planet(position):
		return "轨迹会撞击行星。"
	var radius: float = position.distance_to(target.flight_position)
	if radius > search_radius:
		return "轨迹超出目标中心搜索半径。"
	var own: Vector2 = target.acceleration_at(position)
	var strength := own.length()
	if strength <= 0.0:
		return "当前位置不在目标的有效引力范围内。"
	var perturbation := 0.0
	for source in game.planets:
		if source == target:
			continue
		var contribution: Vector2 = source.acceleration_at(position)
		perturbation += contribution.length()
	if perturbation / strength > MAX_PERTURBATION:
		return "其他引力源干扰过强，无法保证目标主导的稳定轨道。"
	return ""


static func _circular_speed(target, position: Vector2) -> float:
	var gravity: Vector2 = target.acceleration_at(position)
	return sqrt(gravity.length() * position.distance_to(target.flight_position))


static func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
