extends TutorialBase
## 城市入港教程：差异点只有起始安全点、泊船步骤与港口目标高亮。
## 通用状态机与高亮信号见 TutorialBase；对外行为与重构前逐项一致。
signal tutorial_finished(skipped: bool)

const CONFIG_PATH := "res://data/tutorial.json"
## 教程近域固定倍率；默认40像素船图放大到约80像素，物理尺寸不变。
var target_city: Node2D
var _dock_prompted := false
var _forward_threshold := false
var _docked := false

func _init() -> void:
	tutorial_zoom = 2.0

func start_new_game() -> void:
	_begin_run()

func _config_path() -> String:
	return CONFIG_PATH

func _config_required_sections() -> Array[String]:
	var sections: Array[String] = ["unavailable", "dock_ready"]
	return sections

func _config_missing_text() -> String:
	return "教程配置无法读取，已跳过基础教程。你可以正常自由航行。"

func _unavailable_fallback_text() -> String:
	return "当前地图没有可安全使用的城市港口，已跳过基础教程。"

func _before_start_checks() -> void:
	_dock_prompted = false
	# 旧首次加速通知在这局标记已处理，教程结束/跳过后也不突然冒出。
	_game.get_node("TaskManager").triggered_tasks["first_forward_acceleration"] = true

func _start_stage() -> bool:
	return _find_safe_start()

func _on_start_active() -> void:
	_game.selected = false
	tutorial_ship = null

func _find_safe_start() -> bool:
	# 使用真实港口旁的无引力安全点；仅初始化起始飞船，不移动/修改地图节点。
	var vessel: Node2D = _game.ships[0]
	for city: Node2D in _game.cities:
		if not is_instance_valid(city):
			continue
		var port: Vector2 = city.flight_position + city.port_offset_m.rotated(deg_to_rad(city.rotation_degrees_m))
		for direction: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
			for multiplier: float in [1.2, 1.6, 2.0]:
				var point: Vector2 = port + direction * maxf(city.docking_radius_m * multiplier, 1000.0)
				if _game._touches_planet(point) or _game._gravity_at(point).length_squared() > 0.000001:
					continue
				var safe := true
				var approach: Vector2 = port + direction * city.docking_radius_m * 0.8
				# 起点到泊船范围需有无碰撞、无引力直线路径，不能选择不可完成的港口。
				for index in range(17):
					var sample: Vector2 = point.lerp(approach, float(index) / 16.0)
					if _game._touches_planet(sample) or _game._gravity_at(sample).length_squared() > 0.000001:
						safe = false
					for obstacle: Node2D in _game.obstacles:
						if not obstacle.destroyed and sample.distance_to(obstacle.flight_position) < _game._obstacle_radius(obstacle) + 2000.0:
							safe = false
				if not safe:
					continue
				target_city = city
				vessel.flight_position = point
				vessel.flight_velocity = Vector2.ZERO
				# 初始加速朝港口反方向，避免教学期间穿入城市。
				vessel.heading = (point - port).normalized()
				vessel.thrust_direction = vessel.heading
				vessel.reset_orbit()
				_game._refresh_preview()
				_game._update_ui()
				_game._sync_visuals()
				return true
	return false

func _token_key() -> String:
	return "tutorial_token"

func _skip_button_text() -> String:
	return "跳过城市教学"

func _goal_title() -> String:
	return "基础教程"

func _reset_step_flags() -> void:
	super._reset_step_flags()
	_forward_threshold = false
	_docked = false

func _on_step_entered(step_id: String) -> void:
	if step_id == "return_port" and is_instance_valid(target_city) and is_instance_valid(tutorial_ship):
		tutorial_ship.navigation_target = target_city.get_dock_position()
		tutorial_ship.navigation_planet = null
		tutorial_ship.navigation_tracks_planet = false
		tutorial_ship.has_navigation_target = true
		tutorial_ship.navigation_status = "教程：沿引导线返回 %s 港口，提前减速。" % target_city.display_name

func _on_ship_selected(vessel: Node2D, player_initiated: bool) -> void:
	if not active or not player_initiated:
		return
	if current_step_id() == "select_ship" and vessel == _game.ships[0]:
		tutorial_ship = vessel
		_complete_objective()

func _on_propulsion_committed(vessel: Node2D, forward_delta_v: float, source: StringName) -> void:
	if active and current_step_id() == "accelerate" and vessel == tutorial_ship and forward_delta_v > 0.000001 and source in [&"manual_button", &"directional_thrust"] and vessel.flight_velocity.length() >= 20.0:
		_forward_threshold = true

