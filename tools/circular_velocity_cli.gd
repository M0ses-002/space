extends SceneTree
## Tk 地图工具通过临时地图调用本入口，直接复用游戏的 acceleration_at。
const Loader = preload("res://scripts/navigation/map_loader.gd")
const Advisor = preload("res://scripts/navigation/circular_velocity_advisor.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 4 or args[3] not in ["clockwise", "counterclockwise"]:
		_finish({"ok": false, "reason": "圆轨道建议参数无效。"})
		return
	var map := Loader.read_map(args[0])
	if map.is_empty():
		_finish({"ok": false, "reason": "地图未通过游戏加载器校验。"})
		return
	var point := Vector2.ZERO
	var found_target := false
	var source: Node = null
	var sources: Array = []
	for item in map.objects:
		if item.id == args[1] and item.type in ["asteroid", "debris"]:
			point = Vector2(item.position[0], item.position[1])
			found_target = true
		if item.type not in ["planet", "city"]:
			continue
		var node: Node2D = Loader.SCENES[item.type].instantiate()
		for key in item.get("fields", {}):
			var value: Variant = item.fields[key]
			if key in Loader.VECTORS:
				value = Vector2(value[0], value[1])
			node.set(key, value)
		node.flight_position = Vector2(item.position[0], item.position[1])
		sources.append(node)
		if item.id == args[2] and item.type == "planet":
			source = node
	var result := Advisor.suggest(source, point, args[3] == "clockwise", sources) if found_target else {"ok": false, "reason": "请选择小行星或太空垃圾。"}
	if result.get("ok", false):
		var velocity: Vector2 = result.velocity
		result.velocity = [velocity.x, velocity.y]
	for node in sources:
		node.free()
	_finish(result)

func _finish(result: Dictionary) -> void:
	print("CIRCULAR_VELOCITY_RESULT=" + JSON.stringify(result))
	quit(0 if result.get("ok", false) else 1)
