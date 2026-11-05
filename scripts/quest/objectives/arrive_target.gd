class_name QuestArriveTarget
extends QuestObjective
## 连续型：飞船接近地图对象 target 到「对象自身半径 + radius_m」以内。
## 地图节点名规则是 "Map_" + id；城市自身半径取 docking_radius_m，行星取 radius_m。

var target := ""
var radius_m := 0.0

func setup(data: Dictionary, owner_game: Node = null) -> void:
	super.setup(data, owner_game)
	target = str(data.get("target", ""))
	radius_m = float(data.get("radius_m", 0.0))

func validate() -> String:
	if target.strip_edges().is_empty():
		return "arrive_target 任务需要 target 地图对象 id。"
	if not _number_ok(quest.get("radius_m", 0.0)) or radius_m < 0.0:
		return "arrive_target 任务的 radius_m 不能为负。"
	if is_instance_valid(game) and _target_node(_game_lists()) == null:
		return "地图上找不到目标对象：" + target
	return super.validate()

func is_satisfied(ctx: Dictionary) -> bool:
	var node := _target_node(ctx)
	if not is_instance_valid(node):
		return false
	var point: Variant = ctx.get("ship_position")
	if not point is Vector2:
		return false
	return point.distance_to(node.flight_position) <= _own_radius(node) + radius_m

## 未绑定场景时也能给出 cities/planets 列表，供 validate() 使用。
func _game_lists() -> Dictionary:
	if not is_instance_valid(game):
		return {}
	return {"cities": game.get("cities"), "planets": game.get("planets")}

func _target_node(ctx: Dictionary) -> Node2D:
	for key in ["cities", "planets"]:
		var list: Variant = ctx.get(key)
		if not list is Array:
			continue
		for node in list:
			if is_instance_valid(node) and node is Node2D and node.name == "Map_" + target:
				return node
	return null

## 对象自身半径：城市用泊船范围，行星用表面半径；缺失时按 0 处理。
func _own_radius(node: Node2D) -> float:
	var docking: Variant = node.get("docking_radius_m")
	if docking != null:
		return float(docking)
	var radius: Variant = node.get("radius_m")
	return float(radius) if radius != null else 0.0
