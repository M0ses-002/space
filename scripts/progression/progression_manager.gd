extends Node
## 新手教程编排器：按顺序驱动「行星入轨教程 → 太空城入港教程 → 世界地图」三个阶段。
## 两个教程都完成后，才加载世界地图进入自由游戏。

const CITY_MAP_PATH := "res://maps/city_teach.json"
const ORBIT_MAP_PATH := "res://maps/plante_teach.json"

enum Stage { NONE, CITY, ORBIT, WORLD }

var stage := Stage.NONE
var _game: Node
var _tutorial: Node
var _orbit_tutorial: Node

func bind_game(game: Node) -> void:
	_game = game
	_tutorial = game.get_node("TutorialController")
	_orbit_tutorial = game.get_node("OrbitTutorialController")
	_tutorial.tutorial_finished.connect(_on_city_finished)
	_orbit_tutorial.orbit_tutorial_finished.connect(_on_orbit_finished)
	var skip_button := game.get_node_or_null("TutorialHUD/Root/Panel/Margin/Content/Skip")
	if skip_button != null:
		skip_button.pressed.connect(_on_skip_pressed)

func _on_skip_pressed() -> void:
	# 唯一订阅者在信号入口只选择一次，避免同步启动的下一教程接到同一次点击。
	if _tutorial.active:
		_tutorial.skip_tutorial()
	elif _orbit_tutorial.active:
		_orbit_tutorial.skip_tutorial()

## 新游戏入口：加载行星教程地图并启动行星入轨教程。同步完成初始化后保存进度。
## 新游戏入口：清空 CG 播放记录，加载行星教程地图并启动行星入轨教程。
func start_new_game() -> void:
	var cg := _game.get_node_or_null("CgController")
	if cg != null and cg.has_method("reset_for_new_game"):
		cg.reset_for_new_game()
	_begin_orbit()

func _begin_city() -> void:
	if not _game.load_map_file(CITY_MAP_PATH):
		return
	stage = Stage.CITY
	_tutorial.start_new_game()
	_save_progress()

func _on_city_finished(_skipped: bool) -> void:
	if stage != Stage.CITY:
		return
	_enter_world()

func _begin_orbit() -> void:
	if not _game.load_map_file(ORBIT_MAP_PATH):
		return
	stage = Stage.ORBIT
	_orbit_tutorial.start()
	_save_progress()

func _on_orbit_finished(_skipped: bool) -> void:
	if stage != Stage.ORBIT:
		return
	_begin_city()

func _enter_world() -> void:
	if not _game.load_world_map():
		return
	stage = Stage.WORLD
	if not _game.ships.is_empty():
		_game._select_target(_game.ships[0], false)
	_save_progress()

func _save_progress() -> void:
	var saves := get_node_or_null("/root/SaveManager")
	if saves != null and saves.enabled and saves.game == _game:
		saves.save_game()

func make_state() -> Dictionary:
	return {"version": 1, "stage": int(stage), "orbit_tutorial": _orbit_tutorial.make_state()}

func is_state_valid(state: Variant) -> bool:
	if not state is Dictionary or state.get("version") != 1:
		return false
	if not state.get("stage") is int or state.stage < 0 or state.stage > Stage.WORLD:
		return false
	var orbit_state = state.get("orbit_tutorial", {})
	return orbit_state is Dictionary and (orbit_state.is_empty() or _orbit_tutorial.is_state_valid(orbit_state))

## 读档前按阶段加载对应地图；由 SaveManager 在恢复前调用。
## stage 为 NONE（旧存档或直接调用教程，未经编排器）时保持当前地图不变。
func prepare_for_restore(state: Variant) -> bool:
	if not state is Dictionary or state.get("version") != 1:
		stage = Stage.NONE
		return true
	var target := int(state.get("stage", Stage.WORLD))
	var loaded := true
	match target:
		Stage.CITY:
			loaded = _game.load_map_file(CITY_MAP_PATH)
		Stage.ORBIT:
			loaded = _game.load_map_file(ORBIT_MAP_PATH)
		Stage.WORLD:
			loaded = _game.load_world_map()
		_:
			stage = Stage.NONE
			return true
	if not loaded:
		return false
	stage = target
	return true

## 恢复行星教程状态；城市教程状态由 SaveManager 直接恢复。
func restore_orbit_state(state: Variant) -> void:
	if state is Dictionary:
		_orbit_tutorial.restore_state(state.get("orbit_tutorial", {}))
