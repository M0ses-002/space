class_name QuestArrivePoint
extends QuestObjective
## 连续型：飞船进入以 position 为圆心、radius_m 为半径的圆内即满足。
## 坐标使用模拟世界米，与 game.ship_position 同一坐标系。

var position := Vector2.ZERO
var radius_m := 0.0

func setup(data: Dictionary, owner_game: Node = null) -> void:
	super.setup(data, owner_game)
	var point: Variant = data.get("position")
	if point is Array and point.size() == 2:
		position = Vector2(float(point[0]), float(point[1]))
	radius_m = float(data.get("radius_m", 0.0))

func validate() -> String:
	var point: Variant = quest.get("position")
	if not point is Array or point.size() != 2 or not _number_ok(point[0]) or not _number_ok(point[1]):
		return "arrive_point 任务需要 position 为 [x, y] 米制坐标。"
	if not _number_ok(quest.get("radius_m")) or float(quest.get("radius_m", 0.0)) <= 0.0:
		return "arrive_point 任务的 radius_m 必须为正数。"
	return super.validate()

func is_satisfied(ctx: Dictionary) -> bool:
	var point: Variant = ctx.get("ship_position")
	if not point is Vector2:
		return false
	return point.distance_to(position) <= radius_m
