extends CanvasLayer
## 局内 ESC 暂停菜单：继续游戏、保存游戏、设置（背景音乐音量）。
## 保存按钮的按下信号由 SaveManager 绑定，本脚本只负责菜单显示、暂停与音量。

const SETTINGS_PATH := "user://settings.cfg"

@onready var root: Control = $Root
@onready var title_label: Label = $Root/Panel/Menu/Title
@onready var continue_button: Button = $Root/Panel/Menu/ContinueButton
@onready var save_button: Button = $Root/Panel/Menu/SaveButton
@onready var settings_button: Button = $Root/Panel/Menu/SettingsButton
@onready var manual_button: Button = $Root/Panel/Menu/ManualButton
@onready var manual: CanvasLayer = $CaptainManual
@onready var debug_credits_button: Button = $Root/Panel/Menu/DebugCreditsButton
@onready var main_menu_button: Button = $Root/Panel/Menu/MainMenuButton
@onready var return_dialog: ConfirmationDialog = $ReturnDialog
@onready var settings_panel: VBoxContainer = $Root/Panel/Menu/SettingsPanel
@onready var volume_label: Label = $Root/Panel/Menu/SettingsPanel/VolumeLabel
@onready var volume_slider: HSlider = $Root/Panel/Menu/SettingsPanel/VolumeSlider

var game: Node2D
var was_paused := false

func _ready() -> void:
	game = get_parent()
	continue_button.pressed.connect(close)
	settings_button.pressed.connect(open_settings)
	manual_button.pressed.connect(manual.open)
	debug_credits_button.pressed.connect(_add_debug_credits)
	main_menu_button.pressed.connect(return_dialog.popup_centered)
	return_dialog.confirmed.connect(_return_to_main_menu)
	settings_panel.get_node("BackButton").pressed.connect(close_settings)
	volume_slider.value_changed.connect(_on_volume_changed)
	_load_volume()

func is_open() -> bool:
	return root.visible

func toggle() -> void:
	if manual.is_open():
		manual.close()
	elif root.visible:
		close()
	else:
		open()

func open() -> void:
	was_paused = game.simulation_paused
	game.simulation_paused = true
	if not was_paused and game.has_method("_stop_thrust"):
		game._stop_thrust()
	close_settings()
	debug_credits_button.text = "+1000 信用点（调试）· 当前%d" % game.get_node("PortController").session.get_credits()
	root.visible = true

func close() -> void:
	manual.close()
	game.simulation_paused = was_paused or game.tutorial_pause
	close_settings()
	root.visible = false

func open_settings() -> void:
	title_label.visible = false
	continue_button.visible = false
	save_button.visible = false
	settings_button.visible = false
	manual_button.visible = false
	debug_credits_button.visible = false
	main_menu_button.visible = false
	settings_panel.visible = true

func close_settings() -> void:
	settings_panel.visible = false
	title_label.visible = true
	continue_button.visible = true
	save_button.visible = true
	settings_button.visible = true
	manual_button.visible = true
	debug_credits_button.visible = true
	main_menu_button.visible = true

func _add_debug_credits() -> void:
	var port := game.get_node("PortController")
	var added: bool = port.session.add_credits(1000)
	port.refresh()
	debug_credits_button.text = "+1000 信用点（调试）· 当前%d" % port.session.get_credits()
	if not added:
		var dialog: AcceptDialog = $SaveStatus
		dialog.dialog_text = "信用点增加失败：本次加点将超出余额上限，当前余额未改变。"
		dialog.popup_centered()

func _return_to_main_menu() -> void:
	if get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn") != OK:
		var dialog: AcceptDialog = $SaveStatus
		dialog.dialog_text = "无法返回开始界面，请重试。"
		dialog.popup_centered()

func _load_volume() -> void:
	var config := ConfigFile.new()
	var volume := 1.0
	if config.load(SETTINGS_PATH) == OK:
		volume = clampf(float(config.get_value("audio", "music_volume", 1.0)), 0.0, 1.0)
	volume_slider.set_value_no_signal(volume)
	_apply_music_volume(volume)

func _on_volume_changed(value: float) -> void:
	_apply_music_volume(value)
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH)
	config.set_value("audio", "music_volume", value)
	config.save(SETTINGS_PATH)

func _apply_music_volume(volume: float) -> void:
	volume_label.text = "背景音乐音量：%d%%" % roundi(volume * 100.0)
	var music := get_node_or_null("/root/BackgroundMusic") as AudioStreamPlayer
	if music:
		music.volume_db = linear_to_db(volume)
