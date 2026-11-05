class_name QuestInstallUpgrade
extends QuestObjective
## 事件型：在太空城船坞给任一飞船装上一件装备时 +1。
## target 缺省或留空表示任意装备；否则必须是 port_session.UPGRADES 的键
## （computer / fuel / shield / thruster / capture_net）。
## 安装动作无法从世界状态可靠观察——装好之后一直存在，也可能在接取前就已装好，
## 因此 is_satisfied() 恒为 false，只由 PortController 安装成功后调用 QuestManager.note_upgrade() 推入。

const Session = preload("res://scripts/ports/port_session.gd")

var target := ""

func setup(data: Dictionary, owner_game: Node = null) -> void:
	super.setup(data, owner_game)
	target = str(data.get("target", "")).strip_edges()

func validate() -> String:
	if not target.is_empty() and not Session.UPGRADES.has(target):
		return "install_upgrade 任务的 target 不是船坞里的装备 id：" + target
	return super.validate()

func is_edge_triggered() -> bool:
	return true

## 本次安装的装备是否推进本目标；空 target 表示装任意装备都算。
func matches_upgrade(upgrade_id: String) -> bool:
	return target.is_empty() or upgrade_id == target
