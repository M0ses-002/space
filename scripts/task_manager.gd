extends Node
## 场景级任务协调器：只观察已提交操作和游戏状态，不读取按钮，不负责推进物理。
signal task_triggered(task_id: String)
@export_file("*.json") var config_path: String = "res://data/dialogue_tasks.json"
@export var dialogue_path: NodePath = NodePath("../DialogueWindow")
var triggered_tasks: Dictionary = {}
var _tasks: Array[Dictionary] = []
var _game: Node
var _dialogue: Node

func bind_game(game: Node) -> void:
	_game = game
	_dialogue = get_node_or_null(dialogue_path)
	_load_config()
	if not _game.is_connected("propulsion_committed", _on_propulsion_committed):
		_game.connect("propulsion_committed", _on_propulsion_committed)

func _load_config() -> void:
	_tasks.clear()
	var file := FileAccess.open(config_path, FileAccess.READ)
	if file == null:
		push_warning("任务配置无法读取：%s" % config_path)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or not parsed.get("tasks") is Array:
		push_warning("任务配置需要tasks数组。")
		return
	var ids: Dictionary = {}
	for task: Variant in parsed.tasks:
		if not task is Dictionary or not task.get("id") is String or str(task.id).is_empty() or ids.has(task.id):
			continue
		if task.get("trigger") != "first_forward_acceleration" or not task.get("dialogue") is Dictionary:
			continue
		ids[task.id] = true
		_tasks.append(task.duplicate(true))

func _on_propulsion_committed(vessel: Node2D, forward_delta_v: float, source: StringName) -> void:
	if not is_instance_valid(_game) or not is_instance_valid(_dialogue) or not is_instance_valid(vessel):
		return
	if _game.simulation_paused or _game.selecting_orbit or not _game.selected or _game.ship != vessel:
		return
	if vessel.crashed or vessel.voyage_finished or forward_delta_v <= 0.000001 or source not in [&"manual_button", &"directional_thrust"]:
		return
	for task: Dictionary in _tasks:
		var id: String = task.id
		if triggered_tasks.has(id):
			continue
		if _dialogue.enqueue_dialogue(task.dialogue):
			# 入队成功立即记账，不等待通知结束，防止同帧多物理步重复与中途保存重播。
			triggered_tasks[id] = true
			task_triggered.emit(id)

func make_state() -> Dictionary:
	return {"version": 1, "triggered": triggered_tasks.duplicate(true)}

func is_state_valid(state: Variant) -> bool:
	if not state is Dictionary or state.get("version") != 1 or not state.get("triggered") is Dictionary:
		return false
	for id: Variant in state.triggered:
		if not id is String or not state.triggered[id] is bool or not state.triggered[id]:
			return false
	return true

func restore_state(state: Dictionary) -> void:
	clear_dialogues()
	triggered_tasks = state.triggered.duplicate(true) if is_state_valid(state) else {}

func clear_dialogues() -> void:
	if is_instance_valid(_dialogue):
		_dialogue.clear_queue()

## 仅新游戏使用。普通“重置航行”只清通知，不清任务历史。
func reset_for_new_game() -> void:
	triggered_tasks.clear()
	clear_dialogues()
