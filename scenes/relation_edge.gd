extends Line2D

# 每条边均由独立模板实例化，线始终处于人物控件之后。
func render(start: Vector2, finish: Vector2, relation_type: String) -> void:
	points = PackedVector2Array([start, finish])
	default_color = Color("6a9fd3") if relation_type == "cooperation" else Color("d77d7d")
