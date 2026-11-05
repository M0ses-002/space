extends Node
## CG 剧情调度器：读取 data/cg.json，按「进入地图 / 进入行星或太空城 / 完成任务 / 到达地点」四类条件，
## 把命中的 CG 交给 CgWindow 播放。只做判定与记账，不绘制任何东西。
signal cg_triggered(id: String)

const TRIGGER_TYPES := ["map_enter", "enter_object", "quest_complete", "reach_point"]
const OBJECT_KINDS := ["", "any", "planet", "city"]
const ID_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
const IMAGE_EXTENSIONS := ["png", "jpg", "jpeg", "webp", "svg", "bmp", "tres"]

@export_file("*.json") var config_path: String = "res://data/cg.json"
@export var window_path: NodePath = NodePath("../CgWindow")
## 到达地点的采样间隔（秒）；用线段扫掠判定，高速穿过小范围也不会漏。
@export var poll_interval: float = 0.1

var played: Dictionary = {}
var _cgs: Array[Dictionary] = []
## 全局 CG（data/cg.json，跨地图通用）与当前地图绑定的 CG（地图根节点 cg_data_path）。
var _global_cgs: Array[Dictionary] = []
var _map_cgs: Array[Dictionary] = []
var _map_config_path: String = ""
var _map_config_owner: String = ""
var _game: Node
var _window: Node
var _elapsed: float = 0.0
var _last_map_epoch: int = -1
var _last_position := Vector2.INF
var _primed: bool = false
var _inside: Dictionary = {}
var _paused_for_cg: bool = false
var _pause_before_cg: bool = false

func bind_game(game: Node) -> void:
	_game = game
	_window = get_node_or_null(window_path)
	_load_config()
	_sync_map_config(true)
	if _window != null:
		if _window.has_signal("cg_started") and not _window.cg_started.is_connected(_on_cg_started):
			_window.cg_started.connect(_on_cg_started)
		if _window.has_signal("queue_finished") and not _window.queue_finished.is_connected(_on_cg_queue_finished):
			_window.queue_finished.connect(_on_cg_queue_finished)
	var port := _game.get_node_or_null("PortController")
	if port != null and port.has_signal("port_entered") and not port.port_entered.is_connected(_on_port_entered):
		port.port_entered.connect(_on_port_entered)
	var quests := _game.get_node_or_null("QuestManager")
	if quests != null and not quests.quest_completed.is_connected(_on_quest_completed):
		quests.quest_completed.connect(_on_quest_completed)

func _load_config() -> void:
	_global_cgs = _read_cg_file(config_path, "")
	_rebuild_cgs()

## 重新合并「全局 + 当前地图」两份配置。地图切换时只会换掉后一份，已播记录不受影响。
func _rebuild_cgs() -> void:
	_cgs.clear()
	_cgs.append_array(_global_cgs)
	_cgs.append_array(_map_cgs)

## 跟随当前地图的 cg_data_path 装载地图专属 CG；路径没变就不重复解析。
func _sync_map_config(force: bool = false) -> void:
	if not is_instance_valid(_game):
		return
	var raw: Variant = _game.get("current_cg_path")
	var path := str(raw) if raw is String else ""
	# 两张地图可以指向同一份 CG 文件；归属也要参与比对，否则前缀与归属校验会沿用上一张图的。
	var map_id := str(_game.get("current_map_id"))
	if not force and path == _map_config_path and map_id == _map_config_owner:
		return
	_map_config_path = path
	_map_config_owner = map_id
	_map_cgs = _read_cg_file(path, map_id)
	_rebuild_cgs()
	# 换地图后旧地图的采样点与圈内状态全部失效：重新起算，避免跨地图误判「到达」。
	_primed = false
	_last_position = Vector2.INF
	_inside.clear()

