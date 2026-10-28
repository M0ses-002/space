extends Node2D
## 管理模拟、舰队注册与交互绑定；外观、布局与按钮模板定义在 .tscn 中。
## 编辑器布景原点（像素坐标），对应模拟世界的零点。首次读取行星/飞船节点布局时使用。
@export var layout_origin := Vector2(440.0, 360.0)
## 编辑器布景的换算比例：每米对应多少像素。仅用于首次初始化，物理计算不依赖窗口和相机。
@export var layout_pixels_per_meter := 0.004
var planets: Array[Node2D] = []
const SIM_STEP := 0.25
const TIME_SCALE := 20.0
const PREVIEW_REFRESH_INTERVAL := 0.1
const PREVIEW_SECONDS := 620.0
const PREVIEW_SAMPLE_STEPS := 4
const OrbitPlanner = preload("res://scripts/orbit_planner.gd")
const EXHAUST_VELOCITY := 3700.0
const DRY_MASS := 8000.0
const INITIAL_FUEL := 3200.0
const START_POSITION := Vector2(0.0, -62000.0)
const START_VELOCITY := Vector2(655.0, 0.0)

const SHIP_BUTTON := preload("res://scenes/ship_selector_button.tscn")
var ships: Array[Node2D] = []
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

@onready var fleet_buttons: HBoxContainer = $HUD/Root/FleetBar/Margin/Row/Scroll/Buttons
@onready var orbit_preview: Line2D = $World/OrbitPreview
@onready var panel: PanelContainer = $HUD/Root/FlightPanel
@onready var info_label: Label = $HUD/Root/FlightPanel/Margin/Content/Info
@onready var hint_label: Label = $HUD/Root/FlightPanel/Margin/Content/Hint
@onready var selection_status: Label = $HUD/Root/FlightPanel/Margin/Content/SelectionStatus
@onready var accelerate_button: Button = $HUD/Root/FlightPanel/Margin/Content/AccelerateButton
@onready var brake_button: Button = $HUD/Root/FlightPanel/Margin/Content/BrakeButton


@onready var hover_button: Button = $HUD/Root/FlightPanel/Margin/Content/HoverButton
@onready var stay_button: Button = $HUD/Root/FlightPanel/Margin/Content/StayButton
@onready var speed_row: HBoxContainer = $HUD/Root/FlightPanel/Margin/Content/SpeedRow

@onready var pause_button: Button = $HUD/Root/FlightPanel/Margin/Content/PauseButton
@onready var orbit_button: Button = $HUD/Root/FlightPanel/Margin/Content/OrbitButton
@onready var orbit_actions: HBoxContainer = $HUD/Root/FlightPanel/Margin/Content/OrbitActions

func _ready() -> void:
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
	hover_button.pressed.connect(_toggle_hover)
	# StayButton 故意不绑定动作，后续实现停留玩法。
	for index in range(4):
		speed_row.get_child(index).pressed.connect(_set_simulation_speed.bind([0.5, 1.0, 1.5, 2.0][index]))
	$HUD/Root/FlightPanel/Margin/Content/ResetButton.pressed.connect(_reset)
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)
	for source in get_tree().get_nodes_in_group("gravity_sources"):
		_register_planet(source, true)
	for candidate in get_tree().get_nodes_in_group("flight_ships"):
		_register_ship(candidate)
	get_viewport().size_changed.connect(_sync_visuals)
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _on_node_added(node: Node) -> void:
	if node.is_in_group("flight_ships"):
		_register_ship.call_deferred(node)
	elif node.is_in_group("gravity_sources"):
		_register_planet.call_deferred(node, false)


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
	_refresh_preview()
	_sync_visuals()


