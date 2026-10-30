extends SceneTree
## 可用 --headless 检查交互布局；有渲染器时额外保存三页截图。
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)
func click(button: Control) -> void:
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	Input.parse_input_event(motion)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()
func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1200, 720)
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	game._select_ship()
	var port = game.get_node("PortController")
	game.ship.voyage_finished = true
	game.ship.fuel = 1000.25
	port.enter_port(game.planets[0], game.ship)
	var view = port.view
	for window_size in [Vector2i(960, 640), Vector2i(1000, 700), Vector2i(1200, 720), Vector2i(1600, 900)]:
		root.size = window_size
		await process_frame
		await process_frame
		for tab in (["trade"] if window_size == Vector2i(960, 640) else ["events", "trade", "relations"]):
			var button_name: String = {"events": "EventsButton", "trade": "TradeButton", "relations": "RelationsButton"}[tab]
			click(view.get_node("%" + button_name))
			await process_frame
			await process_frame
			check(port.session.get_state().tab == tab, "真实点击切换页面")
			for id in ["DepartButton", button_name]:
				var rect: Rect2 = view.get_node("%" + id).get_global_rect()
				check(rect.position.x >= 0 and rect.position.y >= 0 and rect.end.x <= window_size.x + 1 and rect.end.y <= window_size.y + 1, "页面按钮在视口内")
			if tab == "trade":
				var table_rect: Rect2 = view.get_node("Margin/Layout/Pages/TradePage/Layout/List/Scroll").get_global_rect()
				var details_rect: Rect2 = view.get_node("Margin/Layout/Pages/TradePage/Layout/DetailsScroll").get_global_rect()
				check(table_rect.end.x <= details_rect.position.x, "商品列表位于交易详情左侧")
				var footer_rect: Rect2 = view.get_node("Margin/Layout/Footer").get_global_rect()
				for id in ["FuelSummary", "FuelDeltaV", "FuelQuantity", "BuyFuel", "FuelMessage", "ConfirmTrade"]:
					var rect: Rect2 = view.get_node("%" + id).get_global_rect()
					check(rect.position.x >= 0 and rect.position.y >= 0 and rect.end.x <= window_size.x + 1 and rect.end.y <= window_size.y + 1, "燃料购买控件在视口内：" + id)
					check(not rect.intersects(table_rect) and not rect.intersects(footer_rect), "燃料购买控件不覆盖商品表与页脚：" + id)
				var row = view.get_node("%TradeRows").get_child(1)
				var row_rect: Rect2 = row.get_global_rect()
				check(row_rect.position.x >= table_rect.position.x and row_rect.end.x <= table_rect.end.x + 1, "商品卡片适配列表宽度")
				var item_id: String = row.item_id
				var original_stock: int = port.session.get_state().trade_rows[0].ship_stock
				row.get_node("%Quantity").value = 1
				await process_frame
				check(not view.get_node("%ConfirmTrade").disabled, "设置数量后启用交易")
				click(view.get_node("%ConfirmTrade"))
				await process_frame
				check(port.session.get_state().trade_rows[0].id == item_id and port.session.get_state().trade_rows[0].ship_stock == original_stock + 1, "真实点击确认交易更新船舱库存")
				port.view.get_node("%FuelQuantity").value = 100
				var fuel_before: float = game.ship.fuel
				var credits_before: int = port.session.get_state().credits
				click(view.get_node("%BuyFuel"))
				await process_frame
				check(game.ship.fuel == fuel_before + 100 and port.session.get_state().credits == credits_before - 10, "真实点击补给按钮只购买一次100kg并扣10信用点")
				check(view.get_node("%FuelQuantity").value == 0 and view.get_node("%BuyFuel").disabled, "买油后数量清零并禁用再次确认")
				check(view.get_node("%FuelSummary").text.contains("10 kg / 1 信用点"), "没有有效购买量仍永久显示单价")
				click(view.get_node("%BuyFuel"))
				check(game.ship.fuel == fuel_before + 100 and port.session.get_state().credits == credits_before - 10, "真实重复点击不再扣款或赠油")
			if tab == "relations":
				for icon in view.get_node("%People").get_children():
					var rect: Rect2 = icon.get_global_rect()
					check(rect.position.x >= 0 and rect.end.x <= window_size.x and rect.end.y < window_size.y - 60, "人物图标在图谱区域内")
				var icons: Array = view.get_node("%People").get_children()
				for first in range(icons.size()):
					for second in range(first + 1, icons.size()):
						check(not icons[first].get_global_rect().intersects(icons[second].get_global_rect()), "人物卡片不互相重叠")
				click(icons[1])
				await process_frame
				check(port.session.get_state().selected_person == port.session.get_state().persons[1].id, "真实点击人物图标更新关系")
	root.size = Vector2i(1200, 720)
	await process_frame
	await process_frame
	var arguments := OS.get_cmdline_user_args()
	if not arguments.is_empty() and DisplayServer.get_name() != "headless":
		for tab in ["events", "trade", "relations"]:
			port._change_tab(tab)
			if tab == "relations":
				port._select_person(port.session.get_state().persons[0].id)
			await process_frame
			await process_frame
			await RenderingServer.frame_post_draw
			check(root.get_texture().get_image().save_png(arguments[0].path_join("space-port-" + tab + ".png")) == OK, "保存港口页截图")
	port.leave_port()
	game.queue_free()
	await process_frame
	print("PORT_VISUAL_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
