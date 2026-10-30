extends Node2D
## 管理模拟、舰队注册与交互绑定；外观、布局与按钮模板定义在 .tscn 中。
## 编辑器布景原点（像素坐标），对应模拟世界的零点。首次读取行星/飞船节点布局时使用。
@export var layout_origin := Vector2(440.0, 360.0)
## 编辑器布景的换算比例：每米对应多少像素。仅用于首次初始化，物理计算不依赖窗口和相机。
@export var layout_pixels_per_meter := 0.004
var planets: Array[Node2D] = []
var cities: Array[Node2D] = []
const DOCK_SPEED_TOLERANCE := 0.1 # m/s
const SIM_STEP := 0.25
const TIME_SCALE := 20.0
const PREVIEW_REFRESH_INTERVAL := 0.1
const PREVIEW_SECONDS := 620.0
const PREVIEW_SAMPLE_STEPS := 4
const OrbitPlanner = preload("res://scripts/orbit_planner.gd")
const MapLoader = preload("res://scripts/map_loader.gd")
## 无 user:// 自定义地图时是否回退加载打包内置地图；实际游戏入口开启，最小场景保持默认内容。
@export var allow_builtin_map := false
var map_hash := ""
var map_load_error := false
const INITIAL_FUEL := 3200.0
const START_POSITION := Vector2(0.0, -62000.0)
const START_VELOCITY := Vector2(655.0, 0.0)

const SHIP_BUTTON := preload("res://scenes/ship_selector_button.tscn")
var ships: Array[Node2D] = []
var obstacles: Array[Node2D] = []
var stopped_obstacles: Dictionary = {}
var ship_buttons: Dictionary = {}
var ship: Node2D
# 当前控制对象的兼容访问，实际状态归各飞船实例所有。
var ship_position: Vector2:
	get: return ship.flight_position if is_instance_valid(ship) else Vector2.ZERO
	set(value):
		if is_instance_valid(ship): ship.flight_position = value
var ship_velocity: Vector2:
	get: return ship.flight_velocity if is_instance_valid(ship) else Vector2.ZERO
	set(value):
		if is_instance_valid(ship): ship.flight_velocity = value
var fuel_mass: float:
	get: return ship.fuel if is_instance_valid(ship) else 0.0
	set(value):
		if is_instance_valid(ship): ship.fuel = value
var selected := false
var crashed: bool:
	get: return ship.crashed if is_instance_valid(ship) else false
	set(value):
		if is_instance_valid(ship): ship.crashed = value
var simulation_paused := false
var selecting_orbit := false
var paused_before_selection := false
var orbit_candidates: Array[Node2D] = []
var pending_target: Node2D
var pending_plan: Dictionary = {}
var flight_message := ""
var simulation_speed := 1.0
var accumulator := 0.0
var preview_refresh_elapsed := 0.0
var preview_points := PackedVector2Array()
var preview_ship: Node2D
var preview_job: Dictionary = {}
const PREVIEW_STEPS_PER_FRAME := 400

@onready var fleet_buttons: HBoxContainer = $HUD/Root/FleetBar/Margin/Row/Scroll/Buttons
@onready var orbit_preview: Line2D = $World/OrbitPreview
@onready var panel: PanelContainer = $HUD/Root/FlightPanel
@onready var info_label: Label = $HUD/Root/FlightPanel/Margin/Content/Info
@onready var hint_label: Label = $HUD/Root/FlightPanel/Margin/Content/Hint
@onready var selection_status: Label = $HUD/Root/FlightPanel/Margin/Content/SelectionStatus
@onready var accelerate_button: Button = $HUD/Root/FlightPanel/Margin/Content/AccelerateButton
@onready var brake_button: Button = $HUD/Root/FlightPanel/Margin/Content/BrakeButton


@onready var mining_button: Button = $HUD/Root/FlightPanel/Margin/Content/MiningButton
@onready var stay_button: Button = $HUD/Root/FlightPanel/Margin/Content/StayButton
@onready var speed_row: HBoxContainer = $HUD/Root/FlightPanel/Margin/Content/SpeedRow

@onready var pause_button: Button = $HUD/Root/FlightPanel/Margin/Content/PauseButton
@onready var orbit_button: Button = $HUD/Root/FlightPanel/Margin/Content/OrbitButton
@onready var orbit_actions: HBoxContainer = $HUD/Root/FlightPanel/Margin/Content/OrbitActions

func _ready() -> void:
	$HUD/Root/ThrustDial.bind_game(self)
	# 明确绑定交互，编辑器保存/实例化不再依赖丢失的外部信号连接。
	accelerate_button.button_down.connect(_start_thrust.bind(1.0))
	brake_button.button_down.connect(_start_thrust.bind(-1.0))
	accelerate_button.button_up.connect(_stop_thrust)
	brake_button.button_up.connect(_stop_thrust)
	accelerate_button.mouse_exited.connect(_stop_thrust)
	brake_button.mouse_exited.connect(_stop_thrust)
	get_window().focus_exited.connect(_stop_thrust)
	pause_button.pressed.connect(_toggle_pause)
	orbit_button.pressed.connect(_begin_orbit_selection)
	orbit_actions.get_node("Confirm").pressed.connect(_confirm_orbit)
	orbit_actions.get_node("Cancel").pressed.connect(_cancel_orbit_selection)
	mining_button.pressed.connect(_toggle_mining)
	$HUD/Root/FlightPanel/Margin/Content/DepartButton.pressed.connect(_depart)
	$PortController.bind_game(self)
	# 原停留占位保留；确认入轨使用行星上的独立按钮。
	for index in range(4):
		speed_row.get_child(index).pressed.connect(_set_simulation_speed.bind([0.5, 1.0, 1.5, 2.0][index]))
	$HUD/Root/FlightPanel/Margin/Content/ResetButton.pressed.connect(_reset)
	var map_result := MapLoader.load_map(allow_builtin_map)
	var custom_map: Dictionary = map_result.map
	if not custom_map.is_empty():
		MapLoader.apply_map(self, custom_map)
		map_hash = custom_map.hash
	elif bool(map_result.error):
		map_load_error = true
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)
	for source in get_tree().get_nodes_in_group("gravity_sources"):
		_register_planet(source, true)
	for node in $World.get_children():
		if node.has_method("get_dock_position") and node.has_method("contains_docking_point"):
			_register_city(node, true)
	for candidate in get_tree().get_nodes_in_group("flight_ships"):
		_register_ship(candidate)
	for object in get_tree().get_nodes_in_group("flight_obstacles"):
		_register_obstacle(object)
	get_viewport().size_changed.connect(_sync_visuals)
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _on_node_added(node: Node) -> void:
	if node.has_method("get_dock_position") and node.has_method("contains_docking_point"):
		_register_city.call_deferred(node, false)
	elif node.is_in_group("flight_ships"):
		_register_ship.call_deferred(node)
	elif node.is_in_group("gravity_sources"):
		_register_planet.call_deferred(node, false)
	elif node.is_in_group("flight_obstacles"):
		_register_obstacle.call_deferred(node)


