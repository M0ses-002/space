extends TutorialBase
## 行星入轨教程：聚焦「沿切向加速建立轨道 → 收油稳定 → 确认入轨」。
## 通用状态机与高亮信号见 TutorialBase；对外行为与重构前逐项一致。
signal orbit_tutorial_finished(skipped: bool)

const CONFIG_PATH := "res://data/orbit_tutorial.json"
## 初始轨道半径取行星半径的倍数（位于恒强层外的平方反比区）。
const ORBIT_RADIUS_FACTOR := 1.8
## 初始切向速度占该半径圆轨道速度的比例（略低，需玩家加速补足）。
const INITIAL_SPEED_FACTOR := 0.9
## thrust 步骤完成所需的切向速度占比（达到该比例即认为已补足速度）。
const THRUST_TARGET_SPEED_FACTOR := 0.95

var target_planet: Node2D
var _target_speed := 0.0

func _init() -> void:
	# 行星入轨教程需要同时看到行星与绕行轨道，缩放比城市教程更小。
	tutorial_zoom = 0.85

func start() -> void:
	_begin_run()

func _config_path() -> String:
	return CONFIG_PATH

func _config_missing_text() -> String:
	return "行星入轨教程配置无法读取，已跳过。"

func _unavailable_fallback_text() -> String:
	return "当前地图没有可用的行星，已跳过行星入轨教程。"

func _start_stage() -> bool:
	return _setup_orbit_start()

func _on_start_active() -> void:
	# 行星教程直接使用第一艘船，无需玩家选船。
	_game._select_target(tutorial_ship, false)

func _setup_orbit_start() -> bool:
	if _game.planets.is_empty():
		return false
	target_planet = _game.planets[0]
	tutorial_ship = _game.ships[0]
	var radius_m: float = target_planet.radius_m * ORBIT_RADIUS_FACTOR
	# 保证起点位于恒强层之外、且不超出引力范围过多。
	radius_m = clampf(radius_m, target_planet.radius_m + target_planet.field_height_m + 5000.0, target_planet.max_gravity_radius_m * 0.8)
	var position: Vector2 = target_planet.flight_position + Vector2(radius_m, 0.0)
	var accel: float = target_planet.acceleration_at(position).length()
	if accel <= 0.0:
		return false
	var circular_speed: float = sqrt(accel * radius_m)
	_target_speed = circular_speed
	# 逆时针切向；初速略低于圆轨道速度，轨道会缓慢下坠，等待玩家加速。
	tutorial_ship.flight_position = position
	tutorial_ship.flight_velocity = Vector2(0.0, -1.0) * (circular_speed * INITIAL_SPEED_FACTOR)
	tutorial_ship.heading = tutorial_ship.flight_velocity.normalized()
	tutorial_ship.thrust_direction = tutorial_ship.heading
	tutorial_ship.reset_orbit()
	_game._refresh_preview()
	_game._update_ui()
	_game._sync_visuals()
	return true

func _token_key() -> String:
	return "orbit_tutorial_token"

func _skip_button_text() -> String:
	return "跳过行星教学"

func _goal_title() -> String:
	return "行星入轨"

func _evaluate_step(step_id: String, vessel: Node2D) -> bool:
	match step_id:
		"thrust":
			return vessel.flight_velocity.length() >= _target_speed * THRUST_TARGET_SPEED_FACTOR
		"coast":
			return vessel.stay_available
	return false

func _on_objective_achieved() -> void:
	if _dialogue.current_dialogue.get("id") == current_step_id() and _steps[step_index].kind not in ["message", "complete"]:
		_dialogue.complete_current_reading("orbit_tutorial_token", _token)

func _has_valid_target() -> bool:
	return is_instance_valid(target_planet) and _game.planets.has(target_planet)

func _process_step() -> void:
	# 确认入轨后飞船 voyage_finished，物理步不再提交该船，需在此帧级检测完成。
	if current_step_id() == "confirm" and is_instance_valid(tutorial_ship) and tutorial_ship.voyage_finished and tutorial_ship.arrival_source == target_planet:
		_complete_objective()

## 行星入轨教程期间不提供泊船资格，避免进入城市港口后起航被暂停锁死。
func _mention_docking_steps() -> Array[String]:
	var steps: Array[String] = []
	return steps

func _camera_focus() -> Node2D:
	# 行星入轨教程以行星为视角中心，让绕行轨道进入视野。
	return target_planet if is_instance_valid(target_planet) and is_instance_valid(tutorial_ship) else null

func _resolve_target(target_id: String) -> Node:
	if target_id == "planet":
		return target_planet if is_instance_valid(target_planet) else null
	if target_id == "confirm_arrival":
		return target_planet.get_node_or_null("ConfirmArrival") if is_instance_valid(target_planet) else null
	return super._resolve_target(target_id)

func _write_state_target(state: Dictionary) -> void:
	state["planet"] = str(_game.get_path_to(target_planet)) if is_instance_valid(target_planet) and _game.is_ancestor_of(target_planet) else ""
	state["ship"] = str(_game.get_path_to(tutorial_ship)) if is_instance_valid(tutorial_ship) and _game.is_ancestor_of(tutorial_ship) else ""

func _state_target_key() -> String:
	return "planet"

func _restore_targets(state: Dictionary) -> bool:
	target_planet = _game.get_node_or_null(str(state.planet))
	tutorial_ship = _game.get_node_or_null(str(state.ship))
	return is_instance_valid(target_planet) and _game.planets.has(target_planet) and is_instance_valid(tutorial_ship) and _game.ships.has(tutorial_ship)

func _emit_finished(was_skipped: bool) -> void:
	orbit_tutorial_finished.emit(was_skipped)
