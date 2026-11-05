extends AudioStreamPlayer

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().node_added.connect(_register_node)
	_register_tree(get_tree().root)

func _register_tree(node: Node) -> void:
	_register_node(node)
	for child in node.get_children():
		_register_tree(child)

func _register_node(node: Node) -> void:
	if node is BaseButton:
		var button := node as BaseButton
		var callback := _on_button_down.bind(button)
		if not button.button_down.is_connected(callback):
			button.button_down.connect(callback)

func _on_button_down(button: BaseButton) -> void:
	if button.disabled:
		return
	var node: Node = button
	while node != null:
		if node is SpinBox or node.is_in_group("ui_click_sound_exclude"):
			return
		node = node.get_parent()
	play_click()

func play_click() -> void:
	play()
