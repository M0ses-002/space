extends SceneTree

const Manager = preload("res://scripts/persistence/save_manager.gd")
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1200, 720)
	var manager = Manager.new()
	root.add_child(manager)
	var game = load("res://scenes/game/star_map_demo.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	var ship = game.ships[0]
	var port = game.get_node("PortController")
	ship.voyage_finished = true
	ship.arrival_source = game.cities[0]
	port.enter_port(game.cities[0], ship)
	check(port._get_state().shipyard_available, "城市港口提供船坞")
	port.view.get_node("%ShipyardButton").pressed.emit()
	check(port.view.get_node("%ShipyardPage").visible, "船坞页面可打开")
	var candidates = port.view.get_node("%Candidates")
	check(not candidates.visible, "候选列表初始隐藏")
	check(not candidates.detail.visible, "详情面板初始隐藏，不占据左上角")
	port.view.get_node("%Slots").get_child(1).pressed.emit()
	check(port.shipyard_slot == 1, "界面选择正确的槽位")
	check(candidates.visible, "点击槽位后显示候选")
	check(candidates.get_button("fuel") != null, "候选按 id 可定位")
	var fuel_button: Button = candidates.get_button("fuel")
	check(fuel_button.custom_minimum_size == Vector2(96, 96), "候选为方形按钮")
	check(fuel_button.text == "燃料仓 Lv1", "按钮仅显示名字不含成本与描述")
	# 候选数量随改装表增长，这里只断言必备项都在、且各槽位一致，不写死数量。
	var slot0: Dictionary = port.session.get_slot_upgrades(0)
	var slot3: Dictionary = port.session.get_slot_upgrades(3)
	check(slot0.size() == slot3.size() and slot0.has("capture_net") and not slot0.has("recycle_hook"), "缺省 slots 时所有槽位可用（含捕捉网，回收钩已下线）")
	var detail = candidates.detail
	await process_frame
	await process_frame
	var thruster_button: Button = candidates.get_button("thruster")
	var first_point: Vector2 = _viewport_rect(thruster_button).position + Vector2(18, 18)
	_move_mouse(first_point)
	await process_frame
	await process_frame
	check(detail.visible, "真实鼠标悬停显示详情面板")
	check(_viewport_rect(detail).position.is_equal_approx(first_point + Vector2(20, 20)), "详情位于真实鼠标右下20像素：实际=%s 鼠标=%s" % [_viewport_rect(detail), first_point])
	var first_position: Vector2 = _viewport_rect(detail).position
	var second_point := first_point + Vector2(24, 16)
	_move_mouse(second_point)
	await process_frame
	check(detail.visible and _viewport_rect(detail).position.is_equal_approx(first_position + Vector2(24, 16)), "同一按钮内真实鼠标移动持续更新详情位置")
	check(detail.title_label.text == "加力喷口 Lv1", "详情标题为配件名")
	check(detail.description_label.text.contains("加速"), "详情含描述")
	check(detail.credits_label.text == "信用点 100", "详情统一显示100信用点")
	check(detail.get_node_or_null("Margin/Content/Materials") == null, "详情不再展示材料需求")
	check(Rect2(Vector2.ZERO, Vector2(root.size)).encloses(_viewport_rect(detail)), "详情面板定位不越出屏幕")
	_move_mouse(Vector2(10, 10))
	await process_frame
	check(not detail.visible, "真实鼠标移出候选隐藏详情")
	_move_mouse(first_point)
	await process_frame
	check(detail.visible, "移回候选重新显示详情")
	port.view.get_node("%ShipyardPage").hide()
	await process_frame
	check(not detail.visible, "候选祖先页面隐藏时详情同步隐藏")
	port.view.get_node("%ShipyardPage").show()
	_move_mouse(_viewport_rect(fuel_button).get_center())
	for pressed in [true, false]:
		var click := InputEventMouseButton.new()
		click.position = _viewport_rect(fuel_button).get_center()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = pressed
		root.push_input(click, true)
	check(ship.upgrade_slots[1] == "fuel", "真实鼠标点击安装到所选槽位，详情不拦截点击")
	_move_mouse(first_point)
	await process_frame
	check(detail.visible, "离港前详情可以正常显示")
	port.leave_port()
	await process_frame
	check(not detail.visible, "隐藏港口CanvasLayer时详情同步隐藏")
	ship.upgrade_slots = ["", "", "", ""]
	ship.voyage_finished = false
	var session = port.session
	session._credits = 1200
	check(session.open_planet("res://data/planets/flat_nuclear_city.json"), "城市数据加载")
	for upgrade in ["fuel", "computer", "thruster", "shield"]:
		session.set_credits(99)
		var before_slots: Array = ship.upgrade_slots.duplicate()
		var before_shield: bool = ship.shield_ready
		var before_fuel: float = ship.fuel
		check(not session.install_upgrade(ship, 0, upgrade, true), "99信用点拒绝改装：" + upgrade)
		check(session.get_credits() == 99 and ship.upgrade_slots == before_slots and ship.shield_ready == before_shield and ship.fuel == before_fuel, "失败无扣款或船体副作用：" + upgrade)
		session.set_credits(100)
		check(session.install_upgrade(ship, 0, upgrade, true) and session.get_credits() == 0, "100信用点恰好安装：" + upgrade)
		ship.upgrade_slots = ["", "", "", ""]
		ship.shield_ready = false
	session.set_credits(1200)
	check(not session.install_upgrade(ship, 0, "fuel", false), "未停靠时禁止安装")
	check(session.install_upgrade(ship, 0, "fuel", true), "安装燃料仓")
	check(is_equal_approx(ship.get_fuel_capacity(), ship.fuel_capacity * 1.2) and session._credits == 1100, "油箱容量与费用")
	check(not session.install_upgrade(ship, 1, "fuel", true), "禁止重复安装")
	check(session.install_upgrade(ship, 1, "computer", true), "安装航行电脑")
	var map_view = game.get_node("StarMapView")
	check(not game.panel.has_node("Margin/Content/Reference"), "删除旧预演说明组件")
	check(is_equal_approx(game.get_preview_horizon(), 1800.0 if map_view.map_mode else 930.0), "航行电脑改装影响实际预演时间")
	game._set_simulation_speed(1.5)
	check(is_equal_approx(game.get_preview_horizon(), 1800.0 if map_view.map_mode else 930.0), "切换倍速保留正确预演时间")
	check(session.install_upgrade(ship, 2, "thruster", true), "安装加力喷口")
	check(session.install_upgrade(ship, 3, "shield", true), "安装霍普尔盾")
	check(not session.install_upgrade(ship, 0, "computer", true), "占用槽位不能安装")
	check(session.get_credits() == 800, "四种改造各扣100信用点且无需材料")
	check(is_equal_approx(ship.get_effective_acceleration(), 15.0), "加速度改装生效")
	check(is_equal_approx(ship.get_effective_deceleration(), 15.0), "减速度改装按载重生效")
	check(is_equal_approx(ship.get_effective_steering_acceleration(), 15.0), "方向推进改装按载重生效")
	check(not ship.has_method("get_mass_ratio") and ship.get_total_mass() == ship.dry_mass, "移除货舱后质量固定为干质量")
	var debris = load("res://scenes/world/space_debris.tscn").instantiate()
	root.add_child(debris)
	debris.hit_ship(ship)
	check(not ship.crashed and debris.destroyed and not ship.shield_ready, "护盾抵挡一次垃圾")
	session.set_credits(99)
	var shield_slots: Array = ship.upgrade_slots.duplicate()
	check(not session.install_upgrade(ship, 3, "shield", true) and not ship.shield_ready and session.get_credits() == 99 and ship.upgrade_slots == shield_slots, "99信用点重充失败且无副作用")
	session.set_credits(100)
	check(session.install_upgrade(ship, 3, "shield", true) and ship.shield_ready and session.get_credits() == 0, "100信用点恰好重充护盾")
	check(not session.install_upgrade(ship, 3, "shield", true) and session.get_credits() == 0, "完整护盾不允许重复重充扣款")
	debris.queue_free()
	var snapshot: Dictionary = manager.make_snapshot(game)
	ship.upgrade_slots = ["", "", "", ""]
	ship.shield_ready = false
	check(manager.restore_snapshot(game, snapshot), "改装存档可恢复")
	check(ship.upgrade_slots == ["fuel", "computer", "thruster", "shield"] and ship.shield_ready, "改装与护盾状态恢复")
	var invalid: Dictionary = snapshot.duplicate(true)
	invalid.ships[invalid.ships.keys()[0]].upgrade_slots = ["fuel", "fuel", "", ""]
	check(not manager.restore_snapshot(game, invalid), "拒绝重复改装的损坏存档")
	game.queue_free()
	manager.queue_free()
	await process_frame
	await _test_overlay_edges_and_scaling()
	print("SHIPYARD_TEST: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)

func _viewport_rect(control: Control) -> Rect2:
	return control.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, control.size)

func _move_mouse(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)

func _test_overlay_edges_and_scaling() -> void:
	var fixture = load("res://scenes/ports/shipyard_candidates.tscn").instantiate()
	root.add_child(fixture)
	fixture.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	fixture.size = Vector2(120, 120)
	fixture.render({"thruster": {"name": "加力喷口 Lv1", "description": "提高加速性能", "credits": 100}})
	fixture.show()
	var detail = fixture.detail
	check(detail is PanelContainer and detail.get_parent() is CanvasLayer, "详情是独立CanvasLayer下的普通面板而非原生弹窗")
	for node in detail.find_children("*", "Control"):
		check(node.mouse_filter == Control.MOUSE_FILTER_IGNORE, "详情所有内容忽略鼠标，不抢候选悬停")
	check(detail.mouse_filter == Control.MOUSE_FILTER_IGNORE, "详情面板自身忽略鼠标")
	for scaled in [false, true]:
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		root.content_scale_size = Vector2i(1200, 720) if scaled else Vector2i.ZERO
		root.size = Vector2i(1800, 1080) if scaled else Vector2i(1200, 720)
		await process_frame
		await process_frame
		var viewport_size: Vector2 = root.get_visible_rect().size
		for corner in [Vector2.ZERO, Vector2(1, 0), Vector2(0, 1), Vector2.ONE]:
			_move_mouse(viewport_size / 2)
			fixture.position = Vector2(28, 28) + corner * (viewport_size - Vector2(176, 176))
			await process_frame
			await process_frame
			var button: Button = fixture.get_button("thruster")
			var point := _viewport_rect(button).get_center()
			_move_mouse(point)
			await process_frame
			await process_frame
			var rect := _viewport_rect(detail)
			check(detail.visible, "边缘真实鼠标进入仍显示详情，缩放=%s 边角=%s" % [scaled, corner])
			check(root.get_visible_rect().encloses(rect), "边缘详情完整限制在视口内，缩放=%s 边角=%s 面板=%s 视口=%s" % [scaled, corner, rect, root.get_visible_rect()])
			var expected := point + Vector2(20, 20)
			if corner.x == 1:
				expected.x = point.x - rect.size.x - 20
			if corner.y == 1:
				expected.y = point.y - rect.size.y - 20
			check(rect.position.is_equal_approx(expected), "按右下20像素偏移并独立翻转边缘，缩放=%s 边角=%s 实际=%s 预期=%s" % [scaled, corner, rect.position, expected])
			var next_point := point + Vector2(-8, -6)
			_move_mouse(next_point)
			await process_frame
			check(detail.visible and _viewport_rect(detail).position.is_equal_approx(rect.position + Vector2(-8, -6)), "翻转及缩放后仍连续跟随真实鼠标")
			_move_mouse(viewport_size / 2)
			await process_frame
			check(not detail.visible, "边缘与缩放情形移出候选均隐藏详情")
		fixture.position = Vector2(1, 1)
		await process_frame
		await process_frame
		var near_origin := Vector2(3, 3)
		_move_mouse(near_origin)
		await process_frame
		check(detail.visible and _viewport_rect(detail).position.is_equal_approx(near_origin + Vector2(20, 20)), "贴近左上角也不错误翻转或固定左上角")
		fixture.position = viewport_size - Vector2(100, 100)
		await process_frame
		await process_frame
		var edge_point := viewport_size - Vector2(6, 6)
		_move_mouse(edge_point)
		await process_frame
		check(detail.visible and root.get_visible_rect().encloses(_viewport_rect(detail)), "鼠标接近右下极限仍翻转且限制视口内")
		var overlay_transform: Transform2D = fixture.get_node("DetailLayer").transform
		fixture.get_node("DetailLayer").transform = Transform2D(0, Vector2(1.2, 1.2), 0, Vector2(17, 13))
		_move_mouse(edge_point - Vector2(4, 4))
		await process_frame
		var transformed_rect := _viewport_rect(detail)
		check(transformed_rect.end.is_equal_approx(edge_point - Vector2(24, 24)), "浮层自身画布缩放和平移后仍在视口坐标正确翻转")
		fixture.get_node("DetailLayer").transform = overlay_transform
		_move_mouse(viewport_size / 2)
		await process_frame
		check(not detail.visible, "变换浮层不会保留鼠标命中或阻止隐藏")
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(400, 320)
	fixture.position = Vector2(152, 112)
	await process_frame
	await process_frame
	_move_mouse(Vector2(200, 160))
	await process_frame
	await process_frame
	check(detail.visible and _viewport_rect(detail).position.is_equal_approx(Vector2(12, 12)), "双侧空间均不足时夹取到12像素视口边距")
	check(_viewport_rect(detail).has_point(Vector2(200, 160)), "小视口测试确实让浮层覆盖当前鼠标")
	_move_mouse(Vector2(204, 164))
	await process_frame
	check(detail.visible and root.gui_get_hovered_control() == fixture.get_button("thruster"), "鼠标位于浮层覆盖范围也保持候选hover，不发生抢占闪烁")
	fixture.queue_free()
	await process_frame
	root.size = Vector2i(1200, 720)
