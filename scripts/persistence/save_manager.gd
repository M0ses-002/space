extends Node

const SAVE_PATH := "user://space_save_v1.dat"
const TEMP_PATH := "user://space_save_v1.tmp"
const BACKUP_PATH := "user://space_save_v1.bak"
const GAME_SCENE := "res://scenes/game/star_map_demo.tscn"
# 沿用原存档路径，v1多余的经济、采集与矿体消耗字段不再参与校验或恢复。
# v3 新增新手教程阶段编排（行星入轨教程 → 城市教程 → 世界地图）。
# v4 新增太空垃圾的擦除进度（remaining_mass_kg）。
# v5 新增任务奖励解锁的装备（unlocked_equipment）。
# v6 新增剧情状态（story_state：标记、已播台词、去过的行星），供条件对话使用。
const VERSION := 6
## 已下线的改装 id：老存档里可能仍占着槽位，读档时清空，而不是把整份存档判成损坏。
const RETIRED_UPGRADES := ["recycle_hook"]
const SHIP_FIELDS := ["flight_position", "flight_velocity", "fuel", "crashed", "voyage_finished", "departure_position", "departure_velocity", "current_voyage_distance_m", "last_voyage_distance_m", "completed_voyage_count", "thrust_direction", "thrust_throttle", "navigation_target", "has_navigation_target", "navigation_tracks_planet", "navigation_status", "steering", "heading", "manual_thrust", "maneuver_commands", "maneuver_index", "orbit_angle", "orbit_last_angle", "orbit_start_radius", "orbit_start_speed", "orbit_direction", "stay_available", "region_event"]
const SHIP_REFS := ["navigation_planet", "region_source", "maneuver_target", "orbit_source", "arrival_source", "departed_city"]
var game: Node
var pending: Dictionary = {}
var enabled := false
var elapsed := 0.0
var mode := ""
var loaded_backup := false
var save_layer: CanvasLayer

func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)

func _on_node_added(node: Node) -> void:
	if mode.is_empty() or node.scene_file_path != GAME_SCENE:
		return
	node.set_physics_process(false)
	_attach_after_scene_change.call_deferred(node)

func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH) or FileAccess.file_exists(BACKUP_PATH)

# 调用方负责在存在旧存档时询问覆盖确认。
func start_new_game() -> bool:
	pending = {}
	enabled = false
	game = null
	mode = "new"
	loaded_backup = false
	# 上一局的起航点不能带进新局，否则撞毁时会回档到别人的进度。
	departure_snapshot = {}
	return true

func continue_game() -> bool:
	# 读档后的状态以存档为准，旧起航点不再代表「本次起航」。
	departure_snapshot = {}
	pending = _read_save(SAVE_PATH)
	if pending.is_empty():
		pending = _read_save(BACKUP_PATH)
		loaded_backup = not pending.is_empty()
	else:
		loaded_backup = false
	if pending.is_empty():
		return false
	enabled = false
	game = null
	mode = "continue"
	return true

func _attach_after_scene_change(scene: Node) -> void:
	# 演示场景的 deferred 初始化先完成；期间物理模拟保持冻结。
	await get_tree().process_frame
	if not is_instance_valid(scene) or get_tree().current_scene != scene:
		return
	game = scene
	_create_save_ui()
	if game.map_load_error:
		pending = {}
		mode = ""
		enabled = false
		_show_status("地图文件无效或无法读取，已使用默认场景。为保护存档，保存和自动保存已关闭；请修复或移除地图文件后重启。")
		return
	if mode == "continue" and not restore_snapshot(game, pending):
		var backup := _read_save(BACKUP_PATH)
		if loaded_backup or backup.is_empty() or not restore_snapshot(game, backup):
			pending = {}
			mode = ""
			_show_status("读取存档失败，原存档已保留；自动保存已关闭。")
			return
		loaded_backup = true
	var is_new := mode == "new"
	pending = {}
	mode = ""
	elapsed = 0.0
	enabled = true
	game.set_physics_process(true)
	if is_new:
		# 由 ProgressionManager 驱动教程阶段；地图加载完成后自行保存进度。
		game.get_node("ProgressionManager").start_new_game()

func _create_save_ui() -> void:
	save_layer = game.get_node("PauseMenu")
	save_layer.get_node("Root/Panel/Menu/SaveButton").pressed.connect(_on_save_pressed)

func _show_status(message: String) -> void:
	var dialog: AcceptDialog = save_layer.get_node("SaveStatus")
	dialog.dialog_text = message
	dialog.popup_centered()

