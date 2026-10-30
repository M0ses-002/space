extends Control

const GAME_SCENE := "res://star_map_demo.tscn"
const SETTINGS_PATH := "user://settings.cfg"

@onready var menu: VBoxContainer = $Center/Menu
@onready var settings: VBoxContainer = $Center/Settings
@onready var volume_slider: HSlider = $Center/Settings/VolumeSlider
@onready var volume_label: Label = $Center/Settings/VolumeLabel
@onready var message_dialog: AcceptDialog = $MessageDialog
@onready var overwrite_dialog: ConfirmationDialog = $OverwriteDialog

func _ready() -> void:
	var config := ConfigFile.new()
	var volume := 1.0
	if config.load(SETTINGS_PATH) == OK:
		volume = clampf(float(config.get_value("audio", "music_volume", 1.0)), 0.0, 1.0)
	volume_slider.value = volume
	_apply_music_volume(volume)

func _apply_music_volume(volume: float) -> void:
	volume_label.text = "背景音乐音量：%d%%" % roundi(volume * 100.0)
	var music := get_node_or_null("/root/BackgroundMusic") as AudioStreamPlayer
	if music:
		music.volume_db = linear_to_db(volume)

func _on_volume_changed(value: float) -> void:
	_apply_music_volume(value)
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH)
	config.set_value("audio", "music_volume", value)
	if config.save(SETTINGS_PATH) != OK:
		_show_message("设置保存失败，请检查用户数据目录是否可写。")

func _on_continue_pressed() -> void:
	var saves := get_node_or_null("/root/SaveManager")
	if saves == null:
		_show_message("存档管理器不可用。")
		return
	if not saves.has_save():
		_show_message("没有可继续的存档，请先开始新游戏。")
		return
	if saves.continue_game():
		_enter_game()
	else:
		_show_message("读取存档失败，请检查存档文件。")

func _on_new_game_pressed() -> void:
	var saves := get_node_or_null("/root/SaveManager")
	if saves == null:
		_show_message("存档管理器不可用。")
		return
	if saves.has_save():
		overwrite_dialog.popup_centered()
	else:
		_start_new_game()

func _start_new_game() -> void:
	var saves := get_node_or_null("/root/SaveManager")
	if saves != null and saves.start_new_game():
		_enter_game()
	else:
		_show_message("创建新游戏失败，请检查存档目录。")

func _enter_game() -> void:
	if get_tree().change_scene_to_file(GAME_SCENE) != OK:
		_show_message("无法进入游戏场景。")

func _show_message(text: String) -> void:
	message_dialog.dialog_text = text
	message_dialog.popup_centered()

func _on_settings_pressed() -> void:
	menu.hide()
	settings.show()

func _on_back_pressed() -> void:
	settings.hide()
	menu.show()
