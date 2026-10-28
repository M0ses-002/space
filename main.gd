extends Node2D
## 单星体航行原型：实飞与轨迹预演共用 _integrate()，单位为 m / s。

const PLANET_RADIUS := 50000.0
const ATMOSPHERE_HEIGHT := 3000.0
const FIELD_TOP := PLANET_RADIUS + ATMOSPHERE_HEIGHT
const SURFACE_GRAVITY := 9.81
const MU := SURFACE_GRAVITY * FIELD_TOP * FIELD_TOP
const SIM_STEP := 0.25
const TIME_SCALE := 20.0 # 原型用 20 倍时间，避免等待数分钟才看到一次绕行。
const PREVIEW_REFRESH_INTERVAL := 0.1
const PREVIEW_SECONDS := 620.0
const PREVIEW_SAMPLE_STEPS := 4
const THRUST_DELTA_V := 20.0
const EXHAUST_VELOCITY := 3700.0 # 380 s 比冲约对应 3.7 km/s 排气速度。
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

var info_label: Label
var hint_label: Label
var accelerate_button: Button
var brake_button: Button


func _ready() -> void:
	_build_ui()
	_refresh_preview()
	_update_ui()
	queue_redraw()


func _physics_process(delta: float) -> void:
	if crashed:
		return
	accumulator += delta * TIME_SCALE
	preview_refresh_elapsed += delta
	var advanced := false
	while accumulator >= SIM_STEP:
		accumulator -= SIM_STEP
		var next := _integrate(ship_position, ship_velocity, SIM_STEP)
		ship_position = next[0]
		ship_velocity = next[1]
		advanced = true
		if ship_position.length() <= PLANET_RADIUS:
			crashed = true
			ship_position = ship_position.normalized() * PLANET_RADIUS
			ship_velocity = Vector2.ZERO
			accumulator = 0.0
			break
	if advanced:
		if preview_refresh_elapsed >= PREVIEW_REFRESH_INTERVAL or crashed:
			preview_refresh_elapsed = 0.0
			_refresh_preview()
		_update_ui()
		queue_redraw()


# 先计算径向重力，再做半隐式欧拉积分。预览与实飞必须用同一步长和该函数。
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
	return minf((get_viewport_rect().size.x - 340.0) / 170000.0, get_viewport_rect().size.y / 170000.0)


func _screen_center() -> Vector2:
	return Vector2((get_viewport_rect().size.x - 300.0) * 0.5, get_viewport_rect().size.y * 0.5)


func _to_screen(world_position: Vector2) -> Vector2:
	return _screen_center() + world_position * _view_scale()


