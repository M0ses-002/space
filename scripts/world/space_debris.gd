@tool
extends Node2D
## 太空垃圾只受行星引力，不产生引力。节点位置由主场景换算。
## 整团可被捕捉网像橡皮擦一样逐步擦除：质量按覆盖率单调递减，碎片逐个溶解消失。
## 初始位置（模拟坐标，单位：米）。
@export var initial_position := Vector2(0, -70000)
## 初始速度（单位：m/s）。
@export var initial_velocity := Vector2(600, 0)
## 整团太空垃圾的固定总质量（kg），独立于危险半径及碎片外观，不影响引力加速度。
@export_range(0.000001, 1000000000000000.0, 1.0, "or_greater") var mass_kg := 1000.0
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

## 纹理样式 ID：0 晶体、1 黑曜石，对应 TextureStyle 中注册的 36 帧序列图集。
@export_enum("晶体:0", "黑曜石:1") var texture_id := 0:
	set(value):
		texture_id = maxi(value, 0)
		_apply_texture_style()

## 剩余质量占比低于该值时整团溃散；0 表示必须擦到一点不剩才消失。
@export_range(0.0, 0.5, 0.001) var scatter_threshold_ratio := 0.06

const ERODE_SHADER := preload("res://shaders/debris_erode.gdshader")

var _screen_scale := 0.0
var _anim_elapsed := 0.0
var flight_position := Vector2.ZERO
var flight_velocity := Vector2.ZERO
var destroyed := false
var starting_mass_kg := 1000.0
## 剩余质量（kg），唯一随擦除变化的物理量；整团总质量始终是 mass_kg。
var remaining_mass_kg := 1000.0
## 本轮已被擦到完全消失的碎片数量，供捕捉网统计捕获片数。
var wiped_fragment_count := 0
# 每个碎片 0（完整）~1（完全擦除）；只由擦除事件增减，不参与全量重排。
var _erosion: Array[float] = []
# 已擦除比例的历史峰值：橡皮擦擦过一遍就留下痕迹，网体来回移动不会把质量"擦回来"。
var _erased_peak := 0.0
# 危险区绘制基准：原始稀疏多边形重采样后的密顶点圆，缺口才不会被画成折线三角。
var _rim_outline := PackedVector2Array()
# 擦头相对整团中心的方向（单位向量）：决定缺口朝哪一侧凹。默认朝左，读档后也能看出被擦过。
var _erase_direction := Vector2(-1.0, 0.0)
# 最近一次擦头圆心（世界米坐标），供碎片溶解按距离排序。
var _erase_point := Vector2.ZERO
var _has_erase_point := false
# 上次重排碎片时的剩余比例，用于在擦除过程中按需收缩布局。
var _layout_ratio := 1.0
# 上次重绘轮廓时的剩余比例，用于跳过没有变化的重复重绘。
var _drawn_ratio := -1.0

func _ready() -> void:
	_apply_texture_style()
	_prepare_erosion()
	_prepare_map_area()
	_update_debris()
	if not Engine.is_editor_hint():
		starting_mass_kg = mass_kg
		reset_motion()

func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or not $Visual.visible:
		return
	_advance_animation(_delta)
	# 暂停时主场景不再推 _sync_visuals，相机缩放只在这里才跟得上。
	_refresh_screen_scale()


## 相机或窗口比例变化时重算"每本地单位多少屏幕像素"，并让碎片尺寸跟上。
func _refresh_screen_scale() -> void:
	if Engine.is_editor_hint():
		return
	var view := get_viewport().get_screen_transform() * get_canvas_transform()
	var per_local := minf(view.x.length(), view.y.length()) * maxf(absf(scale.x), 0.000001)
	if not is_equal_approx(per_local, _screen_scale):
		_screen_scale = per_local
		_update_debris()


## 切换图集并让每个碎片从不同相位开始，避免整团同步动画。
func _apply_texture_style() -> void:
	if not is_node_ready() or not has_node("Visual"):
		return
	for i in $Visual.get_child_count():
		var fragment := $Visual.get_child(i) as Sprite2D
		if fragment == null:
			continue
		if not TextureStyle.apply_to(fragment, "debris", texture_id):
			continue
		fragment.frame = TextureStyle.frame_at("debris", texture_id, 0.0, i * 5)
	_anim_elapsed = 0.0
	_update_debris()


