extends CanvasLayer
## 独立非模态通知；UI节点保存在场景，队列不影响游戏物理或模拟倍率。
signal dialogue_started(data: Dictionary)
signal dialogue_finished(data: Dictionary)
signal queue_finished

enum Phase { IDLE, SLIDING_IN, READING, SLIDING_OUT }
@export_range(0.0, 2.0, 0.01) var slide_seconds: float = 0.25
@export var screen_margin: Vector2 = Vector2(16.0, 48.0)
var phase: Phase = Phase.IDLE
var current_dialogue: Dictionary = {}
var _queue: Array[Dictionary] = []
var _phase_started_usec: int = 0
var _reading_seconds: float = 1.0
@onready var panel: PanelContainer = $Root/Panel
@onready var portrait: TextureRect = $Root/Panel/Margin/Content/Message/Portrait
@onready var message: Label = $Root/Panel/Margin/Content/Message/Text
@onready var progress: ProgressBar = $Root/Panel/Margin/Content/Progress
const FALLBACK_PORTRAIT: Texture2D = preload("res://scenes/person_default.svg")

func _ready() -> void:
	clear_queue()

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

func clear_queue() -> void:
	_queue.clear()
	current_dialogue = {}
	phase = Phase.IDLE
	visible = false
	if is_instance_valid(progress):
		progress.value = 0.0

func pending_count() -> int:
	return _queue.size() + (0 if phase == Phase.IDLE else 1)

func _start_next() -> void:
	if _queue.is_empty():
		phase = Phase.IDLE
		visible = false
		queue_finished.emit()
		return
	current_dialogue = _queue.pop_front()
	message.text = current_dialogue.text
	_reading_seconds = float(current_dialogue.duration)
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
	# 窄屏让出右侧仪表；布局仍来自场景，运行时只调整尺寸与整体位置。
	var narrow: bool = get_viewport().get_visible_rect().size.x < 1060.0
	var left: float = 12.0 if narrow else screen_margin.x
	portrait.custom_minimum_size = Vector2.ONE * (36.0 if narrow else 44.0)
	message.add_theme_font_size_override("font_size", 13 if narrow else 15)
	# 高度由当前换行后的容器最小尺寸重新计算，避免保留窄/零宽初排产生的旧高度。
	panel.size = Vector2(210.0 if narrow else 320.0, 0.0)
	var top: float = screen_margin.y
	var fleet := get_parent().get_node_or_null("HUD/Root/FleetBar") as Control
	if fleet != null:
		top = fleet.get_global_rect().end.y + 12.0
	panel.position = Vector2(lerpf(-panel.size.x - left, left, reveal), top)

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
			if elapsed >= _reading_seconds:
				phase = Phase.SLIDING_OUT
				_phase_started_usec = Time.get_ticks_usec()
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