func _register_city(city: Node, from_editor: bool) -> void:
	if not is_instance_valid(city) or not city.is_inside_tree() or not $World.is_ancestor_of(city) or cities.has(city):
		return
	var canvas_position: Vector2 = $World.to_local(city.global_position)
	city.flight_position = (canvas_position - layout_origin) / maxf(layout_pixels_per_meter, 0.000001) if from_editor else (canvas_position - _screen_center()) / _view_scale()
	cities.append(city)
	city.get_node("DockButton").pressed.connect(_dock_city.bind(city))
	_sync_visuals()


func _register_obstacle(object: Node) -> void:
	if not is_instance_valid(object) or not object.is_inside_tree() or not $World.is_ancestor_of(object) or obstacles.has(object):
		return
	obstacles.append(object)
	_sync_visuals()


func _register_planet(source: Node, from_editor: bool) -> void:
	if not is_instance_valid(source) or not source.is_inside_tree() or not $World.is_ancestor_of(source) or planets.has(source):
		return
	var canvas_position: Vector2 = $World.to_local(source.global_position)
	if from_editor:
		source.flight_position = (canvas_position - layout_origin) / maxf(layout_pixels_per_meter, 0.000001)
	else:
		# 运行时添加的节点使用当前世界画布坐标（不是鼠标屏幕坐标）。
		source.flight_position = (canvas_position - _screen_center()) / _view_scale()
	planets.append(source)
	source.get_node("ConfirmArrival").pressed.connect(_confirm_arrival.bind(source))
	_refresh_preview()
	_sync_visuals()


func _register_ship(candidate: Node) -> void:
	if not is_instance_valid(candidate) or not candidate.is_inside_tree() or not $World.is_ancestor_of(candidate) or ships.has(candidate):
		return
	ships.append(candidate)
	$PortController.register_ship(candidate)
	candidate.region_source = _dominant_source(candidate.flight_position)
	if not is_instance_valid(ship):
		ship = candidate
	var button: Button = SHIP_BUTTON.instantiate()
	fleet_buttons.add_child(button)
	button.pressed.connect(_select_target.bind(candidate))
	candidate.get_node("SelectButton").pressed.connect(_select_target.bind(candidate))
	ship_buttons[candidate] = button
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _on_node_removed(node: Node) -> void:
	if node is Node2D and cities.has(node):
		cities.erase(node)
		return
	if node is Node2D and obstacles.has(node):
		obstacles.erase(node)
		stopped_obstacles.erase(node)
		return
	if node is Node2D and planets.has(node):
		planets.erase(node)
		orbit_candidates.erase(node)
		if pending_target == node:
			pending_target = null
			pending_plan.clear()
			flight_message = "入轨目标已移除，请重新选择。"
		if is_inside_tree() and is_instance_valid(orbit_preview) and orbit_preview.is_inside_tree():
			_refresh_preview()
		return
	if not node is Node2D or not ships.has(node) or not is_instance_valid(fleet_buttons) or not fleet_buttons.is_inside_tree():
		return
	ships.erase(node)
	var button: Button = ship_buttons[node]
	fleet_buttons.remove_child(button)
	button.queue_free()
	ship_buttons.erase(node)
	if ship == node:
		ship = ships[0] if not ships.is_empty() else null
		selected = false
	if not is_inside_tree():
		return
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _select_target(target: Node2D) -> void:
	if $PortController.active:
		return
	if not is_instance_valid(target) or not ships.has(target):
		return
	_stop_thrust()
	if selecting_orbit:
		_cancel_orbit_selection()
	flight_message = ""
	ship = target
	selected = true
	$StarMapView.on_ship_selected()
	if ship.voyage_finished and is_instance_valid(ship.arrival_source) and cities.has(ship.arrival_source):
		$PortController.enter_port(ship.arrival_source, ship)
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _process(_delta: float) -> void:
	_advance_preview_job()
	_sync_city_buttons()


