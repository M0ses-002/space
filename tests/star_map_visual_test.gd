extends SceneTree
## 验证固定底角按钮、点击坐标和自动视角切换；有渲染器时可保存试玩截图。
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)
func click(position: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	root.push_input(motion, true)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = position
		event.pressed = pressed
		root.push_input(event, true)

func key(physical: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = physical
		event.keycode = physical
		event.pressed = pressed
		root.push_input(event, true)

func wheel_at(position: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	root.push_input(motion, true)
	var wheel := InputEventMouseButton.new()
	wheel.position = position
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	for pressed in [true, false]:
		wheel.pressed = pressed
		root.push_input(wheel, true)

func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1200, 720)
	var editor_ship = load("res://scenes/ships/ship.tscn").instantiate()
	check(editor_ship.get_node("Visual/NearSprite").visible and not editor_ship.get_node("Visual/Hull").visible and not editor_ship.get_node("Visual/Engine").visible, "场景资源默认显示近域Sprite2D，编辑器无需运行即可预览")
	editor_ship.free()
	var game = load("res://scenes/game/star_map_demo.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	var view = game.get_node("StarMapView")
	var camera = game.get_node("NavigationCamera")
	var vessel = game.ship
	var sprite: Sprite2D = vessel.get_node("Visual/NearSprite")
	var hull: Polygon2D = vessel.get_node("Visual/Hull")
	var engine: Polygon2D = vessel.get_node("Visual/Engine")
	var picker: Button = vessel.get_node("SelectButton")
	check(sprite.texture != null and sprite.texture.resource_path == "res://assets/ships/transport_ship.png", "近域使用原图派生的透明舰船贴图")
	check(sprite.texture.get_size() == Vector2(1588, 390), "近域贴图已紧裁且保持原始舰体比例")
	var sprite_size := sprite.texture.get_size() * sprite.scale
	check(is_equal_approx(sprite_size.x, 40.0) and sprite_size.y < 10.0, "近域船体宽40像素，保持真实长宽比")
	check(sprite.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, "大图缩小使用线性mipmap采样")
	var texture_import := ConfigFile.new()
	check(texture_import.load("res://assets/ships/transport_ship.png.import") == OK and texture_import.get_value("params", "mipmaps/generate", false), "透明舰船贴图导入实际生成mipmap")
	check(picker.size == Vector2(50, 50) and is_zero_approx(picker.self_modulate.a) and not picker.disabled, "选船热区保持50像素且透明不覆盖舰船")
	check(not sprite.visible and hull.visible and engine.visible, "星图只保留原有简化图标")
	var saved_position: Vector2 = vessel.flight_position
	var saved_velocity: Vector2 = vessel.flight_velocity
	var saved_heading: Vector2 = vessel.heading
	var saved_fuel: float = vessel.fuel
	var saved_mass: float = vessel.get_total_mass()
	view.set_map_mode(false)
	check(sprite.visible and not hull.visible and not engine.visible, "近域只显示舰船贴图，不叠加旧图标")
	check(vessel.scale == Vector2.ONE, "近域保持原有世界显示缩放")
	game.selected = false
	game._sync_visuals()
	click(vessel.get_global_transform_with_canvas().origin)
	await process_frame
	check(game.selected and game.ship == vessel, "近域透明选船按钮仍接收实际鼠标点击")
	vessel.flight_velocity = Vector2.ZERO
	for direction in [Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT, Vector2.UP]:
		vessel.heading = direction
		game._sync_visuals()
		var facing: Vector2 = sprite.get_transform().x.rotated(vessel.get_node("Visual").rotation).normalized()
		check(facing.dot(direction) > 0.9999, "静止船首仍对齐实际heading：%s" % direction)
	vessel.flight_velocity = saved_velocity
	vessel.heading = saved_heading
	view.set_map_mode(true)
	check(not sprite.visible and hull.visible and engine.visible, "切回星图恢复原Hull和Engine")
	game.selected = false
	game._sync_visuals()
	click(vessel.get_global_transform_with_canvas().origin)
	await process_frame
	check(game.selected and game.ship == vessel, "星图简化图标仍接收实际鼠标点击")
	check(vessel.scale.is_equal_approx(Vector2.ONE / camera.zoom.x), "星图仍按相机反缩放保持图标可辨")
	check(vessel.flight_position == saved_position and vessel.flight_velocity == saved_velocity and vessel.heading == saved_heading and vessel.fuel == saved_fuel and vessel.get_total_mass() == saved_mass, "外观切换不改变坐标、速度、朝向、燃料或质量")
	for window_size in [Vector2i(1200, 720), Vector2i(1600, 900), Vector2i(960, 640)]:
		root.size = window_size
		await process_frame
		await process_frame
		game._sync_visuals()
		var navigation_rect: Rect2 = view.navigation_buttons.get_global_rect()
		var bottom: Control = game.get_node("HUD/Root/BottomActions")
		var bottom_rect := bottom.get_global_rect()
		check(navigation_rect == Rect2(16, window_size.y - 60, 144, 44), "左下三枚按钮固定边距与尺寸")
		check(bottom_rect == Rect2(window_size.x - 310, window_size.y - 60, 294, 44), "右下六枚按钮固定边距与尺寸")
		check(not view.has_node("HUD/Root/MapPanel") and not game.panel.has_node("Margin/Content/Hint"), "删除原星图面板与Hint文本，不保留空面板")
		check(not game.panel.has_node("Margin/Content/Reference") and not game.panel.has_node("Margin/Content/PauseButton"), "删除Reference与原面板暂停节点")
		check(game.pause_button == bottom.get_node("PauseButton"), "暂停按钮引用迁至右下快捷栏")
		var controls: Array = view.navigation_buttons.get_children() + game.speed_row.get_children() + [bottom.get_node("ResetButton"), game.pause_button]
		for control: Control in controls:
			check(control.size == Vector2(44, 44) and not control.tooltip_text.is_empty(), "全部快捷按钮均为44像素正方形且保留完整提示：%s" % control.name)
			check(not control.get_global_rect().intersects(game.get_node("HUD/Root/ThrustDial").get_global_rect()) and not control.get_global_rect().intersects(game.panel.get_global_rect()), "快捷按钮不与推力仪表或右面板重叠")
		for index in range(controls.size()):
			for next in range(index + 1, controls.size()):
				check(not controls[index].get_global_rect().intersects(controls[next].get_global_rect()), "固定快捷按钮相互不重叠")
		for index in range(4):
			click(game.speed_row.get_child(index).get_global_rect().get_center())
			await process_frame
			check(is_equal_approx(game.simulation_speed, [0.5, 1.0, 1.5, 2.0][index]), "三窗口真实点击倍速按钮生效：%s / %.1f×" % [window_size, [0.5, 1.0, 1.5, 2.0][index]])
		game._set_navigation_target(vessel.flight_position + Vector2(100000, 50000))
		view.sync_visuals()
		click(view.clear_button.get_global_rect().get_center())
		check(not vessel.has_navigation_target, "清除按钮真实点击有效且不穿透设置新目标")
		var mode_before: bool = view.map_mode
		click(view.map_button.get_global_rect().get_center())
		check(view.map_mode != mode_before, "固定地图按钮真实切换视角")
		click(view.return_button.get_global_rect().get_center())
		check(camera.following, "固定回船按钮真实开启跟随")
		for control: Control in controls:
			var zoom_before: float = camera.zoom.x
			wheel_at(control.get_global_rect().get_center())
			check(camera.zoom.x == zoom_before, "全部固定快捷按钮屏蔽世界滚轮")
		check(not vessel.has_navigation_target, "倍速回船地图按钮不会穿透生成导航目标")
		var pause_position: Vector2 = vessel.flight_position
		var pause_velocity: Vector2 = vessel.flight_velocity
		var pause_fuel: float = vessel.fuel
		click(game.pause_button.get_global_rect().get_center())
		check(game.simulation_paused and game.pause_button.text == "继续" and game.pause_button.size == Vector2(44, 44), "三尺寸右下真实点击暂停且文字不撑宽")
		game._physics_process(game.SIM_STEP / game.TIME_SCALE)
		check(vessel.flight_position == pause_position and vessel.flight_velocity == pause_velocity and vessel.fuel == pause_fuel, "迁移后暂停仍不积分或耗油")
		click(game.pause_button.get_global_rect().get_center())
		check(not game.simulation_paused and game.pause_button.text == "暂停" and game.pause_button.size == Vector2(44, 44), "三尺寸右下真实点击继续且文字不撑宽")
		check(not vessel.has_navigation_target, "暂停继续按钮不会穿透设置导航目标")
		var fixed_before: Vector2 = view.navigation_buttons.position
		for control: Control in [view.return_button, game.speed_row.get_child(0)]:
			var pointer := control.get_global_rect().get_center()
			var press := InputEventMouseButton.new()
			press.position = pointer
			press.button_index = MOUSE_BUTTON_LEFT
			press.pressed = true
			root.push_input(press, true)
			var motion := InputEventMouseMotion.new()
			motion.position = pointer + Vector2(60, -80)
			motion.button_mask = MOUSE_BUTTON_MASK_LEFT
			root.push_input(motion, true)
			press.position = motion.position
			press.pressed = false
			root.push_input(press, true)
			check(view.navigation_buttons.position == fixed_before and bottom.get_global_rect() == bottom_rect, "底角快捷按钮不能被真实鼠标拖动")
		click(bottom.get_node("ResetButton").get_global_rect().get_center())
		check(not game.selected and is_equal_approx(game.simulation_speed, 1.0) and not vessel.has_navigation_target, "三窗口真实点击重置恢复航行且不穿透")
		mode_before = view.map_mode
		key(KEY_M)
		check(view.map_mode != mode_before, "M快捷键保留")
		key(KEY_F)
		check(camera.following, "F快捷键保留")
		game._set_simulation_speed(2.0)
		key(KEY_R)
		check(is_equal_approx(game.simulation_speed, 1.0), "R快捷键保留")
		# 勾选「视角始终跟随」后重置视角仍保持跟随，未勾选才回到自由视角。
		check(camera.following == vessel.camera_always_follow, "R快捷键保留：跟随状态与飞船开关一致")
		await process_frame
		await process_frame
	root.size = Vector2i(1200, 720)
	await process_frame
	await process_frame
	view.set_map_mode(false)
	view.set_map_mode(true)
	# 点击世界位置，以事件position而非全局鼠标位置换算。
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(400, 220)
	var expected: Vector2 = (game.get_canvas_transform().affine_inverse() * click.position - game._screen_center()) / game._view_scale()
	game._unhandled_input(click)
	check(game.ship.navigation_target.distance_to(expected) < 1.0, "缩放后的点击坐标正确")
	# UI命中不应透传，滚轮不影响UI上相机。
	var previous_zoom: float = camera.zoom.x
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = view.map_button.get_global_rect().get_center()
	camera._input(wheel)
	check(camera.zoom.x == previous_zoom, "固定导航按钮上滚轮不缩放世界")
	# 使用独立范围夹具，避免试玩场景的可调引力范围污染250km边界测试。
	for source in game.planets:
		source.max_gravity_radius_m = 250000.0
	game.ship.flight_position = Vector2(0, -260000)
	game._update_region(game.ship, game.ship.flight_position)
	view.on_ship_selected()
	# 自动切换防抖通过模拟计时值验证，不等待真实航程。
	game.ship.flight_position = Vector2(0, -240000)
	game._update_region(game.ship, Vector2(0, -260000))
	view._observe_region()
	view.pending_since_msec = Time.get_ticks_msec() - 600
	view._observe_region()
	check(not view.map_mode, "进入引力区稳定后自动近域")
	game.ship.flight_position = Vector2(0, -260000)
	game._update_region(game.ship, Vector2(0, -240000))
	view._observe_region()
	view.pending_since_msec = Time.get_ticks_msec() - 600
	view._observe_region()
	check(view.map_mode, "离开引力区稳定后自动星图")
	# 恢复初始演示画面输出截图。
	game._reset()
	await process_frame
	await process_frame
	game._sync_visuals()
	# 无渲染器不会发出frame_post_draw；仅显式请求截图时保存，headless照常验证布局。
	var arguments := OS.get_cmdline_user_args()
	if DisplayServer.get_name() != "headless" and not arguments.is_empty():
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		check(image.save_png(arguments[0]) == OK, "保存真实星图截图")
	game.queue_free()
	await process_frame
	print("STAR_MAP_VISUAL_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
