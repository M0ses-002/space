extends SceneTree

const MAP := "user://space_map_v1.json"
const SAVE := "user://space_save_v1.dat"
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func _run() -> void:
	var sandbox := OS.get_environment("SPACE_MAP_TEST_SANDBOX").replace("\\", "/").simplify_path()
	var user_dir := OS.get_user_data_dir().replace("\\", "/").simplify_path()
	if sandbox.is_empty() or not user_dir.begins_with(sandbox + "/") or FileAccess.file_exists(MAP) or FileAccess.file_exists(SAVE):
		push_error("测试用户目录未隔离或已存在文件，拒绝执行：" + user_dir)
		quit(1)
		return
	var manager = root.get_node("SaveManager")
	var data := {"version": 1, "ship": {"position": [100000, 70000], "velocity": [2, 3]}, "objects": [
		{"type": "planet", "id": "p", "position": [20000, -30000], "fields": {"radius_m": 1000}},
		{"type": "city", "id": "c", "position": [80000, 90000], "fields": {}},
		{"type": "asteroid", "id": "a", "position": [10000, 11000], "fields": {"initial_velocity": [0, 0], "radius_m": 50, "mass_kg": 100}},
	]}
	var file := FileAccess.open(MAP, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()
	manager.start_new_game()
	change_scene_to_file("res://star_map_demo.tscn")
	await process_frame
	await process_frame
	await process_frame
	var game = current_scene
	game.set_physics_process(false)
	check(not game.map_hash.is_empty() and not game.map_load_error, "实际场景加载地图")
	check(game.planets.size() == 1 and game.cities.size() == 1 and game.obstacles.size() == 1, "实际场景注册对象")
	check(game.planets[0].flight_position.distance_to(Vector2(20000, -30000)) < 0.1, "行星坐标")
	check(game.cities[0].flight_position.distance_to(Vector2(80000, 90000)) < 0.1, "城市坐标")
	check(game.ship.initial_position == Vector2(100000, 70000) and game.ship.initial_velocity == Vector2(2, 3), "飞船起点配置")
	game._reset()
	check(game.ship.flight_position == Vector2(100000, 70000) and game.ship.flight_velocity == Vector2(2, 3), "重置起点与速度")
	check(manager.enabled and FileAccess.file_exists(SAVE), "新游戏写入隔离存档")
	var before := FileAccess.get_sha256(SAVE)
	file = FileAccess.open(MAP, FileAccess.WRITE)
	file.store_string("{broken")
	file.close()
	manager.start_new_game()
	change_scene_to_file("res://star_map_demo.tscn")
	await process_frame
	await process_frame
	await process_frame
	game = current_scene
	check(game.map_load_error and not manager.enabled, "无效地图禁用保存")
	check(not manager.save_game() and FileAccess.get_sha256(SAVE) == before, "无效地图保留原存档")
	check(not manager.save_layer.get_node("SaveStatus").dialog_text.is_empty(), "错误提示可见")
	print("MAP_INTEGRATION_TEST: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)
