class_name TutorialBase
extends Node
## 城市入港 / 行星入轨两套新手教程的公共状态机骨架。
## 只观察真实操作与固定步结果，不改动物理公式或地图；全部差异由子类钩子提供。

signal highlight_requested(target_id: String)
signal highlight_cleared

## 高亮适配器可订阅信号并调用resolve_highlight_target；port为实际目标城市泊船按钮。
## 城市与行星共用同一份并集，子类只会用到自身步骤里出现的键。
const TARGET_PATHS := {
	"fleet": "HUD/Root/FleetBar", "accelerate": "HUD/Root/ThrustDial/Layout/AccelerateButton",
	"brake": "HUD/Root/ThrustDial/Layout/BrakeButton", "throttle": "HUD/Root/ThrustDial/Layout/Throttle",
	"acceleration": "HUD/Root/ThrustDial/Layout/Acceleration", "direction": "HUD/Root/ThrustDial/Layout/Dial",
	"angle": "HUD/Root/ThrustDial/Layout/Angle", "angle_lock": "HUD/Root/ThrustDial/Layout/AngleLock"
}
## 教程近域固定倍率；默认值由子类在_init里给出。
@export_range(0.25, 4.0, 0.05) var tutorial_zoom := 1.0

var active := false
var completed := false
var skipped := false
var step_index := 0
var tutorial_ship: Node2D
var duration_scale := 1.0
var _config: Dictionary = {}
var _steps: Array = []
var _game: Node
var _dialogue: Node
var _view: CanvasLayer
var _token := 0
# 一局只允许发一次结束信号，避免完成/跳过/启动失败互相重复推进阶段。
var _finish_emitted := false
var _message_done := false
var _objective_done := false
var _camera_locked := false
var _previous_map_mode := false

func bind_game(game: Node) -> void:
	_game = game
	_dialogue = game.get_node("DialogueWindow")
	_view = game.get_node("TutorialHUD")
	_load_config()
	game.ship_selected.connect(_on_ship_selected)
	game.propulsion_committed.connect(_on_propulsion_committed)
	game.simulation_step_committed.connect(_on_simulation_step)
	_dialogue.dialogue_finished.connect(_on_dialogue_finished)
	_dialogue.dialogue_started.connect(_on_dialogue_started)
	_view.hide()

