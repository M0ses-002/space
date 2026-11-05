extends SceneTree
## 序列帧纹理样式专项：图集完整性、texture_id 切换、帧推进、场景节点与地图字段。

var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _run() -> void:
	root.size = Vector2i(1200, 720)
	for category in ["debris", "asteroid", "planet"]:
		check(not TextureStyle.ids(category).is_empty(), "%s 至少注册一种样式" % category)
		for id in TextureStyle.ids(category):
			var data: Dictionary = TextureStyle.style(category, id)
			var sheet: Texture2D = load(str(data.get("sheet", ""))) as Texture2D
			check(sheet != null, "%s/%d 图集可加载" % [category, id])
			if sheet == null:
				continue
			check(sheet.get_width() == sheet.get_height(), "%s/%d 图集为正方形" % [category, id])
			check(sheet.get_width() % TextureStyle.COLS == 0, "%s/%d 宽度可被列数整除" % [category, id])
			check(sheet.get_height() % TextureStyle.ROWS == 0, "%s/%d 高度可被行数整除" % [category, id])
			check(float(data.get("fps", 0.0)) > 0.0, "%s/%d 播放帧率有效" % [category, id])

	# 帧索引循环且受相位偏移
	check(TextureStyle.frame_at("debris", 0, 0.0, 0) == 0, "起始帧为 0")
	check(TextureStyle.frame_at("debris", 0, 0.0, 36) == 0, "相位 36 回到 0")
	check(TextureStyle.frame_at("debris", 0, 0.0, 1) == 1, "相位 1 偏移一帧")
	var fps: float = TextureStyle.style("debris", 0).get("fps", 12.0)
	check(TextureStyle.frame_at("debris", 0, 1.0 / fps, 0) == 1, "推进一个帧间隔后到第 1 帧")
	check(TextureStyle.frame_at("debris", 0, 3.0, 0) == 0, "整圈后回到第 0 帧")

	# 碎片：默认样式与切换
	var debris: Node2D = load("res://scenes/world/space_debris.tscn").instantiate()
	root.add_child(debris)
	await process_frame
	var visual: Node = debris.get_node("Visual")
	check(visual.get_child_count() == 32, "碎片场景保留 32 个预置节点")
	check(debris.texture_id == 0, "碎片默认纹理 ID 为 0")
	var first := visual.get_child(0) as Sprite2D
	var crystal: String = TextureStyle.style("debris", 0).get("sheet", "")
	check(first.texture != null and first.texture.resource_path == crystal, "碎片默认使用晶体图集")
	check(first.hframes == 6 and first.vframes == 6, "碎片设为 6×6 网格")
	check(not first.region_enabled, "碎片不再使用 region 裁切")
	check(first.frame >= 0 and first.frame < 36, "碎片帧索引在范围内")
	var phases := {}
	for i in visual.get_child_count():
		phases[(visual.get_child(i) as Sprite2D).frame] = true
	check(phases.size() > 1, "碎片起始帧按相位错开")

	debris.texture_id = 1
	await process_frame
	var obsidian: String = TextureStyle.style("debris", 1).get("sheet", "")
	check(first.texture.resource_path == obsidian, "切换纹理 ID 后改用黑曜石图集")
	check(debris.texture_id == 1, "碎片纹理 ID 写回")

	# 主动推进动画，确认帧真的在变
	var before := first.frame
	debris._advance_animation(1.0 / fps * 2.0)
	check(first.frame != before, "推进时间后碎片帧发生变化")

	# 小行星：默认 0 使用沙漠序列帧，-1 回退到静态岩石外观
	var asteroid: Node2D = load("res://scenes/world/asteroid.tscn").instantiate()
	root.add_child(asteroid)
	await process_frame
	var sequence := asteroid.get_node("Visual/Sequence") as Sprite2D
	check(sequence != null, "小行星场景包含序列帧节点")
	check(asteroid.texture_id == 0, "小行星默认使用序列帧纹理")
	var desert: String = TextureStyle.style("asteroid", 0).get("sheet", "")
	check(sequence.visible, "默认显示序列帧节点")
	check(sequence.texture.resource_path == desert, "小行星使用沙漠图集")
	for i in range(asteroid.get_node("Visual").get_child_count()):
		var child: Node = asteroid.get_node("Visual").get_child(i)
		if child != sequence:
			check(not child.visible, "序列帧模式下静态岩石全部隐藏")
	var asteroid_frame := sequence.frame
	asteroid._process(1.0 / float(TextureStyle.style("asteroid", 0).get("fps", 12.0)))
	check(sequence.frame != asteroid_frame, "小行星帧随时间推进")

	asteroid.texture_id = -1
	await process_frame
	check(not sequence.visible, "纹理 ID -1 时序列帧隐藏")
	check(asteroid.get_node("Visual").get_child(asteroid.style_index).visible, "纹理 ID -1 回退到对应静态岩石")

	asteroid.texture_id = 0
	await process_frame
	check(sequence.visible, "切回 0 恢复序列帧")
	check(asteroid.texture_id == 0, "小行星纹理 ID 写回")

	asteroid.texture_id = 1
	await process_frame
	var rust: String = TextureStyle.style("asteroid", 1).get("sheet", "")
	check(sequence.texture != null and sequence.texture.resource_path == rust, "纹理 ID 1 切换到铁锈图集")
	check(sequence.visible, "铁锈样式同样显示序列帧")

	# 行星：图集与缩放补偿
	var planet: Node2D = load("res://scenes/world/planet.tscn").instantiate()
	root.add_child(planet)
	await process_frame
	var surface := planet.get_node("Surface") as Sprite2D
	var russian: String = TextureStyle.style("planet", 0).get("sheet", "")
	check(surface.texture.resource_path == russian, "行星使用罗宋图集")
	check(surface.hframes == 6 and surface.vframes == 6, "行星设为 6×6 网格")
	var frame_px := TextureStyle.frame_size(surface)

	# 球心必须落在节点原点：Sprite2D 不能靠 position / offset 挪动来"对齐"。
	check(surface.centered, "行星 Sprite2D 保持居中绘制")
	check(surface.position.is_zero_approx(), "行星 Sprite2D 无额外位移")
	check(surface.offset.is_zero_approx(), "行星 Sprite2D 无偏移量")

	# 每种行星样式都要满足：圆盘圆心落在帧中心、占比与 disc_ratio 一致、视觉直径补偿到 400 单位。
	# 旧版按 alpha 并集包围盒裁切，环和星点把裁切框拉偏，圆盘在帧内偏移约 13px。
	for planet_id in TextureStyle.ids("planet"):
		var planet_style: Dictionary = TextureStyle.style("planet", planet_id)
		var style_sheet: String = str(planet_style.get("sheet", ""))
		var disc_ratio: float = float(planet_style.get("disc_ratio", 1.0))
		planet.texture_id = planet_id
		await process_frame
		check(surface.texture != null and surface.texture.resource_path == style_sheet,
			"行星样式 %d 使用注册图集" % planet_id)
		var disc_units := frame_px * disc_ratio * surface.scale.x
		check(absf(disc_units - 400.0) <= 1.0,
			"行星样式 %d 圆盘补偿到 400 单位画幅：%.2f" % [planet_id, disc_units])
		var planet_image: Image = null
		if surface.texture != null:
			planet_image = surface.texture.get_image()
		check(planet_image != null, "行星样式 %d 图集可取像素" % planet_id)
		if planet_image == null:
			continue
		var tile_px := int(planet_image.get_width() / TextureStyle.COLS)
		var sum_dx := 0.0
		var sum_dy := 0.0
		var sum_ratio := 0.0
		var sampled := [0, 6, 12, 18, 24, 30]
		for raw_index in sampled:
			var index := int(raw_index)
			var row := int(index / TextureStyle.COLS)
			var column := index % TextureStyle.COLS
			var frame_image := planet_image.get_region(
				Rect2i(column * tile_px, row * tile_px, tile_px, tile_px))
			var geometry := _disc_geometry(frame_image)
			var dx: float = float(geometry["cx"]) - float(tile_px) * 0.5
			var dy: float = float(geometry["cy"]) - float(tile_px) * 0.5
			sum_dx += dx
			sum_dy += dy
			# 源序列里行星本身有轻微漂移，单帧允许 10px 内；系统性偏移由下面的均值把关。
			check(absf(dx) <= 10.0 and absf(dy) <= 9.0,
				"行星 %d 帧 %d 圆心接近帧中心：偏移 (%.1f, %.1f)px" % [planet_id, index, dx, dy])
			var measured := float(geometry["ratio"])
			sum_ratio += measured
			# 源序列的可见直径本身逐帧有约 3% 起伏，单帧放宽到 0.07，均值再收紧。
			check(absf(measured - disc_ratio) <= 0.07,
				"行星 %d 帧 %d 圆盘占比与 disc_ratio 一致：实测 %.4f / 注册 %.4f"
				% [planet_id, index, measured, disc_ratio])
		# 旧版按 alpha 并集包围盒裁切时，圆盘整体下移约 13px、右移约 6px，均值会明显跑偏。
		var mean_dx := sum_dx / float(sampled.size())
		var mean_dy := sum_dy / float(sampled.size())
		check(absf(mean_dx) <= 5.0 and absf(mean_dy) <= 4.0,
			"行星 %d 圆盘与帧中心的系统偏移在容差内：均值 (%.2f, %.2f)px"
			% [planet_id, mean_dx, mean_dy])
		var mean_ratio := sum_ratio / float(sampled.size())
		check(absf(mean_ratio - disc_ratio) <= 0.03,
			"行星 %d 圆盘平均占比与 disc_ratio 一致：均值 %.4f / 注册 %.4f"
			% [planet_id, mean_ratio, disc_ratio])
	var planet_before := surface.frame
	planet._process(1.0 / float(TextureStyle.style("planet", planet.texture_id).get("fps", 10.0)))
	check(surface.frame != planet_before, "行星帧随时间推进")

	# 地图字段：接受合法 ID，拒绝越界与小数，且纯视觉字段不影响指纹
	var loader: GDScript = load("res://scripts/navigation/map_loader.gd")
	check(loader != null, "地图加载器可加载")
	var base := {
		"version": 1,
		"objects": [
			{"id": "d1", "type": "debris", "position": [0.0, 0.0], "fields": {"texture_id": 0}},
			{"id": "p1", "type": "planet", "position": [0.0, 0.0], "fields": {"texture_id": 1}},
		],
		"ship": {"position": [0.0, 0.0], "velocity": [0.0, 0.0]},
	}
	var variant := base.duplicate(true)
	variant.objects[0].fields.texture_id = 1
	var valid_path := "user://texture_style_valid.json"
	var variant_path := "user://texture_style_variant.json"
	_write_json(valid_path, base)
	_write_json(variant_path, variant)
	var parsed_valid: Dictionary = loader.read_map(valid_path)
	var parsed_variant: Dictionary = loader.read_map(variant_path)
	check(not parsed_valid.is_empty(), "地图接受 texture_id=0")
	check(not parsed_variant.is_empty(), "地图接受 texture_id=1")
	check(int(parsed_valid.objects[1].fields.get("texture_id", -1)) == 1, "地图保留行星的拉丁样式 ID")
	check(parsed_valid.get("hash", "") == parsed_variant.get("hash", ""), "纯视觉纹理 ID 不改变地图指纹")

	for bad in [9.0, 1.5, -2.0]:
		var bad_map := base.duplicate(true)
		bad_map.objects[0].fields.texture_id = bad
		var bad_path := "user://texture_style_bad.json"
		_write_json(bad_path, bad_map)
		check(loader.read_map(bad_path).is_empty(), "地图拒绝非法纹理 ID：%s" % bad)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(valid_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(variant_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://texture_style_bad.json"))

	for node in [debris, asteroid, planet]:
		if is_instance_valid(node):
			node.free()
	print("TEXTURE_STYLE_TEST: %s checks=%d failures=%d" % ["PASS" if failures == 0 else "FAIL", checks, failures])
	quit(0 if failures == 0 else 1)

func _write_json(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(data))
	file.close()

## 从图集单帧里量出实心圆盘的圆心与直径占比。
## 用"每行/每列最长连续不透明段"识别圆盘：环、卫星、星点是独立短段，不参与计算。
func _disc_geometry(image: Image) -> Dictionary:
	var width := image.get_width()
	var height := image.get_height()
	var data := image.get_data()
	var row_len := PackedFloat64Array()
	var row_mid := PackedFloat64Array()
	for y in height:
		var run := _longest_run(data, y * width, 1, width)
		row_len.append(float(run.y))
		row_mid.append(float(run.z) * 0.5)
	var col_len := PackedFloat64Array()
	var col_mid := PackedFloat64Array()
	for x in width:
		var run := _longest_run(data, x, width, height)
		col_len.append(float(run.y))
		col_mid.append(float(run.z) * 0.5)
	var diameter := maxf(_max_value(row_len), _max_value(col_len))
	if diameter <= 0.0:
		return {"cx": 0.0, "cy": 0.0, "ratio": 0.0}
	# 只有弦长接近直径的行/列属于圆盘主体，取其中点中位数作为圆心。
	var solid_x := PackedFloat64Array()
	var col_limit := _max_value(col_len) * 0.85
	for i in col_mid.size():
		if col_len[i] > col_limit:
			solid_x.append(col_mid[i])
	var solid_y := PackedFloat64Array()
	var row_limit := _max_value(row_len) * 0.85
	for i in row_mid.size():
		if row_len[i] > row_limit:
			solid_y.append(row_mid[i])
	return {
		"cx": _median(solid_x),
		"cy": _median(solid_y),
		"ratio": diameter / float(width),
	}

## 沿一条直线找最长连续不透明段，返回 (起点, 长度, 起点×2+长度)；第三项即中点的 2 倍。
func _longest_run(data: PackedByteArray, first_pixel: int, stride: int, count: int) -> Vector3i:
	var best_start := 0
	var best_length := 0
	var run_start := -1
	for i in count:
		if data[(first_pixel + i * stride) * 4 + 3] > 128:
			if run_start < 0:
				run_start = i
		elif run_start >= 0:
			var length := i - run_start
			if length > best_length:
				best_length = length
				best_start = run_start
			run_start = -1
	if run_start >= 0:
		var tail := count - run_start
		if tail > best_length:
			best_length = tail
			best_start = run_start
	return Vector3i(best_start, best_length, best_start * 2 + best_length)

func _max_value(values: PackedFloat64Array) -> float:
	var result := 0.0
	for value in values:
		result = maxf(result, value)
	return result

func _median(values: PackedFloat64Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var middle := sorted.size() / 2
	if sorted.size() % 2 == 1:
		return sorted[middle]
	return (sorted[middle - 1] + sorted[middle]) * 0.5

