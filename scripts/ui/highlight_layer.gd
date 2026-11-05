extends CanvasLayer
## 教程高亮层：订阅教程的高亮信号，在目标控件周围显示高亮框，或在世界节点上显示圆环标记。
## 只做视觉，不拦截鼠标；目标节点由 TutorialController.resolve_highlight_target 解析。

@export var highlight_padding := 6.0
@export var ring_radius := 28.0

var _tutorials: Array[Node] = []
var _target: Node
var _time := 0.0
@onready var frame: Panel = $Frame
@onready var ring: Line2D = $Ring

func _ready() -> void:
	frame.visible = false
	ring.visible = false
	_build_ring()
	var tutorial := get_parent().get_node_or_null("TutorialController")
	if tutorial != null:
		bind_tutorial(tutorial)
	var orbit_tutorial := get_parent().get_node_or_null("OrbitTutorialController")
	if orbit_tutorial != null:
		bind_tutorial(orbit_tutorial)

func bind_tutorial(tutorial: Node) -> void:
	if tutorial == null or _tutorials.has(tutorial):
		return
	_tutorials.append(tutorial)
	if not tutorial.highlight_requested.is_connected(_on_highlight):
		tutorial.highlight_requested.connect(_on_highlight)
	if not tutorial.highlight_cleared.is_connected(_clear):
		tutorial.highlight_cleared.connect(_clear)

func _on_highlight(target_id: String) -> void:
	_target = null
	for tutorial in _tutorials:
		if tutorial != null and tutorial.has_method("resolve_highlight_target"):
			var target: Node = tutorial.resolve_highlight_target(target_id)
			if is_instance_valid(target):
				_target = target
				break
	_refresh()

func _clear() -> void:
	_target = null
	frame.visible = false
	ring.visible = false

func _build_ring() -> void:
	var segments := 48
	var points := PackedVector2Array()
	for i in range(segments + 1):
		var angle := TAU * float(i) / float(segments)
		points.append(Vector2(cos(angle), sin(angle)) * ring_radius)
	ring.points = points

func _process(delta: float) -> void:
	_time += delta
	# 呼吸动画：让高亮更醒目，但不改变边框几何。
	var pulse := 0.7 + 0.3 * sin(_time * 4.0)
	frame.modulate.a = pulse
	ring.modulate.a = pulse
	_refresh()

func _refresh() -> void:
	if not is_instance_valid(_target):
		frame.visible = false
		ring.visible = false
		return
	if _target is Control:
		var rect := (_target as Control).get_global_rect().grow(highlight_padding)
		frame.visible = true
		frame.position = rect.position
		frame.size = rect.size
		ring.visible = false
	elif _target is CanvasItem:
		var origin := (_target as CanvasItem).get_global_transform_with_canvas().origin
		frame.visible = false
		ring.visible = true
		ring.position = origin
	else:
		frame.visible = false
		ring.visible = false
