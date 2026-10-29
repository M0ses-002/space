@tool
extends Node2D
## 太空垃圾只受行星引力，不产生引力。节点位置由主场景换算。
## 初始位置（模拟坐标，单位：米）。
@export var initial_position := Vector2(0, -70000)
## 初始速度（单位：m/s）。
@export var initial_velocity := Vector2(600, 0)
## 圆形碰撞区域半径（单位：米），同时决定视觉大小。
@export_range(0.01, 10000000.0, 0.1, "or_greater") var radius_m := 500.0

var flight_position := Vector2.ZERO
var flight_velocity := Vector2.ZERO
var destroyed := false

func _ready() -> void:
	if not Engine.is_editor_hint():
		reset_motion()

func reset_motion() -> void:
	flight_position = initial_position
	flight_velocity = initial_velocity
	destroyed = false
	visible = true

func sync_view(map_mode: bool, pixels_per_meter: float) -> void:
	$Visual.visible = not map_mode and not destroyed
	$MapArea.visible = map_mode and not destroyed
	scale = Vector2.ONE * maxf(radius_m, 0.0) * pixels_per_meter / 100.0

## 飞船撞上垃圾后的默认效果；可在派生场景中扩展。
func hit_ship(vessel: Node) -> void:
	vessel.crashed = true
	vessel.steering = false
	vessel.thrust_throttle = 0.0
	vessel.manual_thrust = 0.0
	vessel.navigation_status = "飞船撞击太空垃圾损毁，请重置航行。"
	vessel.hovering = false
	vessel.hover_source = null
	vessel.maneuver_commands.clear()
	vessel.maneuver_index = 0
	vessel.maneuver_target = null
	vessel.reset_orbit()
	vessel.flight_velocity = Vector2.ZERO
