extends Button

signal person_pressed(person_id: String)

const DEFAULT_PORTRAIT = preload("res://scenes/person_default.svg")
var person_id: String = ""
var _portrait_path: String = ""

func _ready() -> void:
	pressed.connect(_on_pressed)

func render(data: Dictionary, selected: bool) -> void:
	person_id = str(data.get("id", ""))
	%PersonName.text = str(data.get("name", ""))
	%PersonRole.text = str(data.get("role", ""))
	tooltip_text = "%s\n%s" % [str(data.get("name", "")), str(data.get("description", ""))]
	var relation := str(data.get("relation", "neutral"))
	var tint := Color("d7dee6")
	if selected or relation == "selected":
		tint = Color("f1ca57")
	elif relation == "cooperation":
		tint = Color("5d9bd7")
	elif relation == "competition":
		tint = Color("dc7b7b")
	%Status.modulate = tint
	%Portrait.modulate = tint if relation != "neutral" else Color.WHITE
	%StatusText.text = "已选择" if selected or relation == "selected" else {"cooperation": "合作", "competition": "竞争"}.get(relation, "未关联")
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