## 泊船步骤的资格提示既是判定也是唯一的副作用点；返回 false 表示本步仍需玩家实际泊船。
func _evaluate_step(step_id: String, vessel: Node2D) -> bool:
	match step_id:
		"accelerate":
			return _forward_threshold
		"brake":
			return vessel.flight_velocity.length() <= _game.DOCK_SPEED_TOLERANCE
		"dock":
			if not _dock_prompted and _game._can_dock_city(target_city):
				_dock_prompted = true
				_game._stop_thrust()
				_message_done = false
				var prompt: Dictionary = _config.dock_ready.duplicate(true)
				prompt["id"] = "dock_ready"
				_enqueue(prompt)
				_on_dialogue_started(_dialogue.current_dialogue)
	return false

func _on_objective_achieved() -> void:
	_on_dialogue_started(_dialogue.current_dialogue)

func _take_completed_shortcut() -> bool:
	return _docked

func _shortcut_step_index() -> int:
	# 泊船后不再直接结束，而是进入港口界面介绍段，介绍完再收尾。
	for index in range(_steps.size()):
		if str(_steps[index].id).begins_with("port_"):
			return index
	return super._shortcut_step_index()

func _on_dialogue_started(data: Dictionary) -> void:
	if not active or data.get("tutorial_token", -1) != _token:
		return
	var id: String = str(data.get("id", ""))
	# 泊船正文的目标是取得资格，补充提示的目标则是实际泊船，不能共用达标结果。
	var achieved: bool = id == current_step_id() and ((_objective_done and _steps[step_index].kind not in ["message", "complete"]) or (id == "dock" and _dock_prompted) or (id in ["return_port", "approach", "dock"] and _docked))
	if achieved or (id == "dock_ready" and _docked):
		_dialogue.complete_current_reading("tutorial_token", _token)

func _has_valid_target() -> bool:
	return is_instance_valid(target_city) and _game.cities.has(target_city)

func _process_step() -> void:
	if current_step_id() in ["return_port", "approach", "dock"]:
		var port: Node = _game.get_node("PortController")
		if port.active and port.docked_ship == tutorial_ship and tutorial_ship.arrival_source == target_city:
			_docked = true
			_on_dialogue_started(_dialogue.current_dialogue)
			_try_advance()

func _mention_docking_steps() -> Array[String]:
	# return_port/approach 属既有「提前泊船」流程，仍允许泊船。
	var steps: Array[String] = ["return_port", "approach", "dock"]
	return steps

func _camera_focus() -> Node2D:
	return tutorial_ship if is_instance_valid(tutorial_ship) else (_game.ships[0] if not _game.ships.is_empty() else null)

func _resolve_target(target_id: String) -> Node:
	var city_targets := {"port": "DockButton", "port_line": "PortGuideLine", "port_marker": "Port/DockMarker"}
	if city_targets.has(target_id):
		return target_city.get_node_or_null(city_targets[target_id]) if is_instance_valid(target_city) else null
	# 港口界面介绍：高亮停泊后的 PortView 各页签与起航按钮。
	var port_targets := {
		"port_events_tab": "%EventsButton", "port_people_tab": "%RelationsButton",
		"port_shipyard_tab": "%ShipyardButton", "port_depart": "%DepartButton",
	}
	if port_targets.has(target_id):
		var port_view := _game.get_node_or_null("PortController/PortView")
		return port_view.get_node_or_null(port_targets[target_id]) if port_view != null else null
	return super._resolve_target(target_id)

func _clear_navigation_on_cancel() -> void:
	if is_instance_valid(tutorial_ship):
		tutorial_ship.has_navigation_target = false

func _write_state_target(state: Dictionary) -> void:
	state["city"] = str(_game.get_path_to(target_city)) if is_instance_valid(target_city) and _game.is_ancestor_of(target_city) else ""
	state["ship"] = str(_game.get_path_to(tutorial_ship)) if is_instance_valid(tutorial_ship) and _game.is_ancestor_of(tutorial_ship) else ""
	state["dock_prompted"] = _dock_prompted

func _state_required_bools() -> Array[String]:
	var fields: Array[String] = ["active", "completed", "skipped", "dock_prompted", "previous_pause"]
	return fields

func _state_optional_bools() -> Array[String]:
	var fields: Array[String] = ["objective_done"]
	return fields

func _state_target_key() -> String:
	return "city"

func _restore_targets(state: Dictionary) -> bool:
	target_city = _game.get_node_or_null(str(state.city))
	tutorial_ship = _game.get_node_or_null(str(state.ship))
	return is_instance_valid(target_city) and _game.cities.has(target_city) and (step_index == 0 or (is_instance_valid(tutorial_ship) and _game.ships.has(tutorial_ship)))

func _on_state_flags_restored() -> void:
	# 泊船说明允许读档后重新提示，避免只恢复一般接近文案却丢失点击指引。
	_dock_prompted = false

func _emit_finished(was_skipped: bool) -> void:
	tutorial_finished.emit(was_skipped)
