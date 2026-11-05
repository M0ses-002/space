@tool
extends Node2D
## 每个实例独立保存航行状态，编辑器中可配置名称与初始条件。
## 飞船显示名称，用于舰队选择栏与 UI 标识。
@export var display_name := "运输船"
## 初始位置（模拟坐标，单位：米）。请勿通过拖动节点位置设置航迹起点。
@export var initial_position := Vector2(0, -62000)
## 初始速度矢量（单位：m/s），同时决定初始航向。
@export var initial_velocity := Vector2(655, 0)
## 飞船干质量（单位：kg），燃料不计入质量；沿用既有8000kg质量基准。
@export_range(0.001, 100000000.0, 1.0) var dry_mass := 8000.0:
	set(value):
		if not is_finite(value) or value <= 0.0:
			push_warning("干质量必须为有限正数，已恢复既有8000kg质量基准。")
			dry_mass = 8000.0
		else:
			dry_mass = value
## 燃料舱容量（单位：kg）；燃料不计入推进质量。
@export_range(0.0, 100000000.0, 1.0) var fuel_capacity := 6000.0
## 初始燃料量（单位：kg）。重置航行时恢复；城市和行星成功起航时补满有效容量。
@export var initial_fuel := 3200.0
## 稳定绕行判定允许的半径波动容差（相对初始半径的比例，0.25 即 ±25%）。
@export_range(0.01, 0.9, 0.01) var orbit_radius_tolerance := 0.25
## 稳定绕行判定允许的速度波动容差（相对初始速度的比例）。
@export_range(0.01, 0.9, 0.01) var orbit_speed_tolerance := 0.25
## 稳定绕行判定允许的其他行星引力扰动上限（相对主导行星引力的比例）。
@export_range(0.01, 0.9, 0.01) var orbit_perturbation_tolerance := 0.2
## 加速推进器加速度（不含重力，单位 m/s²）。
@export_range(0.01, 1000.0, 0.1) var max_acceleration := 10.0
## 减速推进器加速度（不含重力，单位 m/s²）。
@export_range(0.01, 1000.0, 0.1) var max_deceleration := 10.0
## 单位速度变化 Δv 耗油量，单位 kg/(m/s)。
@export_range(0.001, 100.0, 0.001) var propulsion_fuel_per_delta_v := 8000.0 / 3700.0
## 入轨选星搜索半径：从飞船到行星中心的距离上限，单位米。
@export var orbit_search_radius := 250000.0
## 入轨机动规划的时限，单位模拟秒；超过此时间无法完成速度修正则判失败。
@export var orbit_plan_horizon := 900.0
## 入轨捕获容差：完成机动后速度方向与圆轨道速度的允许偏差比例。
@export_range(0.005, 0.1, 0.005) var orbit_capture_tolerance := 0.04
## 手动方向推进加速度，单位 m/s²，不含重力。
@export_range(0.0, 1000.0, 0.1) var max_steering_acceleration := 10.0
## 捕捉网相对飞船的发射速度，单位 m/s；设 0 则网体随飞船速度原地铺开。网体自身的半径增长、质量、寿命见 capture_net.tscn。
@export_range(0.0, 100000.0, 1.0) var capture_net_launch_speed := 60.0
## 视角始终跟随：开启后相机不会被 WASD 平移解除跟随，也不自动切到星图拟合视角；
## 缩放、重置与切船都保持飞船在原屏幕锚点上。
@export var camera_always_follow := false
var current_voyage_distance_m := 0.0
var last_voyage_distance_m := 0.0
var completed_voyage_count := 0
var thrust_direction := Vector2.RIGHT
var thrust_lock_enabled := false
var thrust_lock_angle := 0.0
var thrust_throttle := 0.0
var navigation_target := Vector2.ZERO
var has_navigation_target := false
var navigation_planet: Node2D
var navigation_tracks_planet := false
var navigation_status := "拖动橙针设置推力方向，油门归零停止推进。"
var steering := false
var region_source: Node2D
var region_event := ""
var heading := Vector2.RIGHT
var manual_thrust := 0.0
var maneuver_commands: Array = []
var maneuver_index := 0
var maneuver_target: Node2D
var orbit_source: Node2D
var orbit_stable_time := 0.0
var orbit_world_state: Array = []
var orbit_verify_elapsed := 0.0
var orbit_angle := 0.0
var orbit_last_angle := 0.0
var orbit_start_radius := 0.0
var orbit_start_speed := 0.0
var orbit_direction := 0.0
var stay_available := false
var flight_position := Vector2.ZERO
var flight_velocity := Vector2.ZERO
var fuel := 0.0
var upgrade_slots: Array = ["", "", "", ""]
var shield_ready := false
# 自动模式与执行目标分离：开启后先待命，到达目标后仍保持待命。
var autopilot_enabled := false
var autopilot_active := false
var autopilot_target := Vector2.ZERO
var autopilot_max_speed := 500.0
var autopilot_phase := 0 # 0加速/修向 / 1巡航 / 2制动，仅供显示
var autopilot_acceleration := Vector2.ZERO