## 读取一份 CG 配置。map_id 非空时按地图绑定处理：校验归属、给 id 加地图前缀。
func _read_cg_file(path: String, map_id: String) -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	if path.is_empty():
		return items
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("CG 配置无法读取：%s" % path)
		return items
	if file.get_length() > 1048576:
		push_warning("CG 配置超过 1 MiB，已忽略：%s" % path)
		return items
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or parsed.get("version") != 1 or not parsed.get("cgs") is Array:
		push_warning("CG 配置需要 version=1 与 cgs 数组：%s" % path)
		return items
	# 配置里可写 map 归属，防止「A 地图的 CG 文件」被误挂到 B 地图上。
	if not map_id.is_empty():
		var owner := str(parsed.get("map", ""))
		if not owner.is_empty() and owner != map_id:
			push_warning("CG 配置归属 %s 与当前地图 %s 不一致，已忽略：%s" % [owner, map_id, path])
			return items
	var errors := collect_errors(parsed)
	for message in errors:
		push_warning("CG 配置：%s" % message)
	var seen := {}
	for item: Variant in parsed.cgs:
		if not item is Dictionary:
			continue
		var id := str(item.get("id", ""))
		if id.is_empty() or seen.has(id) or not bool(item.get("enabled", true)):
			continue
		if not _is_playable(item):
			continue
		seen[id] = true
		var copy: Dictionary = item.duplicate(true)
		# 地图专属 CG 用「地图名/本文件 id」记账：不同地图里的同名 id 不会互相顶掉。
		if not map_id.is_empty():
			copy.id = "%s/%s" % [map_id, id]
		items.append(copy)
	return items

## 静态校验，返回全部错误（中文，最多 50 条）。供测试与未来编辑器复用。
func collect_errors(data: Variant) -> Array[String]:
	var errors: Array[String] = []
	if not data is Dictionary:
		return ["配置根必须是 JSON 对象"]
	if data.get("version") != 1:
		errors.append("version 必须是整数 1")
	if data.has("map") and not data.get("map") is String:
		errors.append("map 必须是字符串（本文件归属的地图名，可留空）")
	if not data.get("cgs") is Array:
		errors.append("cgs 必须是数组")
		return errors
	var seen := {}
	for index in range(data.cgs.size()):
		var item: Variant = data.cgs[index]
		var where := "第 %d 条" % (index + 1)
		if not item is Dictionary:
			errors.append("%s：必须是对象" % where)
			continue
		var id: Variant = item.get("id")
		if not id is String or str(id).is_empty():
			errors.append("%s：id 必须是非空字符串" % where)
		elif not _valid_id(str(id)):
			errors.append("%s：id 只能包含字母、数字、下划线和连字符，且不超过 64 字符" % where)
		elif seen.has(id):
			errors.append("%s：id %s 重复" % [where, str(id)])
		else:
			seen[id] = true
			where = "%s（%s）" % [where, str(id)]
		if not item.get("image") is String or str(item.get("image", "")).is_empty():
			errors.append("%s：image 必须是非空字符串" % where)
		elif not _valid_image_path(str(item.image)):
			errors.append("%s：image 必须是 res:// 下的图片路径（%s）" % [where, ", ".join(PackedStringArray(IMAGE_EXTENSIONS))])
		if not item.get("text") is String:
			errors.append("%s：text 必须是字符串" % where)
		elif str(item.text).length() > 4000:
			errors.append("%s：text 不超过 4000 字符" % where)
		var duration: Variant = item.get("duration")
		if not (duration is float or duration is int) or not is_finite(float(duration)) or float(duration) <= 0.0 or float(duration) > 3600.0:
			errors.append("%s：duration 必须是 0–3600 之间的正数（现实秒）" % where)
		for flag in ["once", "skippable", "enabled"]:
			if item.has(flag) and not item.get(flag) is bool:
				errors.append("%s：%s 必须是 true 或 false" % [where, flag])
		errors.append_array(_trigger_errors(item.get("trigger"), where))
		if errors.size() >= 50:
			errors.append("错误过多，已截断")
			break
	return errors

