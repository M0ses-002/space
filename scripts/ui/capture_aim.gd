extends CanvasLayer
## 捕捉网瞄准层：以飞船屏幕位置为圆心的定长箭头 + 角度输入框。
## 只负责显示、拖动/输入的角度维护与信号上报；暂停、发射与取消由 main 决定。

signal angle_submitted(radians: float)

## 箭头长度（屏幕像素），与缩放无关，保证任何视角下长度一致。
@export_range(40.0, 600.0, 5.0) var arrow_length_px := 160.0
## 箭头颜色。
@export var arrow_color := Color(0.86, 0.91, 0.96, 0.95)
## 角度面板相对飞船中心的偏移（屏幕像素）。
@export var panel_offset := Vector2(56.0, -112.0)
## 角度面板与窗口边缘的最小距离。
@export_range(0.0, 120.0, 1.0) var panel_margin := 12.0

var _angle := 0.0

@onready var arrow: Node2D = $Arrow
@onready var shaft: Line2D = $Arrow/Shaft
@onready var head: Polygon2D = $Arrow/Head
@onready var angle_panel: PanelContainer = $AnglePanel
@onready var angle_input: LineEdit = $AnglePanel/Margin/Content/Row/AngleInput

func _ready() -> void:
	shaft.default_color = arrow_color
	head.color = arrow_color
	shaft.points = PackedVector2Array([Vector2.ZERO, Vector2(arrow_length_px, 0.0)])
	head.polygon = PackedVector2Array([
		Vector2(arrow_length_px - 14.0, -9.0),
		Vector2(arrow_length_px, 0.0),
		Vector2(arrow_length_px - 14.0, 9.0),
	])
	angle_input.text_submitted.connect(_on_text_submitted)
	angle_input.focus_exited.connect(_commit_text)
	hide_aim()

func is_aiming() -> bool:
	return angle_panel.visible

## 显示瞄准并同步一次位置与角度。
func show_aim(ship_screen: Vector2, radians: float) -> void:
	arrow.visible = true
	angle_panel.visible = true
	set_placement(ship_screen)
	set_angle(radians, true)

func hide_aim() -> void:
	arrow.visible = false
	angle_panel.visible = false
	angle_input.release_focus()

## 每帧跟随飞船；面板按窗口边缘夹取，避免飞出屏幕。
func set_placement(ship_screen: Vector2) -> void:
	arrow.position = ship_screen
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var panel_size: Vector2 = angle_panel.size
	if panel_size.x <= 0.0 or panel_size.y <= 0.0:
		panel_size = angle_panel.get_combined_minimum_size()
	var target: Vector2 = ship_screen + panel_offset
	target.x = clampf(target.x, panel_margin, maxf(panel_margin, viewport_size.x - panel_size.x - panel_margin))
	target.y = clampf(target.y, panel_margin, maxf(panel_margin, viewport_size.y - panel_size.y - panel_margin))
	angle_panel.position = target

## 写入角度（弧度）；输入框获得焦点时不覆盖玩家正在输入的内容。
func set_angle(radians: float, sync_input: bool = true) -> void:
	_angle = wrapf(radians, -PI, PI)
	arrow.rotation = _angle
	if sync_input and not angle_input.has_focus():
		angle_input.text = "%.1f" % rad_to_deg(_angle)

func angle() -> float:
	return _angle

## 鼠标是否落在角度输入面板上；用于区分拖动箭头与操作输入框。
func contains_point(point: Vector2) -> bool:
	return angle_panel.visible and angle_panel.get_global_rect().has_point(point)

func _on_text_submitted(_text: String) -> void:
	_commit_text()
	angle_input.release_focus()

func _commit_text() -> void:
	var text := angle_input.text.strip_edges()
	if not text.is_valid_float():
		angle_input.text = "%.1f" % rad_to_deg(_angle)
		return
	var degrees := fmod(float(text), 360.0)
	set_angle(deg_to_rad(degrees), true)
	angle_input.text = "%.1f" % rad_to_deg(_angle)
	angle_submitted.emit(_angle)