func get_fuel_capacity() -> float:
	return fuel_capacity * (EquipmentCatalog.number("fuel", "fuel_capacity_scale", 1.2) if upgrade_slots.has("fuel") else 1.0)

## 拆掉燃料仓后油箱变小：多出来的燃料直接排空，避免出现 fuel > capacity 的非法状态。
func clamp_fuel_to_capacity() -> void:
	fuel = clampf(fuel, 0.0, maxf(get_fuel_capacity(), 0.0))


## 已安装的捕捉网数量；捕捉网允许装在多个槽位。
func capture_net_count() -> int:
	var count := 0
	for id in upgrade_slots:
		if id == "capture_net":
			count += 1
	return count


## 是否装了机库：机库是解锁舰载机的前置组件，自身不占快捷栏按钮。
func has_hangar() -> bool:
	return upgrade_slots.has("hangar")


## 机库解锁的舰载机 id（按目录 drones 的书写顺序），每个占一格快捷栏按钮。
func drone_kinds() -> Array[String]:
	var kinds: Array[String] = []
	if not has_hangar():
		return kinds
	for kind: String in EquipmentCatalog.values("hangar").get("drones", {}):
		kinds.append(kind)
	return kinds


## 快捷栏绑定表：按槽位顺序列出占用按钮的装备 id，一个装备占用一格。
## 自动入轨固定占第 1 格，因此这里的下标 0 对应快捷栏第 2 格。
## 机库不直接占格，而是展开成它解锁的每种舰载机各一格。
func skill_loadout() -> Array[String]:
	var loadout: Array[String] = []
	for id in upgrade_slots:
		if id == "capture_net":
			loadout.append(id)
		elif id == "hangar":
			for kind in drone_kinds():
				loadout.append("drone_%s" % kind)
	return loadout
var crashed := false
# 航行结束后冻结本船，保留确认时轨道快照供再次起航。
var voyage_finished := false
var arrival_source: Node2D
var departed_city: Node2D
var departure_position := Vector2.ZERO
var departure_velocity := Vector2.ZERO

func get_total_mass() -> float:
	return dry_mass

func get_effective_acceleration() -> float:
	return max_acceleration + (EquipmentCatalog.number("thruster", "acceleration_bonus", 5.0) if upgrade_slots.has("thruster") else 0.0)

func get_effective_deceleration() -> float:
	return max_deceleration + (EquipmentCatalog.number("thruster", "deceleration_bonus", 5.0) if upgrade_slots.has("thruster") else 0.0)

func get_effective_steering_acceleration() -> float:
	return max_steering_acceleration + (EquipmentCatalog.number("thruster", "steering_bonus", 5.0) if upgrade_slots.has("thruster") else 0.0)

