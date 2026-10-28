extends Node2D
## 管理模拟、舰队注册与交互绑定；外观、布局与按钮模板定义在 .tscn 中。
# 编辑器布景基准：250 米/像素，(440, 360) 对应模拟原点。
# 仅用于首次读取节点布局，物理计算不依赖窗口和相机。
@export var layout_origin := Vector2(440.0, 360.0)
@export var layout_pixels_per_meter := 0.004
var planets: Array[Node2D] = []
const SIM_STEP := 0.25
const TIME_SCALE := 20.0
const PREVIEW_REFRESH_INTERVAL := 0.1
const PREVIEW_SECONDS := 620.0
const PREVIEW_SAMPLE_STEPS := 4
const THRUST_DELTA_V := 20.0
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


func _ready() -> void:
	# 明确绑定交互，编辑器保存/实例化不再依赖丢失的外部信号连接。
	accelerate_button.pressed.connect(_accelerate)
	brake_button.pressed.connect(_brake)
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
	ship = target
	selected = true
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _physics_process(delta: float) -> void:
	accumulator += delta * TIME_SCALE
	preview_refresh_elapsed += delta
	while accumulator >= SIM_STEP:
		accumulator -= SIM_STEP
		for vessel in ships:
			if vessel.crashed:
				continue
			var next := _integrate(vessel.flight_position, vessel.flight_velocity, SIM_STEP, vessel.gravity_threshold)
			vessel.flight_position = next[0]
			vessel.flight_velocity = next[1]
			if _touches_planet(vessel.flight_position):
				vessel.crashed = true
				vessel.flight_velocity = Vector2.ZERO
	if preview_refresh_elapsed >= PREVIEW_REFRESH_INTERVAL or crashed:
		preview_refresh_elapsed = 0.0
		_refresh_preview()
	_update_ui()
	_sync_visuals()


func _gravity_at(position: Vector2, gravity_threshold: float = 0.0) -> Vector2:
	var acceleration := Vector2.ZERO
	var threshold := maxf(gravity_threshold, 0.0)
	for source in planets:
		var contribution: Vector2 = source.acceleration_at(position)
		if contribution.length() >= threshold:
			acceleration += contribution
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
func _integrate(position: Vector2, velocity: Vector2, step: float, gravity_threshold: float = 0.0) -> Array[Vector2]:
	var new_velocity := velocity + _gravity_at(position, gravity_threshold) * step
	var end := position + new_velocity * step
	var fraction := _collision_fraction(position, end)
	if fraction < 1.0 or _touches_planet(end):
		return [position.lerp(end, fraction), Vector2.ZERO]
	return [end, new_velocity]


func _refresh_preview() -> void:
	preview_points.clear()
	if not is_instance_valid(ship) or crashed:
		return
	var position := ship_position
	var velocity := ship_velocity
	preview_points.append(position)
	for index in range(int(PREVIEW_SECONDS / SIM_STEP)):
		var next := _integrate(position, velocity, SIM_STEP, ship.gravity_threshold)
		position = next[0]
		velocity = next[1]
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
	for vessel in ships:
		vessel.position = _to_screen(vessel.flight_position)
		vessel.get_node("Visual").rotation = vessel.flight_velocity.angle()
		vessel.get_node("Visual").modulate = Color("e48579") if vessel.crashed else Color.WHITE
		vessel.get_node("SelectionRing").visible = selected and vessel == ship
		vessel.get_node("SelectButton").disabled = false
	var mapped := PackedVector2Array()
	for point in preview_points:
		mapped.append(_to_screen(point))
	orbit_preview.points = mapped


func _select_ship() -> void:
	if is_instance_valid(ship):
		_select_target(ship)


func _accelerate() -> void:
	_burn(1.0)


func _brake() -> void:
	_burn(-1.0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		selected = false
		_update_ui()
		_sync_visuals()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_reset()


func _burn_cost(delta_v: float) -> float:
	return (DRY_MASS + fuel_mass) * (1.0 - exp(-delta_v / EXHAUST_VELOCITY))


func _burn(sign_of_burn: float) -> void:
	if not selected or crashed or ship_velocity.length() < 0.01:
		return
	# 逆推最多降到零，不会因一次点击反向加速。
	var delta_v := minf(THRUST_DELTA_V, ship_velocity.length()) if sign_of_burn < 0.0 else THRUST_DELTA_V
	var required_fuel := _burn_cost(delta_v)
	if fuel_mass < required_fuel:
		return
	fuel_mass -= required_fuel
	ship_velocity += ship_velocity.normalized() * delta_v * sign_of_burn
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _reset() -> void:
	$NavigationCamera.reset_view()
	for vessel in ships:
		vessel.reset_flight()
	selected = false
	accumulator = 0.0
	preview_refresh_elapsed = 0.0
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _update_ui() -> void:
	fleet_buttons.get_node("Empty").visible = ships.is_empty()
	for index in range(ships.size()):
		var vessel := ships[index]
		var button: Button = ship_buttons[vessel]
		button.text = "%02d · %s%s" % [index + 1, vessel.display_name, "（损毁）" if vessel.crashed else ""]
		button.set_pressed_no_signal(selected and vessel == ship)
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
	var unavailable := not selected or crashed or ship_velocity.length() < 0.01
	accelerate_button.disabled = unavailable or fuel_mass < _burn_cost(THRUST_DELTA_V)
	brake_button.disabled = unavailable or fuel_mass < _burn_cost(minf(THRUST_DELTA_V, ship_velocity.length()))
	selection_status.text = "已选中 · %s" % ship.display_name if selected else "未选中 · 点击顶部飞船按钮"
	if crashed:
		hint_label.text = "已撞击行星，请重置。"
	elif selected and accelerate_button.disabled and brake_button.disabled:
		hint_label.text = "当前无法点火：燃料不足或速度为零。"
	elif selected:
		hint_label.text = "加速沿速度方向顺推，减速反向点火。每次扣油；金线立即更新。"
	else:
		hint_label.text = "选中飞船后可调速。金色线为不再点火时的预测航迹。"