func _register_ship(candidate: Node) -> void:
	if not is_instance_valid(candidate) or not candidate.is_inside_tree() or not $World.is_ancestor_of(candidate) or ships.has(candidate):
		return
	ships.append(candidate)
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
	if not is_instance_valid(target) or not ships.has(target):
		return
	_stop_thrust()
	if selecting_orbit:
		_cancel_orbit_selection()
	flight_message = ""
	ship = target
	selected = true
	$StarMapView.on_ship_selected()
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _physics_process(delta: float) -> void:
	var hover_invalidated := false
	for vessel in ships:
		_validate_navigation(vessel)
		_update_region(vessel, vessel.flight_position)
		if vessel.hovering and not _valid_hover_source(vessel):
			_release_invalid_hover(vessel)
			hover_invalidated = true
	if hover_invalidated:
		_refresh_preview()
		_update_ui()
		_sync_visuals()
	if simulation_paused:
		return
	accumulator += delta * TIME_SCALE * simulation_speed
	preview_refresh_elapsed += delta
	while accumulator >= SIM_STEP:
		accumulator -= SIM_STEP
		for vessel in ships:
			if vessel.crashed:
				continue
			var command: float = vessel.manual_thrust * (vessel.max_acceleration if vessel.manual_thrust > 0.0 else vessel.max_deceleration)
			if vessel.maneuver_index < vessel.maneuver_commands.size():
				if not is_instance_valid(vessel.maneuver_target) or not planets.has(vessel.maneuver_target) or vessel.maneuver_target.acceleration_at(vessel.flight_position).length_squared() <= 0.0:
					vessel.maneuver_commands.clear()
					flight_message = "目标已移除或已失去其有效引力，入轨机动取消。"
				else:
					command = vessel.maneuver_commands[vessel.maneuver_index]
					if vessel.fuel + 0.00001 < absf(command) * SIM_STEP * vessel.propulsion_fuel_per_delta_v:
						vessel.maneuver_commands.clear()
						command = 0.0
						flight_message = "燃料不足，入轨机动中止。"
					else:
						vessel.maneuver_index += 1
						if vessel.maneuver_index == vessel.maneuver_commands.size():
							flight_message = "入轨机动已执行完成；继续自由绕行。"
			if vessel.hovering and not _valid_hover_source(vessel):
				_release_invalid_hover(vessel)
			var previous_position: Vector2 = vessel.flight_position
			var state: Dictionary
			if vessel.steering:
				state = _steering_step(vessel, SIM_STEP)
				state.hovering = false
				vessel.reset_orbit()
			elif vessel.hovering:
				state = _advance_flight(vessel.flight_position, vessel.flight_velocity, vessel.fuel, true, SIM_STEP, vessel.hover_fuel_per_delta_v)
			else:
				state = _propulsion_step(vessel.flight_position, vessel.flight_velocity, vessel.fuel, SIM_STEP, command, vessel.heading, vessel.propulsion_fuel_per_delta_v)
				state.hovering = false
			if absf(command) > 0.0:
				vessel.reset_orbit()
			if state.velocity.length() > 0.01:
				vessel.heading = state.velocity.normalized()
			vessel.flight_position = state.position
			vessel.flight_velocity = state.velocity
			vessel.fuel = state.fuel
			vessel.hovering = state.hovering
			_update_region(vessel, previous_position)
			if _touches_planet(vessel.flight_position):
				vessel.crashed = true
				vessel.steering = false
				vessel.thrust_throttle = 0.0
				vessel.manual_thrust = 0.0
				vessel.navigation_status = "飞船撞击损毁，请重置航行。"
				vessel.hovering = false
				vessel.flight_velocity = Vector2.ZERO
			vessel.track_orbit(_dominant_source(vessel.flight_position), _gravity_at(vessel.flight_position))
	if preview_refresh_elapsed >= PREVIEW_REFRESH_INTERVAL or crashed:
		preview_refresh_elapsed = 0.0
		_refresh_preview()
	_update_ui()
	_sync_visuals()


