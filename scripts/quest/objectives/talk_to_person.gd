class_name QuestTalkToPerson
extends QuestObjective
## 事件型：与 target 人物对话一次计数一次。
## 对话无法从世界状态观察，因此 is_satisfied() 恒为 false，只由 QuestManager.note_talk() 推入。

var target := ""
## 目标人物所在的行星（JSON 里的 planet_id）。人物 id 允许跨行星重名，
## 配了这一项就只在对应行星上交谈才计数；缺省（旧数据）仍按 id 匹配。
var target_planet_id := ""

func setup(data: Dictionary, owner_game: Node = null) -> void:
	super.setup(data, owner_game)
	target = str(data.get("target", ""))
	target_planet_id = str(data.get("target_planet_id", "")).strip_edges()

func validate() -> String:
	if target.strip_edges().is_empty():
		return "talk_to_person 任务需要 target 人物 id。"
	return super.validate()

func is_edge_triggered() -> bool:
	return true

func matches_talk(person_id: String, planet_id: String = "") -> bool:
	if person_id != target:
		return false
	if target_planet_id.is_empty():
		return true
	# 交谈方没给出行星（老调用、单元测试）时退回 id 匹配，避免静默失效。
	return planet_id.is_empty() or planet_id == target_planet_id
