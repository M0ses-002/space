extends RefCounted
class_name StoryConditions
## 声明式剧情条件求值：when 字典里每个键都要满足（AND），列表内元素也要全部满足。
## 故意只接受白名单键、不解析表达式字符串——编辑器能静态校验，读档也不会因为写法漂移改语义。
## when 为空字典或缺省表示「无条件成立」，用作台词表的兜底条目。

const KEYS: Array[String] = [
	"quests_done", "quests_active", "quests_awaiting", "quests_untouched",
	"flags", "stage_min", "planet_id", "visited",
	"has_equipment", "unlocked_equipment", "credits_min", "offerable_quest",
]

## 求值入口。ctx 是调用方一次性组装的扁平快照，求值器不碰节点树。
## ctx 键：quests（quest_id -> status）、flags、stage、planet_id、credits、
## equipment、unlocked、visited、offerable_quest。
static func evaluate(when: Variant, ctx: Dictionary) -> bool:
	if when == null:
		return true
	if not (when is Dictionary):
		return false
	var data: Dictionary = when
	if data.is_empty():
		return true
	for key: Variant in data.keys():
		if not _check(str(key), data[key], ctx):
			return false
	return true

static func _check(key: String, value: Variant, ctx: Dictionary) -> bool:
	match key:
		"quests_done":
			return _all_status(ctx, value, "completed")
		"quests_active":
			return _any_status(ctx, value, "active")
		"quests_awaiting":
			return _any_status(ctx, value, "awaiting_return")
		"quests_untouched":
			return _any_status(ctx, value, "")
		"flags":
			return _flags_match(value, ctx)
		"stage_min":
			return _number(ctx.get("stage", 0)) >= _number(value)
		"planet_id":
			return str(ctx.get("planet_id", "")) == str(value)
		"visited":
			return _subset(ctx.get("visited", []), value)
		"has_equipment":
			return _subset(ctx.get("equipment", []), value)
		"unlocked_equipment":
			return _subset(ctx.get("unlocked", []), value)
		"credits_min":
			return _number(ctx.get("credits", 0)) >= _number(value)
		"offerable_quest":
			return bool(ctx.get("offerable_quest", false)) == bool(value)
	push_warning("未知对话条件键：%s" % key)
	return false

static func _quest_table(ctx: Dictionary) -> Dictionary:
	var table: Variant = ctx.get("quests", {})
	return table if table is Dictionary else {}

static func _status_of(ctx: Dictionary, quest_id: String) -> String:
	return str(_quest_table(ctx).get(quest_id, ""))

static func _all_status(ctx: Dictionary, value: Variant, wanted: String) -> bool:
	var ids := _text_list(value)
	if ids.is_empty():
		return false
	for quest_id in ids:
		if _status_of(ctx, quest_id) != wanted:
			return false
	return true

static func _any_status(ctx: Dictionary, value: Variant, wanted: String) -> bool:
	var ids := _text_list(value)
	if ids.is_empty():
		return false
	for quest_id in ids:
		if _status_of(ctx, quest_id) == wanted:
			return true
	return false

static func _flags_match(value: Variant, ctx: Dictionary) -> bool:
	if not (value is Dictionary):
		return false
	var have: Variant = ctx.get("flags", {})
	if not (have is Dictionary):
		return false
	var wanted: Dictionary = value
	for name: Variant in wanted.keys():
		if bool((have as Dictionary).get(str(name), false)) != bool(wanted[name]):
			return false
	return true

static func _subset(have_value: Variant, want_value: Variant) -> bool:
	var wanted := _text_list(want_value)
	if wanted.is_empty():
		return false
	var have := _text_list(have_value)
	for item in wanted:
		if not have.has(item):
			return false
	return true

## 值写单个字符串时按一项处理，写数组时逐项；其它类型视为空，让非法规格直接不成立。
static func _text_list(value: Variant) -> Array[String]:
	var out: Array[String] = []
	if value is String:
		var single := str(value).strip_edges()
		if not single.is_empty():
			out.append(single)
		return out
	if value is Array:
		for item: Variant in value:
			if item is String and not str(item).strip_edges().is_empty():
				out.append(str(item).strip_edges())
	return out

static func _number(value: Variant) -> float:
	if value is int or value is float:
		return float(value)
	if value is String and str(value).is_valid_float():
		return float(value)
	return 0.0