func _on_save_pressed() -> void:
	if save_game():
		_show_status("游戏已保存。")
	else:
		_show_status("保存失败或存档不可用，原存档已保留。")

func _process(delta: float) -> void:
	if not enabled or not is_instance_valid(game) or get_tree().current_scene != game:
		return
	if is_instance_valid(save_layer) and save_layer.is_open():
		return
	elapsed += delta
	if elapsed >= 30.0:
		elapsed = 0.0
		if not save_game():
			_show_status("自动保存失败，请检查用户数据目录；原存档已保留。")

func save_game() -> bool:
	if not enabled or not is_instance_valid(game):
		return false
	return _write_save(make_snapshot(game))

## 关键节点存档（停泊/起航）：与 30 秒自动保存写同一份文件，并重置计时避免紧接着再写一次。
## 停泊、起航可能与教程阶段切换（换地图）落在同一帧，调用方应在帧末（call_deferred）触发，
## 这样快照里的地图 hash 与 progression 阶段始终是同一份状态。
## 地图加载失败时拒绝写入：此时 hash 指向的是一份没加载成功的地图，写下去等于毁档。
func save_checkpoint() -> bool:
	if not enabled or not is_instance_valid(game) or get_tree().current_scene != game:
		return false
	if bool(game.get("map_load_error")):
		return false
	elapsed = 0.0
	return save_game()

## 「上次起航」的回档点：一份完整的局内快照，只放内存、不写盘。
## 不落盘是有意的——重新启动游戏等于读档，那是另一条恢复路径；
## 落盘反而会让新开一局的玩家回档到上一局最后一次起航，白丢进度。
var departure_snapshot: Dictionary = {}

## 起航成功后记录回档点。与 save_checkpoint 一样由调用方延到帧末触发，
## 这样教程在同一帧换图时，快照里的地图、阶段与飞船状态是同一份。
## 复用 make_snapshot：信用点、装备解锁、任务、教程进度、全船状态、障碍物擦除进度都会一并记下。
func stash_departure() -> bool:
	if not enabled or not is_instance_valid(game) or get_tree().current_scene != game:
		return false
	if bool(game.get("map_load_error")):
		return false
	var snapshot := make_snapshot(game)
	if snapshot.is_empty():
		return false
	departure_snapshot = snapshot
	return true

func has_departure() -> bool:
	return not departure_snapshot.is_empty()

func clear_departure() -> void:
	departure_snapshot = {}

## 回档到上次起航：套用与读档完全相同的恢复流程（含按阶段换回原地图），
## 因此装备解锁、信用点、任务进度与船况都会回到起航那一刻。
## 恢复期间关掉自动保存与物理推进，避免把中间态写进存档或让船多跑一帧。
func restore_departure() -> bool:
	if departure_snapshot.is_empty() or not is_instance_valid(game) or get_tree().current_scene != game:
		return false
	enabled = false
	game.set_physics_process(false)
	var restored := restore_snapshot(game, departure_snapshot)
	game.set_physics_process(true)
	enabled = true
	elapsed = 0.0
	return restored

func _path(owner: Node, node: Variant) -> String:
	if not is_instance_valid(node) or not node is Node or not owner.is_ancestor_of(node):
		return ""
	return str(owner.get_path_to(node))

