extends Node

const SAVE_PATH := "user://space_save_v1.dat"
const TEMP_PATH := "user://space_save_v1.tmp"
const BACKUP_PATH := "user://space_save_v1.bak"
const GAME_SCENE := "res://star_map_demo.tscn"
const VERSION := 1
const SHIP_FIELDS := ["flight_position", "flight_velocity", "fuel", "crashed", "voyage_finished", "departure_position", "departure_velocity", "current_voyage_distance_m", "last_voyage_distance_m", "completed_voyage_count", "mining_enabled", "mining_progress", "thrust_direction", "thrust_throttle", "navigation_target", "has_navigation_target", "navigation_tracks_planet", "navigation_status", "steering", "heading", "manual_thrust", "maneuver_commands", "maneuver_index", "orbit_angle", "orbit_last_angle", "orbit_start_radius", "orbit_start_speed", "orbit_direction", "stay_available", "region_event"]
const SHIP_REFS := ["mining_target", "navigation_planet", "region_source", "maneuver_target", "orbit_source", "arrival_source", "departed_city"]
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
	return true

func continue_game() -> bool:
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
	if is_new and not save_game():
		_show_status("保存失败，请检查用户数据目录；原存档已保留。")

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
	elapsed += delta
	if elapsed >= 30.0:
		elapsed = 0.0
		if not save_game():
			_show_status("自动保存失败，请检查用户数据目录；原存档已保留。")

func save_game() -> bool:
	if not enabled or not is_instance_valid(game):
		return false
	return _write_save(make_snapshot(game))

func _path(owner: Node, node: Variant) -> String:
	if not is_instance_valid(node) or not node is Node or not owner.is_ancestor_of(node):
		return ""
	return str(owner.get_path_to(node))

func make_snapshot(owner: Node) -> Dictionary:
	var data := {"version": VERSION, "ships": {}, "obstacles": {}, "credits": 0, "cargo": {}, "settled": {}, "planets": {}, "selected": _path(owner, owner.ship) if owner.selected else "", "docked": ""}
	data["map_hash"] = owner.map_hash
	data["paused"] = owner.paused_before_selection if owner.selecting_orbit else owner.simulation_paused
	data["speed"] = owner.simulation_speed
	data["accumulator"] = owner.accumulator
	var session = owner.get_node("PortController").session
	data.credits = session._credits
	data.planets = session._planets.duplicate(true)
	for vessel in owner.ships:
		var path := _path(owner, vessel)
		var state := {}
		for field in SHIP_FIELDS:
			state[field] = vessel.get(field)
		for field in SHIP_REFS:
			state[field] = _path(owner, vessel.get(field))
		state["upgrade_slots"] = vessel.upgrade_slots.duplicate()
		state["shield_ready"] = vessel.shield_ready
		data.ships[path] = state
		data.cargo[path] = session._fleet_cargo.get(vessel.get_instance_id(), {}).duplicate(true)
		data.settled[path] = session._settled_voyages.get(vessel.get_instance_id(), 0)
	for object in owner.obstacles:
		var state := {"flight_position": object.flight_position, "flight_velocity": object.flight_velocity, "destroyed": object.destroyed, "stopped": owner.stopped_obstacles.has(object)}
		if object.is_in_group("asteroids") or object.has_method("get_mineral_id"):
			state["mass_kg"] = object.mass_kg
			state["radius_m"] = object.radius_m
		data.obstacles[_path(owner, object)] = state
	var port = owner.get_node("PortController")
	if port.active:
		data.docked = _path(owner, port.docked_ship)
	return data

func restore_snapshot(owner: Node, data: Dictionary) -> bool:
	if not _compatible(owner, data):
		return false
	var port = owner.get_node("PortController")
	port.leave_port()
	owner.simulation_paused = data.paused
	owner.simulation_speed = data.speed
	owner.accumulator = data.accumulator
	var session = port.session
	session._credits = int(data.credits)
	session._planets = data.planets.duplicate(true)
	session._fleet_cargo.clear()
	session._settled_voyages.clear()
	owner.stopped_obstacles.clear()
	if not data.selected.is_empty():
		owner._select_target(owner.get_node(data.selected))
	else:
		owner.selected = false
	for path in data.ships:
		var vessel = owner.get_node(path)
		var state: Dictionary = data.ships[path]
		vessel.upgrade_slots = state.get("upgrade_slots", ["", "", "", ""]).duplicate()
		vessel.shield_ready = state.get("shield_ready", false)
		for field in SHIP_FIELDS:
			vessel.set(field, state[field])
		for field in SHIP_REFS:
			vessel.set(field, owner.get_node_or_null(state[field]) if not state[field].is_empty() else null)
		session._fleet_cargo[vessel.get_instance_id()] = data.cargo[path].duplicate(true)
		session._settled_voyages[vessel.get_instance_id()] = int(data.settled[path])
		vessel.cargo_mass = session.get_ship_cargo_mass(vessel.get_instance_id())
		vessel._update_mining_range()
	for path in data.obstacles:
		var object = owner.get_node(path)
		var state: Dictionary = data.obstacles[path]
		object.flight_position = state.flight_position
		object.flight_velocity = state.flight_velocity
		object.destroyed = state.destroyed
		if state.has("mass_kg"):
			object.mass_kg = state.mass_kg
			object.radius_m = state.radius_m
		if state.stopped:
			owner.stopped_obstacles[object] = true
	if not data.docked.is_empty():
		var vessel = owner.get_node(data.docked)
		port.enter_port(vessel.arrival_source, vessel)
	owner._refresh_preview()
	owner._update_ui()
	owner._sync_visuals()
	return true

