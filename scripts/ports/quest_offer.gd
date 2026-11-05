extends Control
## 港口委托领取面板：全屏遮罩挡住港口点击，只由控制器驱动显示。

signal accept_pressed(person_id: String, quest: Dictionary)
signal decline_pressed()
## 右上角 ✕ 与 Esc 只关闭窗口，不代表放弃，委托之后仍可再领。
signal close_pressed()

var person_id: String = ""
var quest: Dictionary = {}

func _ready() -> void:
	%AcceptButton.pressed.connect(_on_accept_pressed)
	%DeclineButton.pressed.connect(func(): decline_pressed.emit())
	%CloseButton.pressed.connect(func(): close_pressed.emit())
	hide()

## 面板是模态的：打开时 Esc 只关面板，不触发暂停菜单。
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		accept_event()
		close_pressed.emit()

func open(owner_id: String, owner_name: String, data: Dictionary, status: Dictionary, quest_system_ready: bool) -> void:
	person_id = owner_id
	quest = data.duplicate(true)
	%Giver.text = owner_name
	%Title.text = str(quest.get("title", "人物委托"))
	%Description.text = str(quest.get("description", ""))
	%Reward.text = _reward_text(quest)
	%Target.text = _target_text(quest)
	show()
	var needs_return := bool(quest.get("requires_return", false))
	match str(status.get("status", "")):
		"active":
			set_notice("已接取 · 进度 %d/%d" % [int(status.get("progress", 0)), int(status.get("required", quest.get("count", 1)))], false)
		"awaiting_return":
			set_notice("目标已完成，回到委托人处复命后才会结算奖励。", false)
		"completed":
			set_notice("已复命 · 奖励已发放" if needs_return else "已完成", false)
		_:
			if quest_system_ready:
				set_notice("对话已结束，可以接取这份委托。" + ("完成目标后需回来复命。" if needs_return else ""), true)
			else:
				set_notice("任务系统未就绪，暂时无法接取。", false)

## 目标文案。交谈目标可能在别的行星上，直接把「找谁、去哪儿」写进面板，
## 省得玩家接完委托还得自己猜要不要再飞一趟。
func _target_text(data: Dictionary) -> String:
	var count := int(data.get("count", 1))
	if str(data.get("type", "")) == "talk_to_person":
		var target_name := str(data.get("target_name", "")).strip_edges()
		var target_planet := str(data.get("target_planet", "")).strip_edges()
		if not target_name.is_empty():
			var where := "（%s）" % target_planet if not target_planet.is_empty() else ""
			return "目标：与 %s%s 交谈 %d 次" % [target_name, where, count]
	return "目标 %d 次" % count

## 奖励文案：信用点 + （可选）任务解锁的装备名。
func _reward_text(quest: Dictionary) -> String:
	var text := "奖励 %d 信用点" % int(quest.get("reward_credits", 0))
	var unlock := str(quest.get("reward_unlock", "")).strip_edges()
	if not unlock.is_empty():
		text += " · 解锁「%s」" % EquipmentCatalog.display_name(unlock)
	return text

## allow_accept=false 时隐藏接受按钮，只保留状态文字（已接取/已完成/系统未就绪）。
func set_notice(text: String, allow_accept: bool) -> void:
	%Notice.text = text
	%Notice.visible = not text.is_empty()
	%AcceptButton.disabled = not allow_accept
	%AcceptButton.visible = allow_accept

func close() -> void:
	person_id = ""
	quest = {}
	hide()

func _on_accept_pressed() -> void:
	if person_id.is_empty() or quest.is_empty() or %AcceptButton.disabled:
		return
	accept_pressed.emit(person_id, quest.duplicate(true))