func _set_simulation_speed(value: float) -> void:
	if value not in [0.5, 1.0, 1.5, 2.0]:
		return
	simulation_speed = value
	for index in range(4):
		speed_row.get_child(index).set_pressed_no_signal(is_equal_approx(value, [0.5, 1.0, 1.5, 2.0][index]))
	$HUD/Root/FlightPanel/Margin/Content/Reference.text = "WASD 移动 · 滚轮缩放\n运行 %.1f× · 基础 20 模拟秒/秒\n预演 620 s · 耗油按模拟秒" % value


func _toggle_hover() -> void:
	if not selected or not is_instance_valid(ship) or crashed or selecting_orbit or simulation_paused:
		return
	_stop_thrust()
	if ship.hovering:
		if not _valid_hover_source(ship):
			_release_invalid_hover(ship)
			_refresh_preview()
			_update_ui()
			_sync_visuals()
			return
		var source: Node2D = ship.hover_source
		var radial: Vector2 = ship_position - source.flight_position
		var g: float = source.acceleration_at(ship_position).length()
		if radial.length() <= source.radius_m or g <= 0.0:
			flight_message = "参考行星引力无效或位置不安全。"
			_update_ui()
			return
		var tangent: Vector2 = Vector2(-radial.y, radial.x).normalized() * ship.hover_direction
		var target_velocity := tangent * sqrt(g * radial.length())
		var cost: float = target_velocity.distance_to(ship_velocity) * ship.propulsion_fuel_per_delta_v
		if fuel_mass < cost:
			flight_message = "解除悬停需 %.1f kg 燃料，当前不足；继续悬停。" % cost
			_update_ui()
			return
		fuel_mass -= cost
		ship_velocity = target_velocity
		ship.heading = tangent
		ship.hovering = false
		flight_message = "已扣 %.1f kg，沿原绕行方向获得切向速度；多星扰动仍生效。" % cost
	else:
		if fuel_mass <= 0.0:
			return
		var reference := _dominant_source(ship_position)
		if not is_instance_valid(reference) or _touches_planet(ship_position):
			flight_message = "当前位置没有有效参考行星，无法悬停。"
			_update_ui()
			return
		ship.hover_source = reference
		if is_instance_valid(ship.hover_source):
			var cross_value: float = (ship_position - ship.hover_source.flight_position).cross(ship_velocity)
			ship.hover_direction = signf(cross_value) if absf(cross_value) > 0.001 else float(ship.default_orbit_direction)
		ship.maneuver_commands.clear()
		ship.hovering = true
		ship_velocity = Vector2.ZERO
		flight_message = ""
	ship.reset_orbit()
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _valid_hover_source(vessel: Node2D) -> bool:
	# 先检查已释放的引用，不能先赋给 Node2D 类型局部变量。
	if not is_instance_valid(vessel.hover_source):
		return false
	var source: Node2D = vessel.hover_source
	return planets.has(source) and vessel.flight_position.distance_to(source.flight_position) > source.radius_m and source.acceleration_at(vessel.flight_position).length_squared() > 0.0


func _release_invalid_hover(vessel: Node2D) -> void:
	vessel.hovering = false
	vessel.hover_source = null
	vessel.reset_orbit()
	# 不恢复旧速度、不扣费或赠送圆轨道速度，之后仅受仍有效的引力影响。
	if vessel == ship:
		flight_message = "悬停参考行星已失效，已退出悬停并恢复自由航行。"


func _hover_rate(position: Vector2, coefficient: float) -> float:
	return _gravity_at(position).length() * maxf(coefficient, 0.0)


# 纯状态推进：实飞和预览共用，包括燃料耗尽后的自由落体。
func _advance_flight(position: Vector2, velocity: Vector2, fuel: float, hovering: bool, step: float, coefficient: float) -> Dictionary:
	var remaining := step
	if hovering:
		velocity = Vector2.ZERO
		var rate := _hover_rate(position, coefficient)
		if rate <= 0.0:
			return {"position": position, "velocity": velocity, "fuel": fuel, "hovering": true}
		var held_time := minf(step, maxf(fuel, 0.0) / rate)
		fuel = maxf(0.0, fuel - rate * held_time)
		remaining -= held_time
		if fuel > 0.0:
			return {"position": position, "velocity": velocity, "fuel": fuel, "hovering": true}
		hovering = false
	var next := _integrate(position, velocity, remaining)
	return {"position": next[0], "velocity": next[1], "fuel": fuel, "hovering": hovering}


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
	return acceleration