func _trigger_errors(trigger: Variant, where: String) -> Array[String]:
	var errors: Array[String] = []
	if not trigger is Dictionary:
		return ["%s：trigger 必须是对象" % where]
	var type := str(trigger.get("type", ""))
	if not type in TRIGGER_TYPES:
		return ["%s：trigger.type 必须是 %s 之一" % [where, ", ".join(PackedStringArray(TRIGGER_TYPES))]]
	match type:
		"map_enter":
			if not trigger.get("map") is String or str(trigger.get("map", "")).is_empty():
				errors.append("%s：进入地图需要 map（地图文件名，* 表示任意地图）" % where)
		"enter_object":
			if not trigger.get("object") is String or str(trigger.get("object", "")).is_empty():
				errors.append("%s：进入行星/太空城需要 object（地图对象 id，* 表示任意）" % where)
			if not str(trigger.get("kind", "")) in OBJECT_KINDS:
				errors.append("%s：kind 必须是 %s 之一" % [where, ", ".join(PackedStringArray(["any", "planet", "city"]))])
		"quest_complete":
			if not trigger.get("quest") is String or str(trigger.get("quest", "")).is_empty():
				errors.append("%s：完成委托需要 quest（委托 id）" % where)
		"reach_point":
			var point: Variant = trigger.get("position")
			if not point is Array or point.size() != 2 or not _is_number(point[0]) or not _is_number(point[1]):
				errors.append("%s：到达地点需要 position（[x, y] 米）" % where)
			elif absf(float(point[0])) > 1000000000.0 or absf(float(point[1])) > 1000000000.0:
				errors.append("%s：position 分量绝对值不超过 1e9" % where)
			var radius: Variant = trigger.get("radius_m")
			if not _is_number(radius) or float(radius) <= 0.0 or float(radius) > 1000000000.0:
				errors.append("%s：到达地点需要 radius_m（大于 0 的米数）" % where)
	return errors

func _is_playable(item: Dictionary) -> bool:
	return _trigger_errors(item.get("trigger"), "").is_empty()

func _is_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

func _valid_id(value: String) -> bool:
	if value.is_empty() or value.length() > 64:
		return false
	for c in value:
		if not ID_CHARS.contains(c):
			return false
	return true

func _valid_image_path(path: String) -> bool:
	if not path.begins_with("res://") or ".." in path or "\\" in path:
		return false
	return path.get_extension().to_lower() in IMAGE_EXTENSIONS

func _process(delta: float) -> void:
	if not is_instance_valid(_game):
		return
	# 地图可能在运行中切换（教程→世界），先跟随地图换装再判断是否还有 CG。
	_sync_map_config()
	if _cgs.is_empty():
		return
	_elapsed += delta
	if _elapsed < poll_interval:
		return
	_elapsed = 0.0
	_check_map_enter()
	_check_reach_point()

## 进入地图：以地图文件名判定，同一次加载只判定一次。
func _check_map_enter() -> void:
	var epoch := int(_game.map_epoch)
	if epoch == _last_map_epoch:
		return
	_last_map_epoch = epoch
	var map_id := str(_game.current_map_id)
	for cg: Dictionary in _cgs:
		var trigger: Dictionary = cg.trigger
		if str(trigger.type) == "map_enter" and _map_matches(str(trigger.map), map_id):
			_try_play(cg)

## 到达地点：用上一采样点到当前位置的线段与圆求交，避免高速穿越漏判。
func _check_reach_point() -> void:
	var ship = _game.ship
	var position := Vector2.INF
	if is_instance_valid(ship) and not ship.crashed and ship.flight_position.is_finite():
		position = ship.flight_position
	if not _primed:
		_primed = true
		_last_position = position
		for cg: Dictionary in _cgs:
			if str(cg.trigger.type) == "reach_point":
				_inside[str(cg.id)] = _in_circle(position, cg.trigger)
		return
	var previous := _last_position
	if not previous.is_finite():
		previous = position
	_last_position = position
	for cg: Dictionary in _cgs:
		if str(cg.trigger.type) != "reach_point":
			continue
		var id := str(cg.id)
		var inside := _in_circle(position, cg.trigger)
		var was_inside := bool(_inside.get(id, false))
		_inside[id] = inside
		# 「到达」只在圈外→圈内的那一次成立：停在圈内不重复播，once=false 也不会刷屏。
		if was_inside:
			continue
		if _segment_hits_circle(previous, position, cg.trigger):
			_try_play(cg)

func _in_circle(position: Vector2, trigger: Dictionary) -> bool:
	if not position.is_finite():
		return false
	var center := _circle_center(trigger)
	return position.distance_to(center) <= float(trigger.radius_m)

func _circle_center(trigger: Dictionary) -> Vector2:
	var point: Array = trigger.position
	return Vector2(float(point[0]), float(point[1]))

