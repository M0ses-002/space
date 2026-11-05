class_name QuestObjective
extends RefCounted
## 任务目标基类：一种达成条件写成一个脚本，由 QuestManager.TYPES 注册后按 quest.type 实例化。
## 新增类型 = 在 scripts/quest/objectives/ 加一个 extends QuestObjective 的脚本 + 在 QuestManager.TYPES 里注册一行。

## 原始任务配置，来自 planets/*.json 中 person.quests[] 的一项。
var quest: Dictionary = {}
## 需要达成的次数；连续型按「进入满足态」计数，事件型按事件次数计数。
var count := 1
## 绑定的主场景；只在 validate() 需要查地图对象时使用，判定本身只读 ctx。
var game: Node = null

## 由 QuestManager 在接取/读档时调用：复制配置并读取 count。
func setup(data: Dictionary, owner_game: Node = null) -> void:
	quest = data.duplicate(true)
	game = owner_game
	count = int(data.get("count", 1))

## 返回空串表示配置合法，否则返回中文错误说明；不修改任何游戏状态。
func validate() -> String:
	if count < 1:
		return "任务 count 必须是大于 0 的整数。"
	return ""

## 连续型目标由 QuestManager 每 0.25 秒轮询；事件型目标一般返回 false。
func is_satisfied(_ctx: Dictionary) -> bool:
	return false

## dock/talk 这类一次性事件返回 true；arrive_* 连续型返回 false。
func is_edge_triggered() -> bool:
	return false

## 事件型对话目标：该 id 的人物对话是否推进本目标。
## planet_id 是交谈发生地的行星 id：人物 id 允许在不同行星重名，配置了 target_planet_id 时按行星区分。
func matches_talk(_person_id: String, _planet_id: String = "") -> bool:
	return false

## 事件型船坞目标：本次安装的装备 id 是否推进本目标。
func matches_upgrade(_upgrade_id: String) -> bool:
	return false

## 事件型回收目标：本次回收的物资质量应推进多少进度（单位由目标自己定义，默认按 kg）。
## 返回 0 表示不推进；基类默认不响应任何回收事件。
func recycle_amount(_mass_kg: float) -> int:
	return 0

## 子类校验 JSON 数值时复用的类型检查，避免把字符串当作坐标。
func _number_ok(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))