func _touches_planet(position: Vector2) -> bool:
	for source in planets:
		if position.distance_to(source.flight_position) <= source.radius_m + 0.1:
			return true
	return false


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
	return earliest


# 实飞与预览共用引力叠加、固定步长半隐式欧拉及全行星撞击裁剪。
func _integrate(position: Vector2, velocity: Vector2, step: float) -> Array[Vector2]:
	# 普通航行维持原固定步；跨引力边界按扫掠交点分段，避免两端圈外漏算整段引力。
	var projected_end := position + (velocity + _gravity_at(position) * step) * step
	var cuts: Array[float] = [0.0, 1.0]
	for source in planets:
		for fraction in _circle_crossings(position, projected_end, source.flight_position, source.max_gravity_radius_m):
			if fraction > 0.000001 and fraction < 0.999999:
				cuts.append(fraction)
	cuts.sort()
	for index in range(1, cuts.size()):
		var interval := step * (cuts[index] - cuts[index - 1])
		if interval <= 0.0:
			continue
		var sample := position if cuts.size() == 2 else position + velocity * interval * 0.5
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


func _refresh_preview() -> void:
	preview_points.clear()
	if not is_instance_valid(ship) or crashed:
		return
	var position := ship_position
	var velocity := ship_velocity
	var preview_fuel := fuel_mass
	var preview_hovering: bool = ship.hovering and _valid_hover_source(ship)
	var preview_heading: Vector2 = ship.heading
	preview_points.append(position)
	var horizon := PREVIEW_SECONDS
	var map_view := get_node_or_null("StarMapView")
	if map_view != null and map_view.is_initialized:
		horizon = map_view.preview_seconds
	for index in range(int(horizon / SIM_STEP)):
		# 手动推进只改变实际状态；预览假设此刻松手，按当前速度受引力滑行。
		# 自动入轨仍预览已确认的剩余机动指令。
		var command: float = 0.0
		var command_index: int = ship.maneuver_index + index
		if command_index < ship.maneuver_commands.size():
			command = ship.maneuver_commands[command_index]
		var state: Dictionary
		if preview_hovering:
			state = _advance_flight(position, velocity, preview_fuel, true, SIM_STEP, ship.hover_fuel_per_delta_v)
		else:
			state = _propulsion_step(position, velocity, preview_fuel, SIM_STEP, command, preview_heading, ship.propulsion_fuel_per_delta_v)
			state.hovering = false
		if state.velocity.length() > 0.01:
			preview_heading = state.velocity.normalized()
		position = state.position
		velocity = state.velocity
		preview_fuel = state.fuel
		preview_hovering = state.hovering
		if _touches_planet(position):
			preview_points.append(position)
			break
		if (index + 1) % PREVIEW_SAMPLE_STEPS == 0:
			preview_points.append(position)


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
	for vessel in ships:
		vessel.position = _to_screen(vessel.flight_position)
		vessel.get_node("Visual").rotation = vessel.flight_velocity.angle()
		vessel.get_node("Visual").modulate = Color("e48579") if vessel.crashed else Color.WHITE
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
	if simulation_paused or selecting_orbit or not selected or not is_instance_valid(ship) or crashed or ship.hovering or fuel_mass <= 0.0:
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


func _toggle_pause() -> void:
	if selecting_orbit:
		flight_message = "请先确认或取消入轨选星。"
	else:
		simulation_paused = not simulation_paused
	_stop_thrust()
	_update_ui()


