extends Node2D
## 捕捉网：沿发射方向飞行的灰色圆网，半径按速率持续膨胀。
## 网面像橡皮擦一样擦除整团太空碎片的一块：擦头覆盖多大面积就最多擦掉多大比例的质量，
## 质量按 erase_follow_rate_per_s 指数逼近几何上限，累计到 capture_capacity_kg 后停止擦除。
## 物理位置、半径推进与擦除判定由主场景统一推进；本脚本只维护参数、外观缩放与记账。

## 发射瞬间的半径（单位：米）。
@export_range(0.01, 1000000.0, 1.0) var initial_radius_m := 80.0
## 半径增长速率（单位：米/模拟秒）。
@export_range(0.0, 1000000.0, 1.0) var growth_rate_m_per_s := 300.0
## 半径上限（单位：米）；达到后停止扩张。
@export_range(0.01, 10000000.0, 1.0) var max_radius_m := 6000.0
## 网体自身质量（单位：kg）；吸附碎片后累加，不影响飞船质量。
@export_range(0.0, 100000000.0, 1.0) var initial_mass_kg := 120.0
## 网体存活时长（单位：模拟秒）；0 表示永久存在，不自动回收。
@export_range(0.0, 3600.0, 0.1) var lifetime_s := 0.0
## 撞上行星时是否销毁；关闭后网体会穿过行星继续存在。
@export var destroy_on_planet_impact := true
## 橡皮擦跟随速率（1/模拟秒）：擦头覆盖一片后，质量以该速率指数逼近几何覆盖上限，0 表示瞬间擦掉。
@export_range(0.0, 10.0, 0.005) var erase_follow_rate_per_s := 0.06
## 捕获效率：擦掉的质量中真正进入网体的比例，1.0 表示擦掉多少就捕获多少。
@export_range(0.0, 1.0, 0.01) var capture_efficiency := 1.0
## 网体最大擦除质量（kg），达到后停止擦除；0 表示不设上限。
@export_range(0.0, 100000000.0, 1.0) var capture_capacity_kg := 2000.0

var mass_kg := 0.0
var absorbed_count := 0
var absorbed_mass_kg := 0.0
var radius_m := 0.0
var flight_position := Vector2.ZERO
var flight_velocity := Vector2.ZERO
var remaining_s := 0.0
var destroyed := false
var capped := false
var cap_notified := false
var full_notified := false
var launched_by: Node2D

func _ready() -> void:
	mass_kg = initial_mass_kg
	radius_m = initial_radius_m
	remaining_s = lifetime_s

## 从飞船位置沿方向发射：网体速度 = 飞船当前速度 + 方向 × 发射速度。
## config 来自 data/equipment.json 的 values，缺字段时保留场景/飞船上的默认值。
func launch(from: Node2D, direction: Vector2, config: Dictionary = {}) -> void:
	launched_by = from
	initial_radius_m = EquipmentCatalog.number_from(config, "initial_radius_m", initial_radius_m)
	growth_rate_m_per_s = EquipmentCatalog.number_from(config, "growth_rate_m_per_s", growth_rate_m_per_s)
	max_radius_m = EquipmentCatalog.number_from(config, "max_radius_m", max_radius_m)
	initial_mass_kg = EquipmentCatalog.number_from(config, "initial_mass_kg", initial_mass_kg)
	lifetime_s = EquipmentCatalog.number_from(config, "lifetime_s", lifetime_s)
	erase_follow_rate_per_s = EquipmentCatalog.number_from(config, "erase_follow_rate_per_s", erase_follow_rate_per_s)
	capture_efficiency = clampf(EquipmentCatalog.number_from(config, "capture_efficiency", capture_efficiency), 0.0, 1.0)
	capture_capacity_kg = EquipmentCatalog.number_from(config, "capture_capacity_kg", capture_capacity_kg)
	var launch_speed := EquipmentCatalog.number_from(config, "launch_speed", float(from.capture_net_launch_speed))
	flight_position = from.flight_position
	flight_velocity = from.flight_velocity
	if direction.length_squared() > 0.000001:
		flight_velocity += direction.normalized() * maxf(launch_speed, 0.0)
	mass_kg = initial_mass_kg
	radius_m = initial_radius_m
	remaining_s = lifetime_s
	absorbed_count = 0
	absorbed_mass_kg = 0.0
	destroyed = false
	capped = false
	cap_notified = false
	full_notified = false

## 推进一步：半径按速率扩张到上限后停止扩张（不销毁），寿命同步递减；寿命为 0 时永久存在。
func expand(step: float) -> void:
	if destroyed:
		return
	var safe_step := maxf(step, 0.0)
	var limit := maxf(max_radius_m, initial_radius_m)
	radius_m = minf(radius_m + maxf(growth_rate_m_per_s, 0.0) * safe_step, limit)
	capped = radius_m >= limit and growth_rate_m_per_s > 0.0
	if has_lifetime():
		remaining_s = maxf(remaining_s - safe_step, 0.0)

## 是否配置了有限寿命；0 表示永久存在。
func has_lifetime() -> bool:
	return lifetime_s > 0.0

## 碎片中心进入网面（含碎片自身半径）即判定被擦头覆盖。
func reaches(debris: Node) -> bool:
	return flight_position.distance_to(debris.flight_position) <= radius_m + maxf(float(debris.current_radius_m()), 0.0)

## 步进扫掠判定：用本步的位移线段替代单点，避免高速碎片穿过较小的网面。
func reaches_along(start: Vector2, debris: Node) -> bool:
	var closest := Geometry2D.get_closest_point_to_segment(debris.flight_position, start, flight_position)
	return closest.distance_to(debris.flight_position) <= radius_m + maxf(float(debris.current_radius_m()), 0.0)

## 残留捕获容量（kg）；未配置上限时返回 INF。
func remaining_capacity_kg() -> float:
	if capture_capacity_kg <= 0.0:
		return INF
	return maxf(capture_capacity_kg - absorbed_mass_kg, 0.0)

func is_full() -> bool:
	return remaining_capacity_kg() <= 0.0

## 擦除入账：被擦掉的质量按捕获效率折算进网体，fragments 为本次被擦空的碎片数。
func absorb_erased(erased_kg: float, fragments: int) -> void:
	var allowed := minf(maxf(erased_kg, 0.0) * clampf(capture_efficiency, 0.0, 1.0), remaining_capacity_kg())
	if allowed > 0.0:
		mass_kg += allowed
		absorbed_mass_kg += allowed
	absorbed_count += maxi(fragments, 0)

## 回收/销毁：不再参与显示与推进，由主场景移除节点。
func shutdown() -> void:
	destroyed = true
	$Disc.visible = false
	$Rim.visible = false

## 与太空垃圾一致的显示映射：世界坐标转画布坐标，半径按像素比例缩放。
func sync_view(map_mode: bool, pixels_per_meter: float) -> void:
	var shown := not map_mode and not destroyed
	$Disc.visible = shown
	$Rim.visible = shown
	scale = Vector2.ONE * maxf(radius_m, 0.0) * maxf(pixels_per_meter, 0.0)
	# 本地单位宽度会随缩放放大，这里换算成约 1.6 屏幕像素的细边。
	$Rim.width = clampf(1.6 / maxf(scale.x, 0.000001), 0.0015, 0.5)