func _physics_process(delta: float) -> void:
	for vessel in ships:
		_validate_navigation(vessel)
		_update_region(vessel, vessel.flight_position)
	if simulation_paused:
		return
	accumulator += delta * TIME_SCALE * simulation_speed
	preview_refresh_elapsed += delta
	while accumulator >= SIM_STEP:
		accumulator -= SIM_STEP
		var obstacle_paths: Dictionary = {}
		for object in obstacles:
			if object.destroyed:
				continue
			var start: Vector2 = object.flight_position
			if stopped_obstacles.has(object):
				object.flight_velocity = Vector2.ZERO
				obstacle_paths[object] = [start, start]
				continue
			for source in planets:
				var offset: Vector2 = start - source.flight_position
				if offset.length() < source.radius_m:
					start = source.flight_position + (offset.normalized() if offset.length_squared() > 0.0 else Vector2.RIGHT) * source.radius_m
					object.flight_velocity = Vector2.ZERO
			var next := _integrate(start, object.flight_velocity, SIM_STEP)
			object.flight_position = next[0]
			object.flight_velocity = next[1]
			if _touches_planet(object.flight_position):
				stopped_obstacles[object] = true
				object.flight_velocity = Vector2.ZERO
			obstacle_paths[object] = [start, next[0]]
		for vessel in ships:
			if vessel.crashed or vessel.voyage_finished:
				continue
			var command: float = vessel.manual_thrust * (vessel.get_effective_acceleration() if vessel.manual_thrust > 0.0 else vessel.get_effective_deceleration())
			if vessel.maneuver_index < vessel.maneuver_commands.size():
				if not is_instance_valid(vessel.maneuver_target) or not planets.has(vessel.maneuver_target) or vessel.maneuver_target.acceleration_at(vessel.flight_position).length_squared() <= 0.0:
					vessel.maneuver_commands.clear()
					flight_message = "目标已移除或已失去其有效引力，入轨机动取消。"
				else:
					command = vessel.maneuver_commands[vessel.maneuver_index]
					if vessel.fuel + 0.00001 < absf(command) * SIM_STEP * vessel.get_effective_propulsion_fuel_per_delta_v():
						vessel.maneuver_commands.clear()
						command = 0.0
						flight_message = "燃料不足，入轨机动中止。"
					else:
						vessel.maneuver_index += 1
						if vessel.maneuver_index == vessel.maneuver_commands.size():
							flight_message = "入轨机动已执行完成；继续自由绕行。"
			var previous_position: Vector2 = vessel.flight_position
			if is_instance_valid(vessel.departed_city) and not vessel.departed_city.contains_docking_point(previous_position):
				vessel.departed_city = null
			var state: Dictionary
			if vessel.steering:
				state = _steering_step(vessel, SIM_STEP)
				vessel.reset_orbit()
			else:
				state = _propulsion_step(vessel.flight_position, vessel.flight_velocity, vessel.fuel, SIM_STEP, command, vessel.heading, vessel.get_effective_propulsion_fuel_per_delta_v())
			if absf(command) > 0.0:
				vessel.reset_orbit()
			if state.velocity.length() > 0.01:
				vessel.heading = state.velocity.normalized()
			vessel.flight_position = state.position
			vessel.flight_velocity = state.velocity
			vessel.fuel = state.fuel
			var first_hit: Node2D
			var first_fraction := INF
			for object in obstacle_paths:
				if not is_instance_valid(object) or object.destroyed or not object.is_in_group("space_debris"):
					continue
				var path: Array = obstacle_paths[object]
				var fraction := _swept_fraction(previous_position - path[0], vessel.flight_position - path[1], maxf(object.radius_m, 0.0))
				if fraction >= 0.0 and fraction < first_fraction:
					first_fraction = fraction
					first_hit = object
			if is_instance_valid(first_hit):
				vessel.flight_position = previous_position.lerp(vessel.flight_position, first_fraction)
				first_hit.hit_ship(vessel)
				if vessel == ship:
					flight_message = vessel.navigation_status
			vessel.current_voyage_distance_m += previous_position.distance_to(vessel.flight_position)
			_update_region(vessel, previous_position)
			if _touches_planet(vessel.flight_position):
				vessel.crashed = true
				vessel.steering = false
				vessel.thrust_throttle = 0.0
				vessel.manual_thrust = 0.0
				vessel.navigation_status = "飞船撞击损毁，请重置航行。"
				vessel.flight_velocity = Vector2.ZERO
			if vessel.crashed:
				vessel.mining_enabled = false
			elif vessel.mining_enabled:
				_mining_step(vessel, SIM_STEP)
			vessel.track_orbit(_dominant_source(vessel.flight_position), _gravity_at(vessel.flight_position))
	if preview_refresh_elapsed >= PREVIEW_REFRESH_INTERVAL or crashed:
		preview_refresh_elapsed = 0.0
		if preview_job.is_empty() or crashed:
			_refresh_preview()
	_update_ui()
	_sync_visuals()


func _toggle_mining() -> void:
	if not selected or not is_instance_valid(ship) or ship.crashed or ship.voyage_finished or selecting_orbit:
		return
	ship.mining_enabled = not ship.mining_enabled
	ship.mining_progress = 0.0
	ship.mining_target = null
	_update_ui()
	_sync_visuals()


func _mining_step(vessel: Node2D, step: float) -> void:
	var target: Node2D
	for object in obstacles:
		if object.has_method("get_mineral_id") and not object.destroyed and is_finite(object.mineral_unit_mass) and object.mineral_unit_mass > 0.0 and object.mass_kg >= object.mineral_unit_mass and vessel.flight_position.distance_to(object.flight_position) <= vessel.mining_radius_m + object.radius_m:
			target = object
			break
	if target != vessel.mining_target:
		vessel.mining_target = target
		vessel.mining_progress = 0.0
	if not is_instance_valid(target):
		return
	vessel.mining_progress += maxf(vessel.mining_rate_kg_s, 0.0) * step
	var unit_mass: float = target.mineral_unit_mass
	if not is_finite(unit_mass) or unit_mass <= 0.0:
		return
	var units := int(minf(1000000000.0, floor(minf(vessel.mining_progress, target.mass_kg) / unit_mass)))
	if units <= 0:
		return
	var collected: int = $PortController.add_mined_cargo(vessel, target.get_mineral_id(), units, unit_mass)
	if collected <= 0:
		vessel.mining_enabled = false
		vessel.mining_progress = 0.0
		return
	var extracted := collected * unit_mass
	vessel.mining_progress -= extracted
	var old_mass: float = target.mass_kg
	target.mass_kg = maxf(0.0, old_mass - extracted)
	target.radius_m *= pow(target.mass_kg / old_mass, 1.0 / 3.0)
	if target.mass_kg == 0.0:
		target.radius_m = 0.0
		target.destroyed = true
	if collected < units:
		vessel.mining_enabled = false
		vessel.mining_progress = 0.0


func _set_simulation_speed(value: float) -> void:
	if value not in [0.5, 1.0, 1.5, 2.0]:
		return
	simulation_speed = value
	for index in range(4):
		speed_row.get_child(index).set_pressed_no_signal(is_equal_approx(value, [0.5, 1.0, 1.5, 2.0][index]))
	$HUD/Root/FlightPanel/Margin/Content/Reference.text = "WASD 移动 · 滚轮缩放\n运行 %.1f× · 基础 20 模拟秒/秒\n预演 %.0f s · 耗油按模拟秒" % [value, get_preview_horizon()]


func _dominant_source(position: Vector2) -> Node2D:
	var result: Node2D
	var strongest := 0.0
	for source in planets:
		var strength: float = source.acceleration_at(position).length()
		if strength > strongest:
			strongest = strength
			result = source
	return result


func _gravity_at(position: Vector2) -> Vector2:
	var acceleration := Vector2.ZERO
	for source in planets:
		acceleration += source.acceleration_at(position)
	for city in cities:
		if is_instance_valid(city):
			acceleration += city.acceleration_at(position)
	return acceleration


func _touches_planet(position: Vector2) -> bool:
	for source in planets:
		if position.distance_to(source.flight_position) <= source.radius_m + 0.1:
			return true
	for city in cities:
		if is_instance_valid(city):
			var local: Vector2 = position - city.flight_position
			if absf(local.x) <= city.city_size_m.x * 0.5 + 0.1 and absf(local.y) <= city.city_size_m.y * 0.5 + 0.1:
				return true
	return false


