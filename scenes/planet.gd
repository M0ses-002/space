extends Node2D
## 固定引力源。编辑器节点位置由主场景换算为米；不计算行星间运动。
@export var display_name := "行星"
@export_range(1.0, 10000000.0, 1.0) var radius_m := 50000.0
@export_range(0.0, 1000000.0, 1.0) var field_height_m := 3000.0
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
