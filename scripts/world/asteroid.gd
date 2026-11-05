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
## 外观预设索引：0 为灰岩，1 为赤岩，2 为冰岩。
@export_enum("灰岩:0", "赤岩:1", "冰岩:2") var style_index := 0:
	set(value):
		style_index = clampi(value, 0, 2)
		if is_inside_tree():
			_update_style()

## 纹理样式 ID：0 为沙漠序列帧（默认）；-1 回退到上方 style_index 的静态岩石外观。
@export_range(-1, 8, 1) var texture_id := 0:
	set(value):
		texture_id = value
		_apply_texture_style()
		_update_style()

var flight_position := Vector2.ZERO
var flight_velocity := Vector2.ZERO
var destroyed := false
var starting_mass_kg := 0.0
var starting_radius_m := 0.0
var _anim_elapsed := 0.0

func _ready() -> void:
	_apply_texture_style()
	_update_style()
	if not Engine.is_editor_hint():
		starting_mass_kg = mass_kg
		starting_radius_m = radius_m
		reset_motion()

func _process(delta: float) -> void:
	if Engine.is_editor_hint() or destroyed or not $Visual.visible:
		return
	var sequence := $Visual/Sequence as Sprite2D
	if sequence == null or not sequence.visible:
		return
	_anim_elapsed += delta
	var next_frame := TextureStyle.frame_at("asteroid", texture_id, _anim_elapsed)
	if sequence.frame != next_frame:
		sequence.frame = next_frame


## 序列帧模式下隐藏静态岩石并切换到图集，同时按单帧像素补偿显示尺寸。
func _apply_texture_style() -> void:
	if not is_node_ready() or not has_node("Visual/Sequence"):
		return
	if not TextureStyle.has_style("asteroid", texture_id):
		return
	var sequence := $Visual/Sequence as Sprite2D
	if not TextureStyle.apply_to(sequence, "asteroid", texture_id):
		return
	var frame_px := TextureStyle.frame_size(sequence)
	sequence.scale = Vector2.ONE * (200.0 / maxf(frame_px, 1.0))
	sequence.frame = 0
	_anim_elapsed = 0.0

func _update_style() -> void:
	var sequence := $Visual/Sequence as Sprite2D if has_node("Visual/Sequence") else null
	var use_sequence := sequence != null and TextureStyle.has_style("asteroid", texture_id)
	if sequence != null:
		sequence.visible = use_sequence
	for i in range($Visual.get_child_count()):
		var child := $Visual.get_child(i)
		if child == sequence:
			continue
		child.visible = not use_sequence and i == style_index

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