# 相对位移上的圆形扫掠，返回首次接触时刻；-1 表示未接触。
func _swept_fraction(start: Vector2, end: Vector2, radius: float) -> float:
	var c := start.length_squared() - radius * radius
	if c <= 0.0:
		return 0.0
	var movement := end - start
	var a := movement.length_squared()
	if a < 0.000001:
		return -1.0
	var b := 2.0 * start.dot(movement)
	var discriminant := b * b - 4.0 * a * c
	if discriminant < 0.0:
		return -1.0
	var fraction := (-b - sqrt(discriminant)) / (2.0 * a)
	return fraction if fraction >= 0.0 and fraction <= 1.0 else -1.0


# 同一步内扫过多个星体时取最早接触点，避免高速穿透。
func _collision_fraction(start: Vector2, end: Vector2) -> float:
	var earliest := 1.0
	var movement := end - start
	var a := movement.length_squared()
	for source in planets:
		var offset: Vector2 = start - source.flight_position
		var c: float = offset.length_squared() - source.radius_m * source.radius_m
		if c <= 0.0:
			return 0.0
		if a < 0.000001:
			continue
		var b := 2.0 * offset.dot(movement)
		var discriminant := b * b - 4.0 * a * c
		if discriminant < 0.0:
			continue
		var fraction := (-b - sqrt(discriminant)) / (2.0 * a)
		if fraction >= 0.0 and fraction <= earliest:
			earliest = fraction
	for city in cities:
		if is_instance_valid(city):
			var interval := _rectangle_interval(start, end, city.flight_position, city.city_size_m * 0.5)
			if not interval.is_empty():
				earliest = minf(earliest, interval[0])
	return earliest


# 返回线段在矩形内的参数区间，空数组表示没有交集。
func _rectangle_interval(start: Vector2, end: Vector2, center: Vector2, half_size: Vector2) -> Array[float]:
	var local := start - center
	var delta := end - start
	var enter := 0.0
	var exit := 1.0
	for axis in range(2):
		if absf(delta[axis]) < 0.000001:
			if absf(local[axis]) > half_size[axis]:
				return []
		else:
			var a := (-half_size[axis] - local[axis]) / delta[axis]
			var b := (half_size[axis] - local[axis]) / delta[axis]
			enter = maxf(enter, minf(a, b))
			exit = minf(exit, maxf(a, b))
			if enter > exit:
				return []
	return [enter, exit]


# 实飞与预览共用引力叠加、固定步长半隐式欧拉及全行星撞击裁剪。
func _integrate(position: Vector2, velocity: Vector2, step: float) -> Array[Vector2]:
	# 普通航行维持原固定步；跨引力边界按扫掠交点分段，避免两端圈外漏算整段引力。
	var projected_end := position + (velocity + _gravity_at(position) * step) * step
	var cuts: Array[float] = [0.0, 1.0]
	for source in planets:
		for fraction in _circle_crossings(position, projected_end, source.flight_position, source.max_gravity_radius_m):
			if fraction > 0.000001 and fraction < 0.999999:
				cuts.append(fraction)
	for city in cities:
		if is_instance_valid(city):
			var center: Vector2 = city.flight_position + Vector2(0.0, -(city.city_size_m.y + city.gravity_height_m) * 0.5)
			var bounds := _rectangle_interval(position, projected_end, center, Vector2(city.city_size_m.x, city.gravity_height_m) * 0.5)
			for fraction in bounds:
				if fraction > 0.000001 and fraction < 0.999999:
					cuts.append(fraction)
	cuts.sort()
	for index in range(1, cuts.size()):
		var interval := step * (cuts[index] - cuts[index - 1])
		if interval <= 0.0:
			continue
		var sample := position if cuts.size() == 2 and cities.is_empty() else position + velocity * interval * 0.5
		# 快速穿越时再细分，各段最大行程约为最小星体半径的1/4；上限约束极端输入。
		var slices := 1
		if cuts.size() > 2:
			for source in planets:
				slices = maxi(slices, mini(128, int(ceil(velocity.length() * interval / maxf(source.radius_m * 0.25, 1.0)))))
		var dt := interval / slices
		for substep in range(slices):
			if cuts.size() > 2:
				sample = position + velocity * dt * 0.5
			var new_velocity := velocity + _gravity_at(sample) * dt
			var end := position + new_velocity * dt
			var fraction := _collision_fraction(position, end)
			if fraction < 1.0 or _touches_planet(end):
				return [position.lerp(end, fraction), Vector2.ZERO]
			position = end
			velocity = new_velocity
	return [position, velocity]


func _circle_crossings(start: Vector2, end: Vector2, center: Vector2, radius: float) -> Array[float]:
	var result: Array[float] = []
	var delta := end - start
	var a := delta.length_squared()
	if a < 0.000001:
		return result
	var offset := start - center
	var b := 2.0 * offset.dot(delta)
	var discriminant := b * b - 4.0 * a * (offset.length_squared() - radius * radius)
	if discriminant < 0.0:
		return result
	for value in [(-b - sqrt(discriminant)) / (2.0 * a), (-b + sqrt(discriminant)) / (2.0 * a)]:
		if value >= 0.0 and value <= 1.0:
			result.append(value)
	return result


func get_preview_horizon() -> float:
	var map_view := get_node_or_null("StarMapView")
	if map_view != null and map_view.is_initialized and map_view.map_mode:
		return map_view.preview_seconds
	return PREVIEW_SECONDS * (1.5 if is_instance_valid(ship) and ship.upgrade_slots.has("computer") else 1.0)


func _preview_world_state() -> Array:
	var state: Array = []
	for source in planets:
		if is_instance_valid(source):
			state.append([source, source.flight_position, source.radius_m, source.field_height_m, source.surface_gravity, source.max_gravity_radius_m])
	for city in cities:
		if is_instance_valid(city):
			state.append([city, city.flight_position, city.city_size_m, city.gravity_height_m])
	return state