func _begin_orbit_selection() -> void:
	if not selected or not is_instance_valid(ship) or crashed or ship.hovering:
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
		flight_message = "预计 %.1f 模拟秒 / %.1f kg\n最终高度 %.2f km，确认后恢复运行。" % [pending_plan.duration, pending_plan.fuel_cost, (pending_plan.final_radius - target.radius_m) / 1000.0]
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
	if vessel.crashed or vessel.hovering or vessel.fuel <= 0.0:
		if vessel.steering:
			vessel.navigation_status = "修向停止：损毁、悬停或燃料不足。"
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
	if simulation_paused or selecting_orbit or not selected or crashed or ship.hovering or fuel_mass <= 0.0 or ship.max_steering_acceleration <= 0.0:
		return
	ship.manual_thrust = 0.0
	ship.maneuver_commands.clear()
	ship.thrust_throttle = clampf(value, 0.0, 1.0)
	ship.steering = true
	ship.reset_orbit()
	ship.navigation_status = "手动推力持续生效；油门归零停止。"


func _steering_step(vessel: Node2D, step: float) -> Dictionary:
	var delta_v := maxf(0.0, vessel.max_steering_acceleration) * clampf(vessel.thrust_throttle, 0.0, 1.0) * step
	var coefficient := maxf(vessel.propulsion_fuel_per_delta_v, 0.000001)
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


func _burn_cost(delta_v: float) -> float:
	# 固定质量耗油模型，燃料库存不参与轨道或推进质量计算。
	return DRY_MASS * delta_v / EXHAUST_VELOCITY


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
	$StarMapView.reset_view()
	selected = false
	accumulator = 0.0
	preview_refresh_elapsed = 0.0
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _update_ui() -> void:
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
	hover_button.visible = selected and is_instance_valid(ship)
	stay_button.visible = selected and is_instance_valid(ship) and ship.stay_available and not ship.crashed and is_instance_valid(ship.orbit_source)
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
	info_label.text = "速度  %.1f m/s\n%s\n燃料  %.0f kg" % [ship_velocity.length(), height_text, fuel_mass]
	hover_button.text = "解除悬停（付费入圆轨道）" if ship.hovering else "悬停"
	var has_hover_reference := is_instance_valid(_dominant_source(ship_position)) and not _touches_planet(ship_position)
	hover_button.disabled = crashed or simulation_paused or (not ship.hovering and (fuel_mass <= 0.0 or not has_hover_reference))
	hover_button.tooltip_text = "抵消合引力以维持当前位置。" if has_hover_reference else "当前位置没有有效参考行星，无法悬停。"
	if ship.hovering and not _valid_hover_source(ship):
		hover_button.text = "退出悬停（参考行星失效）"
	orbit_button.text = "取消入轨" if ship.maneuver_index < ship.maneuver_commands.size() else "入轨（暂停选星）"
	orbit_button.disabled = crashed or ship.hovering or selecting_orbit
	accelerate_button.text = "长按加速  %.1f m/s²" % ship.max_acceleration
	brake_button.text = "长按减速  %.1f m/s²" % ship.max_deceleration
	if ship.hovering:
		info_label.text += "\n悬停耗油  %.2f kg/模拟秒" % _hover_rate(ship_position, ship.hover_fuel_per_delta_v)
	var unavailable: bool = not selected or crashed or ship.hovering or simulation_paused or fuel_mass <= 0.0
	accelerate_button.disabled = unavailable
	brake_button.disabled = unavailable or ship_velocity.length() < 0.01
	selection_status.text = "已选中 · %s" % ship.display_name if selected else "未选中 · 点击顶部飞船按钮"
	if not flight_message.is_empty():
		hint_label.text = flight_message
	elif crashed:
		hint_label.text = "已撞击行星，请重置。"
	elif ship.hovering:
		hint_label.text = "悬停中，持续抵消合引力；油尽后下落。金线包含油尽后的航迹。"
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
