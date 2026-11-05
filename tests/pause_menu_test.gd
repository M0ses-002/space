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
	var game = load("res://scenes/game/star_map_demo.tscn").instantiate()
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
	var main_menu_button: Button = menu.get_node("MainMenuButton")
	var debug_button: Button = menu.get_node("DebugCreditsButton")
	var port = game.get_node("PortController")
	var initial_credits: int = port.session.get_credits()
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
	check(not settings_panel.visible and save_button.visible and debug_button.visible, "默认显示主按钮及加款按钮")
	check(debug_button.text.contains("1000"), "调试按钮明确标注1000信用点")
	debug_button.pressed.emit()
	check(port.session.get_credits() == initial_credits + 1000, "航行中点击调试按钮恰好加1000共享信用点")
	pause.open_settings()
	check(settings_panel.visible and not save_button.visible and not main_menu_button.visible and not debug_button.visible, "设置面板显示且主按钮隐藏")
	pause.close_settings()
	check(not settings_panel.visible and save_button.visible and main_menu_button.visible and debug_button.visible, "返回后恢复主按钮")
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
	game.ship.voyage_finished = true
	game.ship.arrival_source = game.cities[0]
	port.enter_port(game.cities[0], game.ship)
	ev = InputEventKey.new()
	ev.pressed = true
	ev.keycode = KEY_ESCAPE
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	await process_frame
	check(panel.visible and port.active, "港口内ESC也能打开暂停菜单")
	var before_port_credits: int = port.session.get_credits()
	debug_button.pressed.emit()
	check(port.session.get_credits() == before_port_credits + 1000, "港口内调试同样加1000共享信用点")
	check(port.view.get_node("%ShipStatus").text.contains(str(before_port_credits + 1000)), "港口余额展示即时刷新")
	check(debug_button.text.contains(str(before_port_credits + 1000)), "调试按钮同步显示当前余额")
	pause.open_settings()
	check(not debug_button.visible, "港口内设置页仍隐藏调试按钮")
	pause.close_settings()
	check(debug_button.visible, "港口内返回主菜单恢复调试按钮")
	pause.close()
	port.leave_port()
	pause.open()
	main_menu_button.pressed.emit()
	await process_frame
	var return_dialog: ConfirmationDialog = pause.get_node("ReturnDialog")
	check(return_dialog.visible, "返回开始界面前显示未保存提示")
	return_dialog.confirmed.emit()
	await process_frame
	await process_frame
	check(is_instance_valid(current_scene) and current_scene.scene_file_path == "res://scenes/ui/main_menu.tscn", "确认后切换到开始界面")
	if is_instance_valid(game):
		game.queue_free()
	await process_frame
	if failures == 0:
		print("PAUSE_MENU_TEST: PASS")
	quit(1 if failures else 0)
