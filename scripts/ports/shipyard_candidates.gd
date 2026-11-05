extends Control
## 船坞配件候选：常态隐藏，点槽位后显示；方形按钮仅显示名字，悬停显示鼠标跟随浮层。

signal candidate_selected(id: String)

@export var columns := 4
@export var separation := 8
@export var button_size := Vector2(96, 96)

@onready var grid: GridContainer = $Scroll/Grid
@onready var detail: PanelContainer = $DetailLayer/Detail

var buttons := {}
var _upgrades: Dictionary = {}

func _ready() -> void:
	grid.columns = columns
	grid.add_theme_constant_override("h_separation", separation)
	grid.add_theme_constant_override("v_separation", separation)
	visible = false

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree() and detail != null:
		detail.hide_detail()

## 按 id 重建/复用候选按钮；id 与按钮实例一一对应，不重复连接。
func render(upgrades: Dictionary) -> void:
	if detail != null:
		detail.hide_detail()
	_upgrades = upgrades
	var present: Array[String] = []
	for id in upgrades:
		var data: Dictionary = upgrades[id]
		present.append(id)
		var button := _ensure_button(id)
		button.text = str(data.get("name", id))
	for id in buttons.keys():
		if not present.has(id):
			var button: Button = buttons[id]
			grid.remove_child(button)
			button.queue_free()
			buttons.erase(id)

func get_button(id: String) -> Button:
	return buttons.get(id)

func _ensure_button(id: String) -> Button:
	if buttons.has(id):
		return buttons[id]
	var button := Button.new()
	button.custom_minimum_size = button_size
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 14)
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	buttons[id] = button
	grid.add_child(button)
	button.pressed.connect(candidate_selected.emit.bind(id))
	button.mouse_entered.connect(_on_hover.bind(id))
	button.mouse_exited.connect(_on_unhover)
	return button

func _on_hover(id: String) -> void:
	if detail == null or not buttons.has(id):
		return
	var anchor: Vector2 = get_viewport().get_mouse_position()
	detail.show_detail(_upgrades.get(id, {}), anchor)

func _on_unhover() -> void:
	if detail != null:
		detail.hide_detail()
