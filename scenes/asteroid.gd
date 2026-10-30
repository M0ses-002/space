@tool
extends Node2D
## 小行星受行星引力，但自身不产生引力；质量不影响其引力加速度。
## 初始位置（模拟坐标，单位：米）。
@export var initial_position := Vector2(0, -80000)
## 初始速度（单位：m/s）。
@export var initial_velocity := Vector2(550, 0)
## 包围小行星的圆形半径（单位：米），同时决定视觉大小。
@export_range(0.01, 10000000.0, 0.1, "or_greater") var radius_m := 1000.0
## 小行星质量（单位：kg），供玩法使用，不影响其受引力加速度。
@export_range(0.01, 1000000000000000.0, 1.0, "or_greater") var mass_kg := 1000000.0
## 采集产物商品 ID，空值时根据外观使用灰岩、赤岩或冰岩矿物。
@export var mineral_id := ""
## 每单位矿物质量（kg）；同一商品 ID 在所有来源必须一致。
@export_range(0.001, 1000000.0, 0.001, "or_greater") var mineral_unit_mass := 1.0
## 外观预设索引：0 为灰岩，1 为赤岩，2 为冰岩。
@export_enum("灰岩:0", "赤岩:1", "冰岩:2") var style_index := 0:
	set(value):
		style_index = clampi(value, 0, 2)
		if is_inside_tree():
			_update_style()

var flight_position := Vector2.ZERO
var flight_velocity := Vector2.ZERO
var destroyed := false
var starting_mass_kg := 0.0
var starting_radius_m := 0.0

func _ready() -> void:
	_update_style()
	if not Engine.is_editor_hint():
		starting_mass_kg = mass_kg
		starting_radius_m = radius_m
		reset_motion()

func get_mineral_id() -> String:
	return mineral_id if not mineral_id.is_empty() else ["gray_ore", "red_ore", "ice_ore"][style_index]

func _update_style() -> void:
	for i in range($Visual.get_child_count()):
		$Visual.get_child(i).visible = i == style_index

func reset_motion() -> void:
	mass_kg = starting_mass_kg
	radius_m = starting_radius_m
	flight_position = initial_position
	flight_velocity = initial_velocity
	destroyed = false
	visible = true

func sync_view(map_mode: bool, pixels_per_meter: float) -> void:
	$Visual.visible = not map_mode and not destroyed
	$MapOutline.visible = map_mode and not destroyed
	scale = Vector2.ONE * maxf(radius_m, 0.0) * pixels_per_meter / 100.0