func _refresh_preview() -> void:
	preview_job.clear()
	if preview_ship != ship:
		preview_points.clear()
		preview_ship = ship
	if not is_instance_valid(ship) or crashed or ship.voyage_finished:
		preview_points.clear()
		return
	var map_view := get_node_or_null("StarMapView")
	var map_mode: bool = map_view != null and map_view.is_initialized and map_view.map_mode
	preview_job = {
		"ship": ship, "map_mode": map_mode, "paused": simulation_paused, "world": _preview_world_state(),
		"position": ship_position, "velocity": ship_velocity, "fuel": fuel_mass,
		"heading": ship.heading, "coefficient": ship.get_effective_propulsion_fuel_per_delta_v(),
		"commands": ship.maneuver_commands.duplicate(), "command_index": ship.maneuver_index,
		"index": 0, "steps": int(get_preview_horizon() / SIM_STEP),
		"points": PackedVector2Array([ship_position])
	}
	if not map_mode:
		_advance_preview_job(int(get_preview_horizon() / SIM_STEP))


func _advance_preview_job(budget: int = PREVIEW_STEPS_PER_FRAME) -> void:
	if preview_job.is_empty():
		return
	var vessel = preview_job.ship
	if not is_instance_valid(vessel) or vessel != ship or vessel.crashed or vessel.voyage_finished:
		preview_job.clear()
		preview_points.clear()
		return
	var map_view := get_node_or_null("StarMapView")
	var map_mode: bool = map_view != null and map_view.is_initialized and map_view.map_mode
	if vessel.maneuver_commands != preview_job.commands or simulation_paused != preview_job.paused or map_mode != preview_job.map_mode or _preview_world_state() != preview_job.world:
		_refresh_preview()
		return
	var position: Vector2 = preview_job.position
	var velocity: Vector2 = preview_job.velocity
	var fuel: float = preview_job.fuel
	var heading: Vector2 = preview_job.heading
	var points: PackedVector2Array = preview_job.points
	var index: int = preview_job.index
	var finished := false
	for unused in range(budget):
		if index >= preview_job.steps:
			finished = true
			break
		var command_index: int = preview_job.command_index + index
		var command: float = preview_job.commands[command_index] if command_index < preview_job.commands.size() else 0.0
		if command == 0.0:
			var next := _integrate(position, velocity, SIM_STEP)
			position = next[0]
			velocity = next[1]
		else:
			var state: Dictionary = _propulsion_step(position, velocity, fuel, SIM_STEP, command, heading, preview_job.coefficient)
			position = state.position
			velocity = state.velocity
			fuel = state.fuel
		if velocity.length() > 0.01:
			heading = velocity.normalized()
		index += 1
		if _touches_planet(position):
			points.append(position)
			finished = true
			break
		if index % PREVIEW_SAMPLE_STEPS == 0:
			points.append(position)
	if finished or index >= preview_job.steps:
		preview_points = points
		preview_job.clear()
		_sync_visuals()
	else:
		preview_job.position = position
		preview_job.velocity = velocity
		preview_job.fuel = fuel
		preview_job.heading = heading
		preview_job.points = points
		preview_job.index = index


func _view_scale() -> float:
	return maxf(0.0001, minf((get_viewport_rect().size.x - panel.size.x - 40.0) / 170000.0, get_viewport_rect().size.y / 170000.0))


func _screen_center() -> Vector2:
	return Vector2((get_viewport_rect().size.x - panel.size.x) * 0.5, get_viewport_rect().size.y * 0.5)


func _to_screen(world_position: Vector2) -> Vector2:
	return _screen_center() + world_position * _view_scale()


func _sync_visuals() -> void:
	if not is_node_ready():
		return
	for source in planets:
		# 显示映射绝不写回物理坐标；窗口变化不会改变天体间距。
		source.global_position = $World.to_global(_to_screen(source.flight_position))
		source.scale = Vector2.ONE * source.radius_m * _view_scale() / 200.0
		source.update_boundary()
		source.get_node("OrbitHighlight").visible = selecting_orbit and orbit_candidates.has(source)
	for city in cities:
		if is_instance_valid(city):
			city.global_position = $World.to_global(_to_screen(city.flight_position))
			city.scale = Vector2.ONE * _view_scale() / maxf(city.pixels_per_meter, 0.000001)
	for object in obstacles:
		object.global_position = $World.to_global(_to_screen(object.flight_position))
		object.sync_view($StarMapView.map_mode, _view_scale())
	for vessel in ships:
		vessel.position = _to_screen(vessel.flight_position)
		vessel.get_node("Visual").rotation = vessel.flight_velocity.angle()
		vessel.get_node("Visual").modulate = Color("e48579") if vessel.crashed else Color.WHITE
		vessel.mining_view_scale = _view_scale()
		vessel._update_mining_range()
		vessel.get_node("SelectionRing").visible = selected and vessel == ship
		vessel.get_node("SelectButton").disabled = false
	var mapped := PackedVector2Array()
	var display_points: PackedVector2Array = pending_plan.points if selecting_orbit and pending_plan.get("ok", false) else preview_points
	for point in display_points:
		mapped.append(_to_screen(point))
	orbit_preview.points = mapped
	$StarMapView.sync_visuals()


func _select_ship() -> void:
	if is_instance_valid(ship):
		_select_target(ship)


func _accelerate() -> void:
	_start_thrust(1.0)


func _brake() -> void:
	_start_thrust(-1.0)


func _start_thrust(direction: float) -> void:
	if simulation_paused or selecting_orbit or not selected or not is_instance_valid(ship) or crashed or ship.voyage_finished or fuel_mass <= 0.0:
		return
	_stop_thrust()
	ship.maneuver_commands.clear()
	ship.manual_thrust = direction
	ship.reset_orbit()
	flight_message = ""
	_refresh_preview()
	_update_ui()


func _stop_thrust() -> void:
	for vessel in ships:
		vessel.manual_thrust = 0.0
		if vessel.steering:
			vessel.navigation_status = "修向已停止，按当前速度惯性滑行。"
		vessel.steering = false
		vessel.thrust_throttle = 0.0


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		# 长按顺逆推仍随松手结束；油门是持续设定，不能被仪表拖动释放清零。
		for vessel in ships:
			vessel.manual_thrust = 0.0


func _can_confirm_arrival(source: Node2D) -> bool:
	return selected and is_instance_valid(ship) and not ship.voyage_finished and not ship.crashed and not ship.steering and ship.manual_thrust == 0.0 and ship.maneuver_index >= ship.maneuver_commands.size() and not selecting_orbit and is_instance_valid(source) and planets.has(source) and ship.orbit_source == source and ship.stay_available


func _sync_arrival_buttons() -> void:
	for source in planets:
		var button: Button = source.get_node("ConfirmArrival")
		button.visible = _can_confirm_arrival(source)
		# 抵消行星自身缩放和相机缩放，按钮始终保持屏幕像素大小。
		var inverse_scale: float = 1.0 / maxf(absf(source.global_scale.x) * $NavigationCamera.zoom.x, 0.000001)
		button.scale = Vector2.ONE * inverse_scale
		button.position = -button.size * inverse_scale * 0.5


