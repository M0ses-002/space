extends SceneTree

const Loader = preload("res://scripts/map_loader.gd")
const TEST_PATH := "user://map_loader_test_tmp.json"
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func write_test(text: String) -> void:
	var file := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	file.store_string(text)
	file.close()

func _run() -> void:
	if FileAccess.file_exists(TEST_PATH):
		push_error("测试临时文件已存在，拒绝覆盖")
		quit(1)
		return
	var data := {"version": 1, "ship": {"position": [123, 456], "velocity": [-7, 8]}, "objects": [
		{"type": "planet", "id": "earth", "position": [12345, -54321], "fields": {"radius_m": 1234}},
		{"type": "city", "id": "city1", "position": [90000, 20000], "fields": {"city_size_m": [5000, 1000]}},
		{"type": "asteroid", "id": "rock", "position": [45000, 30000], "fields": {"initial_velocity": [12, -3], "mass_kg": 100, "radius_m": 20}},
		{"type": "debris", "id": "junk", "position": [80000, 0], "fields": {"debris_count": 3, "radius_m": 100}},
	]}
	write_test(JSON.stringify(data))
	var map := Loader.read_map(TEST_PATH)
	check(not map.is_empty(), "不含旋转字段的旧地图读取")
	data.objects[1].fields.rotation_degrees_m = -90.0
	write_test(JSON.stringify(data))
	map = Loader.read_map(TEST_PATH)
	check(not map.is_empty(), "含负旋转角度的地图读取")
	data.objects[1].fields.rotation_degrees_m = 360001.0
	write_test(JSON.stringify(data))
	check(Loader.read_map(TEST_PATH).is_empty(), "超限旋转角度拒绝")
	data.objects[1].fields.rotation_degrees_m = true
	write_test(JSON.stringify(data))
	check(Loader.read_map(TEST_PATH).is_empty(), "布尔旋转角度拒绝")
	data.objects[1].fields.rotation_degrees_m = -90.0
	write_test(JSON.stringify(data, "  "))
	check(Loader.read_map(TEST_PATH).hash == map.hash, "格式变动不影响地图指纹")
	var game = load("res://main.tscn").instantiate()
	Loader.apply_map(game, map)
	game.map_hash = map.hash
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	check(game.planets.size() == 1 and game.cities.size() == 1 and game.obstacles.size() == 2, "地图对象注册")
	check(game.planets[0].flight_position.distance_to(Vector2(12345, -54321)) < 0.1, "行星使用米坐标")
	check(game.cities[0].flight_position.distance_to(Vector2(90000, 20000)) < 0.1, "城市使用米坐标")
	check(is_equal_approx(game.cities[0].rotation_degrees_m, -90.0), "城市旋转角度生效")
	check(game.get_node("World/Map_rock").flight_velocity == Vector2(12, -3), "障碍速度")
	check(game.get_node("World/Map_rock").mass_kg == 100, "小行星属性")
	check(game.ship.flight_position == Vector2(123, 456) and game.ship.flight_velocity == Vector2(-7, 8), "飞船初始状态")
	game.ship.reset_flight()
	check(game.ship.flight_position == Vector2(123, 456), "重置保留地图飞船初始位置")
	var manager = root.get_node("SaveManager")
	var snapshot: Dictionary = manager.make_snapshot(game)
	check(manager._compatible(game, snapshot), "同一地图存档兼容")
	game.map_hash = "changed"
	check(not manager._compatible(game, snapshot), "地图变化拒绝读取旧存档")
	data.objects.append(data.objects[0])
	write_test(JSON.stringify(data))
	check(Loader.read_map(TEST_PATH).is_empty(), "重复 ID 拒绝")
	write_test("{invalid")
	check(Loader.read_map(TEST_PATH).is_empty(), "损坏 JSON 拒绝")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	game.queue_free()
	await process_frame
	print("MAP_LOADER_TEST: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)
