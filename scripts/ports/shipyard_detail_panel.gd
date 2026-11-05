extends PanelContainer
## 船坞配件详情：非窗口浮层，使用视口鼠标坐标持续跟随，不参与鼠标命中。

const CURSOR_OFFSET := Vector2(20, 20)
const VIEWPORT_MARGIN := Vector2(12, 12)

@onready var title_label: Label = %Title
@onready var description_label: Label = %Description
@onready var credits_label: Label = %Credits

var _anchor_viewport := Vector2.ZERO

func _ready() -> void:
	resized.connect(_update_position)
	minimum_size_changed.connect(_fit_content)
	get_viewport().size_changed.connect(_update_position)
	hide()

func _input(event: InputEvent) -> void:
	if visible and event is InputEventMouseMotion:
		_anchor_viewport = event.position
		_update_position()

func show_detail(data: Dictionary, anchor_viewport_pos: Vector2) -> void:
	title_label.text = str(data.get("name", "未命名改装"))
	description_label.text = str(data.get("description", ""))
	credits_label.text = "信用点 %d" % int(data.get("credits", 0))
	_anchor_viewport = anchor_viewport_pos
	size = custom_minimum_size
	show()
	_update_position()

func _fit_content() -> void:
	size = get_combined_minimum_size()
	_update_position()

func _update_position() -> void:
	if not visible:
		return
	# 在视口坐标中翻转和夹取，再转回浮层画布坐标；不混用窗口物理像素。
	var viewport_rect := get_viewport().get_visible_rect()
	var panel_rect := get_global_transform_with_canvas() * Rect2(Vector2.ZERO, size)
	var panel_size := panel_rect.size
	var lower_bound := viewport_rect.position + VIEWPORT_MARGIN
	var upper_bound := viewport_rect.end - VIEWPORT_MARGIN
	var desired := _anchor_viewport + CURSOR_OFFSET
	if desired.x + panel_size.x > upper_bound.x:
		desired.x = _anchor_viewport.x - panel_size.x - CURSOR_OFFSET.x
	if desired.y + panel_size.y > upper_bound.y:
		desired.y = _anchor_viewport.y - panel_size.y - CURSOR_OFFSET.y
	desired.x = clampf(desired.x, lower_bound.x, maxf(lower_bound.x, upper_bound.x - panel_size.x))
	desired.y = clampf(desired.y, lower_bound.y, maxf(lower_bound.y, upper_bound.y - panel_size.y))
	global_position = get_canvas_transform().affine_inverse() * desired

func hide_detail() -> void:
	hide()
