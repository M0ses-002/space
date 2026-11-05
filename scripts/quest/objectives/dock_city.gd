class_name QuestDockCity
extends QuestObjective
## 事件型：任一飞船在太空城停泊（voyage_finished 且 arrival_source 属于 game.cities）时 +1。
## target 缺省或为空表示任意太空城；否则必须是该城市的地图对象 id（节点名 Map_<id>）。
## 停泊状态可从世界状态观察，所以仍由 QuestManager 的 0.25 秒轮询 + latch 计数：
## 停泊瞬间 +1，起航后才解锁，可累计到 count。

var target := ""

func setup(data: Dictionary, owner_game: Node = null) -> void:
	super.setup(data, owner_game)
	target = str(data.get("target", ""))

func validate() -> String:
	if not target.is_empty() and is_instance_valid(game) and _city_node({"cities": game.get("cities")}) == null:
		return "地图上找不到太空城：" + target
	return super.validate()

func is_edge_triggered() -> bool:
	return true

func is_satisfied(ctx: Dictionary) -> bool:
	var ships: Variant = ctx.get("ships")
	var cities: Variant = ctx.get("cities")
	if not ships is Array or not cities is Array:
		return false
	var wanted: Node2D = null
	if not target.is_empty():
		wanted = _city_node(ctx)
		if not is_instance_valid(wanted):
			return false
	for vessel in ships:
		if not is_instance_valid(vessel) or not vessel.get("voyage_finished"):
			continue
		var arrival: Variant = vessel.get("arrival_source")
		if not is_instance_valid(arrival) or not cities.has(arrival):
			continue
		if target.is_empty() or arrival == wanted:
			return true
	return false

func _city_node(ctx: Dictionary) -> Node2D:
	var cities: Variant = ctx.get("cities")
	if not cities is Array:
		return null
	for node in cities:
		if is_instance_valid(node) and node is Node2D and node.name == "Map_" + target:
			return node
	return null