func _draw() -> void:
	var view := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, view), Color("10192b"))
	var center := _screen_center()
	var scale := _view_scale()
	# 大气边缘与行星表面；飞船/预览均在同一二维坐标系内。
	draw_circle(center, FIELD_TOP * scale, Color("31556c", 0.6))
	draw_arc(center, FIELD_TOP * scale, 0.0, TAU, 128, Color("87b8ca", 0.8), 1.5, true)
	draw_circle(center, PLANET_RADIUS * scale, Color("426b8a"))
	draw_arc(center, PLANET_RADIUS * scale, 0.0, TAU, 128, Color("8dc5d7"), 2.0, true)
	draw_circle(center, 7.0, Color("d5efff"))
	if preview_points.size() > 1:
		var mapped := PackedVector2Array()
		for point in preview_points:
			mapped.append(_to_screen(point))
		draw_polyline(mapped, Color("f1c76c"), 2.0, true)
	var ship_screen := _to_screen(ship_position)
	if selected:
		draw_arc(ship_screen, 16.0, 0.0, TAU, 40, Color("8ff0d7"), 2.0, true)
	draw_circle(ship_screen, 8.0, Color("f7f7f3") if not crashed else Color("e48579"))
	if not crashed:
		var direction := ship_velocity.normalized()
		draw_line(ship_screen, ship_screen + direction * 18.0, Color("8ff0d7"), 2.0, true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		selected = event.position.distance_to(_to_screen(ship_position)) < 22.0 and not crashed
		_update_ui()
		queue_redraw()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_reset()


func _burn(sign_of_burn: float) -> void:
	if not selected or crashed or ship_velocity.length() < 0.01:
		return
	var total_mass := DRY_MASS + fuel_mass
	# 火箭方程：此次按钮点火的燃料消耗从当前总质量计算，不能免费加速。
	var required_fuel := total_mass * (1.0 - exp(-THRUST_DELTA_V / EXHAUST_VELOCITY))
	if fuel_mass < required_fuel:
		_update_ui()
		return
	fuel_mass -= required_fuel
	ship_velocity += ship_velocity.normalized() * THRUST_DELTA_V * sign_of_burn
	_refresh_preview()
	_update_ui()
	queue_redraw()


func _reset() -> void:
	ship_position = START_POSITION
	ship_velocity = START_VELOCITY
	fuel_mass = INITIAL_FUEL
	selected = false
	crashed = false
	accumulator = 0.0
	preview_refresh_elapsed = 0.0
	_refresh_preview()
	_update_ui()
	queue_redraw()


func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -300.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("1d2d40")
	style.border_color = Color("547189")
	style.border_width_left = 1
	panel.add_theme_stylebox_override("panel", style)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	panel.add_child(column)
	var padding := MarginContainer.new()
	padding.add_theme_constant_override("margin_left", 22)
	padding.add_theme_constant_override("margin_right", 22)
	padding.add_theme_constant_override("margin_top", 28)
	padding.add_theme_constant_override("margin_bottom", 24)
	column.add_child(padding)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 18)
	padding.add_child(content)
	var title := Label.new()
	title.text = "单星体航行原型"
	title.add_theme_font_size_override("font_size", 23)
	content.add_child(title)
	var description := Label.new()
	description.text = "点击星图中的白色飞船以选中\n金线：按当前速度预测的航迹"
	description.add_theme_color_override("font_color", Color("b4c8d6"))
	content.add_child(description)
	info_label = Label.new()
	info_label.add_theme_font_size_override("font_size", 17)
	content.add_child(info_label)
	accelerate_button = Button.new()
	accelerate_button.text = "顺推  +20 m/s"
	accelerate_button.custom_minimum_size.y = 52
	accelerate_button.pressed.connect(_burn.bind(1.0))
	content.add_child(accelerate_button)
	brake_button = Button.new()
	brake_button.text = "逆推  -20 m/s"
	brake_button.custom_minimum_size.y = 52
	brake_button.pressed.connect(_burn.bind(-1.0))
	content.add_child(brake_button)
	hint_label = Label.new()
	hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_label.add_theme_color_override("font_color", Color("b4c8d6"))
	content.add_child(hint_label)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(spacer)
	var reset_button := Button.new()
	reset_button.text = "重置航行 (R)"
	reset_button.pressed.connect(_reset)
	content.add_child(reset_button)
	var footer := Label.new()
	footer.text = "50 km 半径  ·  3 km 恒强层\n表面 1g  ·  20 倍时间\n轨道预演 620 s"
	footer.add_theme_color_override("font_color", Color("91adbf"))
	content.add_child(footer)


func _update_ui() -> void:
	info_label.text = "速度  %.1f m/s\n高度  %.2f km\n燃料  %.0f kg\n场顶圆轨道约 721 m/s" % [ship_velocity.length(), (ship_position.length() - PLANET_RADIUS) / 1000.0, fuel_mass]
	accelerate_button.disabled = not selected or crashed or fuel_mass < 1.0
	brake_button.disabled = not selected or crashed or fuel_mass < 1.0
	if crashed:
		hint_label.text = "已撞击行星。点击重置重新开始。"
	elif selected:
		hint_label.text = "已选中飞船。按钮沿当前速度方向顺推或逆推；每次点火按火箭方程扣油。"
	else:
		hint_label.text = "请先点击白色飞船。轨迹只是无后续点火的预测，不会替你驾驶。"
