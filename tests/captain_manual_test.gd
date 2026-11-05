extends SceneTree
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	event = InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = false
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _run() -> void:
	check(OS.get_user_data_dir().contains("space-manual-test"), "测试使用隔离目录")
	if failures > 0:
		quit(1)
		return
	root.get_node("BackgroundMusic").stop_music()
	var manual_scene: PackedScene = load("res://scenes/ui/captain_manual.tscn")
	var editor_manual: Node = manual_scene.instantiate()
	check(editor_manual.get_node("Root").visible, "独立场景在编辑器默认可见，运行后才隐藏")
	editor_manual.free()
	var game: Node = load("res://scenes/game/star_map_demo.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	current_scene = game
	game.set_physics_process(false)
	await process_frame
	await process_frame
	var menu: Node = game.get_node("PauseMenu")
	var manual: Node = menu.get_node("CaptainManual")
	if not is_instance_valid(game.ship):
		check(false, "游戏脚本未完整初始化，无法继续手册集成测试")
		game.queue_free()
		await process_frame
		quit(1)
		return
	var camera: Node = game.get_node("NavigationCamera")
	var map: Node = game.get_node("StarMapView")
	check(not manual.is_open() and manual.categories.size() == 2, "独立手册默认关闭并加载飞行与导航两个分类")
	menu.open()
	menu.manual_button.pressed.emit()
	await process_frame
	await process_frame
	check(manual.is_open() and menu.is_open() and game.simulation_paused, "ESC菜单按钮打开手册且菜单继续持有暂停")
	var pages := 0
	for category_index in range(manual.categories.size()):
		manual.select_category(category_index)
		check(manual.chapters.item_count == manual.categories[category_index].chapters.size(), "切分类刷新左章节")
		for page_index in range(manual.chapters.item_count):
			manual.select_page(page_index)
			check(manual.page_image.texture != null and not manual.current_page_id.is_empty(), "图片页实际加载：" + manual.current_page_id)
			check(manual.page_image.texture.get_width() >= 1440 and manual.page_image.texture.get_height() >= 1000, "独立完整图片清晰尺寸：" + manual.current_page_id)
			pages += 1
	check(pages == 8, "八页保留手册资产均由JSON列出，删除旧采集经济说明")
	manual.select_category(0)
	manual.select_page(0)
	manual.page_image.texture.get_image().save_png("user://manual_first_page_preview.png")
	root.content_scale_size = Vector2i.ZERO
	for viewport_size: Vector2i in [Vector2i(960, 640), Vector2i(1200, 720), Vector2i(1600, 900)]:
		root.size = viewport_size
		await process_frame
		await process_frame
		manual.fit_page()
		await process_frame
		var bounds: Rect2 = manual.get_node("Root/Panel").get_global_rect()
		check(Rect2(Vector2.ZERO, Vector2(viewport_size)).encloses(bounds), "手册完整位于窗口：" + str(viewport_size))
		check(manual.page_image.custom_minimum_size.x <= manual.scroll.size.x and manual.page_image.custom_minimum_size.y <= manual.scroll.size.y, "图片按整页适配窗口：" + str(viewport_size))
		var before: Vector2 = manual.page_image.custom_minimum_size
		manual._set_zoom(1.0)
		await process_frame
		check(manual.page_image.custom_minimum_size.x > before.x and manual.zoom_factor == 2.0, "图片可放大并滚动查看：" + str(viewport_size))
		manual.fit_page()
	var selected_ship: Node = game.ship
	var before_position: Vector2 = camera.position
	var before_zoom: Vector2 = camera.zoom
	var map_mode: bool = map.map_mode
	var before_fuel: float = selected_ship.fuel
	check(camera.process_mode == Node.PROCESS_MODE_DISABLED and map.process_mode == Node.PROCESS_MODE_DISABLED, "手册禁用键盘轮询与世界相机输入")
	key(KEY_M)
	key(KEY_F)
	key(KEY_R)
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.position = Vector2(900, 400)
	wheel.pressed = true
	Input.parse_input_event(wheel)
	Input.flush_buffered_events()
	var click := InputEventMouseButton.new()
	click.position = Vector2(100, 600)
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	Input.parse_input_event(click)
	Input.flush_buffered_events()
	await process_frame
	check(camera.position == before_position and camera.zoom == before_zoom and map.map_mode == map_mode, "手册键盘滚轮不穿透世界视角")
	check(game.ship == selected_ship and selected_ship.fuel == before_fuel and game.simulation_paused, "手册输入不触发世界重置或推进")
	key(KEY_ESCAPE)
	await process_frame
	check(not manual.is_open() and menu.is_open() and game.simulation_paused, "首次ESC只关闭手册，返回暂停菜单")
	check(camera.process_mode != Node.PROCESS_MODE_DISABLED and map.process_mode != Node.PROCESS_MODE_DISABLED, "关闭后恢复原输入模式")
	key(KEY_ESCAPE)
	await process_frame
	check(not menu.is_open() and not game.simulation_paused, "再次ESC退出菜单恢复原运行状态")
	game.simulation_paused = true
	menu.open()
	menu.manual_button.pressed.emit()
	manual.close()
	check(menu.is_open() and game.simulation_paused, "关闭按钮不解除主面板原暂停")
	menu.close()
	check(game.simulation_paused, "关闭菜单保留原暂停")
	game.simulation_paused = false
	game.set_tutorial_pause(true)
	menu.open()
	manual.open()
	manual.close()
	menu.close()
	check(game.simulation_paused and game.tutorial_pause, "手册关闭与菜单关闭不解除教程暂停锁")
	game.set_tutorial_pause(false)
	game.queue_free()
	await process_frame
	print("CAPTAIN_MANUAL_TEST: %s (%d checks, %d failures); isolated_user=%s" % ["PASS" if failures == 0 else "FAIL", checks, failures, OS.get_user_data_dir()])
	quit(0 if failures == 0 else 1)
