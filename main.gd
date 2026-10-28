extends Node2D
## 仅管理模拟和节点状态。外观、布局和按钮连接均定义在 .tscn 中。
const PLANET_RADIUS := 50000.0
const ATMOSPHERE_HEIGHT := 3000.0
const FIELD_TOP := PLANET_RADIUS + ATMOSPHERE_HEIGHT
const SURFACE_GRAVITY := 9.81
const MU := SURFACE_GRAVITY * FIELD_TOP * FIELD_TOP
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

var ship_position := START_POSITION
var ship_velocity := START_VELOCITY
var fuel_mass := INITIAL_FUEL
var selected := false
var crashed := false
var accumulator := 0.0
var preview_refresh_elapsed := 0.0
var preview_points := PackedVector2Array()

@onready var planet: Node2D = $World/Planet
@onready var ship: Node2D = $World/Ship
@onready var orbit_preview: Line2D = $World/OrbitPreview
@onready var panel: PanelContainer = $HUD/Root/FlightPanel
@onready var info_label: Label = $HUD/Root/FlightPanel/Margin/Content/Info
@onready var hint_label: Label = $HUD/Root/FlightPanel/Margin/Content/Hint
@onready var selection_status: Label = $HUD/Root/FlightPanel/Margin/Content/SelectionStatus
@onready var accelerate_button: Button = $HUD/Root/FlightPanel/Margin/Content/AccelerateButton
@onready var brake_button: Button = $HUD/Root/FlightPanel/Margin/Content/BrakeButton


func _ready() -> void:
	get_viewport().size_changed.connect(_sync_visuals)
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _physics_process(delta: float) -> void:
	if crashed:
		return
	accumulator += delta * TIME_SCALE
	preview_refresh_elapsed += delta
	while accumulator >= SIM_STEP:
		accumulator -= SIM_STEP
		var next := _integrate(ship_position, ship_velocity, SIM_STEP)
		ship_position = next[0]
		ship_velocity = next[1]
		if ship_position.length() <= PLANET_RADIUS:
			crashed = true
			ship_position = ship_position.normalized() * PLANET_RADIUS
			ship_velocity = Vector2.ZERO
			accumulator = 0.0
			break
	if preview_refresh_elapsed >= PREVIEW_REFRESH_INTERVAL or crashed:
		preview_refresh_elapsed = 0.0
		_refresh_preview()
	_update_ui()
	_sync_visuals()


# 实飞与预测共用相同步长和半隐式欧拉积分。
func _integrate(position: Vector2, velocity: Vector2, step: float) -> Array[Vector2]:
	var radius := maxf(position.length(), PLANET_RADIUS)
	var gravity := SURFACE_GRAVITY if radius <= FIELD_TOP else MU / (radius * radius)
	var new_velocity := velocity - position.normalized() * gravity * step
	return [position + new_velocity * step, new_velocity]


func _refresh_preview() -> void:
	preview_points.clear()
	if crashed:
		return
	var position := ship_position
	var velocity := ship_velocity
	preview_points.append(position)
	for index in range(int(PREVIEW_SECONDS / SIM_STEP)):
		var next := _integrate(position, velocity, SIM_STEP)
		position = next[0]
		velocity = next[1]
		if (index + 1) % PREVIEW_SAMPLE_STEPS == 0:
			preview_points.append(position)
		if position.length() <= PLANET_RADIUS:
			preview_points.append(position)
			break


func _view_scale() -> float:
	return maxf(0.0001, minf((get_viewport_rect().size.x - panel.size.x - 40.0) / 170000.0, get_viewport_rect().size.y / 170000.0))


func _screen_center() -> Vector2:
	return Vector2((get_viewport_rect().size.x - panel.size.x) * 0.5, get_viewport_rect().size.y * 0.5)


func _to_screen(world_position: Vector2) -> Vector2:
	return _screen_center() + world_position * _view_scale()


func _sync_visuals() -> void:
	if not is_node_ready():
		return
	planet.position = _screen_center()
	# 行星素材基准半径 200px；其外观可在子场景中直接替换。
	planet.scale = Vector2.ONE * PLANET_RADIUS * _view_scale() / 200.0
	ship.position = _to_screen(ship_position)
	ship.get_node("Visual").rotation = ship_velocity.angle()
	ship.get_node("Visual").modulate = Color("e48579") if crashed else Color.WHITE
	ship.get_node("SelectionRing").visible = selected and not crashed
	ship.get_node("SelectButton").disabled = crashed
	var mapped := PackedVector2Array()
	for point in preview_points:
		mapped.append(_to_screen(point))
	orbit_preview.points = mapped


func _select_ship() -> void:
	selected = not crashed
	_update_ui()
	_sync_visuals()


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
	ship_position = START_POSITION
	ship_velocity = START_VELOCITY
	fuel_mass = INITIAL_FUEL
	selected = false
	crashed = false
	accumulator = 0.0
	preview_refresh_elapsed = 0.0
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _update_ui() -> void:
	info_label.text = "速度  %.1f m/s\n高度  %.2f km\n燃料  %.0f kg" % [ship_velocity.length(), (ship_position.length() - PLANET_RADIUS) / 1000.0, fuel_mass]
	var unavailable := not selected or crashed or ship_velocity.length() < 0.01
	accelerate_button.disabled = unavailable or fuel_mass < _burn_cost(THRUST_DELTA_V)
	brake_button.disabled = unavailable or fuel_mass < _burn_cost(minf(THRUST_DELTA_V, ship_velocity.length()))
	selection_status.text = "已选中 · 运输船" if selected and not crashed else "未选中 · 点击星图中的飞船"
	if crashed:
		hint_label.text = "已撞击行星，请重置。"
	elif selected and accelerate_button.disabled and brake_button.disabled:
		hint_label.text = "当前无法点火：燃料不足或速度为零。"
	elif selected:
		hint_label.text = "加速沿速度方向顺推，减速反向点火。每次扣油；金线立即更新。"
	else:
		hint_label.text = "选中飞船后可调速。金色线为不再点火时的预测航迹。"