func _confirm_arrival(source: Node2D) -> void:
	if not _can_confirm_arrival(source):
		return
	# 点击时复核当前轨道，避免过期资格或编辑器调整后仍可确认。
	ship.track_orbit(_dominant_source(ship_position), _gravity_at(ship_position))
	if not _can_confirm_arrival(source):
		_sync_arrival_buttons()
		return
	_stop_thrust()
	ship.departure_position = ship_position
	ship.departure_velocity = ship_velocity
	ship.arrival_source = source
	ship.voyage_finished = true
	ship.last_voyage_distance_m = ship.current_voyage_distance_m
	ship.completed_voyage_count += 1
	ship.mining_enabled = false
	ship.mining_progress = 0.0
	ship.flight_velocity = Vector2.ZERO
	ship.maneuver_commands.clear()
	ship.reset_orbit()
	ship.navigation_status = "本次航行已结束；可在港口购买燃料，起航仅恢复原轨道。"
	flight_message = ship.navigation_status
	_refresh_preview()
	_update_ui()
	_sync_visuals()
	$PortController.enter_port(source, ship)


func _depart() -> void:
	if not selected or not is_instance_valid(ship) or not ship.voyage_finished:
		return
	if not $PortController.can_depart(ship):
		flight_message = "请先在贸易页结清本航程生活补给；若港口数据异常，请重置航行。"
		_update_ui()
		return
	var city_departure := is_instance_valid(ship.arrival_source) and cities.has(ship.arrival_source)
	if not city_departure and (not is_instance_valid(ship.arrival_source) or not planets.has(ship.arrival_source) or ship.arrival_source.acceleration_at(ship.departure_position).length_squared() <= 0.0 or _touches_planet(ship.departure_position)):
		flight_message = "原轨道参考行星失效，无法起航；请重置航行。"
		_update_ui()
		return
	if not city_departure:
		ship.flight_position = ship.departure_position
	ship.flight_velocity = Vector2.ZERO if city_departure else ship.departure_velocity
	ship.departed_city = ship.arrival_source if city_departure else null
	ship.voyage_finished = false
	ship.current_voyage_distance_m = 0.0
	ship.arrival_source = null
	ship.reset_orbit()
	ship.navigation_status = "已从城市停靠位置起航。" if city_departure else ("已起航：恢复原轨道，保留当前燃料。" if ship.fuel > 0.0 else "警告：零燃料起航，只能按原轨道无动力滑行。")
	flight_message = ship.navigation_status
	$PortController.leave_port()
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _toggle_pause() -> void:
	if selecting_orbit:
		flight_message = "请先确认或取消入轨选星。"
	else:
		simulation_paused = not simulation_paused
	_stop_thrust()
	_update_ui()


func _can_dock_city(city: Node2D) -> bool:
	return selected and is_instance_valid(ship) and is_instance_valid(city) and cities.has(city) and not $PortController.active and not selecting_orbit and not ship.crashed and not ship.voyage_finished and ship.departed_city != city and city.contains_docking_point(ship.flight_position) and ship.flight_velocity.length_squared() <= DOCK_SPEED_TOLERANCE * DOCK_SPEED_TOLERANCE and not _touches_planet(ship.flight_position)


func _sync_city_buttons() -> void:
	for city in cities:
		if not is_instance_valid(city):
			continue
		var button: Button = city.get_node("DockButton")
		button.visible = _can_dock_city(city)
		var inverse_scale: float = 1.0 / maxf(absf(city.global_scale.x) * $NavigationCamera.zoom.x, 0.000001)
		button.scale = Vector2.ONE * inverse_scale
		button.position = (city.port_offset_m + city.dock_offset_m) * city.pixels_per_meter - button.size * inverse_scale * 0.5


func _dock_city(city: Node2D) -> void:
	if not _can_dock_city(city):
		_sync_city_buttons()
		return
	_stop_thrust()
	_finish_city_arrival(ship, city)
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _begin_orbit_selection() -> void:
	if not selected or not is_instance_valid(ship) or crashed or ship.voyage_finished:
		return
	if ship.maneuver_index < ship.maneuver_commands.size():
		ship.maneuver_commands.clear()
		flight_message = "已取消入轨；保留已产生的速度和已消耗的燃料。"
		_update_ui()
		return
	_stop_thrust()
	paused_before_selection = simulation_paused
	simulation_paused = true
	selecting_orbit = true
	pending_plan.clear()
	pending_target = null
	orbit_candidates.clear()
	for source in planets:
		if ship_position.distance_to(source.flight_position) <= ship.orbit_search_radius and source.acceleration_at(ship_position).length_squared() > 0.0:
			orbit_candidates.append(source)
	flight_message = "点击高亮行星，计算顺逆推入轨方案。" if not orbit_candidates.is_empty() else "搜索范围内没有提供有效引力的行星，可取消后接近目标。"
	_update_ui()
	_sync_visuals()


func _choose_orbit_target(target: Node2D) -> void:
	if not selecting_orbit or not orbit_candidates.has(target) or not planets.has(target):
		return
	pending_target = target
	pending_plan = OrbitPlanner.plan(self, ship, target)
	if pending_plan.get("ok", false):
		flight_message = "预计 %.1f 模拟秒 / %.1f m/s Δv\n最终高度 %.2f km，确认后恢复运行。" % [pending_plan.duration, ship.fuel_to_delta_v(pending_plan.fuel_cost), (pending_plan.final_radius - target.radius_m) / 1000.0]
	else:
		flight_message = pending_plan.get("reason", "未找到安全入轨方案。")
	_update_ui()
	_sync_visuals()


func _cancel_orbit_selection() -> void:
	if not selecting_orbit:
		return
	selecting_orbit = false
	simulation_paused = paused_before_selection
	pending_plan.clear()
	pending_target = null
	orbit_candidates.clear()
	flight_message = "已取消选星，未扣油。"
	_update_ui()
	_sync_visuals()


