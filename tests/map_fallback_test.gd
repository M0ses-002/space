extends SceneTree

const Loader = preload("res://scripts/map_loader.gd")
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _run() -> void:
	# 隔离环境下用户地图不应预先存在；若存在则删除以获得干净状态。
	if FileAccess.file_exists(Loader.MAP_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Loader.MAP_PATH))

	# 1. 允许回退且无用户地图 → 回退内置地图。
	var result: Dictionary = Loader.load_map(true)
	check(FileAccess.file_exists(Loader.BUILTIN_MAP_PATH), "内置地图文件存在")
	check(not result.map.is_empty() and not bool(result.error), "无用户地图时回退内置地图")
	var builtin_hash: String = result.map.hash

	# 1b. 不允许回退且无用户地图 → 返回空，使用场景默认内容。
	result = Loader.load_map(false)
	check(result.map.is_empty() and not bool(result.error), "禁用回退时保留场景默认内容")

	# 2. 用户地图存在但内容无效 → 标记错误，禁止存档写入。
	var file := FileAccess.open(Loader.MAP_PATH, FileAccess.WRITE)
	file.store_string("{invalid")
	file.close()
	result = Loader.load_map(true)
	check(result.map.is_empty() and bool(result.error), "用户地图无效时标记错误")

	# 3. 用户地图有效 → 优先使用用户地图而非内置地图。
	var data := {"version": 1, "ship": {"position": [1, 2], "velocity": [0, 0]}, "objects": [
		{"type": "planet", "id": "user_planet", "position": [5000, 6000], "fields": {"radius_m": 1234}},
	]}
	file = FileAccess.open(Loader.MAP_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()
	result = Loader.load_map(true)
	check(not result.map.is_empty() and not bool(result.error), "有效用户地图优先于内置地图")
	check(result.map.hash != builtin_hash, "用户地图指纹与内置地图不同")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(Loader.MAP_PATH))
	print("MAP_FALLBACK_TEST: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)
