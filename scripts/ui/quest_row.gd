extends HBoxContainer
## 任务清单中的一行：标题 + 进度条 + 计数 + 完成标记；全部节点在编辑器场景里可见。
## 状态三态：active（进行中）/ awaiting_return（待复命）/ completed（已完成）。
@onready var title_label: Label = $Title
@onready var bar: ProgressBar = $Bar
@onready var count_label: Label = $Count
@onready var done_label: Label = $Done

const DONE_COLOR := Color(0.45, 0.95, 0.55, 1)
## 待复命用琥珀色：目标做完了但奖励还没到手，和真正的“完成”区分开。
const RETURN_COLOR := Color(0.98, 0.78, 0.36, 1)

## 用 QuestManager.state() 的快照渲染一行；字段缺失时按 0/1 显示。
func render(data: Dictionary) -> void:
	var required: int = maxi(1, int(data.get("required", 1)))
	var progress: int = clampi(int(data.get("progress", 0)), 0, required)
	var status := str(data.get("status", ""))
	var done: bool = status == "completed"
	var awaiting: bool = status == "awaiting_return"
	title_label.text = str(data.get("title", ""))
	# 交谈目标可能在别的行星上，标题里塞不下，写进提示框：玩家得知道该飞去哪儿找人。
	var title_tip := str(data.get("description", "")).strip_edges()
	var target_name := str(data.get("target_name", "")).strip_edges()
	if str(data.get("type", "")) == "talk_to_person" and not target_name.is_empty():
		var place := str(data.get("target_planet", "")).strip_edges()
		var target_tip := "目标人物：%s（%s）" % [target_name, place] if not place.is_empty() else "目标人物：%s" % target_name
		title_tip = target_tip if title_tip.is_empty() else "%s\n%s" % [title_tip, target_tip]
	title_label.tooltip_text = title_tip
	bar.max_value = required
	bar.value = progress
	bar.modulate = RETURN_COLOR if awaiting else Color.WHITE
	if awaiting:
		# 待复命时进度已满，数字没有信息量，直接写状态；委托人名字放提示里，别挤标题。
		var giver := str(data.get("person_name", "")).strip_edges()
		var tip := "目标已完成，回到委托人处交谈后结算奖励。"
		if not giver.is_empty():
			tip = "目标已完成，回到%s处交谈后结算奖励。" % giver
		count_label.text = "待复命"
		count_label.tooltip_text = tip
		done_label.tooltip_text = tip
	else:
		# 回收类任务的进度单位是 kg，不加单位会被误读成“件”。
		var unit := " kg" if str(data.get("type", "")) == "recycle_mass" else ""
		count_label.text = "%d/%d%s" % [progress, required, unit]
		count_label.tooltip_text = ""
		done_label.tooltip_text = ""
	done_label.visible = done or awaiting
	done_label.text = "回报" if awaiting else "✓"
	done_label.add_theme_color_override("font_color", RETURN_COLOR if awaiting else DONE_COLOR)
	count_label.modulate = RETURN_COLOR if awaiting else (DONE_COLOR if done else Color.WHITE)