func _load_config(path: String = "") -> void:
	_config = {}
	_steps = []
	var config_path: String = path if not path.is_empty() else _config_path()
	var file := FileAccess.open(config_path, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or not parsed.get("steps") is Array or parsed.steps.is_empty():
		return
	for section: String in _config_required_sections():
		if not parsed.get(section) is Dictionary:
			return
	for step: Variant in parsed.steps:
		if not step is Dictionary or not step.get("id") is String or not step.get("kind") is String or not step.get("paused") is bool or not step.get("target") is String or not step.get("goal") is String or not step.get("text") is String or not (step.get("duration") is float or step.get("duration") is int) or float(step.duration) <= 0.0:
			return
	_config = parsed
	_steps = parsed.steps

## 启动失败时 active 仍为 false，没人消费对话队列，且会被下一阶段 clear_queue 吞掉；
## 提示直接写到航行消息，并延迟发结束信号让调用栈先返回。
func _begin_run() -> void:
	_cancel(false)
	_finish_emitted = false
	completed = false
	skipped = false
	step_index = 0
	_before_start_checks()
	if _steps.is_empty():
		skipped = true
		_game.flight_message = _config_missing_text()
		_game._update_ui()
		_finish(true, true)
		return
	if _game.ships.is_empty() or not _start_stage():
		skipped = true
		var unavailable: Dictionary = _config.get("unavailable", {})
		_game.flight_message = str(unavailable.get("text", _unavailable_fallback_text()))
		_game._update_ui()
		_finish(true, true)
		return
	active = true
	_game._stop_thrust()
	_on_start_active()
	_enter_step()

func current_step_id() -> String:
	return str(_steps[step_index].id) if active else ""

func _lock_camera() -> void:
	var focus: Node2D = _camera_focus()
	if not is_instance_valid(focus):
		return
	var camera: Node = _game.get_node("NavigationCamera")
	var view: Node = _game.get_node("StarMapView")
	if not _camera_locked:
		_previous_map_mode = view.map_mode
		_camera_locked = true
	camera.lock_tutorial_view(focus, tutorial_zoom)
	view.set_map_mode(false)

func _unlock_camera() -> void:
	if not _camera_locked or not is_instance_valid(_game):
		return
	_camera_locked = false
	_game.get_node("NavigationCamera").clear_tutorial_view()
	_game.get_node("StarMapView").set_map_mode(_previous_map_mode)

func _exit_tree() -> void:
	if _camera_locked and is_instance_valid(_game):
		var camera := _game.get_node_or_null("NavigationCamera")
		if camera != null:
			camera.clear_tutorial_view()
	_camera_locked = false

func _enter_step() -> void:
	if not active:
		return
	_lock_camera()
	_reset_step_flags()
	var step: Dictionary = _steps[step_index]
	_game._stop_thrust()
	_game.set_tutorial_pause(bool(step.paused))
	_dialogue.clear_queue()
	_token += 1
	_view.show()
	_view.get_node("Root/Panel/Margin/Content/Skip").text = _skip_button_text()
	_view.get_node("Root/Panel/Margin/Content/Goal").text = "%s %d/%d\n%s" % [_goal_title(), step_index + 1, _steps.size(), step.goal]
	highlight_cleared.emit()
	if not str(step.target).is_empty():
		highlight_requested.emit(str(step.target))
	_on_step_entered(str(step.id))
	_enqueue(step)
	_game._update_ui()

func _enqueue(message: Dictionary) -> void:
	var data := message.duplicate(true)
	data["portrait"] = "res://assets/ui/tutorial_portrait.png"
	data.duration = maxf(float(data.duration) * duration_scale, 0.001)
	data[_token_key()] = _token
	data["requires_confirmation"] = true
	_dialogue.enqueue_dialogue(data)

func _advance() -> void:
	step_index += 1
	if step_index >= _steps.size():
		completed = true
		_cancel(false)
		_finish(false)
	else:
		_enter_step()

func _on_simulation_step(vessel: Node2D) -> void:
	if not active or vessel != tutorial_ship or not _game.selected or _game.ship != vessel or vessel.crashed:
		return
	if not _has_valid_target():
		skip_tutorial()
		_enqueue(_config.unavailable)
		return
	if _evaluate_step(current_step_id(), vessel):
		_complete_objective()

func _complete_objective() -> void:
	if not _objective_done:
		_objective_done = true
		_game._stop_thrust()
		# 达标后可能仍在等待本步手动确认，冻结模拟直到下一步明确恢复。
		_game.set_tutorial_pause(true)
	_on_objective_achieved()
	_try_advance()

func _try_advance() -> void:
	if not active or not _message_done:
		return
	if _take_completed_shortcut():
		step_index = _shortcut_step_index()
		_enter_step()
		return
	if _objective_done or _steps[step_index].kind in ["message", "complete"]:
		_advance()

func _layout_view() -> void:
	var panel: Control = _view.get_node("Root/Panel")
	var narrow: bool = _game.get_viewport_rect().size.x < 1060.0
	panel.position = Vector2(390.0, 280.0) if narrow else Vector2(350.0, 43.0)
	panel.size = Vector2(234.0 if narrow else 250.0, 0.0)

func _process(_delta: float) -> void:
	if not active:
		return
	_layout_view()
	if not _has_valid_target():
		skip_tutorial()
		_enqueue(_config.unavailable)
		return
	_process_step()

func _on_dialogue_finished(data: Dictionary) -> void:
	if not active or data.get(_token_key(), -1) != _token:
		return
	# 同一步可能排有补充说明，全部确认前不能进入下一步。
	_message_done = _dialogue.pending_count() == 0
	_try_advance()

func resolve_highlight_target(target_id: String) -> Node:
	if target_id == "ship":
		return tutorial_ship if is_instance_valid(tutorial_ship) else (_game.ships[0] if not _game.ships.is_empty() else null)
	return _resolve_target(target_id)

## 一局只发一次结束信号；启动失败时延迟发送，让调用栈先返回。
func _finish(was_skipped: bool, deferred := false) -> void:
	if _finish_emitted:
		return
	_finish_emitted = true
	if deferred:
		_emit_finished.call_deferred(was_skipped)
	else:
		_emit_finished(was_skipped)

func skip_tutorial() -> void:
	if active:
		skipped = true
		_cancel(true)
		_finish(true)

## 重置航行只清理当前课，不推进阶段；由restart()在同一阶段重做。
func cancel_for_reset() -> void:
	if active:
		_cancel(true)

func restart() -> void:
	_cancel(true)
	_finish_emitted = false
	_begin_run()

## 教程未进入入港阶段时不提供泊船资格，避免进港后起航被教程暂停锁死。
func allows_docking() -> bool:
	if not active:
		return true
	return current_step_id() in _mention_docking_steps()

func _cancel(clear_navigation: bool) -> void:
	var was_active := active
	active = false
	_token += 1
	if not is_instance_valid(_game):
		return
	_unlock_camera()
	if was_active:
		_game._stop_thrust()
	_game.set_tutorial_pause(false)
	_dialogue.clear_queue()
	_view.hide()
	highlight_cleared.emit()
	if clear_navigation:
		_clear_navigation_on_cancel()

func make_state() -> Dictionary:
	var menu: Node = _game.get_node_or_null("PauseMenu")
	var base_pause: bool = menu.was_paused if menu != null and menu.is_open() else _game.simulation_paused
	var state := {"version": 1, "active": active, "completed": completed, "skipped": skipped, "step": step_index}
	_write_state_target(state)
	state["previous_pause"] = _game.tutorial_previous_pause if _game.tutorial_pause else base_pause
	state["objective_done"] = _objective_done
	return state

func is_state_valid(state: Variant) -> bool:
	if not state is Dictionary or state.get("version") != 1:
		return false
	for field: String in _state_required_bools():
		if not state.get(field) is bool:
			return false
	for field: String in _state_optional_bools():
		if state.has(field) and not state[field] is bool:
			return false
	return state.get("step") is int and state.step >= 0 and state.step <= _steps.size() and (not state.active or state.step < _steps.size()) and state.get(_state_target_key()) is String and state.get("ship") is String

func restore_state(state: Dictionary) -> void:
	# 仅在本教程活动时清理，避免 inactive 时误清除另一教程的暂停状态。
	if active:
		_cancel(false)
	_finish_emitted = false
	completed = bool(state.get("completed", false))
	skipped = bool(state.get("skipped", false))
	step_index = int(state.get("step", 0))
	active = bool(state.get("active", false))
	_on_state_flags_restored()
	if not active:
		return
	var menu: Node = _game.get_node_or_null("PauseMenu")
	var previous_pause: bool = bool(state.get("previous_pause", false))
	if menu != null and menu.is_open():
		menu.was_paused = previous_pause
		_game.simulation_paused = true
	else:
		_game.simulation_paused = previous_pause
	if not _restore_targets(state):
		skip_tutorial()
		_enqueue(_config.unavailable)
		return
	_enter_step()
	if bool(state.get("objective_done", false)):
		_complete_objective()

# —— 子类钩子 ——

## 本阶段配置 JSON 路径。
func _config_path() -> String:
	return ""

## 配置里必须存在的字典段落，缺失即视为配置无效。
func _config_required_sections() -> Array[String]:
	var sections: Array[String] = ["unavailable"]
	return sections

func _config_missing_text() -> String:
	return "教程配置无法读取，已跳过。"

func _unavailable_fallback_text() -> String:
	return "当前地图不可用，已跳过教程。"

## 配置校验通过、准备起始飞船；返回 false 表示本图无法完成本阶段。
func _start_stage() -> bool:
	return true

## 启动前的局内标记（例如旧通知去重标记）。
func _before_start_checks() -> void:
	pass

## active 置真、收油之后的选择/飞船初始化。
func _on_start_active() -> void:
	pass

## 对话队列里标记本教程来源的字段名。
func _token_key() -> String:
	return "tutorial_token"

func _skip_button_text() -> String:
	return "跳过教学"

func _goal_title() -> String:
	return "教程"

## 每步进入时重置本步临时标记。
func _reset_step_flags() -> void:
	_message_done = false
	_objective_done = false

## 步骤进入时的额外动作（导航引导、步骤提示等）。
func _on_step_entered(_step_id: String) -> void:
	pass

## 单个步骤的达成判定；返回 true 时由基类统一收油、暂停并尝试推进。
func _evaluate_step(_step_id: String, _vessel: Node2D) -> bool:
	return false

## 达成目标后刷新当前对话的读条（各教程的提前确认条件不同）。
func _on_objective_achieved() -> void:
	pass

## 是否允许「确认时已实际泊船」直接跳到完成说明。
func _take_completed_shortcut() -> bool:
	return false

## 提前达成（如提前泊船）时跳转到的步骤索引；默认跳到完成说明。
## 子类可在「完成」前插入收尾说明段（如港口界面介绍），让捷径跳到该段起点。
func _shortcut_step_index() -> int:
	for index in range(_steps.size()):
		if _steps[index].kind == "complete":
			return index
	return step_index

## 本教程活动时允许泊船的步骤白名单。
func _mention_docking_steps() -> Array[String]:
	var steps: Array[String] = []
	return steps

## 相机锁定的跟随目标；无效时基类不解锁也不移动视角。
func _camera_focus() -> Node2D:
	return tutorial_ship

## 教程目标的通用路径查找（"ship" 已由基类处理）。
func _resolve_target(target_id: String) -> Node:
	return _game.get_node_or_null(TARGET_PATHS[target_id]) if TARGET_PATHS.has(target_id) else null

## 教程目标是否仍在地图里；丢失即跳过本课。
func _has_valid_target() -> bool:
	return true

## 每帧的活动期检测（泊船资格、入轨确认等）。
func _process_step() -> void:
	pass

## 取消时是否清除飞船导航引导（行星教程不使用导航引导）。
func _clear_navigation_on_cancel() -> void:
	pass

## 写入本教程特有的存档目标字段。
func _write_state_target(_state: Dictionary) -> void:
	pass

func _state_required_bools() -> Array[String]:
	var fields: Array[String] = ["active", "completed", "skipped"]
	return fields

func _state_optional_bools() -> Array[String]:
	var fields: Array[String] = ["previous_pause", "objective_done"]
	return fields

func _state_target_key() -> String:
	return "city"

## 读档时恢复目标与飞船；返回 false 表示存档目标已不存在。
func _restore_targets(_state: Dictionary) -> bool:
	return false

## 读档设置完基础字段后的额外标记恢复。
func _on_state_flags_restored() -> void:
	pass

## 本教程结束时对外发出的信号名与载荷；两个外部信号不能合并。
func _emit_finished(_was_skipped: bool) -> void:
	pass

func _on_ship_selected(_vessel: Node2D, _player_initiated: bool) -> void:
	pass

func _on_propulsion_committed(_vessel: Node2D, _forward_delta_v: float, _source: StringName) -> void:
	pass

func _on_dialogue_started(_data: Dictionary) -> void:
	pass
