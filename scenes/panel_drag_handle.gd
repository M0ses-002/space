extends Label
## 标题栏拖动组件：只移动面板，不拦截面板内按钮、油门和指针。
## 要移动的面板节点，相对于当前标题栏；面板应放在普通 Control 下而不是 Container 下。
@export var panel_path: NodePath
## 自动布局面板的期望高度，单位像素；0 保留当前高度，内容最小高度仍优先。
@export var preferred_height := 0.0
var panel: Control
var moving := false
var grab_offset := Vector2.ZERO

func _ready() -> void:
	panel = get_node(panel_path) as Control
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_MOVE
	tooltip_text = "按住标题拖动面板"
	gui_input.connect(_handle_input)
	get_window().focus_exited.connect(_cancel_drag)
	# 等待容器完成首次换行布局，避免用中间尺寸改写场景中的初始位置。
	await get_tree().process_frame
	if not is_inside_tree():
		return
	await get_tree().process_frame
	if not is_inside_tree():
		return
	get_viewport().size_changed.connect(_schedule_clamp)
	panel.resized.connect(_schedule_clamp)
	panel.minimum_size_changed.connect(_schedule_clamp)
	_clamp_panel.call_deferred()

func _handle_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		moving = event.pressed
		if moving:
			grab_offset = get_global_transform() * event.position - panel.global_position
			panel.move_to_front()
		accept_event()

func _input(event: InputEvent) -> void:
	if not moving:
		return
	if not is_visible_in_tree():
		_cancel_drag()
		return
	if event is InputEventMouseMotion:
		panel.global_position = event.position - grab_offset
		_clamp_panel()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_cancel_drag()
		get_viewport().set_input_as_handled()

func _cancel_drag() -> void:
	moving = false

func _schedule_clamp() -> void:
	_clamp_panel.call_deferred()

func _clamp_panel() -> void:
	if not is_instance_valid(panel) or not panel.is_inside_tree():
		return
	var viewport_size := get_viewport_rect().size
	# 自动换行控件初始化时可能短暂撑高面板；布局稳定后收回到视口内。
	panel.size = Vector2(minf(panel.size.x, viewport_size.x), minf(preferred_height if preferred_height > 0.0 else panel.size.y, viewport_size.y))
	# 普通窗口保持整块可见；窗口小于面板时仍保留左上标题可操作。
	panel.global_position = Vector2(
		clampf(panel.global_position.x, 0.0, maxf(0.0, viewport_size.x - panel.size.x)),
		clampf(panel.global_position.y, 0.0, maxf(0.0, viewport_size.y - panel.size.y)))
