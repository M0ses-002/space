extends RefCounted
## 仅以指定行星的真实引力场给出瞬时圆轨道建议，不承诺多源下长期稳定。

static func suggest(source: Node, point: Vector2, clockwise: bool, other_sources: Array = []) -> Dictionary:
	if not is_instance_valid(source) or not source.has_method("acceleration_at") or not source.has_method("contains_gravity_point") or not point.is_finite():
		return {"ok": false, "reason": "无有效行星或位置。"}
	var offset: Vector2 = point - source.flight_position
	var radius := offset.length()
	if radius < 0.001:
		return {"ok": false, "reason": "位置位于行星中心，切向方向未定义。"}
	if radius <= source.radius_m + 0.1:
		return {"ok": false, "reason": "位置位于行星表面或内部，会发生碰撞。"}
	if not source.contains_gravity_point(point):
		return {"ok": false, "reason": "位置超出所选行星的最大引力范围。"}
	var outward := offset / radius
	var acceleration: Vector2 = source.acceleration_at(point)
	var radial := -acceleration.dot(outward)
	if not acceleration.is_finite() or not is_finite(radial) or radial <= 0.0:
		return {"ok": false, "reason": "当前位置没有有效向心引力。"}
	if (acceleration + outward * radial).length() > maxf(radial * 0.00001, 0.000001):
		return {"ok": false, "reason": "所选引力场并非指向行星中心。"}
	var reference := Vector2.ZERO
	# 当前行星固定；若后续提供速度属性，使用其惯性系速度。
	for property in source.get_property_list():
		if property.name == "flight_velocity":
			reference = source.get("flight_velocity")
			break
	if not reference.is_finite():
		return {"ok": false, "reason": "行星参考系速度无效。"}
	var speed := sqrt(radius * radial)
	var tangent := Vector2(-outward.y, outward.x) * (1.0 if clockwise else -1.0)
	var velocity := reference + tangent * speed
	if not velocity.is_finite() or absf(velocity.x) > 1e9 or absf(velocity.y) > 1e9:
		return {"ok": false, "reason": "建议速度超出地图允许范围。"}
	var perturbation := Vector2.ZERO
	var contributors := 0
	for other in other_sources:
		if not is_instance_valid(other) or other == source:
			continue
		var force: Vector2 = other.acceleration_at(point)
		perturbation += force
		if force.length_squared() > 0.0:
			contributors += 1
	return {"ok": true, "velocity": velocity, "relative_speed": speed, "radius": radius, "radial_acceleration": radial, "perturbation_ratio": perturbation.length() / radial, "other_source_count": contributors}
