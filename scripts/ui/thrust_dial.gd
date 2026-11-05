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
@onready var max_speed_input: SpinBox = $Layout/MaxSpeed
@onready var max_speed_label: Label = $Layout/MaxSpeedLabel
@onready var cancel_autopilot_button: Button = $Layout/CancelAutopilot
@onready var autopilot_button: Button = $Layout/AutoPilot

func _ready() -> void:
	dial.gui_input.connect(_dial_input)
	slider.value_changed.connect(_throttle_changed)
	angle_input.value_changed.connect(_angle_changed)
	angle_lock.toggled.connect(_lock_changed)
	acceleration_input.value_changed.connect(_acceleration_changed)
	angle_input.get_line_edit().focus_exited.connect(_commit_input.bind(angle_input))
	acceleration_input.get_line_edit().focus_exited.connect(_commit_input.bind(acceleration_input))
	max_speed_input.value_changed.connect(_max_speed_changed)
	max_speed_input.get_line_edit().focus_exited.connect(_commit_input.bind(max_speed_input))
	cancel_autopilot_button.pressed.connect(_cancel_autopilot)
	autopilot_button.pressed.connect(func():
		if is_instance_valid(game):
			game._toggle_autopilot_mode()
			sync_state())
	$Layout/Cutoff.pressed.connect(_cutoff)
	get_window().focus_exited.connect(func(): dragging = false)

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
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		if event.pressed and is_visible_in_tree():
			# 点击输入框之外即提交失焦，不吞掉其他控件的点击。
			for input in [angle_input, acceleration_input, max_speed_input]:
				if input.get_line_edit().has_focus() and not input.get_global_rect().has_point(event.position):
					input.get_line_edit().release_focus()
		else:
			dragging = false

func _can_aim() -> bool:
	return is_instance_valid(game) and is_instance_valid(game.ship) and game.selected and not game.tutorial_pause and not game.selecting_orbit and not game.ship.crashed and not game.ship.voyage_finished and not game.ship.autopilot_enabled

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
	if not _can_aim():
		return
	var base: Vector2 = game._thrust_reference(game.ship.flight_velocity, game.ship.heading)
	game._set_thrust_direction(base.rotated(deg_to_rad(value)))
	angle_input.set_value_no_signal(rad_to_deg(base.angle_to(game.ship.thrust_direction)))
	sync_state()

func _acceleration_changed(value: float) -> void:
	if not _can_aim():
		return
	var maximum: float = game.ship.get_effective_steering_acceleration()
	game._set_throttle(clampf(value, 0.0, maximum) / maximum if maximum > 0.0 else 0.0)
	sync_state()

func _cutoff() -> void:
	if is_instance_valid(game):
		game._stop_thrust()
		sync_state()

func _max_speed_changed(value: float) -> void:
	if is_instance_valid(game) and is_instance_valid(game.ship):
		game._set_autopilot_max_speed(value)
		if not is_finite(value) or value < 1.0 or value > 100000.0:
			max_speed_input.set_value_no_signal(game.ship.autopilot_max_speed)

func _cancel_autopilot() -> void:
	if is_instance_valid(game) and not game.tutorial_pause:
		game._stop_autopilot("自动航行已取消，保持当前速度。")
		sync_state()

## 自动航行模式下只保留仪表、最大速度与取消按钮；默认模式恢复全部控件。
func set_autopilot_mode(enabled: bool) -> void:
	$Layout/Title.text = "自动航行" if enabled else "手动推力"
	$Layout/MaxSpeedLabel.visible = enabled
	$Layout/MaxSpeed.visible = enabled
	$Layout/CancelAutopilot.visible = enabled
	var normal := not enabled
	for node in [$Layout/Throttle, $Layout/AngleLabel, $Layout/AngleLock, $Layout/Angle, $Layout/AccelerationLabel, $Layout/Acceleration, $Layout/AccelerateButton, $Layout/BrakeButton, $Layout/Cutoff, $Layout/Legend]:
		node.visible = normal
	$Layout/Output.visible = true

func sync_state() -> void:
	if not is_node_ready() or not is_instance_valid(game):
		return
	var valid := is_instance_valid(game.ship)
	var automatic: bool = valid and game.ship.autopilot_enabled
	set_autopilot_mode(automatic)
	autopilot_button.visible = not automatic and game._can_enable_autopilot()
	cancel_autopilot_button.disabled = game.tutorial_pause
	max_speed_input.editable = automatic and not game.tutorial_pause
	var next_id: int = game.ship.get_instance_id() if valid else 0
	if next_id != controlled_id or not _can_aim():
		dragging = false
	controlled_id = next_id
	velocity_needle.visible = valid and game.ship.flight_velocity.length() > 0.01
	thrust_needle.visible = valid
	if valid:
		velocity_needle.rotation = game.ship.flight_velocity.angle()
		if automatic:
			thrust_needle.visible = game.ship.autopilot_acceleration.length_squared() > 0.000001
			thrust_needle.rotation = game.ship.autopilot_acceleration.angle()
		else:
			thrust_needle.rotation = game.ship.thrust_direction.angle()
		if not max_speed_input.get_line_edit().has_focus():
			max_speed_input.set_value_no_signal(game.ship.autopilot_max_speed)
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
		if automatic:
			$Layout/Title.text = "自动航行 · 执行中" if game.ship.autopilot_active else "自动航行 · 待命"
			output.text = "右键空白处设点 / 更换目标" if game.ship.autopilot_active else "右键空白处设置导航点"
		if game.ship.flight_velocity.length() <= 0.01:
			$Layout/Legend.text = "绿：静止  橙：推力"
		else:
			$Layout/Legend.text = "绿：速度  橙：推力"
	else:
		slider.set_value_no_signal(0)
		output.text = "未选中飞船"
	slider.editable = _can_aim() and game.ship.fuel > 0.0 and game.ship.get_effective_steering_acceleration() > 0.0
	angle_input.editable = _can_aim()
	angle_lock.disabled = not _can_aim()
	acceleration_input.editable = slider.editable
