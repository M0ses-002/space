extends Node2D
## 每个实例独立保存航行状态，编辑器中可配置名称与初始条件。
## 飞船显示名称，用于舰队选择栏与 UI 标识。
@export var display_name := "运输船"
## 初始位置（模拟坐标，单位：米）。请勿通过拖动节点位置设置航迹起点。
@export var initial_position := Vector2(0, -62000)
## 初始速度矢量（单位：m/s），同时决定初始航向。
@export var initial_velocity := Vector2(655, 0)
## 初始燃料量（单位：kg）。重置航行时恢复为该值。
@export var initial_fuel := 3200.0
## 单个引力源产生的加速度低于此值时忽略该引力源，单位 m/s²。0 表示全部计入。
@export_range(0.0, 1000.0, 0.001, "or_greater") var gravity_threshold := 0.0
## 悬停耗油系数：每模拟秒耗油 = 合引力加速度 × 此系数；单位 kg/(m/s)。不含燃料质量。
@export var hover_fuel_per_delta_v := 8000.0 / 3700.0
## 稳定绕行判定允许的半径波动容差（相对初始半径的比例，0.25 即 ±25%）。
@export_range(0.01, 0.9, 0.01) var orbit_radius_tolerance := 0.25
## 稳定绕行判定允许的速度波动容差（相对初始速度的比例）。
@export_range(0.01, 0.9, 0.01) var orbit_speed_tolerance := 0.25
## 稳定绕行判定允许的其他行星引力扰动上限（相对主导行星引力的比例）。
@export_range(0.01, 0.9, 0.01) var orbit_perturbation_tolerance := 0.2
## 加速推进器的加速度（不含重力，单位 m/s²）。长按加速与入轨顺推均受此限制。
@export_range(0.01, 1000.0, 0.1) var max_acceleration := 10.0
## 减速推进器的加速度（不含重力，单位 m/s²）。长按减速与入轨逆推均受此限制。
@export_range(0.01, 1000.0, 0.1) var max_deceleration := 10.0
## 单位速度变化 Δv 的耗油量，单位 kg/(m/s)；推力耗油 = 实际 Δv × 此系数。
@export_range(0.001, 100.0, 0.001) var propulsion_fuel_per_delta_v := 8000.0 / 3700.0
## 入轨选星搜索半径：从飞船到行星中心的距离上限，单位米。
@export var orbit_search_radius := 250000.0
## 入轨机动规划的时限，单位模拟秒；超过此时间无法完成速度修正则判失败。
@export var orbit_plan_horizon := 900.0
## 入轨捕获容差：完成机动后速度方向与圆轨道速度的允许偏差比例。
@export_range(0.005, 0.1, 0.005) var orbit_capture_tolerance := 0.04
## 无速度或径向运动时解除悬停默认采用的绕行方向。
@export_enum("顺时针:1", "逆时针:-1") var default_orbit_direction: int = 1
var heading := Vector2.RIGHT
var manual_thrust := 0.0
var hover_source: Node2D
var hover_direction := 1.0
var maneuver_commands: Array = []
var maneuver_index := 0
var maneuver_target: Node2D
var hovering := false
var orbit_source: Node2D
var orbit_angle := 0.0
var orbit_last_angle := 0.0
var orbit_start_radius := 0.0
var orbit_start_speed := 0.0
var orbit_direction := 0.0
var stay_available := false
var flight_position := Vector2.ZERO
var flight_velocity := Vector2.ZERO
var fuel := 0.0
var crashed := false

func _ready() -> void:
	reset_flight()

func reset_flight() -> void:
	flight_position = initial_position
	flight_velocity = initial_velocity
	fuel = initial_fuel
	crashed = false
	hovering = false
	heading = initial_velocity.normalized() if initial_velocity.length() > 0.01 else Vector2.RIGHT
	manual_thrust = 0.0
	hover_source = null
	hover_direction = float(default_orbit_direction)
	maneuver_commands.clear()
	maneuver_index = 0
	maneuver_target = null
	reset_orbit()

func reset_orbit() -> void:
	orbit_source = null
	orbit_angle = 0.0
	orbit_last_angle = 0.0
	orbit_start_radius = 0.0
	orbit_start_speed = 0.0
	orbit_direction = 0.0
	stay_available = false

func track_orbit(source: Node2D, total_gravity: Vector2) -> void:
	if hovering or crashed or not is_instance_valid(source):
		reset_orbit()
		return
	var offset: Vector2 = flight_position - source.flight_position
	var radius := offset.length()
	var speed := flight_velocity.length()
	var own_gravity: Vector2 = source.acceleration_at(flight_position)
	var strength := own_gravity.length()
	if radius <= source.radius_m or strength <= 0.0 or speed < 0.01:
		reset_orbit()
		return
	var circular_speed := sqrt(strength * radius)
	# 首版稳定轨道为近圆轨道；排除高速掠过、径向坠落和强烈多体扰动。
	if absf(speed / circular_speed - 1.0) > orbit_speed_tolerance or absf(flight_velocity.dot(offset / radius)) / speed > orbit_radius_tolerance or (total_gravity - own_gravity).length() / strength > orbit_perturbation_tolerance:
		reset_orbit()
		return
	var angle := offset.angle()
	var direction := signf(offset.cross(flight_velocity))
	if source != orbit_source:
		reset_orbit()
		orbit_source = source
		orbit_start_radius = radius
		orbit_start_speed = speed
		orbit_last_angle = angle
		orbit_direction = direction
		return
	if direction != orbit_direction or absf(radius / orbit_start_radius - 1.0) > orbit_radius_tolerance or absf(speed / orbit_start_speed - 1.0) > orbit_speed_tolerance:
		reset_orbit()
		return
	var increment := wrapf(angle - orbit_last_angle, -PI, PI)
	orbit_last_angle = angle
	if increment * orbit_direction < -0.00001:
		reset_orbit()
		return
	orbit_angle += absf(increment)
	stay_available = orbit_angle >= TAU
