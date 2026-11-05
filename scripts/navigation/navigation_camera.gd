extends Camera2D
## WASD 平移和滚轮缩放世界画布；HUD 位于独立 CanvasLayer，不受相机影响。
## WASD 平移速度，单位：屏幕像素/秒。缩放倍率越高，屏幕移动速度保持一致。
@export_range(50.0, 2000.0, 50.0) var pan_speed := 600.0
## 最小缩放倍率，滚轮向下缩小时不会低于此值。
@export_range(0.025, 1.0, 0.025) var minimum_zoom := 0.025
## 最大缩放倍率，滚轮向上放大时不会超过此值。
@export_range(1.0, 10.0, 0.25) var maximum_zoom := 4.0
## 每格滚轮的缩放步进倍率，大于 1 表示向上放大。
@export_range(1.01, 2.0, 0.01) var wheel_step := 1.15
## HUD 根节点路径，用于判断鼠标是否悬停在 UI 上以屏蔽滚轮缩放。
@export var ui_root: NodePath = NodePath("../HUD/Root")

## 回船操作开启跟随；手动平移解除跟随，滚轮只调整缩放。
var following := false
var zoom_level := 1.0
var previous_viewport_size := Vector2.ZERO
var tutorial_target: Node2D
var tutorial_zoom := 2.0
var _before_tutorial_following := false
var _before_tutorial_zoom := 1.0

func is_tutorial_locked() -> bool:
	return is_instance_valid(tutorial_target)

## 受控飞船开启 camera_always_follow 时，视角锁定跟随，任何平移都不解除。
func is_ship_follow_locked() -> bool:
	var game := get_parent()
	if game == null:
		return false
	var vessel = game.get("ship")
	return is_instance_valid(vessel) and bool(vessel.camera_always_follow)

func lock_tutorial_view(vessel: Node2D, fixed_zoom: float) -> void:
	if not is_tutorial_locked():
		_before_tutorial_following = following
		_before_tutorial_zoom = zoom_level
	tutorial_target = vessel
	tutorial_zoom = clampf(fixed_zoom, minimum_zoom, maximum_zoom)
	apply_tutorial_view()

func clear_tutorial_view() -> void:
	if not is_tutorial_locked():
		tutorial_target = null
		return
	tutorial_target = null
	following = _before_tutorial_following
	zoom_level = _before_tutorial_zoom
	zoom = Vector2.ONE * zoom_level
	force_update_scroll()

func apply_tutorial_view() -> void:
	if not is_tutorial_locked():
		return
	var game := get_parent()
	following = true
	zoom_level = tutorial_zoom
	zoom = Vector2.ONE * zoom_level
	global_position = game.get_node("World").to_global(game._to_screen(tutorial_target.flight_position))
	force_update_scroll()

func _ready() -> void:
	previous_viewport_size = get_viewport_rect().size
	position = previous_viewport_size * 0.5
	get_viewport().size_changed.connect(_on_viewport_resized)
	force_update_scroll()

func _process(delta: float) -> void:
	if is_tutorial_locked():
		apply_tutorial_view()
		return
	# 输入框编辑文字时不抢占 WASD；普通按钮获得焦点不阻止导航。
	var focused := get_viewport().gui_get_focus_owner()
	if focused is LineEdit or focused is TextEdit:
		return
	var direction := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W))
	)
	_pan(direction, delta)

func _pan(direction: Vector2, delta: float) -> void:
	if is_tutorial_locked() or direction.is_zero_approx():
		return
	# 飞船开启「视角始终跟随」时，不允许从跟随状态被平移解除；星图等自由视角仍可平移。
	if is_ship_follow_locked() and following:
		return
	following = false
	# 单位为屏幕像素/秒，避免斜向或高倍率下移动过快。
	position += direction.limit_length(1.0) * pan_speed * delta / zoom_level
	force_update_scroll()

func _on_viewport_resized() -> void:
	var new_size := get_viewport_rect().size
	if is_tutorial_locked():
		previous_viewport_size = new_size
		apply_tutorial_view()
		return
	position += (new_size - previous_viewport_size) * 0.5
	previous_viewport_size = new_size
	force_update_scroll()

func reset_view() -> void:
	if is_tutorial_locked():
		apply_tutorial_view()
		return
	# 锁定跟随时重置只复位缩放，跟随状态保留（居中由 StarMapView 每帧维护）。
	following = is_ship_follow_locked()
	zoom_level = 1.0
	zoom = Vector2.ONE
	position = get_viewport_rect().size * 0.5
	force_update_scroll()

func _over_ui(screen_position: Vector2) -> bool:
	var hovered := get_viewport().gui_get_hovered_control()
	var hud := get_node_or_null(ui_root)
	if hovered != null and hud != null and (hovered == hud or hud.is_ancestor_of(hovered)):
		return true
	for path in ["../StarMapView/HUD/Root/NavigationButtons", "../HUD/Root/ThrustDial", "../HUD/Root/BottomActions"]:
		var map_panel := get_node_or_null(path) as Control
		if map_panel != null and map_panel.is_visible_in_tree() and map_panel.get_global_rect().has_point(screen_position):
			return true
	var root := get_node_or_null(ui_root)
	if root == null:
		return false
	# 首次滚轮可能尚未伴随鼠标移动事件，补充可交互 HUD 的边界检查。
	for node in root.find_children("*", "Control", true, false):
		var control := node as Control
		if control.is_visible_in_tree() and control.mouse_filter != Control.MOUSE_FILTER_IGNORE and control.get_global_rect().has_point(screen_position):
			return true
	return false

func _input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or not event.pressed:
		return
	if event.button_index != MOUSE_BUTTON_WHEEL_UP and event.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return
	if is_tutorial_locked():
		get_viewport().set_input_as_handled()
		return
	if _over_ui(event.position):
		return
	var direction := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
	var amount: float = event.factor if event.factor > 0.0 else 1.0
	var next_zoom := clampf(zoom_level * pow(wheel_step, direction * amount), minimum_zoom, maximum_zoom)
	# 跟随时由视图保持船的屏幕锚点；自由视角才固定光标下的世界位置。
	var world_before: Vector2 = get_canvas_transform().affine_inverse() * event.position
	zoom_level = next_zoom
	zoom = Vector2.ONE * zoom_level
	force_update_scroll()
	if following:
		var view := get_node_or_null("../StarMapView")
		if view != null and view.is_initialized and is_instance_valid(view.game.ship):
			view._center_on_ship()
	else:
		var world_after: Vector2 = get_canvas_transform().affine_inverse() * event.position
		position += world_before - world_after
		force_update_scroll()
	get_viewport().set_input_as_handled()
