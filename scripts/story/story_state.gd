extends Node
## 剧情状态：条件系统的持久化部分。
## flags 是台词/剧情写入的命名标记，seen 记「某人的某条台词已经播过」（once 用），
## visited 记去过的行星（进港时写）。三者随存档保存，也随「回档到上次起航」回退。
##
## 只提供读写，不做条件判断——判断在 StoryConditions，谁需要谁组装 ctx。

const VERSION := 1

## String -> bool。只存 true 的标记也允许，读的时候缺省 false。
var flags: Dictionary = {}
## "person_id/speech_id" -> true
var seen: Dictionary = {}
## planet_id -> true
var visited: Dictionary = {}

func reset() -> void:
	flags.clear()
	seen.clear()
	visited.clear()

func set_flag(name: String, value: bool = true) -> void:
	if name.strip_edges().is_empty():
		return
	if value:
		flags[name] = true
	else:
		flags.erase(name)

func has_flag(name: String) -> bool:
	return bool(flags.get(name, false))

func get_flags() -> Dictionary:
	return flags.duplicate(true)

func mark_seen(key: String) -> void:
	if not key.strip_edges().is_empty():
		seen[key] = true

func is_seen(key: String) -> bool:
	return bool(seen.get(key, false))

func mark_visited(planet_id: String) -> void:
	if not planet_id.strip_edges().is_empty():
		visited[planet_id] = true

func has_visited(planet_id: String) -> bool:
	return bool(visited.get(planet_id, false))

func visited_list() -> Array[String]:
	var out: Array[String] = []
	for id in visited.keys():
		out.append(str(id))
	return out

func make_state() -> Dictionary:
	return {
		"version": VERSION,
		"flags": flags.duplicate(true),
		"seen": _keys_of(seen),
		"visited": _keys_of(visited),
	}

func is_state_valid(state: Variant) -> bool:
	if not (state is Dictionary):
		return false
	if int(state.get("version", 0)) != VERSION:
		return false
	if not (state.get("flags") is Dictionary):
		return false
	for key: Variant in (state.flags as Dictionary).keys():
		if not key is String:
			return false
	for field in ["seen", "visited"]:
		if not (state.get(field) is Array):
			return false
		for item: Variant in state[field]:
			if not item is String:
				return false
	return true

## 读档/回档用：先清空再灌入，非法状态保持空集而不是半套数据。
func restore_state(state: Variant) -> void:
	reset()
	if not is_state_valid(state):
		return
	var saved_flags: Dictionary = state.flags
	for key: Variant in saved_flags.keys():
		if bool(saved_flags[key]):
			flags[str(key)] = true
	for item: Variant in state.seen:
		seen[str(item)] = true
	for item: Variant in state.visited:
		visited[str(item)] = true

func _keys_of(table: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for key in table.keys():
		out.append(str(key))
	out.sort()
	return out