func make_snapshot(owner: Node) -> Dictionary:
	var data := {"version": VERSION, "ships": {}, "obstacles": {}, "credits": 0, "selected": _path(owner, owner.ship) if owner.selected else "", "docked": ""}
	data["map_hash"] = owner.map_hash
	var tasks := owner.get_node_or_null("TaskManager")
	if tasks != null:
		data["task_state"] = tasks.make_state()
	var tutorial := owner.get_node_or_null("TutorialController")
	if tutorial != null:
		data["tutorial_state"] = tutorial.make_state()
	var progression := owner.get_node_or_null("ProgressionManager")
	if progression != null:
		data["progression_state"] = progression.make_state()
	var quests := owner.get_node_or_null("QuestManager")
	if quests != null:
		data["quest_state"] = quests.make_state()
	var story := owner.get_node_or_null("StoryState")
	if story != null:
		data["story_state"] = story.make_state()
	var cg := owner.get_node_or_null("CgController")
	if cg != null:
		data["cg_state"] = cg.make_state()
	var menu := owner.get_node_or_null("PauseMenu")
	data["paused"] = owner.paused_before_selection if owner.selecting_orbit else (menu.was_paused if menu != null and menu.is_open() else owner.simulation_paused)
	data["speed"] = owner.simulation_speed
	data["accumulator"] = owner.accumulator
	var session = owner.get_node("PortController").session
	data.credits = session.get_credits()
	# 只记录需要任务解锁的装备；无需解锁的装备由目录推导，不进存档。
	data["unlocked_equipment"] = session.get_unlocked_equipment()
	for vessel in owner.ships:
		var path := _path(owner, vessel)
		var state := {}
		for field in SHIP_FIELDS:
			state[field] = vessel.get(field)
		for field in SHIP_REFS:
			state[field] = _path(owner, vessel.get(field))
		state["thrust_lock_enabled"] = vessel.thrust_lock_enabled
		state["thrust_lock_angle"] = vessel.thrust_lock_angle
		state["upgrade_slots"] = vessel.upgrade_slots.duplicate()
		state["shield_ready"] = vessel.shield_ready
		data.ships[path] = state
	for object in owner.obstacles:
		var state := {"flight_position": object.flight_position, "flight_velocity": object.flight_velocity, "destroyed": object.destroyed, "stopped": owner.stopped_obstacles.has(object)}
		# 只有太空垃圾会被擦除，小行星没有剩余质量概念，不写该字段。
		if object.is_in_group("space_debris"):
			state["remaining_mass_kg"] = object.remaining_mass_kg
		data.obstacles[_path(owner, object)] = state
	var port = owner.get_node("PortController")
	if port.active:
		data.docked = _path(owner, port.docked_ship)
	return data

func restore_snapshot(owner: Node, data: Dictionary) -> bool:
	var progression := owner.get_node_or_null("ProgressionManager")
	if progression != null and not progression.prepare_for_restore(data.get("progression_state", {})):
		return false
	if not _compatible(owner, data):
		return false
	var tutorial := owner.get_node_or_null("TutorialController")
	if tutorial != null:
		tutorial._cancel(false)
	# 在恢复任一教程的新消息前清理旧活动教程，避免旧教程清掉新教程续档弹窗。
	var orbit_tutorial := owner.get_node_or_null("OrbitTutorialController")
	if orbit_tutorial != null and orbit_tutorial.active:
		orbit_tutorial._cancel(false)
	var port = owner.get_node("PortController")
	port.leave_port()
	owner.simulation_paused = data.paused
	owner.simulation_speed = data.speed
	owner.accumulator = data.accumulator
	var session = port.session
	session.reset_session()
	session.set_credits(data.credits)
	# 旧存档没有该字段：视为没有额外解锁，只保留目录里默认可用的装备。
	session.restore_unlocked(data.get("unlocked_equipment", []))
	owner.stopped_obstacles.clear()
	# 直接恢复选择，避免旧运行态触发入港或清空其他船的已保存推力。
	owner.selected = not data.selected.is_empty()
	if owner.selected:
		owner.ship = owner.get_node(data.selected)
		owner.get_node("StarMapView").on_ship_selected()
	for path in data.ships:
		var vessel = owner.get_node(path)
		# 自动驾驶意图不持久化；恢复同一场景也必须先清除旧执行/待命状态。
		owner._stop_autopilot("", vessel)
		var state: Dictionary = data.ships[path]
		vessel.upgrade_slots = _sanitize_slots(state.get("upgrade_slots", ["", "", "", ""]))
		vessel.shield_ready = state.get("shield_ready", false)
		vessel.thrust_lock_enabled = state.get("thrust_lock_enabled", false)
		vessel.thrust_lock_angle = state.get("thrust_lock_angle", 0.0)
		for field in SHIP_FIELDS:
			vessel.set(field, state[field])
		for field in SHIP_REFS:
			vessel.set(field, owner.get_node_or_null(state[field]) if not state[field].is_empty() else null)
	for path in data.obstacles:
		var object = owner.get_node(path)
		var state: Dictionary = data.obstacles[path]
		object.flight_position = state.flight_position
		object.flight_velocity = state.flight_velocity
		object.destroyed = state.destroyed
		# 固定垃圾总质量来自场景/地图，不读取旧采集存档中的动态质量；只恢复擦除进度。
		if object.is_in_group("space_debris"):
			object.mass_kg = object.starting_mass_kg
			object.restore_erasure(float(state.get("remaining_mass_kg", object.mass_kg)))
		if state.stopped:
			owner.stopped_obstacles[object] = true
	if not data.docked.is_empty():
		var vessel = owner.get_node(data.docked)
		port.enter_port(vessel.arrival_source, vessel)
	var tasks := owner.get_node_or_null("TaskManager")
	if tasks != null:
		# 旧v1存档缺失字段时，默认本局尚未触发；瞬时对话与队列不序列化。
		tasks.restore_state(data.get("task_state", {"version": 1, "triggered": {}}))
	var quests := owner.get_node_or_null("QuestManager")
	if quests != null:
		# 旧存档缺失任务字段时清空任务，避免跨档残留；已完成任务不重发信号与奖励。
		quests.restore_state(data.get("quest_state", {"version": 1, "quests": []}))
	var cg := owner.get_node_or_null("CgController")
	if cg != null:
		# 旧存档缺失 CG 字段时视为未看过任何 CG；恢复动作会撤销读档瞬间误触发的播放。
		cg.restore_state(data.get("cg_state", {"version": 1, "played": {}}))
	var story := owner.get_node_or_null("StoryState")
	if story != null:
		# 旧存档没有剧情状态：清空标记与已播台词，避免跨档残留。
		story.restore_state(data.get("story_state", {"version": 1, "flags": {}, "seen": [], "visited": []}))
	if tutorial != null:
		# 旧v1存档没有教程字段时保持关闭；活动教程重播当前说明而非跳步骤。
		tutorial.restore_state(data.get("tutorial_state", {}))
	if orbit_tutorial != null and progression != null:
		progression.restore_orbit_state(data.get("progression_state", {}))
	owner._refresh_preview()
	owner._update_ui()
	owner._sync_visuals()
	return true

