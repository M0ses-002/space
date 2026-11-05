extends VBoxContainer
## 船载装置快捷栏：3×2 共 6 格。第 1 格固定绑定自动入轨，其余按飞船槽位顺序绑定捕捉网；
## 未绑定的格子保持禁用，点击不会产生任何动作。

signal slot_pressed(index: int)

@onready var title: Label = $Title
@onready var grid: GridContainer = $Grid

var buttons: Array[Button] = []

func _ready() -> void:
	buttons.clear()
	for child in grid.get_children():
		if child is Button:
			var index := buttons.size()
			buttons.append(child)
			child.pressed.connect(slot_pressed.emit.bind(index))
	render({})

## 槽位总数（含自动入轨格）。
func slot_count() -> int:
	return buttons.size()

func get_slot_button(index: int) -> Button:
	return buttons[index] if index >= 0 and index < buttons.size() else null

## 按当前飞船状态刷新文案与可用性。
## state：orbit_enabled / orbit_text / slots（按槽位顺序的装备 id）/ net_count（旧接口回退）
##        / aiming_slot / status_text / status_tip
##        / slot_overrides（可选，index -> {text, enabled, tip}），给舰载机这类
##          可用性取决于世界状态的格子用；有 override 时优先于默认绑定规则。
func render(state: Dictionary) -> void:
	if buttons.is_empty():
		return
	var orbit_enabled := bool(state.get("orbit_enabled", false))
	var orbit_text := str(state.get("orbit_text", "自动入轨"))
	var net_count := maxi(int(state.get("net_count", 0)), 0)
	var aiming_slot := int(state.get("aiming_slot", -1))
	var status_text := str(state.get("status_text", ""))
	var slots: Array = state.get("slots", [])
	var overrides: Dictionary = state.get("slot_overrides", {})
	# 网体状态写在标题上，不额外占用快捷栏高度；标题控制得短，细节放提示框，避免溢出 320px 宽的面板。
	title.text = "船载装置" if status_text.is_empty() else "船载装置 · %s" % status_text
	title.tooltip_text = str(state.get("status_tip", ""))
	buttons[0].text = orbit_text
	buttons[0].disabled = not orbit_enabled
	var net_ordinal := 0
	for index in range(1, buttons.size()):
		var button := buttons[index]
		var override: Variant = overrides.get(index, null)
		if override is Dictionary and not (override as Dictionary).is_empty():
			var data: Dictionary = override
			button.text = str(data.get("text", "未绑定"))
			button.disabled = not bool(data.get("enabled", false))
			button.tooltip_text = str(data.get("tip", ""))
			continue
		var kind := ""
		if not slots.is_empty():
			# slots 的下标 0 对应快捷栏第 2 格。
			kind = str(slots[index - 1]) if index - 1 < slots.size() else ""
		elif index <= net_count:
			# 旧接口：只传 net_count 时按“前 N 格都是捕捉网”处理。
			kind = "capture_net"
		button.disabled = kind != "capture_net"
		button.tooltip_text = ""
		if kind != "capture_net":
			button.text = "未绑定"
		else:
			net_ordinal += 1
			button.text = ("发射网 %d" if aiming_slot == index else "捕捉网 %d") % net_ordinal
