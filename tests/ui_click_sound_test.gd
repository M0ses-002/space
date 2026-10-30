extends SceneTree

var failures := 0
var downs := 0

func mouse_at(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = position
	event.pressed = pressed
	root.push_input(event, true)

func internal_buttons(node: Node) -> Array[BaseButton]:
	var result: Array[BaseButton] = []
	if node is BaseButton:
		result.append(node)
	for child in node.get_children(true):
		result.append_array(internal_buttons(child))
	return result

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func _run() -> void:
	var existing := Button.new()
	root.add_child(existing)
	var sound = root.get_node_or_null("UIClickSound")
	if sound == null:
		sound = load("res://scenes/ui_click_sound.tscn").instantiate()
		root.add_child(sound)
	await process_frame
	check(sound.stream is AudioStreamWAV and sound.stream.get_length() > 0.0, "点击音效资源可播放")
	check(existing.button_down.get_connections().size() == 1, "已有按钮仅连接一次")
	existing.button_down.emit()
	check(sound.playing, "已有按钮触发播放")
	sound.stop()
	existing.disabled = true
	existing.button_down.emit()
	check(not sound.playing, "禁用按钮不触发播放")
	var dynamic := Button.new()
	root.add_child(dynamic)
	check(dynamic.button_down.get_connections().size() == 1, "动态按钮仅连接一次")
	dynamic.position = Vector2(100, 100)
	dynamic.size = Vector2(100, 40)
	dynamic.button_down.connect(func(): downs += 1)
	await process_frame
	mouse_at(Vector2(120, 120), true)
	await create_timer(0.2).timeout
	mouse_at(Vector2(120, 120), false)
	check(downs == 1 and sound.playing, "长按只触发一次按钮按下并播放")
	sound.stop()
	var ship = load("res://scenes/ship.tscn").instantiate()
	root.add_child(ship)
	var world_button: Button = ship.get_node("SelectButton")
	world_button.button_down.emit()
	check(not sound.playing, "世界内飞船拾取不播放界面音效")
	var planet = load("res://scenes/planet.tscn").instantiate()
	root.add_child(planet)
	planet.get_node("ConfirmArrival").button_down.emit()
	check(sound.playing, "行星确认入轨按钮仍播放音效")
	sound.stop()
	var spin := SpinBox.new()
	spin.position = Vector2(300, 100)
	spin.size = Vector2(120, 40)
	root.add_child(spin)
	await process_frame
	mouse_at(Vector2(415, 110), true)
	mouse_at(Vector2(415, 110), false)
	check(spin.value > 0 and not sound.playing, "SpinBox 箭头实际点击不播放音效")
	for child in internal_buttons(spin):
		child.button_down.emit()
	check(not sound.playing, "SpinBox 内部按钮不播放音效")
	paused = true
	dynamic.button_down.emit()
	check(sound.playing and sound.can_process(), "暂停时仍可播放")
	paused = false
	sound.stop()
	sound.play_click()
	check(sound.playing, "扩展接口可播放")
	sound.stop()
	existing.free()
	dynamic.free()
	ship.free()
	planet.free()
	spin.free()
	sound.queue_free()
	await create_timer(0.3).timeout
	quit(1 if failures else 0)
