extends SceneTree

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func make_panel() -> Control:
	var panel := Control.new()
	panel.size = Vector2(300, 200)
	var handle := Label.new()
	handle.set_script(load("res://scenes/panel_drag_handle.gd"))
	handle.panel_path = NodePath("..")
	panel.add_child(handle)
	root.add_child(panel)
	return panel

func _run() -> void:
	var first := make_panel()
	root.remove_child(first)
	await process_frame
	await process_frame
	first.free()
	var second := make_panel()
	await process_frame
	root.remove_child(second)
	await process_frame
	await process_frame
	second.free()
	var surviving := make_panel()
	await process_frame
	await process_frame
	await process_frame
	var handle = surviving.get_child(0)
	check(root.size_changed.is_connected(handle._schedule_clamp), "保留的面板应连接视口大小变化信号")
	check(surviving.resized.is_connected(handle._schedule_clamp), "保留的面板应连接大小变化信号")
	surviving.free()
	var music = root.get_node_or_null("BackgroundMusic")
	if music:
		music.stop()
		music.queue_free()
	await create_timer(0.3).timeout
	quit(1 if failures else 0)
