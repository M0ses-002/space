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
var flight_position := Vector2.ZERO

func acceleration_at(point: Vector2) -> Vector2:
	var offset := flight_position - point
	var distance := offset.length()
	if distance < 0.001:
		return Vector2.ZERO
	var field_top := radius_m + field_height_m
	var strength := surface_gravity
	if distance > field_top:
		strength *= (field_top / distance) * (field_top / distance)
	return offset / distance * strength

func update_boundary() -> void:
	$AtmosphereBoundary.scale = Vector2.ONE * (radius_m + field_height_m) / radius_m