## 清掉已下线的改装：老存档里的槽位变成空槽，玩家的船不会因为装备被删而读不出存档。
func _sanitize_slots(slots) -> Array:
	var result: Array = []
	if not slots is Array:
		return ["", "", "", ""]
	for id in slots:
		result.append("" if (id is String and id in RETIRED_UPGRADES) else id)
	return result


func _compatible(owner: Node, data: Dictionary) -> bool:
	var tutorial := owner.get_node_or_null("TutorialController")
	if data.has("tutorial_state") and (tutorial == null or not tutorial.is_state_valid(data.tutorial_state)):
		return false
	var tasks := owner.get_node_or_null("TaskManager")
	if data.has("task_state") and (tasks == null or not tasks.is_state_valid(data.task_state)):
		return false
	var progression := owner.get_node_or_null("ProgressionManager")
	if data.has("progression_state") and (progression == null or not progression.is_state_valid(data.progression_state)):
		return false
	var quests := owner.get_node_or_null("QuestManager")
	if data.has("quest_state") and (quests == null or not quests.is_state_valid(data.quest_state)):
		return false
	var cg := owner.get_node_or_null("CgController")
	if data.has("cg_state") and (cg == null or not cg.is_state_valid(data.cg_state)):
		return false
	var story := owner.get_node_or_null("StoryState")
	if data.has("story_state") and (story == null or not story.is_state_valid(data.story_state)):
		return false
	if data.get("map_hash", "") != owner.map_hash:
		return false
	if data.get("version") not in [1, 3, 4, 5, VERSION] or not data.get("ships") is Dictionary or not data.get("obstacles") is Dictionary or not data.get("selected") is String or not data.get("docked") is String or not data.get("credits") is int:
		return false
	if data.has("unlocked_equipment"):
		var unlocked = data.unlocked_equipment
		if not unlocked is Array or unlocked.size() > 64:
			return false
		for id in unlocked:
			if not id is String or id.is_empty():
				return false
	if not data.get("paused") is bool or not data.get("speed") is float or not data.get("accumulator") is float:
		return false
	if data.credits < 0 or data.credits > owner.get_node("PortController").session.MAX_NUMBER or not is_finite(data.speed) or data.speed <= 0.0 or not is_finite(data.accumulator) or data.accumulator < 0.0 or data.accumulator >= owner.SIM_STEP:
		return false
	if data.ships.size() != owner.ships.size() or data.obstacles.size() != owner.obstacles.size():
		return false
	var session = owner.get_node("PortController").session
	for path in data.ships:
		var vessel = owner.get_node_or_null(path)
		if not owner.ships.has(vessel) or not data.ships[path] is Dictionary:
			return false
		for field in SHIP_FIELDS:
			if not data.ships[path].has(field) or typeof(data.ships[path][field]) != typeof(vessel.get(field)):
				return false
		var state: Dictionary = data.ships[path]
		if not state.get("thrust_lock_enabled", false) is bool or not state.get("thrust_lock_angle", 0.0) is float or not is_finite(state.get("thrust_lock_angle", 0.0)):
			return false
		var slots = state.get("upgrade_slots", ["", "", "", ""])
		var shield = state.get("shield_ready", false)
		if not slots is Array or slots.size() != 4 or not shield is bool:
			return false
		var seen := {}
		for id in slots:
			if not id is String:
				return false
			# 已下线的改装：老存档里可能还占着槽位，读档时会被清空（见 _sanitize_slots）。
			if id in RETIRED_UPGRADES:
				continue
			# 捕捉网允许占用多个槽位，其余改装仍要求同类唯一。
			var repeatable: bool = id == "capture_net"
			if not id.is_empty() and (not session.UPGRADES.has(id) or (seen.has(id) and not repeatable)):
				return false
			if not id.is_empty():
				seen[id] = true
		if shield and not seen.has("shield"):
			return false
		if state.fuel < 0.0 or state.fuel > vessel.fuel_capacity * (1.2 if seen.has("fuel") else 1.0) or state.completed_voyage_count < 0:
			return false
		for field in SHIP_FIELDS:
			var value = state[field]
			if value is float and not is_finite(value):
				return false
			if value is Vector2 and not value.is_finite():
				return false
		if state.current_voyage_distance_m < 0.0 or state.last_voyage_distance_m < 0.0 or state.maneuver_index < 0 or state.maneuver_index > state.maneuver_commands.size():
			return false
		for command in state.maneuver_commands:
			if not (command is float or command is int) or not is_finite(float(command)):
				return false
		for field in SHIP_REFS:
			var ref = state.get(field)
			if not ref is String:
				return false
			if ref.is_empty():
				continue
			var target = owner.get_node_or_null(ref)
			if field in ["navigation_planet", "region_source", "maneuver_target", "orbit_source"] and not owner.planets.has(target):
				return false
			if field == "arrival_source" and not owner.planets.has(target) and not owner.cities.has(target):
				return false
			if field == "departed_city" and not owner.cities.has(target):
				return false
	for path in data.obstacles:
		var object = owner.get_node_or_null(path)
		var state = data.obstacles[path]
		if not owner.obstacles.has(object) or not state is Dictionary or not state.get("flight_position") is Vector2 or not state.get("flight_velocity") is Vector2 or not state.get("destroyed") is bool or not state.get("stopped") is bool:
			return false
		if not state.flight_position.is_finite() or not state.flight_velocity.is_finite():
			return false
		# v4 新增的擦除进度：旧存档没有该字段，视为整团完好；只有太空垃圾才允许携带。
		if state.has("remaining_mass_kg"):
			if not object.is_in_group("space_debris"):
				return false
			var remaining = state.remaining_mass_kg
			if not (remaining is float or remaining is int) or not is_finite(float(remaining)) or float(remaining) < 0.0 or float(remaining) > float(object.starting_mass_kg):
				return false
	if not data.selected.is_empty() and not data.ships.has(data.selected):
		return false
	if not data.docked.is_empty():
		if not data.ships.has(data.docked) or data.ships[data.docked].arrival_source.is_empty():
			return false
		var arrival = owner.get_node_or_null(data.ships[data.docked].arrival_source)
		if not is_instance_valid(arrival) or not "interaction_data_path" in arrival:
			return false
	return true

func _read_save(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var data = file.get_var(false)
	if not data is Dictionary or data.get("version") not in [1, 3, 5, VERSION]:
		return {}
	return data

func _write_save(data: Dictionary) -> bool:
	var file := FileAccess.open(TEMP_PATH, FileAccess.WRITE)
	if file == null:
		return false
	file.store_var(data, false)
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return false
	var save := ProjectSettings.globalize_path(SAVE_PATH)
	var temp := ProjectSettings.globalize_path(TEMP_PATH)
	var backup := ProjectSettings.globalize_path(BACKUP_PATH)
	if FileAccess.file_exists(SAVE_PATH):
		if loaded_backup and FileAccess.file_exists(BACKUP_PATH):
			if DirAccess.remove_absolute(save) != OK:
				return false
		else:
			if FileAccess.file_exists(BACKUP_PATH) and DirAccess.remove_absolute(backup) != OK:
				return false
			if DirAccess.rename_absolute(save, backup) != OK:
				return false
	if DirAccess.rename_absolute(temp, save) != OK:
		if FileAccess.file_exists(BACKUP_PATH) and not loaded_backup:
			DirAccess.rename_absolute(backup, save)
		return false
	loaded_backup = false
	return true
