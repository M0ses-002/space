extends Node2D
## 固定引力源。编辑器节点位置由主场景换算为米；不计算行星间运动。
## 行星显示名称，用于 UI 与日志标识。
@export var display_name := "行星"
## 行星表面半径，单位：米。飞船接触此半径即判定碰撞。
@export_range(1.0, 10000000.0, 1.0) var radius_m := 50000.0
## 恒强引力层厚度（从表面向外），单位：米。此层内重力恒定，层外按平方反比衰减。
@export_range(0.0, 1000000.0, 1.0) var field_height_m := 3000.0
## 表面重力加速度，单位：m/s²（地球约 9.81）。恒强层内直接采用该值。
@export_range(0.0, 1000.0, 0.01) var surface_gravity := 9.81
## 最大引力半径（从行星中心计算，单位：米）。边界上仍有引力，超出即为零；所有飞船共用此范围。
## 默认 250 km。建议大于表面半径＋恒强层厚度；这是玩法硬边界，不是现实引力消失的距离。
@export_range(1.0, 1000000000.0, 1.0, "or_greater") var max_gravity_radius_m := 250000.0
## 本行星的事件、贸易与人物关系 JSON。复制行星时应配置独立文件；加载失败会显示错误而不是使用其他行星内容。
@export_file("*.json") var interaction_data_path := "res://data/planets/planet_a.json"
var flight_position := Vector2.ZERO

func contains_gravity_point(point: Vector2) -> bool:
	return point.distance_squared_to(flight_position) <= maxf(max_gravity_radius_m, 0.0) ** 2

func acceleration_at(point: Vector2) -> Vector2:
	var offset := flight_position - point
	var distance := offset.length()
	if distance < 0.001 or not contains_gravity_point(point):
		return Vector2.ZERO
	var field_top := radius_m + field_height_m
	var strength := surface_gravity
	if distance > field_top:
		strength *= (field_top / distance) * (field_top / distance)
	return offset / distance * strength

func update_boundary() -> void:
	var boundary_ratio := (radius_m + field_height_m) / maxf(radius_m, 1.0)
	$FieldBoundary.scale = Vector2.ONE * boundary_ratio
	# 仅标注恒强层顶，不代表大气；文字不随相机或行星缩放变小。
	var camera := get_viewport().get_camera_2d()
	var zoom_factor: float = camera.zoom.x if camera != null else 1.0
	var label_scale := 1.0 / maxf(absf(global_scale.x) * zoom_factor, 0.000001)
