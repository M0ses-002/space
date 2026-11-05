extends CanvasLayer
## 全屏 CG 窗口：只有「图片」与「文本」两部分，节奏沿用对话窗口的淡入→停留→淡出。
## 数据接口与 DialogueWindow 一致：每条 CG 是一个字典，入队后按 duration（现实秒）自动推进。
signal cg_started(data: Dictionary)
signal cg_finished(data: Dictionary)
signal queue_finished

enum Phase { IDLE, FADING_IN, HOLDING, FADING_OUT }

@export_range(0.0, 2.0, 0.01) var fade_seconds: float = 0.35
## 停留阶段至少持续这么久才允许点击跳过，避免触发瞬间的误触把整段 CG 吃掉。
@export var minimum_read_seconds: float = 0.35

var phase: Phase = Phase.IDLE
var current_cg: Dictionary = {}
var _queue: Array[Dictionary] = []
var _phase_started_usec: int = 0
var _hold_seconds: float = 1.0
var _skip_requested: bool = false

@onready var root: Control = $Root
@onready var image: TextureRect = $Root/Image
@onready var text_label: Label = $Root/Bottom/Margin/Content/Text
@onready var progress: ProgressBar = $Root/Bottom/Margin/Content/Progress
@onready var hint: Label = $Root/Hint

func _ready() -> void:
	clear_queue()

## 入队一条 CG：image 为 res:// 图片路径，text 为文本，duration 为现实秒。
## 可选 skippable（默认 true）决定点击能否提前结束。
func enqueue_cg(data: Dictionary) -> bool:
	if not data.get("image") is String or str(data.get("image", "")).is_empty():
		return false
	if not data.get("text") is String:
		return false
	var duration: Variant = data.get("duration")
	if not (duration is float or duration is int):
		return false
	if not is_finite(float(duration)) or float(duration) <= 0.0:
		return false
	_queue.append(data.duplicate(true))
	if phase == Phase.IDLE:
		_start_next()
	return true

func clear_queue() -> void:
	_queue.clear()
	current_cg = {}
	phase = Phase.IDLE
	_skip_requested = false
	visible = false
	if is_instance_valid(root):
		root.modulate.a = 0.0
	if is_instance_valid(progress):
		progress.value = 0.0

func pending_count() -> int:
	return _queue.size() + (0 if phase == Phase.IDLE else 1)

func is_playing() -> bool:
	return phase != Phase.IDLE

## 立即结束当前 CG 的停留阶段；只在可跳过时生效。
func request_skip() -> void:
	if phase not in [Phase.FADING_IN, Phase.HOLDING]:
		return
	if not bool(current_cg.get("skippable", true)):
		return
	var elapsed := float(Time.get_ticks_usec() - _phase_started_usec) / 1000000.0
	if phase == Phase.FADING_IN or elapsed < minimum_read_seconds:
		return
	_skip_requested = true

func _input(event: InputEvent) -> void:
	if phase == Phase.IDLE:
		return
	var pressed := false
	if event is InputEventMouseButton:
		pressed = event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	elif event is InputEventKey:
		pressed = event.pressed and not event.echo and event.keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE]
	if pressed:
		request_skip()
		# CG 期间吞掉输入，避免点击穿透到航行操作或暂停菜单。
		get_viewport().set_input_as_handled()

func _start_next() -> void:
	if _queue.is_empty():
		phase = Phase.IDLE
		visible = false
		root.modulate.a = 0.0
		queue_finished.emit()
		return
	current_cg = _queue.pop_front()
	text_label.text = str(current_cg.get("text", ""))
	_hold_seconds = float(current_cg.duration)
	_skip_requested = false
	image.texture = _load_texture(str(current_cg.get("image", "")))
	hint.visible = bool(current_cg.get("skippable", true))
	progress.value = 0.0
	root.modulate.a = 0.0
	visible = true
	phase = Phase.FADING_IN
	_phase_started_usec = Time.get_ticks_usec()
	cg_started.emit(current_cg.duplicate(true))

func _load_texture(path: String) -> Texture2D:
	if path.begins_with("res://") and ResourceLoader.exists(path, "Texture2D"):
		return load(path) as Texture2D
	# 图片缺失不阻断播放：保留黑底与文本，便于美术资源后补时先跑通剧情。
	push_warning("CG 图片不存在：%s" % path)
	return null

func _process(_delta: float) -> void:
	if phase == Phase.IDLE:
		return
	# 与对话窗口一致：单调现实时间，不乘模拟倍率；paused 时仍能读完。
	var elapsed := float(Time.get_ticks_usec() - _phase_started_usec) / 1000000.0
	match phase:
		Phase.FADING_IN:
			var fraction := 1.0 if fade_seconds <= 0.0 else clampf(elapsed / fade_seconds, 0.0, 1.0)
			root.modulate.a = fraction * fraction
			if fraction >= 1.0:
				phase = Phase.HOLDING
				_phase_started_usec = Time.get_ticks_usec()
		Phase.HOLDING:
			root.modulate.a = 1.0
			progress.value = clampf(elapsed / _hold_seconds, 0.0, 1.0)
			if _skip_requested or elapsed >= _hold_seconds:
				progress.value = 1.0
				phase = Phase.FADING_OUT
				_phase_started_usec = Time.get_ticks_usec()
		Phase.FADING_OUT:
			var fraction := 1.0 if fade_seconds <= 0.0 else clampf(elapsed / fade_seconds, 0.0, 1.0)
			root.modulate.a = 1.0 - fraction
			if fraction >= 1.0:
				var completed := current_cg.duplicate(true)
				current_cg = {}
				phase = Phase.IDLE
				visible = false
				root.modulate.a = 0.0
				# 先回到空闲再发完成信号，外部在同一次回调里入队不会丢通知。
				cg_finished.emit(completed)
				if phase == Phase.IDLE:
					_start_next()
