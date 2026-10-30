extends SceneTree

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _run() -> void:
	var isolated := OS.get_environment("SPACE_MENU_TEST_APPDATA")
	if isolated.is_empty() or not OS.get_user_data_dir().replace("\\", "/").begins_with(isolated.replace("\\", "/") + "/"):
		push_error("请将 APPDATA 和 SPACE_MENU_TEST_APPDATA 指向相同的专用测试目录。")
		quit(1)
		return
	if "verify-restart" in OS.get_cmdline_user_args():
		var reloaded = load("res://scenes/main_menu.tscn").instantiate()
		root.add_child(reloaded)
		check(is_equal_approx(reloaded.get_node("Center/Settings/VolumeSlider").value, 0.42), "重启后应恢复音乐音量")
		reloaded.free()
		var music = root.get_node_or_null("BackgroundMusic")
		if music:
			music.stop()
			music.queue_free()
		await create_timer(0.3).timeout
		quit(1 if failures else 0)
		return
	var saves = root.get_node_or_null("SaveManager")
	if saves == null:
		saves = load("res://scripts/save_manager.gd").new()
		saves.name = "SaveManager"
		root.add_child(saves)
	check(not saves.has_save(), "隔离目录应无存档")
	var menu = load("res://scenes/main_menu.tscn").instantiate()
	root.add_child(menu)
	current_scene = menu
	await process_frame
	menu.get_node("Center/Menu/Continue").pressed.emit()
	check(menu.message_dialog.dialog_text.contains("没有可继续的存档"), "真实管理器无存档提示")
	menu.message_dialog.hide()
	menu.get_node("Center/Menu/SettingsButton").pressed.emit()
	menu.get_node("Center/Settings/VolumeSlider").value = 0.42
	menu.get_node("Center/Settings/Back").pressed.emit()
	menu.get_node("Center/Menu/NewGame").pressed.emit()
	for i in range(30):
		await process_frame
		if saves.enabled:
			break
	check(current_scene != null and current_scene.scene_file_path == "res://star_map_demo.tscn", "新游戏应进入游戏场景")
	check(saves.enabled and saves.game == current_scene, "新游戏场景应启用存档")
	current_scene.get_node("PortController").session._credits = 777
	check(saves.save_game(), "游戏应可写入测试存档")
	check(saves.has_save(), "写入后应识别存档")
	var old_save := FileAccess.get_file_as_bytes("user://space_save_v1.dat")
	var old_backup := FileAccess.get_file_as_bytes("user://space_save_v1.bak")
	current_scene.get_node("PortController").session._credits = 999
	var pause = current_scene.get_node("PauseMenu")
	pause.open()
	saves.elapsed = 29.9
	saves._process(1.0)
	check(FileAccess.get_file_as_bytes("user://space_save_v1.dat") == old_save, "暂停菜单期间不得触发自动保存")
	pause.main_menu_button.pressed.emit()
	check(pause.return_dialog.visible, "返回前应提示未保存进度")
	pause.return_dialog.hide()
	check(current_scene == saves.game and current_scene.simulation_paused, "取消返回后保留游戏及暂停状态")
	pause.main_menu_button.pressed.emit()
	pause.return_dialog.confirmed.emit()
	await process_frame
	await process_frame
	menu = current_scene
	check(menu.scene_file_path == "res://scenes/main_menu.tscn", "确认后应返回开始界面")
	check(FileAccess.get_file_as_bytes("user://space_save_v1.dat") == old_save, "返回不得覆盖主存档")
	check(FileAccess.get_file_as_bytes("user://space_save_v1.bak") == old_backup, "返回不得覆盖备份")
	check(is_equal_approx(menu.get_node("Center/Settings/VolumeSlider").value, 0.42), "重新进入菜单应恢复音乐音量")
	menu.get_node("Center/Menu/NewGame").pressed.emit()
	check(menu.overwrite_dialog.visible, "已有真实存档时应先确认")
	check(FileAccess.get_file_as_bytes("user://space_save_v1.dat") == old_save, "确认前不得覆盖旧存档")
	menu.overwrite_dialog.hide()
	check(FileAccess.get_file_as_bytes("user://space_save_v1.dat") == old_save, "取消后不得覆盖旧存档")
	menu.get_node("Center/Menu/Continue").pressed.emit()
	for i in range(30):
		await process_frame
		if saves.enabled and saves.game == current_scene:
			break
	check(current_scene != null and current_scene.scene_file_path == "res://star_map_demo.tscn", "继续应进入游戏场景")
	check(saves.enabled and saves.game == current_scene, "继续后应成功恢复并启用存档")
	if saves.enabled and saves.game == current_scene:
		check(current_scene.get_node("PortController").session._credits == 777, "继续后应恢复已保存的资金")
	if current_scene:
		current_scene.queue_free()
	var music = root.get_node_or_null("BackgroundMusic")
	if music:
		music.stop()
		music.queue_free()
	saves.queue_free()
	await create_timer(0.3).timeout
	quit(1 if failures else 0)