## 36 帧循环播放；只更新隐藏碎片以外的可见节点。
func _advance_animation(delta: float) -> void:
	if destroyed:
		return
	_anim_elapsed += delta
	for i in $Visual.get_child_count():
		var fragment := $Visual.get_child(i) as Sprite2D
		if fragment == null or not fragment.visible:
			continue
		var next_frame := TextureStyle.frame_at("debris", texture_id, _anim_elapsed, i * 5)
		if fragment.frame != next_frame:
			fragment.frame = next_frame


func _prepare_erosion() -> void:
	if not has_node("Visual"):
		return
	var total := $Visual.get_child_count()
	if _erosion.size() != total:
		_erosion.resize(total)
		_erosion.fill(0.0)


## 缓存危险区多边形的原始顶点，重采样成密顶点圆，并画出当前轮廓。
func _prepare_map_area() -> void:
	if not has_node("MapArea/Fill"):
		return
	var fill := $MapArea/Fill as Polygon2D
	if _rim_outline.is_empty() and fill.polygon.size() >= 3:
		_rim_outline = _resample_rim(fill.polygon, maxi(fill.polygon.size(), 64))
	_refresh_map_area_shape()


## 把稀疏多边形重采样成指定顶点数：按极坐标插值半径与角度，16 边形采样后仍是精确正圆
## （线性插值会让弦中点比顶点短 1.9%，初始轮廓就已经是个"小了一圈"的圆）。
func _resample_rim(source: PackedVector2Array, target_count: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var total := source.size()
	out.resize(target_count)
	for k in target_count:
		var t := float(k) * float(total) / float(target_count)
		var lower := int(floor(t)) % total
		var upper := (lower + 1) % total
		var weight: float = t - floor(t)
		var start_angle: float = source[lower].angle()
		var end_angle: float = source[upper].angle()
		var radius: float = lerpf(source[lower].length(), source[upper].length(), weight)
		var angle: float = start_angle + wrapf(end_angle - start_angle, -PI, PI) * weight
		out[k] = Vector2.from_angle(angle) * radius
	return out


## 重绘危险区：整体按 sqrt(剩余比例) 收缩，再朝擦头方向啃出一个有方向的缺口。
## 深度取"顶点方向与擦头方向的点积"，正对擦头的一侧凹得最深、背面几乎不动；
## 只按全局比例等比缩小的话，87.9% 只会变成一个略小的圆，肉眼完全看不出被擦过。
func _refresh_map_area_shape(force := false) -> void:
	if not has_node("MapArea/Fill") or _rim_outline.is_empty():
		return
	var ratio := remaining_ratio()
	# 重绘会触发 Polygon2D 重新三角化，20 倍速下每帧能跑 80 步，必须按变化量节流。
	if not force and absf(ratio - _drawn_ratio) < 0.002:
		return
	var shrink := clampf(sqrt(ratio), 0.0, 1.0)
	var erased := clampf(1.0 - ratio, 0.0, 1.0)
	var direction := _erase_direction
	if direction.length_squared() < 0.000001:
		direction = Vector2(-1.0, 0.0)
	direction = direction.normalized()
	var points := PackedVector2Array()
	points.resize(_rim_outline.size())
	for i in _rim_outline.size():
		var base := _rim_outline[i]
		var dir := base.normalized() if base.length_squared() > 0.000001 else Vector2.RIGHT
		var toward := clampf(dir.dot(direction), 0.0, 1.0)
		var bite := clampf(erased * 2.6 * pow(toward, 1.6), 0.0, 0.85)
		points[i] = base * shrink * (1.0 - bite)
	($MapArea/Fill as Polygon2D).polygon = points
	if has_node("MapArea/Outline"):
		($MapArea/Outline as Line2D).points = points
	_drawn_ratio = ratio


## 按当前擦除状态重排碎片；数量、半径、尺寸或视图比例变化时调用，擦除过程不调用。
func _update_debris() -> void:
	if not is_node_ready():
		return
	var fragments := $Visual.get_children()
	var count := mini(debris_count, fragments.size())
	var layout := maxi(count, 1)
	for i in fragments.size():
		var fragment := fragments[i] as Sprite2D
		var erased: bool = _erosion.size() == fragments.size() and _erosion[i] >= 1.0
		var alive: bool = i < count and not erased
		fragment.visible = alive
		if not alive:
			continue
		var angle := i * 2.399963229728653
		fragment.rotation = angle
		var texture_width := TextureStyle.frame_size(fragment)
		if texture_width <= 0.0:
			texture_width = 200.0
		var size_variation := 0.8 + 0.1 * float(i % 4)
		var fragment_scale := debris_size_m * 100.0 * size_variation / (radius_m * texture_width)
		var half_diagonal := texture_width * (sqrt(2.0) * 0.5)
		# 最小像素下限会放大碎片，放大后必须仍能互相散开；上限按可见数量算，
		# 否则大半径下这个下限会把所有碎片顶成一块、available_radius 归零。
		var spread_limit := 100.0 / (half_diagonal * (sqrt(float(layout)) + 0.2) * 1.5)
		if half_diagonal * fragment_scale > 100.0:
			fragment.scale = Vector2.ONE * fragment_scale
			fragment.visible = false
			continue
		if not Engine.is_editor_hint() and _screen_scale > 0.0:
			var minimum_scale := minimum_fragment_pixels / (_screen_scale * texture_width)
			fragment_scale = maxf(fragment_scale, minf(minimum_scale, spread_limit))
		fragment.scale = Vector2.ONE * fragment_scale
		# 位置按配置数量分摊而不是按当前可见数量，擦除时碎片原地溶解、不会整体收缩跳动；
		# 但整团半径要跟着剩余质量收缩，否则红圈缩小后碎片会露在外面。
		var shrink := clampf(sqrt(remaining_ratio()), 0.0, 1.0)
		var available_radius := maxf(100.0 - half_diagonal * fragment_scale, 0.0) * shrink
		var distance := available_radius * sqrt((float(i) + 0.5) / float(layout))
		fragment.position = Vector2.from_angle(angle) * distance
	_layout_ratio = remaining_ratio()
	_refresh_map_area_shape()


## 剩余质量占比（0~1）。
func remaining_ratio() -> float:
	if mass_kg <= 0.0:
		return 0.0 if destroyed else 1.0
	return clampf(remaining_mass_kg / mass_kg, 0.0, 1.0)


## 当前碰撞/显示半径：整团被擦掉一部分后按 sqrt(剩余比例) 收缩，radius_m 本身绝不改写。
func current_radius_m() -> float:
	if destroyed:
		return 0.0
	return radius_m * sqrt(remaining_ratio())


func is_fully_erased() -> bool:
	return destroyed


## 圆盘擦头与整团的几何覆盖率（0~1）：网体盖住多大一片，就最多能擦掉多大比例。
func coverage_of(world_point: Vector2, world_radius: float) -> float:
	var big := current_radius_m()
	var small := maxf(world_radius, 0.0)
	if big <= 0.0 or small <= 0.0:
		return 0.0
	var distance := flight_position.distance_to(world_point)
	if distance >= big + small:
		return 0.0
	if distance <= absf(big - small):
		return clampf(pow(minf(big, small) / big, 2.0), 0.0, 1.0)
	var cos_big := clampf((distance * distance + big * big - small * small) / (2.0 * distance * big), -1.0, 1.0)
	var cos_small := clampf((distance * distance + small * small - big * big) / (2.0 * distance * small), -1.0, 1.0)
	var height_sq := maxf((-distance + big + small) * (distance + big - small) * (distance - big + small) * (distance + big + small), 0.0)
	var area := big * big * acos(cos_big) + small * small * acos(cos_small) - 0.5 * sqrt(height_sq)
	return clampf(area / (PI * big * big), 0.0, 1.0)


## 按覆盖率擦除一块：质量指数逼近几何上限，同时让落进擦头范围的碎片溶解。
## 返回本次被擦除（从整团剥离）的质量，单位 kg；已被擦空的质量不计入。
func erase_towards(target_ratio: float, step: float, rate_per_s: float, world_point: Vector2, world_radius: float) -> float:
	if Engine.is_editor_hint() or destroyed or mass_kg <= 0.0:
		return 0.0
	_erased_peak = maxf(_erased_peak, clampf(target_ratio, 0.0, 1.0))
	var remaining := remaining_ratio()
	var floor_ratio := clampf(1.0 - _erased_peak, 0.0, 1.0)
	var lost := 0.0
	if remaining > floor_ratio + 0.000001:
		var gain := 1.0 - exp(-maxf(rate_per_s, 0.0) * maxf(step, 0.0))
		lost = mass_kg * (remaining - floor_ratio) * gain
		remaining_mass_kg = maxf(remaining_mass_kg - lost, mass_kg * floor_ratio)
	erode_at(world_point, world_radius, step, rate_per_s)
	if remaining_ratio() <= scatter_threshold_ratio and not destroyed:
		_collapse()
	elif absf(remaining_ratio() - _layout_ratio) > 0.01:
		# 质量掉了 1% 以上才重排一次：先按擦头远近吃掉碎片，再收缩布局。
		_sync_fragment_erasure()
		_update_debris()
	return lost


## 让可见碎片数量跟剩余质量对齐：按离擦头远近排序，最近的一批直接消失。
## 只靠 erode_at 的渐变量在网半径远大于整团时永远到不了 1，碎片会一块都不掉。
func _sync_fragment_erasure() -> void:
	if _erosion.is_empty() or not _has_erase_point or not has_node("Visual"):
		return
	var total := mini(debris_count, $Visual.get_child_count())
	if total <= 0:
		return
	var alive_target := clampi(int(round(float(total) * remaining_ratio())), 0, total)
	var to_erase := total - alive_target
	if to_erase <= 0:
		return
	var order: Array[int] = []
	for i in total:
		order.append(i)
	var point := _erase_point
	order.sort_custom(func(a: int, b: int) -> bool:
		return _fragment_world_position(a).distance_to(point) < _fragment_world_position(b).distance_to(point)
	)
	for rank in to_erase:
		var index: int = order[rank]
		if _erosion[index] >= 1.0:
			continue
		_erosion[index] = 1.0
		_apply_erosion(index)
		var fragment := $Visual.get_child(index) as Sprite2D
		if fragment != null and fragment.visible:
			fragment.visible = false
			wiped_fragment_count += 1


## 橡皮擦式溶解：擦头圆内的碎片按深入程度加速溶解，边缘缓入避免整块齐刷刷消失。
func erode_at(world_point: Vector2, world_radius: float, step: float, rate_per_s: float) -> void:
	if Engine.is_editor_hint() or destroyed:
		return
	var gain := 1.0 - exp(-maxf(rate_per_s, 0.0) * maxf(step, 0.0))
	if gain <= 0.0:
		return
	var reach := maxf(world_radius, 0.0)
	# 溶解权重按"离网中心多远"算，而不是"是否落在网内"：网半径通常远大于整团
	# （6000m 网 vs 3500m 团），用网半径做分母会让所有碎片同时溶解，
	# 看起来像整团变淡，完全看不出是从哪一侧被擦掉的。
	var span := maxf(maxf(current_radius_m(), reach) * 1.1, 1.0)
	for i in _erosion.size():
		if _erosion[i] >= 1.0:
			continue
		var distance := (_fragment_world_position(i) - world_point).length() - _fragment_radius_m(i) * 0.6
		if distance > reach:
			continue
		var inside := clampf(1.0 - maxf(distance, 0.0) / span, 0.0, 1.0)
		var previous := _erosion[i]
		_erosion[i] = minf(1.0, previous + gain * maxf(inside, 0.12))
		_apply_erosion(i)
		if _erosion[i] >= 1.0:
			var fragment := $Visual.get_child(i) as Sprite2D
			if fragment != null:
				fragment.visible = false
			wiped_fragment_count += 1
	# 记录擦头方向：危险区轮廓朝这一侧啃出缺口，看起来才是"从这边被擦掉的"。
	var to_point := world_point - flight_position
	if to_point.length() > 0.001:
		_erase_direction = to_point.normalized()
	_erase_point = world_point
	_has_erase_point = true
	_refresh_map_area_shape()


## 碎片中心的世界米坐标；碎片位置是节点本地单位，1 单位 = radius_m / 100 米。
func _fragment_world_position(index: int) -> Vector2:
	var fragment := $Visual.get_child(index) as Node2D
	if fragment == null:
		return flight_position
	return flight_position + fragment.position * (maxf(radius_m, 0.0) / 100.0)


func _fragment_radius_m(index: int) -> float:
	var fragment := $Visual.get_child(index) as Sprite2D
	if fragment == null:
		return 0.0
	var texture_width := TextureStyle.frame_size(fragment)
	if texture_width <= 0.0:
		texture_width = 200.0
	return texture_width * 0.70710678 * absf(fragment.scale.x) * maxf(radius_m, 0.0) / 100.0


func _apply_erosion(index: int) -> void:
	if Engine.is_editor_hint() or index < 0 or index >= _erosion.size():
		return
	var fragment := $Visual.get_child(index) as Sprite2D
	if fragment == null:
		return
	var material := fragment.material as ShaderMaterial
	if material == null or material.shader != ERODE_SHADER:
		material = ShaderMaterial.new()
		material.shader = ERODE_SHADER
		fragment.material = material
	material.set_shader_parameter("erosion", clampf(_erosion[index], 0.0, 1.0))


func _collapse() -> void:
	destroyed = true
	remaining_mass_kg = 0.0
	visible = false
	_has_erase_point = false
	if has_node("Visual"):
		for i in $Visual.get_child_count():
			var fragment := $Visual.get_child(i) as Sprite2D
			if fragment == null:
				continue
			if i < _erosion.size():
				_erosion[i] = 1.0
			if fragment.visible:
				fragment.visible = false
				wiped_fragment_count += 1
		$Visual.visible = false
	if has_node("MapArea"):
		$MapArea.visible = false


## 定向质量削减：供近卫机这类"持续输出"的装置使用，按 kg 直接扣质量。
## 与 erase_towards 共用同一套溶解/坍缩状态，避免两套账本互相覆盖。
func melt_mass(lost_kg: float, world_point: Vector2, world_radius: float) -> float:
	if Engine.is_editor_hint() or destroyed or mass_kg <= 0.0:
		return 0.0
	var lost := clampf(lost_kg, 0.0, remaining_mass_kg)
	if lost <= 0.0:
		return 0.0
	remaining_mass_kg = maxf(remaining_mass_kg - lost, 0.0)
	# 把已削掉的比例记成"擦过的峰值"，之后橡皮擦不会把它当成还能恢复的部分。
	_erased_peak = maxf(_erased_peak, clampf(1.0 - remaining_ratio(), 0.0, 1.0))
	erode_at(world_point, world_radius, 0.25, 4.0)
	if remaining_ratio() <= scatter_threshold_ratio and not destroyed:
		_collapse()
	elif absf(remaining_ratio() - _layout_ratio) > 0.01:
		_sync_fragment_erasure()
		_update_debris()
	return lost


## 读档：按剩余比例把外侧碎片判为已擦除，恢复"这团已经被擦掉一部分"的外观。
func restore_erasure(remaining: float) -> void:
	remaining_mass_kg = clampf(remaining, 0.0, mass_kg)
	_erased_peak = 1.0 - remaining_ratio()
	_prepare_erosion()
	# 读档时没有真实擦头位置，但必须保留缺口：否则只剩 sqrt(比例) 的整体收缩，
	# 87.9% 只是一个小了一圈的圆，玩家根本看不出这团被擦过。
	_erase_direction = Vector2(-1.0, 0.0)
	_has_erase_point = false
	var layout := maxi(debris_count, 1)
	if has_node("Visual"):
		layout = maxi(mini(debris_count, $Visual.get_child_count()), 1)
	var keep := int(round(float(layout) * remaining_ratio()))
	wiped_fragment_count = 0
	for i in _erosion.size():
		_erosion[i] = 0.0 if i < keep else 1.0
		if _erosion[i] >= 1.0:
			wiped_fragment_count += 1
		_apply_erosion(i)
	if remaining_ratio() <= scatter_threshold_ratio and mass_kg > 0.0:
		_collapse()
		return
	visible = true
	_update_debris()


func reset_motion() -> void:
	mass_kg = starting_mass_kg
	remaining_mass_kg = mass_kg
	_erased_peak = 0.0
	wiped_fragment_count = 0
	_prepare_erosion()
	for i in _erosion.size():
		_erosion[i] = 0.0
		_apply_erosion(i)
	if not _rim_outline.is_empty():
		_drawn_ratio = -1.0
	_erase_direction = Vector2(-1.0, 0.0)
	_has_erase_point = false
	flight_position = initial_position
	flight_velocity = initial_velocity
	destroyed = false
	visible = true
	_update_debris()

func sync_view(map_mode: bool, pixels_per_meter: float) -> void:
	$Visual.visible = not map_mode and not destroyed
	$MapArea.visible = not destroyed
	scale = Vector2.ONE * maxf(radius_m, 0.0) * pixels_per_meter / 100.0
	_prepare_map_area()
	if not map_mode:
		_refresh_screen_scale()

## 飞船撞上垃圾后的默认效果；可在派生场景中扩展。
func hit_ship(vessel: Node) -> void:
	if vessel.shield_ready:
		vessel.shield_ready = false
		_collapse()
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
