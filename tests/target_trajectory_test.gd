extends SceneTree
## 航行电脑扩展：选中目标轨迹预测的专项回归。
## 覆盖：装备门禁、选中即预测、预测等于实飞、静止目标不画线、撞星终点标记、
## 取消选中清空、星图隐藏、销毁/重置清空、信息面板轨迹状态文案。
var failures := 0
var assertions := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		push_error(message)

func click(point: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = point
	press.pressed = true
	root.push_input(press, true)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = point
	release.pressed = false
	root.push_input(release, true)

func place_at_screen(game: Node2D, object: Node2D, point: Vector2) -> void:
	var canvas: Vector2 = game.get_node("World").to_local(game.get_canvas_transform().affine_inverse() * point)
	object.flight_position = (canvas - game._screen_center()) / game._view_scale()
	game._sync_visuals()

func _run() -> void:
	root.size = Vector2i(1200, 720)
	root.get_node("BackgroundMusic").stop_music()
	root.get_node("UIClickSound").stream = null
	var game = load("res://scenes/game/main.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	for i in range(3):
		await process_frame
	var vessel = game.ship
	var info = game.get_node("HUD/Root/SpaceObjectInfo")
	var map = game.get_node("StarMapView")
	var line = game.get_node("World/TargetPreview")

	# 造一个会动的小行星和一个静止的小行星。
	var moving = load("res://scenes/world/asteroid.tscn").instantiate()
	moving.mass_kg = 100.0
	moving.radius_m = 500.0
	moving.initial_position = Vector2(200000, 0)
	moving.initial_velocity = Vector2(0, 300.0)
	var still = load("res://scenes/world/asteroid.tscn").instantiate()
	still.mass_kg = 100.0
	still.radius_m = 500.0
	still.initial_position = Vector2(-200000, 0)
	still.initial_velocity = Vector2.ZERO
	game.get_node("World").add_child(moving)
	game.get_node("World").add_child(still)
	for i in range(5):
		await process_frame

	click(game.ship_buttons[vessel].get_global_rect().get_center())
	await process_frame

	# 1) 未装航行电脑：选中移动目标也不预测。
	place_at_screen(game, moving, Vector2(520, 210))
	click(Vector2(520, 210))
	await process_frame
	check(game.inspected_object == moving, "选中移动小行星")
	check(game.target_preview_job.is_empty() and game.target_preview_dense.is_empty(), "未装航行电脑不产生预测数据")
	check(not line.visible, "未装航行电脑不显示轨迹线")
	check(info.trajectory_status.text.is_empty(), "未装航行电脑无轨迹状态文案")

	# 2) 装上航行电脑：选中同一目标后产生预测。
	vessel.upgrade_slots[0] = "computer"
	game._clear_object_inspection()
	place_at_screen(game, moving, Vector2(520, 210))
	click(Vector2(520, 210))
	for i in range(10):
		await process_frame
	check(game.target_preview_job.is_empty(), "预测在预算内算完整条（job 已清空）")
	check(game.target_preview_dense.size() >= 2, "装航行电脑后产生轨迹顶点：%d" % game.target_preview_dense.size())
	check(line.visible, "装航行电脑后显示轨迹线")

	# 3) 预测必须等于实飞：首点与目标当前位置一致。
	var first_predicted: Vector2 = game.target_preview_dense[0]
	check(first_predicted.distance_to(moving.flight_position) < 1.0, "轨迹首点与目标当前位置一致")

	# 4) 静止目标不画线，只出提示。
	place_at_screen(game, still, Vector2(400, 210))
	click(Vector2(400, 210))
	await process_frame
	check(game.inspected_object == still, "选中静止小行星，实际=%s" % str(game.inspected_object))
	check(not line.visible, "静止目标不画轨迹线")
	check(info.trajectory_status.text == "静止目标，没有未来轨迹", "静止目标显示轨迹状态文案：%s" % info.trajectory_status.text)

	# 5) 取消选中清空轨迹。
	game._clear_object_inspection()
	await process_frame
	check(not line.visible, "取消选中清空轨迹线")

	# 6) 星图模式隐藏轨迹。
	place_at_screen(game, moving, Vector2(520, 210))
	click(Vector2(520, 210))
	for i in range(10):
		await process_frame
	check(line.visible, "近域显示轨迹线")
	map.set_map_mode(true)
	await process_frame
	check(not line.visible, "星图模式隐藏轨迹线")
	map.set_map_mode(false)

	# 7) 目标销毁后清空。
	game._clear_object_inspection()
	place_at_screen(game, moving, Vector2(520, 210))
	click(Vector2(520, 210))
	for i in range(10):
		await process_frame
	check(line.visible, "重新选中移动目标显示轨迹")
	moving.destroyed = true
	await process_frame
	check(game.inspected_object == null and not line.visible, "目标销毁后清除轨迹")

	# 8) 重置清空。
	moving.destroyed = false
	game._clear_object_inspection()
	place_at_screen(game, moving, Vector2(520, 210))
	click(Vector2(520, 210))
	for i in range(10):
		await process_frame
	check(line.visible, "再次选中移动目标显示轨迹")
	game._reset()
	await process_frame
	check(not line.visible and game.target_preview_job.is_empty(), "航行重置清空轨迹预测")

	# 9) 防回归：绕行目标需要跨多帧积分（steps > 每帧预算），轨迹首点必须始终
	# 等于选中时刻的目标位置，不能漂移到"积分推进后的位置"。
	# 曾有一个 bug：_advance_target_preview 每帧重建 dense，把上一帧推进后的
	# position 当成首点，导致整条轨迹整体前移、画在物体前方而非物体上。
	var orbiting = load("res://scenes/world/asteroid.tscn").instantiate()
	orbiting.mass_kg = 100.0
	orbiting.radius_m = 500.0
	# 远离内置行星（原点附近，引力半径约 250000），匀速直线且 horizon 内不撞星。
	orbiting.initial_position = Vector2(800000, 0)
	orbiting.initial_velocity = Vector2(0, 200.0)
	# _reset() 会清空升级槽，这里重新装上航行电脑，否则门禁直接拦截预测。
	vessel.upgrade_slots[0] = "computer"
	game.get_node("World").add_child(orbiting)
	for i in range(5):
		await process_frame
	place_at_screen(game, orbiting, Vector2(520, 210))
	click(Vector2(520, 210))
	for i in range(30):
		await process_frame
	check(game.target_preview_job.is_empty(), "绕行目标跨多帧积分算完整条")
	check(game.target_preview_dense.size() >= 2, "绕行目标产生轨迹顶点：%d" % game.target_preview_dense.size())
	var orbit_first: Vector2 = game.target_preview_dense[0]
	check(orbit_first.distance_to(orbiting.flight_position) < 1.0, "绕行目标轨迹首点始终等于选中时刻位置（delta=%.1f m）" % orbit_first.distance_to(orbiting.flight_position))

	root.remove_child(game)
	await process_frame
	print("TARGET_TRAJECTORY_TEST: %s (%d assertions, %d failures)" % ["PASS" if failures == 0 else "FAIL", assertions, failures])
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
