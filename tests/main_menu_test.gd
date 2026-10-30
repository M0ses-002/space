extends SceneTree

class FakeSaveManager extends Node:
	var saved := false
	var new_calls := 0
	var continue_calls := 0
	var new_result := false
	var continue_result := false

	func has_save() -> bool:
		return saved

	func start_new_game() -> bool:
		new_calls += 1
		return new_result

	func continue_game() -> bool:
		continue_calls += 1
		return continue_result

class TestMenu extends "res://scripts/main_menu.gd":
	var enter_calls := 0

	func _enter_game() -> void:
		enter_calls += 1

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
	var original := root.get_node_or_null("SaveManager")
	if original:
		root.remove_child(original)
	var saves := FakeSaveManager.new()
	saves.name = "SaveManager"
	root.add_child(saves)
	var scene = load("res://scenes/main_menu.tscn").instantiate()
	scene.set_script(TestMenu)
	root.add_child(scene)
	await process_frame
	var continue_button: Button = scene.get_node("Center/Menu/Continue")
	var new_button: Button = scene.get_node("Center/Menu/NewGame")
	var settings_button: Button = scene.get_node("Center/Menu/SettingsButton")
	var slider: HSlider = scene.get_node("Center/Settings/VolumeSlider")
	continue_button.pressed.emit()
	check(scene.message_dialog.dialog_text.contains("没有可继续的存档"), "无存档时应显示提示")
	check(saves.continue_calls == 0, "无存档时不应调用继续")
	scene.message_dialog.hide()
	saves.saved = true
	new_button.pressed.emit()
	check(scene.overwrite_dialog.visible and saves.new_calls == 0, "有存档时应先确认覆盖")
	scene.overwrite_dialog.hide()
	check(saves.new_calls == 0, "取消确认不得开始新游戏")
	new_button.pressed.emit()
	saves.new_result = true
	scene.overwrite_dialog.confirmed.emit()
	scene.overwrite_dialog.hide()
	check(saves.new_calls == 1 and scene.enter_calls == 1, "确认后调用新游戏并进入场景")
	continue_button.pressed.emit()
	check(saves.continue_calls == 1 and scene.enter_calls == 1, "继续失败不应进入游戏")
	check(scene.message_dialog.dialog_text.contains("读取存档失败"), "继续失败应显示提示")
	scene.message_dialog.hide()
	saves.continue_result = true
	continue_button.pressed.emit()
	check(saves.continue_calls == 2 and scene.enter_calls == 2, "继续成功后进入游戏")
	settings_button.pressed.emit()
	check(scene.settings.visible and not scene.menu.visible, "设置按钮应打开设置界面")
	slider.value = 0.37
	var config := ConfigFile.new()
	check(config.load("user://settings.cfg") == OK, "音量配置应保存")
	check(is_equal_approx(float(config.get_value("audio", "music_volume", -1.0)), 0.37), "保存的音量应与滑块一致")
	var music = root.get_node_or_null("BackgroundMusic")
	check(music != null and is_equal_approx(music.volume_db, linear_to_db(0.37)), "音量应即时应用至背景音乐")
	scene.free()
	var reloaded = load("res://scenes/main_menu.tscn").instantiate()
	root.add_child(reloaded)
	check(is_equal_approx(reloaded.get_node("Center/Settings/VolumeSlider").value, 0.37), "重建菜单应恢复音量")
	reloaded.free()
	saves.free()
	if original:
		original.free()
	if music:
		music.stop()
		music.queue_free()
	await create_timer(0.3).timeout
	quit(1 if failures else 0)
