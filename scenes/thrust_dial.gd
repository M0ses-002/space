extends PanelContainer
## 双指针仪表：绿色为实际速度，橙色为世界坐标下的推进器加速度方向。
var game: Node2D
var dragging := false
var controlled_id := 0
@onready var dial: Control = $Layout/Dial
@onready var velocity_needle: Polygon2D = $Layout/Dial/Pivot/VelocityNeedle
@onready var thrust_needle: Polygon2D = $Layout/Dial/Pivot/ThrustNeedle
@onready var slider: VSlider = $Layout/Throttle
@onready var output: Label = $Layout/Output
@onready var angle_input: SpinBox = $Layout/Angle
@onready var angle_lock: CheckBox = $Layout/AngleLock
@onready var acceleration_input: SpinBox = $Layout/Acceleration

func _ready() -> void:
	dial.gui_input.connect(_dial_input)
	slider.value_changed.connect(_throttle_changed)
	angle_input.value_changed.connect(_angle_changed)
	angle_lock.toggled.connect(_lock_changed)
	acceleration_input.value_changed.connect(_acceleration_changed)
	angle_input.get_line_edit().focus_exited.connect(_commit_input.bind(angle_input))
	acceleration_input.get_line_edit().focus_exited.connect(_commit_input.bind(acceleration_input))
	$Layout/Cutoff.pressed.connect(_cutoff)
	get_window().focus_exited.connect(func(): dragging = false)
	get_viewport().size_changed.connect(_adjust_default_position)
	_adjust_default_position()

func _adjust_default_position() -> void:
	var fleet_bar: Control = get_node_or_null("../FleetBar")
	if get_viewport_rect().size.x < 1060.0:
		offset_top = -get_viewport_rect().size.y
		offset_bottom = offset_top + 268.0
		if fleet_bar:
			fleet_bar.offset_right = -688.0
	else:
		offset_top = -312.0
		offset_bottom = -16.0
		if fleet_bar:
			fleet_bar.offset_right = -336.0

func _process(_delta: float) -> void:
	sync_state()

func bind_game(value: Node2D) -> void:
	game = value
	sync_state()

func _dial_input(event: InputEvent) -> void:
	if not _can_aim():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		dragging = event.pressed
		if dragging:
			_aim_at(event.position)
		dial.accept_event()
	elif event is InputEventMouseMotion and dragging:
		_aim_at(event.position)
		dial.accept_event()

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and is_visible_in_tree():
			# 点在两个输入框以外时提交并退出编辑；不吞掉点击，让其他控件正常响应。
			if not angle_input.get_global_rect().has_point(event.position) and not acceleration_input.get_global_rect().has_point(event.position):
				for input in [angle_input, acceleration_input]:
					if input.get_line_edit().has_focus():
						input.get_line_edit().release_focus()
		else:
			dragging = false

func _can_aim() -> bool:
	return is_instance_valid(game) and is_instance_valid(game.ship) and game.selected and not game.selecting_orbit and not game.ship.crashed and not game.ship.voyage_finished

func _aim_at(local_point: Vector2) -> void:
	var direction := local_point - Vector2(76, 76)
	# 中心死区避免跨越圆心时随机翻转；拖出圆周仍保持角度控制。
	if direction.length() >= 8.0:
		game._set_thrust_direction(direction)
		sync_state()

func _throttle_changed(value: float) -> void:
	if is_instance_valid(game):
		game._set_throttle(value / slider.max_value if slider.max_value > 0.0 else 0.0)
		sync_state()

func _commit_input(input: SpinBox) -> void:
	var text := input.get_line_edit().text.strip_edges()
	if text.is_valid_float():
		input.value = text.to_float()
	sync_state.call_deferred()

func _lock_changed(enabled: bool) -> void:
	if is_instance_valid(game):
		game._set_thrust_lock(enabled)
		sync_state()

func _angle_changed(value: float) -> void:
	if not _can_aim() or game.simulation_paused:
		return
	var base: Vector2 = game._thrust_reference(game.ship.flight_velocity, game.ship.heading)
	game._set_thrust_direction(base.rotated(deg_to_rad(value)))
	angle_input.set_value_no_signal(rad_to_deg(base.angle_to(game.ship.thrust_direction)))
	sync_state()

func _acceleration_changed(value: float) -> void:
	if not _can_aim() or game.simulation_paused:
		return
	var maximum: float = game.ship.get_effective_steering_acceleration()
	game._set_throttle(clampf(value, 0.0, maximum) / maximum if maximum > 0.0 else 0.0)
	sync_state()

func _cutoff() -> void:
	if is_instance_valid(game):
		game._stop_thrust()
		sync_state()

func sync_state() -> void:
	if not is_node_ready() or not is_instance_valid(game):
		return
	var valid := is_instance_valid(game.ship)
	var next_id: int = game.ship.get_instance_id() if valid else 0
	if next_id != controlled_id or not _can_aim() or game.simulation_paused:
		dragging = false
	controlled_id = next_id
	velocity_needle.visible = valid and game.ship.flight_velocity.length() > 0.01
	thrust_needle.visible = valid
	if valid:
		velocity_needle.rotation = game.ship.flight_velocity.angle()
		thrust_needle.rotation = game.ship.thrust_direction.angle()
		angle_lock.set_pressed_no_signal(game.ship.thrust_lock_enabled)
		var maximum: float = game.ship.get_effective_steering_acceleration()
		slider.set_block_signals(true)
		slider.max_value = maximum
		slider.set_value_no_signal(game.ship.thrust_throttle * maximum)
		slider.set_block_signals(false)
		var base: Vector2 = game._thrust_reference(game.ship.flight_velocity, game.ship.heading)
		if not angle_input.get_line_edit().has_focus():
			angle_input.set_value_no_signal(rad_to_deg(base.angle_to(game.ship.thrust_direction)))
		acceleration_input.set_block_signals(true)
		acceleration_input.max_value = maximum
		if not acceleration_input.get_line_edit().has_focus():
			acceleration_input.set_value_no_signal(game.ship.thrust_throttle * maximum)
		acceleration_input.set_block_signals(false)
		output.text = "出力 %d%% · %.1f / %.1f m/s²" % [roundi(game.ship.thrust_throttle * 100.0), game.ship.thrust_throttle * maximum, maximum]
		if game.ship.flight_velocity.length() <= 0.01:
			$Layout/Legend.text = "绿：静止无方向  橙：推力方向"
		else:
			$Layout/Legend.text = "绿：速度  橙：推力（不含重力）"
	else:
		slider.set_value_no_signal(0)
		output.text = "未选中飞船"
	slider.editable = _can_aim() and not game.simulation_paused and game.ship.fuel > 0.0 and game.ship.get_effective_steering_acceleration() > 0.0
	angle_input.editable = _can_aim() and not game.simulation_paused
	angle_lock.disabled = not _can_aim() or game.simulation_paused
	acceleration_input.editable = slider.editable
