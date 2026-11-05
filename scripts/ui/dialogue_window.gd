extends CanvasLayer
## 独立非模态通知；UI节点保存在场景，队列不影响游戏物理或模拟倍率。
signal dialogue_started(data: Dictionary)
signal dialogue_finished(data: Dictionary)
signal queue_finished

enum Phase { IDLE, SLIDING_IN, READING, WAITING_CONFIRM, SLIDING_OUT }
@export_range(0.0, 2.0, 0.01) var slide_seconds: float = 0.25
## 读条开始后至少经过这么久才允许点击跳过，避免弹出瞬间的误触吃掉整条对话。
@export var minimum_read_seconds: float = 0.2
@export var screen_margin: Vector2 = Vector2(16.0, 76.0)
var phase: Phase = Phase.IDLE
var current_dialogue: Dictionary = {}
var _queue: Array[Dictionary] = []
var _phase_started_usec: int = 0
var _reading_seconds: float = 1.0
var _skip_requested := false
@onready var panel: PanelContainer = $Root/Panel
@onready var portrait: TextureRect = $Root/Portrait
@onready var portrait_spacer: Control = $Root/Panel/Margin/Content/Message/PortraitSpacer
@onready var message: Label = $Root/Panel/Margin/Content/Message/Text
@onready var progress: ProgressBar = $Root/Panel/Margin/Content/Progress
@onready var confirm_button: Button = $Root/Panel/Margin/Content/Message/Confirm
const FALLBACK_PORTRAIT: Texture2D = preload("res://assets/ui/person_default.svg")

func _ready() -> void:
	confirm_button.pressed.connect(_on_confirm_pressed)
	clear_queue()

func _on_confirm_pressed() -> void:
	if phase != Phase.WAITING_CONFIRM or confirm_button.disabled:
		return
	confirm_button.disabled = true
	phase = Phase.SLIDING_OUT
	_phase_started_usec = Time.get_ticks_usec()

## 数据接口：portrait为res://图片路径，text为正文，duration为现实秒。
func enqueue_dialogue(data: Dictionary) -> bool:
	var duration: Variant = data.get("duration")
	if not data.get("text") is String or not (duration is float or duration is int):
		return false
	if not is_finite(float(duration)) or float(duration) <= 0.0:
		return false
	_queue.append(data.duplicate(true))
	if phase == Phase.IDLE:
		_start_next()
	return true

## 目标达成只解锁当前教程消息；不确认、不出队，也不影响后续消息计时。
func complete_current_reading(token_key: String, token: int) -> bool:
	if token_key not in ["tutorial_token", "orbit_tutorial_token"] or not current_dialogue.has(token_key) or current_dialogue[token_key] != token:
		return false
	if not bool(current_dialogue.get("requires_confirmation", false)) or phase not in [Phase.SLIDING_IN, Phase.READING, Phase.WAITING_CONFIRM]:
		return false
	_place_panel(1.0)
	progress.value = 1.0
	confirm_button.disabled = false
	phase = Phase.WAITING_CONFIRM
	return true

func clear_queue() -> void:
	_queue.clear()
	current_dialogue = {}
	phase = Phase.IDLE
	_skip_requested = false
	visible = false
	if is_instance_valid(progress):
		progress.value = 0.0
	if is_instance_valid(confirm_button):
		confirm_button.disabled = true
		confirm_button.hide()

func pending_count() -> int:
	return _queue.size() + (0 if phase == Phase.IDLE else 1)

func _start_next() -> void:
	if _queue.is_empty():
		phase = Phase.IDLE
		visible = false
		queue_finished.emit()
		return
	current_dialogue = _queue.pop_front()
	confirm_button.visible = bool(current_dialogue.get("requires_confirmation", false))
	confirm_button.disabled = true
	message.text = current_dialogue.text
	_reading_seconds = float(current_dialogue.duration)
	_skip_requested = false
	portrait.texture = FALLBACK_PORTRAIT
	var path: String = str(current_dialogue.get("portrait", ""))
	if path.begins_with("res://") and ResourceLoader.exists(path, "Texture2D"):
		var texture := load(path) as Texture2D
		if texture != null:
			portrait.texture = texture
	progress.value = 0.0
	visible = true
	phase = Phase.SLIDING_IN
	_phase_started_usec = Time.get_ticks_usec()
	_place_panel(0.0)
	dialogue_started.emit(current_dialogue.duplicate(true))

