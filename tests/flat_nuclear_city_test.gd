extends SceneTree

const CityScene = preload("res://scenes/world/flat_nuclear_city.tscn")
const Session = preload("res://scripts/ports/port_session.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var city = CityScene.instantiate()
	var guide: Line2D = city.get_node("PortGuideLine")
	assert(guide.owner == city)
	assert(guide.points.size() == 2 and guide.points[0] == Vector2.ZERO)
	assert(guide.points[1].is_equal_approx(city.port_offset_m * city.pixels_per_meter))
	root.add_child(city)
	assert(guide.visible and guide.z_index < city.get_node("CityBody").z_index)
	assert(guide.default_color.a > 0.0 and guide.default_color.a < 0.7)
	assert(guide.get_child_count() == 0)
	var original_port: Vector2 = city.port_offset_m
	var original_pixels: float = city.pixels_per_meter
	city.port_offset_m = Vector2(-80000.0, 30000.0)
	assert(guide.points[1] == city.get_node("Port").position)
	city.pixels_per_meter = 0.002
	assert(guide.points[1] == city.port_offset_m * city.pixels_per_meter)
	city.dock_offset_m = Vector2(10000.0, -20000.0)
	assert(guide.points[1] == city.get_node("Port").position)
	city.dock_offset_m = Vector2(0.0, -5000.0)
	city.port_offset_m = original_port
	city.pixels_per_meter = original_pixels
	city.flight_position = Vector2(1000, 2000)
	assert(city.acceleration_at(city.flight_position + Vector2(0, -15000)) == Vector2(0, 9.81))
	assert(city.acceleration_at(city.flight_position + Vector2(0, 0)) == Vector2.ZERO)
	assert(city.contains_gravity_point(city.flight_position + Vector2(50000, -40000)))
	assert(city.contains_docking_point(city.flight_position + city.port_offset_m + Vector2(20000, 0)))
	assert(not city.contains_docking_point(city.flight_position + city.port_offset_m + Vector2(20001, 0)))
	assert(city.get_dock_position() == city.flight_position + city.port_offset_m + city.dock_offset_m)
	city.rotation_degrees_m = 90.0
	var angle := deg_to_rad(city.rotation_degrees_m)
	assert(is_equal_approx(city.rotation_degrees, 90.0))
	assert(guide.to_global(guide.points[0]).distance_to(city.global_position) < 0.01)
	assert(guide.to_global(guide.points[1]).distance_to(city.get_node("Port").global_position) < 0.01)
	assert(guide.to_global(guide.points[1]).distance_to(city.to_global(Vector2.ZERO) + (city.port_offset_m * city.pixels_per_meter).rotated(angle)) < 0.01)
	assert(city.contains_gravity_point(city.flight_position + Vector2(0, -15000).rotated(angle)))
	assert(city.acceleration_at(city.flight_position + Vector2(0, -15000).rotated(angle)).distance_to(Vector2(-9.81, 0)) < 0.001)
	assert(city.get_dock_position().distance_to(city.flight_position + (city.port_offset_m + city.dock_offset_m).rotated(angle)) < 0.01)
	assert(city.contains_docking_point(city.flight_position + city.port_offset_m.rotated(angle)))
	var session = Session.new()
	assert(session.open_planet(city.interaction_data_path))
	assert(session.get_state().credits == 1200)
	assert(not session.get_state().events.is_empty())
	# 港里现在有委托人（机库管理员）：无委托人物是旧数据形态，别再把有效数据判成坏的。
	assert(not session.get_state().persons.is_empty())
	assert(not session.has_method("collect_mineral"))
	city.free()
	print("flat_nuclear_city_test: PASS")
	quit()
