@tool
extends Node2D
## 太空垃圾只受行星引力，不产生引力。节点位置由主场景换算。
## 初始位置（模拟坐标，单位：米）。
@export var initial_position := Vector2(0, -70000)
## 初始速度（单位：m/s）。
@export var initial_velocity := Vector2(600, 0)
## 圆形碰撞区域半径（单位：米），与红色区域半径一致。
@export_range(0.01, 10000000.0, 0.1, "or_greater") var radius_m := 500.0:
	set(value):
		radius_m = maxf(value, 0.01) if is_finite(value) else 0.01
		_update_debris()
## 显示的碎片数量，最多使用场景中预设的 32 个节点。
@export_range(0, 32, 1) var debris_count := 24:
	set(value):
		debris_count = clampi(value, 0, 32)
		_update_debris()
## 单个碎片的基准宽度（单位：米），不随危险区域半径改变；过大无法放入区域的碎片会隐藏。
@export_range(0.01, 1000000.0, 0.1, "or_greater") var debris_size_m := 40.0:
	set(value):
		debris_size_m = maxf(value, 0.01) if is_finite(value) else 0.01
		_update_debris()

## 普通视图碎片最长边的最小屏幕像素；受红圈大小限制，0 表示禁用。
@export_range(0.0, 100.0, 0.5, "or_greater") var minimum_fragment_pixels := 4.0:
	set(value):
		minimum_fragment_pixels = maxf(value, 0.0) if is_finite(value) else 0.0
		_update_debris()

var _screen_scale := 0.0
var flight_position := Vector2.ZERO
var flight_velocity := Vector2.ZERO
var destroyed := false

func _ready() -> void:
	_update_debris()
	if not Engine.is_editor_hint():
		reset_motion()

func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or not $Visual.visible:
		return
	var screen_transform := get_viewport().get_screen_transform() * get_global_transform_with_canvas()
	var screen_scale := minf(screen_transform.x.length(), screen_transform.y.length())
	if not is_equal_approx(screen_scale, _screen_scale):
		_screen_scale = screen_scale
		_update_debris()

func _update_debris() -> void:
	if not is_node_ready():
		return
	var fragments := $Visual.get_children()
	var count := mini(debris_count, fragments.size())
	for i in fragments.size():
		var fragment := fragments[i] as Sprite2D
		fragment.visible = i < count
		if i >= count:
			continue
		var angle := i * 2.399963229728653
		fragment.rotation = angle
		fragment.region_enabled = true
		match i % 3:
			0:
				fragment.region_rect = Rect2(12, 64, 47, 54)
			1:
				fragment.region_rect = Rect2(136, 82, 50, 52)
			_:
				fragment.region_rect = Rect2(54, 55, 91, 92)
		var texture_width := maxf(fragment.region_rect.size.x, fragment.region_rect.size.y)
		var size_variation := 0.8 + 0.1 * float(i % 4)
		var fragment_scale := debris_size_m * 100.0 * size_variation / (radius_m * texture_width)
		var half_diagonal := fragment.region_rect.size.length() * 0.5
		if half_diagonal * fragment_scale > 100.0:
			fragment.scale = Vector2.ONE * fragment_scale
			fragment.visible = false
			continue
		if not Engine.is_editor_hint() and _screen_scale > 0.0:
			fragment_scale = maxf(fragment_scale, minimum_fragment_pixels / (_screen_scale * texture_width))
			fragment_scale = minf(fragment_scale, 100.0 / half_diagonal)
		fragment.scale = Vector2.ONE * fragment_scale
		var available_radius := 100.0 - half_diagonal * fragment_scale
		var distance := available_radius * sqrt((float(i) + 0.5) / float(count))
		fragment.position = Vector2.from_angle(angle) * distance

func reset_motion() -> void:
	flight_position = initial_position
	flight_velocity = initial_velocity
	destroyed = false
	visible = true

func sync_view(map_mode: bool, pixels_per_meter: float) -> void:
	$Visual.visible = not map_mode and not destroyed
	$MapArea.visible = not destroyed
	scale = Vector2.ONE * maxf(radius_m, 0.0) * pixels_per_meter / 100.0
	if not map_mode and not Engine.is_editor_hint():
		var screen_transform := get_viewport().get_screen_transform() * get_global_transform_with_canvas()
		var screen_scale := minf(screen_transform.x.length(), screen_transform.y.length())
		if not is_equal_approx(screen_scale, _screen_scale):
			_screen_scale = screen_scale
			_update_debris()

## 飞船撞上垃圾后的默认效果；可在派生场景中扩展。
func hit_ship(vessel: Node) -> void:
	if vessel.shield_ready:
		vessel.shield_ready = false
		destroyed = true
		visible = false
		vessel.navigation_status = "霍普尔盾已拦截太空垃圾，防护已耗尽。"
		return
	vessel.crashed = true
	vessel.steering = false
	vessel.thrust_throttle = 0.0
	vessel.manual_thrust = 0.0
	vessel.navigation_status = "飞船撞击太空垃圾损毁，请重置航行。"
	vessel.maneuver_commands.clear()
	vessel.maneuver_index = 0
	vessel.maneuver_target = null
	vessel.reset_orbit()
	vessel.flight_velocity = Vector2.ZERO
