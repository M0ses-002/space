extends Button

signal event_pressed(event_id: String)
var event_id: String = ""

func _ready() -> void:
	pressed.connect(_on_pressed)

func render(data: Dictionary, selected: bool) -> void:
	event_id = str(data.get("id", ""))
	text = str(data.get("title", "未命名事件"))
	tooltip_text = text
	set_pressed_no_signal(selected)

func _on_pressed() -> void:
	event_pressed.emit(event_id)
