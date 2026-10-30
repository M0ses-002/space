extends RefCounted

const MAP_PATH := "user://space_map_v1.json"
## 打包自带的地图：用户未提供 user:// 地图时回退加载，确保导出的可执行文件开箱有地图。
const BUILTIN_MAP_PATH := "res://maps/default_map.json"
const SCENES := {
	"planet": preload("res://scenes/planet.tscn"),
	"city": preload("res://scenes/flat_nuclear_city.tscn"),
	"asteroid": preload("res://scenes/asteroid.tscn"),
	"debris": preload("res://scenes/space_debris.tscn"),
}
const FIELDS := {
	"planet": ["display_name", "radius_m", "field_height_m", "surface_gravity", "max_gravity_radius_m", "interaction_data_path"],
	"city": ["display_name", "city_size_m", "gravity_height_m", "port_offset_m", "docking_radius_m", "dock_offset_m", "interaction_data_path"],
	"asteroid": ["initial_velocity", "radius_m", "mass_kg", "mineral_id", "mineral_unit_mass", "style_index"],
	"debris": ["initial_velocity", "radius_m", "debris_count", "debris_size_m", "minimum_fragment_pixels"],
}
const VECTORS := ["city_size_m", "port_offset_m", "dock_offset_m", "initial_velocity"]
const STRINGS := ["display_name", "mineral_id", "interaction_data_path"]
const ZERO_ALLOWED := ["field_height_m", "surface_gravity", "style_index", "debris_count", "minimum_fragment_pixels"]

static func _vector(value: Variant) -> bool:
	return value is Array and value.size() == 2 and _number(value[0]) and _number(value[1]) and absf(float(value[0])) <= 1000000000.0 and absf(float(value[1])) <= 1000000000.0

static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

static func _valid_id(value: Variant) -> bool:
	if not value is String or value.is_empty() or value.length() > 64:
		return false
	for c in value:
		if not (c >= "a" and c <= "z") and not (c >= "A" and c <= "Z") and not (c >= "0" and c <= "9") and c != "_" and c != "-":
			return false
	return true

static func read_map(path: String = MAP_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > 1048576:
		return {}
	var text := file.get_as_text()
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	var parsed: Variant = json.data
	if not parsed is Dictionary or parsed.get("version") != 1 or not parsed.get("objects") is Array or parsed.objects.size() > 1000:
		return {}
	if parsed.has("ship"):
		if not parsed.ship is Dictionary or not _vector(parsed.ship.get("position")) or not _vector(parsed.ship.get("velocity")):
			return {}
	var ids := {}
	for item in parsed.objects:
		if not item is Dictionary or not item.get("type") is String or not SCENES.has(item.type) or not _valid_id(item.get("id")) or ids.has(item.id) or not _vector(item.get("position")) or not item.get("fields", {}) is Dictionary:
			return {}
		ids[item.id] = true
		for key in item.get("fields", {}):
			if not key is String or not key in FIELDS[item.type]:
				return {}
			var value: Variant = item.fields[key]
			if key in VECTORS:
				if not _vector(value) or (key == "city_size_m" and (float(value[0]) <= 0.0 or float(value[1]) <= 0.0)):
					return {}
			elif key in STRINGS:
				if not value is String or value.length() > 256:
					return {}
				if key == "interaction_data_path" and (not value.begins_with("res://data/planets/") or not value.ends_with(".json") or ".." in value or "\\" in value):
					return {}
			else:
				if not _number(value) or float(value) > 1000000000000000.0 or float(value) < (0.0 if key in ZERO_ALLOWED else 0.000001):
					return {}
				if key in ["style_index", "debris_count"] and (float(value) != floor(float(value)) or float(value) > (2.0 if key == "style_index" else 32.0)):
					return {}
	return {"objects": parsed.objects, "ship": parsed.get("ship", {}), "hash": JSON.stringify(parsed, "", true).sha256_text()}

## 读取生效地图：优先 user:// 自定义地图；不存在且允许回退时，使用打包内置的 res:// 地图。
## 返回 {"map": Dictionary, "error": bool}；error 为 true 表示 user 地图存在但内容无效。
static func load_map(allow_builtin: bool = false) -> Dictionary:
	if FileAccess.file_exists(MAP_PATH):
		var map := read_map(MAP_PATH)
		if map.is_empty():
			return {"map": {}, "error": true}
		return {"map": map, "error": false}
	if allow_builtin and FileAccess.file_exists(BUILTIN_MAP_PATH):
		var builtin := read_map(BUILTIN_MAP_PATH)
		if not builtin.is_empty():
			return {"map": builtin, "error": false}
	return {"map": {}, "error": false}


static func apply_map(game: Node, map: Dictionary) -> void:
	var world: Node2D = game.get_node("World")
	if not map.get("ship", {}).is_empty():
		for child in world.get_children():
			if child.is_in_group("flight_ships"):
				child.initial_position = Vector2(map.ship.position[0], map.ship.position[1])
				child.initial_velocity = Vector2(map.ship.velocity[0], map.ship.velocity[1])
				if child.is_node_ready():
					child.reset_flight()
				break
	for child in world.get_children():
		if child.is_in_group("gravity_sources") or child.is_in_group("flight_obstacles") or (child.has_method("get_dock_position") and child.has_method("contains_docking_point")):
			world.remove_child(child)
			child.queue_free()
	for item in map.objects:
		var node: Node2D = SCENES[item.type].instantiate()
		node.name = "Map_" + item.id
		var point := Vector2(float(item.position[0]), float(item.position[1]))
		for key in item.get("fields", {}):
			var value: Variant = item.fields[key]
			if key in VECTORS:
				value = Vector2(float(value[0]), float(value[1]))
			elif key in ["style_index", "debris_count"]:
				value = int(value)
			node.set(key, value)
		if item.type in ["planet", "city"]:
			node.position = game.layout_origin + point * game.layout_pixels_per_meter
		else:
			node.initial_position = point
		world.add_child(node)