func _confirm_orbit() -> void:
	if not selecting_orbit or not is_instance_valid(pending_target) or not planets.has(pending_target):
		return
	# 再计算一次，避免检查器编辑/状态变化使旧预算失效。
	pending_plan = OrbitPlanner.plan(self, ship, pending_target)
	if not pending_plan.get("ok", false):
		flight_message = pending_plan.get("reason", "方案已失效。")
		_update_ui()
		return
	ship.maneuver_commands = pending_plan.commands.duplicate()
	ship.maneuver_index = 0
	ship.maneuver_target = pending_target
	ship.reset_orbit()
	selecting_orbit = false
	simulation_paused = false
	orbit_candidates.clear()
	flight_message = "执行顺逆推入轨，可点击取消入轨中断。"
	pending_plan.clear()
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _unhandled_input(event: InputEvent) -> void:
	if $PortController.active:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if selecting_orbit:
			_cancel_orbit_selection()
		else:
			var pause_menu := get_node_or_null("PauseMenu")
			if pause_menu and pause_menu.has_method("toggle"):
				pause_menu.toggle()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if selecting_orbit:
			var mouse_world: Vector2 = get_canvas_transform().affine_inverse() * event.position
			for source in orbit_candidates:
				if is_instance_valid(source) and mouse_world.distance_to(source.global_position) <= source.radius_m * _view_scale():
					_choose_orbit_target(source)
					break
			return
		if $StarMapView.map_mode and selected and is_instance_valid(ship):
			var canvas_point: Vector2 = $World.to_local(get_canvas_transform().affine_inverse() * event.position)
			var meters := (canvas_point - _screen_center()) / _view_scale()
			var target_planet: Node2D
			for source in planets:
				var screen_point: Vector2 = get_canvas_transform() * source.global_position
				if event.position.distance_to(screen_point) <= maxf(18.0, source.radius_m * _view_scale() * $NavigationCamera.zoom.x):
					target_planet = source
					meters = source.flight_position
					break
			_set_navigation_target(meters, target_planet)
			get_viewport().set_input_as_handled()
			return
		_stop_thrust()
		flight_message = ""
		selected = false
		_update_ui()
		_sync_visuals()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_reset()


func _set_navigation_target(point: Vector2, target_planet: Node2D = null) -> void:
	if not selected or not is_instance_valid(ship) or selecting_orbit:
		return
	ship.navigation_target = point
	ship.navigation_planet = target_planet
	ship.navigation_tracks_planet = is_instance_valid(target_planet)
	ship.has_navigation_target = true
	ship.navigation_status = "已标记星心：不会自动避撞或制动，建议瞄准星体旁的空间点。" if is_instance_valid(target_planet) else "目标仅作导航参考；推力由仪表方向与油门控制。"
	_sync_visuals()


func _clear_navigation_target() -> void:
	_stop_thrust()
	if is_instance_valid(ship):
		ship.has_navigation_target = false
		ship.navigation_planet = null
		ship.navigation_tracks_planet = false
		ship.navigation_status = "目标已清除；保持当前速度。"
	_sync_visuals()


func _validate_navigation(vessel: Node2D) -> void:
	# 空间点允许永久保留；行星引用被释放时不能把旧位置当作仍有效的行星目标。
	if vessel.navigation_tracks_planet:
		if not is_instance_valid(vessel.navigation_planet) or not planets.has(vessel.navigation_planet):
			vessel.navigation_planet = null
			vessel.navigation_tracks_planet = false
			vessel.has_navigation_target = false
			vessel.navigation_status = "导航标记已失效；手动推力方向不受影响。"
		else:
			vessel.navigation_target = vessel.navigation_planet.flight_position
	if vessel.crashed or vessel.fuel <= 0.0:
		if vessel.steering:
			vessel.navigation_status = "修向停止：损毁或燃料不足。"
		vessel.steering = false
		vessel.thrust_throttle = 0.0


func _set_thrust_direction(direction: Vector2) -> void:
	if not selected or not is_instance_valid(ship) or selecting_orbit or direction.length_squared() < 0.000001:
		return
	ship.thrust_direction = direction.normalized()


func _set_throttle(value: float) -> void:
	if not is_instance_valid(ship):
		return
	if value <= 0.0:
		_stop_thrust()
		return
	if simulation_paused or selecting_orbit or not selected or crashed or ship.voyage_finished or fuel_mass <= 0.0 or ship.get_effective_steering_acceleration() <= 0.0:
		return
	ship.manual_thrust = 0.0
	ship.maneuver_commands.clear()
	ship.thrust_throttle = clampf(value, 0.0, 1.0)
	ship.steering = true
	ship.reset_orbit()
	ship.navigation_status = "手动推力持续生效；油门归零停止。"


func _finish_city_arrival(vessel: Node2D, city: Node2D) -> void:
	vessel.departure_position = vessel.flight_position
	vessel.departure_velocity = Vector2.ZERO
	vessel.arrival_source = city
	vessel.voyage_finished = true
	vessel.last_voyage_distance_m = vessel.current_voyage_distance_m
	vessel.completed_voyage_count += 1
	vessel.mining_enabled = false
	vessel.mining_progress = 0.0
	vessel.flight_velocity = Vector2.ZERO
	vessel.maneuver_commands.clear()
	vessel.reset_orbit()
	vessel.navigation_status = "已停靠城市港口。"
	if vessel == ship and selected and not $PortController.active:
		flight_message = vessel.navigation_status
		$PortController.enter_port(city, vessel)


func _steering_step(vessel: Node2D, step: float) -> Dictionary:
	var delta_v := maxf(0.0, vessel.get_effective_steering_acceleration()) * clampf(vessel.thrust_throttle, 0.0, 1.0) * step
	var coefficient := maxf(vessel.get_effective_propulsion_fuel_per_delta_v(), 0.000001)
	delta_v = minf(delta_v, maxf(0.0, vessel.fuel) / coefficient)
	var velocity: Vector2 = vessel.flight_velocity + vessel.thrust_direction.normalized() * delta_v
	var fuel: float = maxf(0.0, vessel.fuel - delta_v * coefficient)
	if fuel <= 0.0:
		vessel.steering = false
		vessel.thrust_throttle = 0.0
		vessel.navigation_status = "燃料耗尽，惯性滑行。"
	var next := _integrate(vessel.flight_position, velocity, step)
	return {"position": next[0], "velocity": next[1], "fuel": fuel}


