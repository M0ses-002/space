class_name QuestRecycleMass
extends QuestObjective
## 事件型：累计回收指定质量的物资（kg）。
## 回收发生在捕捉网擦到碎片的那一刻——真正进网的质量（已乘 capture_efficiency）当场记账，
## 由 main._note_recovered() 调 QuestManager.note_recycle() 推入。网体之后飞去哪、是否撞行星都不再影响进度。
## 进度单位是 kg：required = target_mass_kg，progress 累加每次回收的质量。

## 需要累计回收的总质量（kg）。
var target_mass_kg := 1000.0

func setup(data: Dictionary, owner_game: Node = null) -> void:
	super.setup(data, owner_game)
	target_mass_kg = float(data.get("target_mass_kg", 1000.0))
	# 基类用 count 决定 required；这里把目标质量直接写进 count，
	# 于是进度条天然就是“已回收 kg / 目标 kg”。
	count = maxi(1, int(round(target_mass_kg)))

func validate() -> String:
	if not _number_ok(quest.get("target_mass_kg", 1000.0)):
		return "recycle_mass 任务的 target_mass_kg 必须是数值。"
	if target_mass_kg <= 0.0:
		return "recycle_mass 任务的 target_mass_kg 必须大于 0。"
	return super.validate()

func is_edge_triggered() -> bool:
	return true

## 回收多少 kg 就推进多少进度；不足 1 kg 的部分四舍五入，避免小网永远不计数。
func recycle_amount(mass_kg: float) -> int:
	return maxi(0, int(round(mass_kg)))
