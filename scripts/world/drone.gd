extends Node2D
## 舰载机：由机库释放的作业单元。物理推进与碎片判定在 main 里统一做，
## 本脚本只保存作业参数、剩余寿命/容量与外观；数值全部来自 data/equipment.json。

## 机体颜色按机型区分：工程机青、近卫机橙。
const ENGINEER_COLOR := Color(0.45, 0.85, 0.85, 1.0)
const GUARD_COLOR := Color(0.98, 0.62, 0.32, 1.0)
const RING_SEGMENTS := 48

var kind := "engineer"
var definition: Dictionary = {}
var launched_by: Node2D

var flight_position := Vector2.ZERO
var flight_velocity := Vector2.ZERO
var remaining_s := 0.0
var capacity_left_kg := 0.0
var absorbed_mass_kg := 0.0
var recalled := false

var _ring_points := PackedVector2Array()
var _last_ring_radius := -1.0
var _last_ppm := -1.0

@onready var body: Polygon2D = $Body
@onready var ring: Line2D = $Ring
@onready var cone: Polygon2D = $Cone


func configure(new_kind: String, config: Dictionary, from: Node2D) -> void:
	kind = new_kind
	definition = config.duplicate(true)
	launched_by = from
	remaining_s = maxf(float(definition.get("lifetime_s", 0.0)), 0.0)
	capacity_left_kg = maxf(float(definition.get("recycle_capacity_kg", 0.0)), 0.0)
	absorbed_mass_kg = 0.0
	recalled = false
	var color := GUARD_COLOR if kind == "guard" else ENGINEER_COLOR
	body.color = color
	ring.default_color = Color(color.r, color.g, color.b, 0.45)
	cone.color = Color(color.r, color.g, color.b, 0.16)
	ring.visible = kind == "engineer"
	cone.visible = kind == "guard"
	_last_ring_radius = -1.0
	_last_ppm = -1.0


## 剩余寿命推进；返回 true 表示寿命已尽，应由主场景回收。
func tick_lifetime(step: float) -> bool:
	if remaining_s <= 0.0:
		return false
	remaining_s = maxf(remaining_s - maxf(step, 0.0), 0.0)
	return remaining_s <= 0.0


func is_exhausted() -> bool:
	return capacity_left_kg <= 0.0 and has_capacity_limit()


func has_capacity_limit() -> bool:
	return float(definition.get("recycle_capacity_kg", 0.0)) > 0.0


## 进机质量记账（工程机用）：返回真正装进机体的质量。
func absorb(mass_kg: float) -> float:
	var allowed := minf(maxf(mass_kg, 0.0), maxf(capacity_left_kg, 0.0))
	absorbed_mass_kg += allowed
	capacity_left_kg = maxf(capacity_left_kg - allowed, 0.0)
	return allowed


## 屏幕上的一步：位置、朝向、作业范围。半径按像素换算，避免节点缩放把线宽也拉粗。
func sync_view(map_mode: bool, pixels_per_meter: float, heading: Vector2) -> void:
	visible = not map_mode
	if map_mode:
		return
	rotation = heading.angle() if kind == "guard" and heading.length_squared() > 0.000001 else 0.0
	if kind == "engineer":
		var radius_px := maxf(float(definition.get("recycle_radius_m", 0.0)), 0.0) * pixels_per_meter
		if absf(radius_px - _last_ring_radius) > 0.5:
			_last_ring_radius = radius_px
			_rebuild_ring(radius_px)
	elif kind == "guard":
		var range_px := maxf(float(definition.get("range_m", 0.0)), 0.0) * pixels_per_meter
		if absf(pixels_per_meter - _last_ppm) > 0.000001:
			_last_ppm = pixels_per_meter
			_rebuild_cone(range_px, deg_to_rad(maxf(float(definition.get("cone_angle_deg", 0.0)), 0.0)))


func _rebuild_ring(radius_px: float) -> void:
	if radius_px <= 0.0:
		ring.visible = false
		return
	ring.visible = true
	if _ring_points.size() != RING_SEGMENTS:
		_ring_points.resize(RING_SEGMENTS)
	for index in RING_SEGMENTS:
		_ring_points[index] = Vector2.from_angle(TAU * float(index) / float(RING_SEGMENTS)) * radius_px
	ring.points = _ring_points


## 扇形朝本地 +X，节点旋转跟飞船航向一致。
func _rebuild_cone(range_px: float, half_angle: float) -> void:
	if range_px <= 0.0 or half_angle <= 0.0:
		cone.visible = false
		return
	cone.visible = true
	var points := PackedVector2Array()
	var segments := 18
	points.append(Vector2.ZERO)
	for index in segments + 1:
		var angle := -half_angle + 2.0 * half_angle * float(index) / float(segments)
		points.append(Vector2.from_angle(angle) * range_px)
	cone.polygon = points
