extends SceneTree
## 局内 ESC 暂停菜单：显示/隐藏、暂停恢复、设置面板切换、保存按钮位置与音量应用。

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func _run() -> void:
	root.size = Vector2i(1200, 720)
	var game = load("res://star_map_demo.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	await process_frame
	await process_frame
	var pause = game.get_node_or_null("PauseMenu")
	check(pause != null, "暂停菜单节点存在")
	if pause == null:
		quit(1)
		return
	var panel: Control = pause.get_node("Root")
	var menu: VBoxContainer = pause.get_node("Root/Panel/Menu")
	var settings_panel: VBoxContainer = menu.get_node("SettingsPanel")
	var save_button: Button = menu.get_node("SaveButton")
	check(not panel.visible, "初始暂停菜单隐藏")
	check(save_button != null, "保存按钮位于暂停菜单")
	var was_paused: bool = game.simulation_paused
	pause.toggle()
	check(panel.visible, "打开暂停菜单显示面板")
	check(game.simulation_paused, "打开暂停菜单暂停模拟")
	pause.toggle()
	check(not panel.visible, "再次切换关闭暂停菜单")
	check(game.simulation_paused == was_paused, "关闭恢复原暂停状态")
	pause.toggle()
	check(not settings_panel.visible and save_button.visible, "默认显示主按钮")
	pause.open_settings()
	check(settings_panel.visible and not save_button.visible, "设置面板显示且主按钮隐藏")
	pause.close_settings()
	check(not settings_panel.visible and save_button.visible, "返回后恢复主按钮")
	var music = root.get_node_or_null("BackgroundMusic")
	if music:
		var slider: HSlider = settings_panel.get_node("VolumeSlider")
		var before: float = music.volume_db
		slider.value = 0.31
		check(is_equal_approx(music.volume_db, linear_to_db(0.31)), "音量滑块即时应用背景音乐音量")
		slider.value = db_to_linear(before)
	pause.close()
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = KEY_ESCAPE
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	await process_frame
	check(panel.visible, "ESC 打开暂停菜单")
	ev = InputEventKey.new()
	ev.pressed = true
	ev.keycode = KEY_ESCAPE
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	await process_frame
	check(not panel.visible, "ESC 再次关闭暂停菜单")
	game.queue_free()
	await process_frame
	if failures == 0:
		print("PAUSE_MENU_TEST: PASS")
	quit(1 if failures else 0)
