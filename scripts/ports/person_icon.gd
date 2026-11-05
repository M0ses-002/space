extends Button
## 港口人物卡片：点击即开始对话。状态文字只表达“有委托/已选中”。

signal person_pressed(person_id: String)

const DEFAULT_PORTRAIT = preload("res://assets/ui/person_default.svg")
var person_id: String = ""
var _portrait_path: String = ""

func _ready() -> void:
	pressed.connect(_on_pressed)

func render(data: Dictionary, selected: bool) -> void:
	person_id = str(data.get("id", ""))
	%PersonName.text = str(data.get("name", ""))
	%PersonRole.text = str(data.get("role", ""))
	tooltip_text = "%s\n%s" % [str(data.get("name", "")), str(data.get("description", ""))]
	var quests: Array = data.get("quests", [])
	var has_quest := not quests.is_empty()
	%Status.modulate = Color("f1ca57") if selected else (Color("6bbf7b") if has_quest else Color("d7dee6"))
	%StatusText.text = "已选中" if selected else ("有委托" if has_quest else "可对话")
	var portrait_path := str(data.get("portrait", ""))
	if portrait_path != _portrait_path:
		_portrait_path = portrait_path
		%Portrait.texture = DEFAULT_PORTRAIT
		# 只允许项目内纹理，外部数据不能访问任意本机路径。
		if portrait_path.begins_with("res://") and ResourceLoader.exists(portrait_path):
			var portrait = load(portrait_path)
			if portrait is Texture2D:
				%Portrait.texture = portrait

func _on_pressed() -> void:
	person_pressed.emit(person_id)
