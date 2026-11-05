extends SceneTree

const Loader = preload("res://scripts/navigation/map_loader.gd")
## 磁盘级安全副本：即使测试进程被强杀，也能从这里手工恢复玩家地图。
const DISK_BACKUP := "user://space_map_v1.test_backup.json"
var failures := 0
## 用户地图原始字节：测试期间会被临时改写，结束时必须原样写回，绝不能删掉玩家地图。
var _user_map_backup := PackedByteArray()
var _had_user_map := false

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

## 读取用户地图原始字节，用于测试后无损还原；同时落一份磁盘副本兜底。
func _backup_user_map() -> void:
	_had_user_map = FileAccess.file_exists(Loader.MAP_PATH)
	if not _had_user_map:
		return
	var file := FileAccess.open(Loader.MAP_PATH, FileAccess.READ)
	if file == null:
		return
	_user_map_backup = file.get_buffer(file.get_length())
	file.close()
	var disk := FileAccess.open(DISK_BACKUP, FileAccess.WRITE)
	if disk != null:
		disk.store_buffer(_user_map_backup)
		disk.close()

## 还原用户地图：原来有就写回原字节，原来没有才删除。
func _restore_user_map() -> void:
	if _had_user_map:
		if _user_map_backup.is_empty() and FileAccess.file_exists(DISK_BACKUP):
			_user_map_backup = FileAccess.get_file_as_bytes(DISK_BACKUP)
		var file := FileAccess.open(Loader.MAP_PATH, FileAccess.WRITE)
		if file != null:
			file.store_buffer(_user_map_backup)
			file.close()
	elif FileAccess.file_exists(Loader.MAP_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Loader.MAP_PATH))
	if FileAccess.file_exists(DISK_BACKUP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DISK_BACKUP))

func _run() -> void:
	# 绝不删除玩家地图：先备份原始内容，测完原样写回。
	_backup_user_map()
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

	_restore_user_map()
	check(not _had_user_map or FileAccess.file_exists(Loader.MAP_PATH), "测试结束后用户地图必须还原")
	print("MAP_FALLBACK_TEST: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)
