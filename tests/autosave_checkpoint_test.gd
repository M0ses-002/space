extends SceneTree
## 停泊/起航自动存档：城市停泊、行星停泊、起航各写一份存档；地图加载失败时拒绝写档。
## 自动存档写在帧末（call_deferred），因此每次动作后要等两帧再去读文件。

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
	# 本测试会真的写 user:// 存档，必须跑在隔离目录里，绝不允许碰玩家自己的存档。
	check(OS.get_user_data_dir().contains("space-autosave-test-regress"), "必须在隔离用户目录下运行：%s" % OS.get_user_data_dir())
	if failures > 0:
		quit(1)
		return
	_clear_saves()
	root.size = Vector2i(1200, 720)
	var game = load("res://scenes/game/star_map_demo.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	# save_checkpoint() 只对当前场景生效，测试里手动认领，避免误存别的场景。
	current_scene = game
	await process_frame
	await process_frame

	var saves := root.get_node("SaveManager")
	saves.enabled = true
	saves.game = game
	check(not saves.has_save(), "清空隔离目录后没有存档")

	var port = game.get_node("PortController")
	var ship = game.ship
	var city = game.get_node("World/FlatNuclearCity")

	# —— 城市停泊：写出的快照记录停靠中的船 ——
	game._select_target(ship)
	check(not port.active, "起手不在港口")
	ship.flight_position = city.get_dock_position() + Vector2(-1000.0, 0.0)
	ship.flight_velocity = Vector2.ZERO
	# 把 30 秒自动保存计时推到快到期，验证停泊存档会把它归零、不会紧跟着再写一次。
	saves.elapsed = 29.0
	game._dock_city(city)
	check(port.active and port.docked_ship == ship, "城市停泊打开港口")
	await process_frame
	await process_frame
	var data: Dictionary = saves._read_save(SAVE)
	check(not data.is_empty(), "城市停泊写出存档文件")
	check(str(data.get("docked", "")).ends_with(str(ship.name)), "存货快照记录停靠船：%s" % str(data.get("docked", "")))
	check(saves.elapsed < 5.0, "停泊存档重置 30 秒计时（29.0 → %.2f）" % saves.elapsed)

	# —— 起航：档案里的停靠记录被清空，船回到航行状态 ——
	port.view.depart_requested.emit()
	check(not port.active and not ship.voyage_finished, "起航关闭港口")
	await process_frame
	await process_frame
	data = saves._read_save(SAVE)
	check(not data.is_empty(), "起航写出存档文件")
	check(str(data.get("docked", "")).is_empty(), "起航快照不再记录停靠船")

	# —— 行星停泊：真实积分取得稳定轨道资格后确认到达，同样写盘 ——
	var planet = game.planets[0]
	var radius: float = planet.radius_m * 1.4
	ship.flight_position = planet.flight_position + Vector2(radius, 0.0)
	var pull: Vector2 = planet.acceleration_at(ship.flight_position)
	ship.flight_velocity = Vector2(0.0, -1.0) * sqrt(pull.length() * radius)
	game.simulation_paused = false
	var steps := 0
	while not (ship.stay_available and ship.orbit_stable_time >= 30.0) and steps < 4000:
		game.accumulator = 0.0
		game._physics_process(game.SIM_STEP / game.TIME_SCALE)
		steps += 1
	check(ship.stay_available and steps < 4000, "真实积分取得行星稳定轨道资格（%d 步）" % steps)
	game._confirm_arrival(planet)
	check(port.active and port.docked_ship == ship and ship.voyage_finished, "行星停泊打开港口")
	await process_frame
	await process_frame
	data = saves._read_save(SAVE)
	check(not data.is_empty() and str(data.get("docked", "")).ends_with(str(ship.name)), "行星停泊同样写出存档")

	# —— 地图加载失败时拒绝写档，原文件保持不变 ——
	var before := FileAccess.get_sha256(SAVE)
	game.map_load_error = true
	check(not saves.save_checkpoint(), "地图加载失败时拒绝写档")
	check(FileAccess.get_sha256(SAVE) == before, "拒写时原存档字节不变")
	game.map_load_error = false
	check(saves.save_checkpoint(), "地图恢复正常后可以写档")

	# —— 停靠状态可回读：新场景恢复后仍停在港口 ——
	var restored = load("res://scenes/game/star_map_demo.tscn").instantiate()
	restored.allow_builtin_map = false
	root.add_child(restored)
	restored.set_physics_process(false)
	await process_frame
	await process_frame
	var snapshot: Dictionary = saves._read_save(SAVE)
	check(saves.restore_snapshot(restored, snapshot), "停泊中写下的存档可以恢复")
	check(restored.get_node("PortController").active, "恢复后重新回到港口")
	restored.queue_free()
	await process_frame

	print("AUTOSAVE_CHECKPOINT_TEST: %s (%d checks, %d failures)" % ["PASS" if failures == 0 else "FAIL", checks, failures])
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