func _update_region(vessel: Node2D, previous_position: Vector2) -> void:
	var old_source: Node2D
	if is_instance_valid(vessel.region_source):
		old_source = vessel.region_source
	var next_source: Node2D = old_source
	# 只稳定显示归属，不筛选引力：所有有效星体仍参与合力计算。
	if not is_instance_valid(old_source) or not planets.has(old_source) or not old_source.contains_gravity_point(vessel.flight_position):
		next_source = _dominant_source(vessel.flight_position)
	if next_source != old_source:
		vessel.region_source = next_source
		vessel.region_event = "进入 %s 引力区（不等于入轨）" % next_source.display_name if is_instance_valid(next_source) else "已离开行星引力区，星际滑行。"
	elif not is_instance_valid(next_source):
		vessel.region_source = null
	# 一步从圈外穿到圈外仍报告掠过，但不切到已经离开的局部镜头。
	for source in planets:
		if not source.contains_gravity_point(previous_position) and not source.contains_gravity_point(vessel.flight_position):
			if _circle_crossings(previous_position, vessel.flight_position, source.flight_position, source.max_gravity_radius_m).size() == 2:
				vessel.region_event = "高速掠过 %s 引力区；未停靠。" % source.display_name


func _propulsion_step(position: Vector2, velocity: Vector2, fuel: float, step: float, accel_command: float, heading: Vector2, fuel_coefficient: float) -> Dictionary:
	var coefficient := maxf(fuel_coefficient, 0.000001)
	var delta_v := minf(absf(accel_command) * step, maxf(fuel, 0.0) / coefficient)
	if accel_command < 0.0:
		delta_v = minf(delta_v, velocity.length())
	var direction := velocity.normalized() if velocity.length() > 0.00001 else heading.normalized()
	velocity += direction * delta_v * signf(accel_command)
	fuel = maxf(0.0, fuel - delta_v * coefficient)
	var next := _integrate(position, velocity, step)
	return {"position": next[0], "velocity": next[1], "fuel": fuel}


func _reset() -> void:
	$PortController.leave_port()
	$NavigationCamera.reset_view()
	simulation_paused = false
	selecting_orbit = false
	orbit_candidates.clear()
	pending_plan.clear()
	pending_target = null
	flight_message = ""
	_set_simulation_speed(1.0)
	for vessel in ships:
		vessel.reset_flight()
		vessel.region_source = _dominant_source(vessel.flight_position)
	stopped_obstacles.clear()
	for object in obstacles:
		object.reset_motion()
	$PortController.reset_fleet()
	$StarMapView.reset_view()
	selected = false
	accumulator = 0.0
	preview_refresh_elapsed = 0.0
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _update_ui() -> void:
	$HUD/Root/FlightPanel/Margin/Content/DepartButton.visible = false # 起航统一由行星交互场景提供。
	_sync_arrival_buttons()
	_sync_city_buttons()
	pause_button.text = "继续" if simulation_paused else "暂停"
	orbit_actions.visible = selecting_orbit
	orbit_actions.get_node("Confirm").disabled = not pending_plan.get("ok", false)
	orbit_button.visible = selected and is_instance_valid(ship)
	fleet_buttons.get_node("Empty").visible = ships.is_empty()
	for index in range(ships.size()):
		var vessel := ships[index]
		var button: Button = ship_buttons[vessel]
		button.text = "%02d · %s%s" % [index + 1, vessel.display_name, "（损毁）" if vessel.crashed else ""]
		button.set_pressed_no_signal(selected and vessel == ship)
	mining_button.visible = selected and is_instance_valid(ship)
	if is_instance_valid(ship):
		mining_button.text = "停止采集" if ship.mining_enabled else "开始采集"
		mining_button.disabled = ship.crashed or ship.voyage_finished or selecting_orbit
	stay_button.visible = false # 原停留占位由行星上的“确认入轨”入口取代。
	if not is_instance_valid(ship):
		info_label.text = "暂无飞船"
		selection_status.text = "未选中"
		hint_label.text = "在 World 下添加 ship.tscn 实例后自动显示选择按钮。"
		accelerate_button.disabled = true
		brake_button.disabled = true
		return
	var nearest_height := INF
	for source in planets:
		nearest_height = minf(nearest_height, ship_position.distance_to(source.flight_position) - source.radius_m)
	var height_text := "最近表面  %.2f km" % (nearest_height / 1000.0) if not planets.is_empty() else "最近表面  无行星"
	info_label.text = "速度 %.1f m/s · 总重 %.1f kg\n%s · 货重 %.1f kg\n燃料 Δv %.1f / %.1f m/s" % [ship_velocity.length(), ship.get_total_mass(), height_text, ship.cargo_mass, ship.fuel_to_delta_v(fuel_mass), ship.fuel_to_delta_v(ship.get_fuel_capacity())]
	info_label.text += "\n本航程 %.2f km · 上航程 %.2f km" % [ship.current_voyage_distance_m / 1000.0, ship.last_voyage_distance_m / 1000.0]
	info_label.tooltip_text = "总质量 = 干质量 %.1f kg + 货物 %.1f kg（燃料不计重）。Δv为当前载重下的推进速度变化预算，不是当前速度。" % [ship.dry_mass, ship.cargo_mass]
	orbit_button.text = "取消入轨" if ship.maneuver_index < ship.maneuver_commands.size() else "入轨（暂停选星）"
	orbit_button.disabled = crashed or ship.voyage_finished or selecting_orbit
	accelerate_button.text = "长按加速  %.1f m/s²" % ship.get_effective_acceleration()
	brake_button.text = "长按减速  %.1f m/s²" % ship.get_effective_deceleration()
	var unavailable: bool = not selected or crashed or ship.voyage_finished or simulation_paused or fuel_mass <= 0.0
	accelerate_button.disabled = unavailable
	brake_button.disabled = unavailable or ship_velocity.length() < 0.01
	selection_status.text = "已选中 · %s" % ship.display_name if selected else "未选中 · 点击顶部飞船按钮"
	if not flight_message.is_empty():
		hint_label.text = flight_message
	elif crashed:
		hint_label.text = "已撞击行星，请重置。"
	elif selected and fuel_mass <= 0.0:
		hint_label.text = "当前无法点火：燃料耗尽。"
	elif simulation_paused:
		hint_label.text = "模拟已暂停；继续后需手动重新设置油门。"
	elif selected and ship.steering:
		hint_label.text = "仪表油门持续推进中，松开滑条不会停止。收油按钮或滑条归零可停止；金线预演现在收油后的航迹。"
	elif selected:
		hint_label.text = "顺逆推按钮长按生效；仪表拖动橙针并设置油门可手动控制推力。金线预演现在停止推进后的航迹。"
	else:
		hint_label.text = "选中飞船后可调速。金色线为不再点火时的预测航迹。"
