@tool
extends Node2D
## 平面核城市：位置和几何均使用模拟世界米坐标，图形是可编辑场景节点。

## 城市显示名称。
@export var display_name := "平面核城市"
## 城市静态角度，单位：度；正值为顺时针。
@export var rotation_degrees_m := 0.0:
	set(value):
		rotation_degrees_m = value
		rotation_degrees = value
## 城市主体宽高，单位：米。
@export var city_size_m := Vector2(100000.0, 20000.0):
	set(value):
		city_size_m = value
		_sync_geometry()
## 主体上方重力区域高度，单位：米。
@export_range(1.0, 10000000.0, 1.0, "or_greater") var gravity_height_m := 30000.0:
	set(value):
		gravity_height_m = value
		_sync_geometry()
## 港口相对于城市中心的位置，单位：米。
@export var port_offset_m := Vector2(60000.0, 0.0):
	set(value):
		port_offset_m = value
		_sync_geometry()
## 泊船范围半径，以港口为圆心，单位：米。飞船在此范围内停住后可点击泊船按钮停泊。
@export_range(1.0, 10000000.0, 1.0, "or_greater") var docking_radius_m := 20000.0:
	set(value):
		docking_radius_m = value
		_sync_geometry()
## 停泊点相对港口的位置，单位：米。
@export var dock_offset_m := Vector2(0.0, -5000.0):
	set(value):
		dock_offset_m = value
		_sync_geometry()
## 场景视觉换算：每米多少场景单位，不影响模拟判断。
@export_range(0.000001, 10.0, 0.000001, "or_greater") var pixels_per_meter := 0.004:
	set(value):
		pixels_per_meter = value
		_sync_geometry()
## 港口事件、贸易与人物数据。
@export_file("*.json") var interaction_data_path := "res://data/planets/flat_nuclear_city.json"
## 城市中心模拟坐标，单位：米，由航行系统初始化。
var flight_position := Vector2.ZERO

func _ready() -> void:
	rotation_degrees = rotation_degrees_m
	_sync_geometry()

func _sync_geometry() -> void:
	if not is_inside_tree():
		return
	var size := city_size_m * pixels_per_meter
	$CityBody.scale = size
	$GravityArea.scale = Vector2(size.x, gravity_height_m * pixels_per_meter)
	$GravityArea.position = Vector2(0.0, -(size.y + gravity_height_m * pixels_per_meter) * 0.5)
	$Port.position = port_offset_m * pixels_per_meter
	$Port/DockingRange.scale = Vector2.ONE * (docking_radius_m * pixels_per_meter / 200.0)
	$Port/DockMarker.position = dock_offset_m * pixels_per_meter
	$DockButton.position = (port_offset_m + dock_offset_m) * pixels_per_meter

## 重力范围包含矩形边界。point 为模拟世界坐标，单位：米。
func contains_gravity_point(point: Vector2) -> bool:
	var local := (point - flight_position).rotated(-deg_to_rad(rotation_degrees_m))
	return absf(local.x) <= city_size_m.x * 0.5 and local.y >= -city_size_m.y * 0.5 - gravity_height_m and local.y <= -city_size_m.y * 0.5

## 矩形范围内重力沿城市局部正 Y 方向，区域外为零。
func acceleration_at(point: Vector2) -> Vector2:
	return Vector2(0.0, 9.81).rotated(deg_to_rad(rotation_degrees_m)) if contains_gravity_point(point) else Vector2.ZERO

func get_dock_position() -> Vector2:
	return flight_position + (port_offset_m + dock_offset_m).rotated(deg_to_rad(rotation_degrees_m))

func contains_docking_point(point: Vector2) -> bool:
	return point.distance_squared_to(flight_position + port_offset_m.rotated(deg_to_rad(rotation_degrees_m))) <= docking_radius_m * docking_radius_m