func _place_panel(reveal: float) -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	var bottom := viewport_size.y - screen_margin.y
	# 底部对话框占窗口72%，HUD在上方预留独立空间。
	panel.size = Vector2(viewport_size.x * 0.55, 100.0)
	var left := (viewport_size.x - panel.size.x) * 0.5
	panel.position = Vector2(left, lerpf(viewport_size.y + 12.0, bottom - panel.size.y, reveal))
	# 人物图独立于 Message 布局：底部对齐面板，可向上超出面板边界。
	portrait.size = portrait.custom_minimum_size
	portrait_spacer.custom_minimum_size.x = portrait.size.x + 18.0
	portrait.position = panel.position + Vector2(16.0, panel.size.y - 12.0 - portrait.size.y)

func _process(_delta: float) -> void:
	if phase == Phase.IDLE:
		return
	# 单调现实时间，不乘模拟倍率；process_mode=ALWAYS使暂停菜单也不会冻结通知。
	var elapsed := float(Time.get_ticks_usec() - _phase_started_usec) / 1000000.0
	match phase:
		Phase.SLIDING_IN:
			var fraction := 1.0 if slide_seconds <= 0.0 else clampf(elapsed / slide_seconds, 0.0, 1.0)
			_place_panel(1.0 - pow(1.0 - fraction, 3.0))
			if fraction >= 1.0:
				phase = Phase.READING
				_phase_started_usec = Time.get_ticks_usec()
		Phase.READING:
			_place_panel(1.0)
			progress.value = clampf(elapsed / _reading_seconds, 0.0, 1.0)
			if (elapsed >= _reading_seconds) or (_skip_requested and elapsed >= minimum_read_seconds):
				_finish_reading()
		Phase.WAITING_CONFIRM:
			_place_panel(1.0)
		Phase.SLIDING_OUT:
			var fraction := 1.0 if slide_seconds <= 0.0 else clampf(elapsed / slide_seconds, 0.0, 1.0)
			_place_panel(1.0 - fraction * fraction * fraction)
			if fraction >= 1.0:
				var completed := current_dialogue.duplicate(true)
				# 先进入空闲再发完成信号，保证外部重入入队不会丢失通知。
				current_dialogue = {}
				phase = Phase.IDLE
				visible = false
				dialogue_finished.emit(completed)
				if phase == Phase.IDLE:
					_start_next()

## 读条结束：需要确认则进入等待确认（出现「确认继续」），否则滑出进入下一条。
func _finish_reading() -> void:
	progress.value = 1.0
	if bool(current_dialogue.get("requires_confirmation", false)):
		phase = Phase.WAITING_CONFIRM
		confirm_button.disabled = false
	else:
		phase = Phase.SLIDING_OUT
	_phase_started_usec = Time.get_ticks_usec()

## 读条期间单击立即结束当前读条；确认阶段由「确认继续」按钮处理，不吞点击。
func _input(event: InputEvent) -> void:
	if phase != Phase.READING:
		return
	var pressed := false
	if event is InputEventMouseButton:
		pressed = event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	elif event is InputEventKey:
		pressed = event.pressed and not event.echo and event.keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]
	if not pressed:
		return
	var elapsed := float(Time.get_ticks_usec() - _phase_started_usec) / 1000000.0
	if elapsed < minimum_read_seconds:
		return
	_skip_requested = true
	# 读条期间吞掉点击，避免穿透到航行操作或暂停菜单。
	get_viewport().set_input_as_handled()
