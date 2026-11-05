extends SceneTree
const Loader = preload("res://scripts/navigation/map_loader.gd")
var TEST_PATH := "user://debris_mass_test_%d_tmp.json" % OS.get_process_id()
var assertions := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	assertions += 1
	if not ok:
		failures += 1
		push_error(message)

func _run() -> void:
	if FileAccess.file_exists(TEST_PATH):
		push_error("测试临时文件已存在，拒绝覆盖")
		quit(1)
		return
	root.get_node("BackgroundMusic").stop_music()
	root.get_node("UIClickSound").stream = null
	var data := {"version": 1, "objects": [
		{"id": "legacy", "type": "debris", "position": [400000, 0], "fields": {}},
		{"id": "custom", "type": "debris", "position": [500000, 0], "fields": {"mass_kg": 2345.125, "radius_m": 20, "debris_count": 3, "debris_size_m": 2}}
	]}
	var file := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()
	var map := Loader.read_map(TEST_PATH)
	check(not map.is_empty(), "旧地图及自定义垃圾质量均通过真实加载器")
	var game = load("res://scenes/game/main.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	check(game.load_map_file(TEST_PATH), "通过真实运行时入口载入质量地图")
	await process_frame
	var legacy = game.get_node("World/Map_legacy")
	var custom = game.get_node("World/Map_custom")
	check(legacy.mass_kg == 1000.0 and custom.mass_kg == 2345.125, "旧地图默认1000kg，自定义值载入")
	for radius in [1.0, 1000.0, 1000000.0]:
		custom.radius_m = radius
		for count in [0, 1, 32]:
			custom.debris_count = count
			custom.debris_size_m = radius * 2
			custom.minimum_fragment_pixels = count
			custom.sync_view(false, 0.004)
			custom.sync_view(true, 0.004)
			check(custom.mass_kg == 2345.125, "改变危险半径/数量/尺寸/最小像素/视图不改变总质量")
	var info = game.get_node("HUD/Root/SpaceObjectInfo")
	info.refresh(custom, 0.004, 1.0)
	check(info.mass.text == "质量：2345.125 / 2345.125 kg", "信息面板显示剩余/总质量")
	var manager = root.get_node("SaveManager")
	var snapshot: Dictionary = manager.make_snapshot(game)
	check(not snapshot.obstacles["World/Map_custom"].has("mass_kg"), "静态质量不作为旧采集消耗写入快照")
	custom.mass_kg = 99.0
	check(manager.restore_snapshot(game, snapshot) and custom.mass_kg == 2345.125, "恢复快照回到地图固定质量")
	custom.mass_kg = 98.0
	custom.destroyed = true
	custom.reset_motion()
	check(custom.mass_kg == 2345.125 and not custom.destroyed, "重置恢复固定总质量")
	var gravity_before: Vector2 = game._gravity_at(custom.flight_position)
	custom.mass_kg = 1e12
	check(game._gravity_at(custom.flight_position) == gravity_before, "垃圾质量不产生引力")
	game.queue_free()
	await process_frame
	var rebuilt = load("res://scenes/game/main.tscn").instantiate()
	rebuilt.allow_builtin_map = false
	root.add_child(rebuilt)
	rebuilt.set_physics_process(false)
	check(rebuilt.load_map_file(TEST_PATH), "重建后载入同一质量地图")
	await process_frame
	check(manager.restore_snapshot(rebuilt, snapshot) and rebuilt.get_node("World/Map_custom").mass_kg == 2345.125, "场景销毁重建及存档恢复仍保留地图质量")
	for invalid in [-1, 0, true, "100", 1e16]:
		data.objects[1].fields.mass_kg = invalid
		file = FileAccess.open(TEST_PATH, FileAccess.WRITE)
		file.store_string(JSON.stringify(data))
		file.close()
		check(Loader.read_map(TEST_PATH).is_empty(), "拒绝非法垃圾质量")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	rebuilt.queue_free()
	await process_frame
	print("DEBRIS_MASS_TEST: %s (%d assertions, %d failures)" % ["PASS" if failures == 0 else "FAIL", assertions, failures])
	quit(0 if failures == 0 else 1)