func _segment_hits_circle(start: Vector2, end: Vector2, trigger: Dictionary) -> bool:
	if not start.is_finite() or not end.is_finite():
		return false
	var center := _circle_center(trigger)
	var radius := float(trigger.radius_m)
	if start.distance_to(center) <= radius or end.distance_to(center) <= radius:
		return true
	var movement := end - start
	var length_squared := movement.length_squared()
	if length_squared < 0.000001:
		return false
	var offset := start - center
	var b := 2.0 * offset.dot(movement)
	var discriminant := b * b - 4.0 * length_squared * (offset.length_squared() - radius * radius)
	if discriminant < 0.0:
		return false
	var fraction := (-b - sqrt(discriminant)) / (2.0 * length_squared)
	return fraction >= 0.0 and fraction <= 1.0

func _map_matches(pattern: String, map_id: String) -> bool:
	var value := pattern.strip_edges()
	if value == "*":
		return not map_id.is_empty()
	return value.get_file().get_basename() == map_id

func _on_port_entered(object_id: String, source: Node2D) -> void:
	var kind := "planet" if is_instance_valid(source) and _game.planets.has(source) else ("city" if is_instance_valid(source) and _game.cities.has(source) else "")
	for cg: Dictionary in _cgs:
		var trigger: Dictionary = cg.trigger
		if str(trigger.type) != "enter_object":
			continue
		var wanted := str(trigger.object)
		if wanted != "*" and wanted != object_id:
			continue
		var wanted_kind := str(trigger.get("kind", ""))
		if wanted_kind not in ["", "any"] and wanted_kind != kind:
			continue
		_try_play(cg)

func _on_quest_completed(quest_id: String) -> void:
	for cg: Dictionary in _cgs:
		var trigger: Dictionary = cg.trigger
		if str(trigger.type) == "quest_complete" and str(trigger.quest) == quest_id:
			_try_play(cg)

func _try_play(cg: Dictionary) -> void:
	if not is_instance_valid(_window) or not _window.has_method("enqueue_cg"):
		return
	var id := str(cg.id)
	var once := bool(cg.get("once", true))
	if once and played.has(id):
		return
	var payload := {
		"id": id,
		"image": str(cg.image),
		"text": str(cg.text),
		"duration": float(cg.duration),
		"skippable": bool(cg.get("skippable", true)),
	}
	if not _window.enqueue_cg(payload):
		return
	# 入队即记账，不等待播放结束：中途存档、同帧多条命中都不会重播。
	if once:
		played[id] = true
	cg_triggered.emit(id)

## CG 全屏遮挡，播放期间暂停模拟；恢复时只解除自己设的暂停，不覆盖教程或玩家的暂停。
func _on_cg_started(_data: Dictionary) -> void:
	if not is_instance_valid(_game) or _paused_for_cg:
		return
	_pause_before_cg = bool(_game.simulation_paused)
	if not _pause_before_cg:
		_game.simulation_paused = true
		_paused_for_cg = true

func _on_cg_queue_finished() -> void:
	_release_cg_pause()

func _release_cg_pause() -> void:
	if not _paused_for_cg:
		return
	_paused_for_cg = false
	if is_instance_valid(_game) and not _pause_before_cg and not _game.tutorial_pause:
		_game.simulation_paused = false
	_pause_before_cg = false

func make_state() -> Dictionary:
	return {"version": 1, "played": played.duplicate(true)}

func is_state_valid(state: Variant) -> bool:
	if not state is Dictionary or state.get("version") != 1 or not state.get("played") is Dictionary:
		return false
	for id: Variant in state.played:
		if not id is String or not state.played[id] is bool or not state.played[id]:
			return false
	return true

func restore_state(state: Dictionary) -> void:
	if is_instance_valid(_window):
		_window.clear_queue()
	_release_cg_pause()
	played = state.played.duplicate(true) if is_state_valid(state) else {}
	# 读档刚加载过地图，同步 epoch 与位置，避免把「读档」当成一次新进入。
	if is_instance_valid(_game):
		_last_map_epoch = int(_game.map_epoch)
		_primed = false
		_inside.clear()

func clear_played() -> void:
	played.clear()

## 仅新游戏使用；普通重置航行不重播已看过的 CG。
func reset_for_new_game() -> void:
	played.clear()
	_primed = false
	_inside.clear()
	_last_map_epoch = -1
	if is_instance_valid(_window):
		_window.clear_queue()
	_release_cg_pause()
