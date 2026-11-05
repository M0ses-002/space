extends SceneTree
## 回档到上次起航：起航记录完整快照；只有撞毁 / 燃油耗尽且未入轨才提供入口；
## 回档恢复的是整份状态（船况、信用点、装备解锁、任务进度），不只把船挪回去。

const SAVE := "user://space_save_v1.dat"
const BACKUP := "user://space_save_v1.bak"
const TEMP := "user://space_save_v1.tmp"

var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _clear_saves() -> void:
	for path in [SAVE, BACKUP, TEMP]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func _run() -> void:
	# 会真的写 user:// 存档，必须跑在隔离目录，绝不允许碰玩家自己的存档。
	check(OS.get_user_data_dir().contains("space-rollback-regress"), "必须在隔离用户目录下运行：%s" % OS.get_user_data_dir())
	if failures > 0:
		quit(1)
		return
	_clear_saves()
	root.size = Vector2i(1200, 720)
	var game = load("res://scenes/game/star_map_demo.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	current_scene = game
	await process_frame
	await process_frame

	var saves := root.get_node("SaveManager")
	saves.enabled = true
	saves.game = game
	saves.clear_departure()

	var port = game.get_node("PortController")
	var ship = game.ship
	var city = game.get_node("World/FlatNuclearCity")
	var rollback: Button = game.get_node("HUD/Root/FlightPanel/Margin/Content/RollbackButton")
	check(rollback != null, "飞行面板必须有回档按钮")

	# —— 1. 新局没有起航记录，正常航行也不显示回档 ——
	check(not saves.has_departure(), "新局没有起航记录")
	check(game._rollback_reason().is_empty(), "有燃料且未损毁时不提供回档")
	game._update_ui()
	check(not rollback.visible, "正常航行不显示回档按钮")

	# —— 2. 停泊后起航：抓下回档点 ——
	game._select_target(ship)
	ship.flight_position = city.get_dock_position() + Vector2(-1000.0, 0.0)
	ship.flight_velocity = Vector2.ZERO
	game._dock_city(city)
	check(port.active and port.docked_ship == ship, "城市停泊打开港口")
	port.view.depart_requested.emit()
	await process_frame
	await process_frame
	check(saves.has_departure(), "起航记录回档点")
	check(not port.active and not ship.voyage_finished, "起航离开港口并回到航行状态")

	var start_position: Vector2 = ship.flight_position
	var start_velocity: Vector2 = ship.flight_velocity
	var start_fuel: float = ship.fuel
	var start_credits: int = port.session.get_credits()
	check(start_fuel > 0.0, "起航补满燃料")

	# —— 3. 起航后挣到的进度必须随回档一起回退 ——
	port.session.set_credits(start_credits + 500)
	check(port.session.unlock_equipment("hangar"), "机库需要解锁且可以解锁")
	check(port.session.is_unlocked("hangar"), "起航后解锁了机库")
	ship.flight_position += Vector2(5000.0, 5000.0)
	ship.fuel = 12.0
	ship.crashed = true

	# —— 4. 撞毁：入口出现且可点 ——
	check(game._rollback_reason() == "飞船已损毁", "撞毁提供回档")
	game._update_ui()
	await process_frame
	check(rollback.visible and not rollback.disabled, "撞毁时回档按钮可见可用")
	check(Rect2(Vector2.ZERO, Vector2(1200, 720)).encloses(rollback.get_global_rect()), "回档按钮完整位于窗口内：%s" % str(rollback.get_global_rect()))
	check(game.selection_status.text.contains("回档"), "状态行提示可以回档")

	game._rollback_to_departure()
	game.set_physics_process(false)
	check(not ship.crashed, "回档清除损毁状态")
	check(ship.flight_position.is_equal_approx(start_position), "回档回到起航位置：%s" % str(ship.flight_position))
	check(ship.flight_velocity.is_equal_approx(start_velocity), "回档回到起航速度")
	check(is_equal_approx(ship.fuel, start_fuel), "回档回到起航燃料：%.1f" % ship.fuel)
	check(port.session.get_credits() == start_credits, "信用点回到起航时：%d" % port.session.get_credits())
	check(not port.session.is_unlocked("hangar"), "装备解锁回到起航时（未解锁机库）")
	check(game._rollback_reason().is_empty(), "回档后不再是卡死状态")
	game._update_ui()
	check(not rollback.visible, "脱困后隐藏回档按钮")

	# —— 5. 燃油耗尽：只有「还入不了轨」才算卡死 ——
	ship.fuel = 0.0
	ship.voyage_finished = false
	ship.orbit_source = null
	ship.stay_available = false
	check(game._rollback_reason() == "燃料耗尽且未入轨", "燃油耗尽且未入轨提供回档")
	ship.orbit_source = game.planets[0]
	ship.stay_available = true
	check(game._rollback_reason().is_empty(), "已在可确认的稳定轨道上不提供回档（还能进港补给）")
	ship.orbit_source = null
	ship.stay_available = false
	ship.fuel = 100.0
	check(game._rollback_reason().is_empty(), "还有燃料不提供回档")
	ship.fuel = 0.0
	ship.voyage_finished = true
	check(game._rollback_reason().is_empty(), "停泊中不提供回档")

	# —— 6. 没有起航记录时不改状态，只给提示 ——
	ship.voyage_finished = false
	ship.crashed = true
	saves.clear_departure()
	var before: Vector2 = ship.flight_position
	var before_credits: int = port.session.get_credits()
	game._update_ui()
	check(rollback.visible and rollback.disabled, "无回档点时按钮置灰")
	check(rollback.text.contains("无起航记录"), "无回档点按钮写明原因：%s" % rollback.text)
	game._rollback_to_departure()
	check(ship.crashed and ship.flight_position.is_equal_approx(before), "没有回档点时保持原状")
	check(port.session.get_credits() == before_credits, "没有回档点时不改信用点")
	check(game.flight_message.contains("还没有起航记录"), "提示没有起航记录：%s" % game.flight_message)

	# —— 7. 起航同帧换图（教程收尾）：回档点必须记录换图后的地图 ——
	# 起航会先注册一次 deferred 存档，教程「本课完成」也是 deferred 且换图排在存档之后；
	# 只等一次帧末会抓到旧地图 + 已结束教程的中间态，回档后玩家会卡在旧地图上。
	var switched = load("res://scenes/game/star_map_demo.tscn").instantiate()
	switched.allow_builtin_map = false
	root.add_child(switched)
	switched.set_physics_process(false)
	current_scene = switched
	await process_frame
	await process_frame
	check(switched.load_map_file("res://maps/plante_teach.json"), "教程地图一可加载")
	saves.game = switched
	saves.clear_departure()
	switched._stash_departure()
	check(switched.load_map_file("res://maps/city_teach.json"), "教程地图二可加载（模拟同帧换图）")
	for index in range(3):
		await process_frame
	check(saves.has_departure(), "换图后仍记录回档点")
	check(str(saves.departure_snapshot.get("map_hash", "")) == str(switched.map_hash), "回档点记录的是换图后的地图")
	check(int(saves.departure_snapshot.get("progression_state", {}).get("stage", -1)) == int(switched.get_node("ProgressionManager").stage), "回档点的教程阶段与地图同步")
	switched.queue_free()
	await process_frame

	if failures == 0:
		print("ROLLBACK_TEST: PASS (%d checks)" % checks)
	else:
		print("ROLLBACK_TEST: FAIL (%d/%d)" % [failures, checks])
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
