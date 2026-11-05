class_name TextureStyle
extends RefCounted
## 序列帧样式表：texture_id 决定使用哪一套图集。
## 图集由 tools/build_texture_sheets.py 生成，统一为 6 列 × 6 行、36 帧、按文件名顺序排列。

const COLS := 6
const ROWS := 6
const FRAMES := COLS * ROWS

const NULL_STYLE := {}

## 行星圆盘在世界坐标里的目标直径。main.gd 把行星节点缩放到 radius_m / 200，
## 因此圆盘必须占满 400 个世界单位，才能与 2 × radius_m 的碰撞半径重合。
const PLANET_SOURCE_WIDTH := 400.0

const STYLES := {
	"debris": {
		0: {"name": "晶体", "sheet": "res://assets/world/debris_crystal_sheet.png", "fps": 12.0},
		1: {"name": "黑曜石", "sheet": "res://assets/world/debris_obsidian_sheet.png", "fps": 12.0},
	},
	"asteroid": {
		0: {"name": "沙漠", "sheet": "res://assets/world/asteroid_desert_sheet.png", "fps": 12.0},
		1: {"name": "铁锈", "sheet": "res://assets/world/asteroid_rust_sheet.png", "fps": 12.0},
	},
	"planet": {
		0: {
			"name": "罗宋",
			"sheet": "res://assets/world/planet_russian_sheet.png",
			"fps": 10.0,
			# 圆盘直径占图集帧边长的比例（由 build_texture_sheets.py 实测输出），
			# 用于把视觉直径对齐物理半径。裁切框以圆盘圆心为中心，故圆心即帧中心。
			"disc_ratio": 0.8477,
		},
		1: {
			"name": "拉丁",
			"sheet": "res://assets/world/planet_latin_sheet.png",
			"fps": 10.0,
			# 与罗宋同一裁切画幅，比例一致。
			"disc_ratio": 0.8477,
		},
	},
}

static func has_style(category: String, id: int) -> bool:
	if not STYLES.has(category):
		return false
	var styles: Dictionary = STYLES[category]
	return styles.has(id)

static func style(category: String, id: int) -> Dictionary:
	if not has_style(category, id):
		return NULL_STYLE
	var styles: Dictionary = STYLES[category]
	var data: Dictionary = styles[id]
	return data

## 该类别下所有可用 ID，按升序返回，供地图编辑器与脚本循环。
static func ids(category: String) -> Array[int]:
	var result: Array[int] = []
	if not STYLES.has(category):
		return result
	var styles: Dictionary = STYLES[category]
	for id in styles.keys():
		result.append(int(id))
	result.sort()
	return result

static func names(category: String) -> PackedStringArray:
	var result := PackedStringArray()
	for id in ids(category):
		result.append("%s:%d" % [style(category, id).get("name", ""), id])
	return result

## 把样式应用到 Sprite2D：切换图集、设为 6×6 网格并清除旧的 region 裁切。
static func apply_to(sprite: Sprite2D, category: String, id: int) -> bool:
	if not is_instance_valid(sprite) or not has_style(category, id):
		return false
	var data := style(category, id)
	var sheet := load(data.get("sheet", "")) as Texture2D
	if sheet == null:
		return false
	sprite.texture = sheet
	sprite.hframes = COLS
	sprite.vframes = ROWS
	sprite.region_enabled = false
	sprite.frame = clampi(sprite.frame, 0, FRAMES - 1)
	return true

## 图集单帧像素边长（图集为正方形分格）。
static func frame_size(sprite: Sprite2D) -> float:
	if not is_instance_valid(sprite) or sprite.texture == null:
		return 0.0
	var columns := maxi(sprite.hframes, 1)
	return float(sprite.texture.get_width()) / float(columns)

## 由累计时间与相位求当前帧，循环播放。
static func frame_at(category: String, id: int, elapsed: float, phase: int = 0) -> int:
	var data := style(category, id)
	if data.is_empty():
		return 0
	var fps: float = data.get("fps", 12.0)
	return posmod(posmod(phase, FRAMES) + int(elapsed * fps), FRAMES)

## 行星圆盘视觉直径对齐物理直径所需的 Sprite2D 缩放。
static func planet_surface_scale(category: String, id: int, frame_px: float) -> float:
	var data := style(category, id)
	var disc_ratio: float = float(data.get("disc_ratio", 1.0))
	if frame_px <= 0.0 or disc_ratio <= 0.0:
		return 1.0
	return PLANET_SOURCE_WIDTH / (frame_px * disc_ratio)