func _compatible(owner: Node, data: Dictionary) -> bool:
	if data.get("map_hash", "") != owner.map_hash:
		return false
	if data.get("version") != VERSION or not data.get("ships") is Dictionary or not data.get("obstacles") is Dictionary or not data.get("cargo") is Dictionary or not data.get("settled") is Dictionary or not data.get("planets") is Dictionary or not data.get("selected") is String or not data.get("docked") is String or not data.get("credits") is int:
		return false
	if not data.get("paused") is bool or not data.get("speed") is float or not data.get("accumulator") is float:
		return false
	if data.credits < 0 or not is_finite(data.speed) or data.speed <= 0.0 or not is_finite(data.accumulator) or data.accumulator < 0.0 or data.accumulator >= owner.SIM_STEP:
		return false
	if data.ships.size() != owner.ships.size() or data.obstacles.size() != owner.obstacles.size():
		return false
	var session = owner.get_node("PortController").session
	for path in data.ships:
		var vessel = owner.get_node_or_null(path)
		if not owner.ships.has(vessel) or not data.ships[path] is Dictionary or not data.cargo.get(path) is Dictionary or not data.settled.has(path):
			return false
		if not data.settled[path] is int or data.settled[path] < 0:
			return false
		for item in data.cargo[path]:
			if not owner.get_node("PortController").session._masses.has(item) or not owner.get_node("PortController").session._is_integer(data.cargo[path][item]) or data.cargo[path][item] < 0:
				return false
		for field in SHIP_FIELDS:
			if not data.ships[path].has(field) or typeof(data.ships[path][field]) != typeof(vessel.get(field)):
				return false
		var state: Dictionary = data.ships[path]
		var slots = state.get("upgrade_slots", ["", "", "", ""])
		var shield = state.get("shield_ready", false)
		if not slots is Array or slots.size() != 4 or not shield is bool:
			return false
		var seen := {}
		for id in slots:
			if not id is String or (not id.is_empty() and (not session.UPGRADES.has(id) or seen.has(id))):
				return false
			if not id.is_empty():
				seen[id] = true
		if shield and not seen.has("shield"):
			return false
		var cargo_mass := 0.0
		for item in data.cargo[path]:
			cargo_mass += float(data.cargo[path][item]) * float(session._masses[item])
		if not is_finite(cargo_mass) or cargo_mass > session._capacity or state.fuel < 0.0 or state.fuel > vessel.fuel_capacity * (1.2 if seen.has("fuel") else 1.0) or state.completed_voyage_count < 0 or data.settled[path] > state.completed_voyage_count:
			return false
		for field in SHIP_FIELDS:
			var value = state[field]
			if value is float and not is_finite(value):
				return false
			if value is Vector2 and not value.is_finite():
				return false
		if state.current_voyage_distance_m < 0.0 or state.last_voyage_distance_m < 0.0 or state.mining_progress < 0.0 or state.maneuver_index < 0 or state.maneuver_index > state.maneuver_commands.size():
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
			if field == "mining_target" and not owner.obstacles.has(target):
				return false
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
		if object.has_method("get_mineral_id"):
			if not session._number(state.get("mass_kg")) or not session._number(state.get("radius_m")) or state.mass_kg < 0.0 or state.radius_m < 0.0:
				return false
	if not data.selected.is_empty() and not data.ships.has(data.selected):
		return false
	if not data.docked.is_empty():
		if not data.ships.has(data.docked) or data.ships[data.docked].arrival_source.is_empty():
			return false
		var arrival = owner.get_node_or_null(data.ships[data.docked].arrival_source)
		if not is_instance_valid(arrival) or not "interaction_data_path" in arrival:
			return false
	for path in data.planets:
		if not path is String or not session._valid_json_path(path) or not data.planets[path] is Dictionary or not session._validate_planet(data.planets[path]).is_empty():
			return false
		for item in data.planets[path].trade.items:
			if not session._masses.has(item.id) or float(session._masses[item.id]) != float(item.unit_mass):
				return false
	return true

func _read_save(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var data = file.get_var(false)
	if not data is Dictionary or data.get("version") != VERSION:
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