func get_effective_propulsion_fuel_per_delta_v() -> float:
	return propulsion_fuel_per_delta_v

## 油箱燃料可供推进的速度变化预算（m/s）；并非当前飞行速度。
func fuel_to_delta_v(fuel_kg: float) -> float:
	return maxf(fuel_kg, 0.0) / maxf(get_effective_propulsion_fuel_per_delta_v(), 0.000001)

func _ready() -> void:
	if not Engine.is_editor_hint():
		reset_flight()

func reset_flight() -> void:
	upgrade_slots = ["", "", "", ""]
	shield_ready = false
	current_voyage_distance_m = 0.0
	last_voyage_distance_m = 0.0
	completed_voyage_count = 0
	flight_position = initial_position
	flight_velocity = initial_velocity
	if not is_finite(fuel_capacity) or fuel_capacity < 0.0:
		push_warning("燃料舱容量必须为有限非负数，已按0kg处理。")
		fuel_capacity = 0.0
	if not is_finite(initial_fuel) or initial_fuel < 0.0:
		push_warning("初始燃料必须为有限非负数，本次重置按0kg处理。")
		fuel = 0.0
	else:
		fuel = minf(initial_fuel, fuel_capacity)
		if initial_fuel > fuel_capacity:
			push_warning("初始燃料超过油箱容量，本次重置已限制为%.1fkg；未增加燃料。" % fuel_capacity)
	crashed = false
	voyage_finished = false
	arrival_source = null
	departed_city = null
	departure_position = Vector2.ZERO
	departure_velocity = Vector2.ZERO
	heading = initial_velocity.normalized() if initial_velocity.length() > 0.01 else Vector2.RIGHT
	manual_thrust = 0.0
	steering = false
	thrust_direction = heading
	thrust_lock_enabled = false
	thrust_lock_angle = 0.0
	thrust_throttle = 0.0
	autopilot_enabled = false
	autopilot_active = false
	autopilot_acceleration = Vector2.ZERO
	autopilot_target = Vector2.ZERO
	autopilot_max_speed = 500.0
	autopilot_phase = 0
	has_navigation_target = false
	navigation_planet = null
	navigation_tracks_planet = false
	navigation_status = "拖动橙针设置推力方向，油门归零停止推进。"
	region_source = null
	region_event = ""
	maneuver_commands.clear()
	maneuver_index = 0
	maneuver_target = null
	reset_orbit()

func reset_orbit() -> void:
	orbit_source = null
	orbit_stable_time = 0.0
	orbit_world_state.clear()
	orbit_verify_elapsed = 0.0
	orbit_angle = 0.0
	orbit_last_angle = 0.0
	orbit_start_radius = 0.0
	orbit_start_speed = 0.0
	orbit_direction = 0.0
	stay_available = false

func track_orbit(source: Node2D, total_gravity: Vector2, step: float = 0.0) -> void:
	if voyage_finished or crashed or not is_instance_valid(source):
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
	if (total_gravity - own_gravity).length() / strength > orbit_perturbation_tolerance:
		reset_orbit()
		return
	var angle := offset.angle()
	var direction := signf(offset.cross(flight_velocity))
	if absf(offset.cross(flight_velocity)) <= radius * speed * 0.00001:
		reset_orbit()
		return
	if source != orbit_source:
		reset_orbit()
		orbit_source = source
		orbit_start_radius = radius
		orbit_start_speed = speed
		orbit_last_angle = angle
		orbit_direction = direction
		orbit_stable_time = maxf(step, 0.0)
		return
	if direction == 0.0 or direction != orbit_direction or absf(radius / orbit_start_radius - 1.0) > orbit_radius_tolerance:
		reset_orbit()
		return
	var increment := wrapf(angle - orbit_last_angle, -PI, PI)
	orbit_last_angle = angle
	if increment * orbit_direction < -0.00001:
		reset_orbit()
		return
	orbit_angle += absf(increment)
	orbit_stable_time += maxf(step, 0.0)
