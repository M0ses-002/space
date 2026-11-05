extends SceneTree
## 港口人物页：散列头像、真实点击对话、对话结束后领取委托、重复接取防护。
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func click(control: Control) -> void:
	var point := control.get_global_rect().get_center()
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

func icon_of(view: Node, person_id: String) -> Button:
	for icon in view.get_node("%People").get_children():
		if icon.person_id == person_id:
			return icon
	return null

func wait_dialogue(dialogue: Node, limit: float) -> bool:
	var elapsed := 0.0
	while dialogue.pending_count() > 0 and elapsed < limit:
		await create_timer(0.1).timeout
		elapsed += 0.1
	return dialogue.pending_count() == 0

func press_escape() -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = KEY_ESCAPE
		event.physical_keycode = KEY_ESCAPE
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()

## 开面板前都要先走一次「点头像 → 对话结束」，这里抽出来复用。
func reopen_offer(view: Node, dialogue: Node, person_id: String) -> bool:
	click(icon_of(view, person_id))
	await process_frame
	dialogue.clear_queue()
	dialogue.queue_finished.emit()
	await process_frame
	return view.is_quest_offer_open()

func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1200, 720)
	var game = load("res://scenes/game/main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	game._select_ship()
	var port = game.get_node("PortController")
	var view = port.view
	var session = port.session
	var dialogue = game.get_node("DialogueWindow")
	game.ship.voyage_finished = true
	port.enter_port(game.planets[0], game.ship)
	await process_frame
	await process_frame

	# 1. 关系数据与连线彻底消失。
	var state: Dictionary = session.get_state()
	check(not state.has("relations"), "会话状态不再输出 relations")
	for person: Dictionary in state.persons:
		check(not person.has("relation"), "人物不再携带 relation 字段：%s" % str(person.get("id", "")))
	check(not state.persons.is_empty(), "港口至少有一位人物")
	# 人物与委托都由 data/planets/*.json 决定，测试按实际数据挑选，不写死人数或 id。
	var quest_person_id := ""
	var quest_id := ""
	var quest_title := ""
	var quest_reward := 0
	var plain_person_id := ""
	for person: Dictionary in state.persons:
		var quests: Array = person.get("quests", [])
		if quests.is_empty():
			if plain_person_id.is_empty():
				plain_person_id = str(person.id)
			continue
		if quest_person_id.is_empty():
			quest_person_id = str(person.id)
			quest_id = str(quests[0].get("id", ""))
			quest_title = str(quests[0].get("title", ""))
			quest_reward = int(quests[0].get("reward_credits", 0))
	check(not quest_person_id.is_empty() and not quest_id.is_empty(), "数据中至少有一位可发放委托的人物")
	for node in view.find_children("*", "Line2D", true, false):
		check(false, "人物页不再创建关系连线：%s" % str(node.name))
	check(view.get_node_or_null("%Edges") == null and view.get_node_or_null("%GraphArea") == null, "旧图谱容器已移除")

	# 2. 头像散列网格：卡片数量随人物数据、不重叠、当前窗口完整可见。
	port._change_tab("relations")
	await process_frame
	await process_frame
	var people = view.get_node("%People")
	check(people is GridContainer, "%People 是 GridContainer")
	check(people.columns == 4, "网格固定 4 列")
	var icons: Array = people.get_children()
	check(icons.size() == state.persons.size(), "头像卡片数量与人物数据一致")
	var scroll: ScrollContainer = view.get_node("%GraphScroll")
	check(scroll.get_global_rect().encloses(people.get_global_rect()), "1200x720 下网格无需滚动即可完整看到")
	for first in range(icons.size()):
		var a: Rect2 = icons[first].get_global_rect()
		check(Rect2(Vector2.ZERO, Vector2(root.size)).encloses(a), "卡片在视口内：%s" % str(icons[first].name))
		for second in range(first + 1, icons.size()):
			var b: Rect2 = icons[second].get_global_rect()
			check(not a.intersects(b), "人物卡片不重叠：%d-%d" % [first, second])
	check(view.get_node("%PersonsEmpty").visible == false, "有数据时不显示空态")
	# 窄窗口回退：网格总高度超过可视区域时由 ScrollContainer 滚动到达，而不是重叠。
	root.size = Vector2i(900, 600)
	await process_frame
	await process_frame
	var narrow_scroll: Rect2 = scroll.get_global_rect()
	var narrow_grid: Rect2 = people.get_global_rect()
	check(narrow_scroll.encloses(narrow_grid) or narrow_grid.size.y > narrow_scroll.size.y, "窄窗口靠滚动承载超出的卡片")
	root.size = Vector2i(1200, 720)
	await process_frame
	await process_frame

	# 3. 真实点击带委托的人物卡片 → 对话窗口出现。
	var test_icon := icon_of(view, quest_person_id)
	check(test_icon != null, "找到带委托的人物卡片")
	dialogue.clear_queue()
	click(test_icon)
	await process_frame
	check(session.get_state().selected_person == quest_person_id, "点击头像选中该人物")
	check(dialogue.visible and dialogue.pending_count() > 0, "点击头像打开对话窗口并排队台词")

	# 4. 对话播完后弹出任务领取面板。
	var finished := await wait_dialogue(dialogue, 25.0)
	check(finished, "对话队列真实播完")
	await process_frame
	await process_frame
	check(view.is_quest_offer_open(), "对话结束后出现任务领取面板")
	var offer = view.get_node("%QuestOffer")
	var accept: Button = offer.get_node("%AcceptButton")
	check(offer.get_node("%Title").text == quest_title, "面板显示委托标题")
	check(offer.get_node("%Reward").text.contains(str(quest_reward)), "面板显示奖励信用点")
	var arguments := OS.get_cmdline_user_args()
	if not arguments.is_empty() and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png(str(arguments[0]).path_join("space-port-quest-offer.png")) == OK, "保存任务领取面板截图")

	# 4b. Esc / ✕ 只关面板、不改委托状态；面板是模态的，Esc 不能连带打开暂停菜单。
	var pause_menu = game.get_node_or_null("PauseMenu")
	press_escape()
	await process_frame
	check(not view.is_quest_offer_open(), "Esc 关闭委托面板")
	if pause_menu != null:
		check(not pause_menu.is_open(), "Esc 关面板时不打开暂停菜单")
	check(await reopen_offer(view, dialogue, quest_person_id), "再次对话后面板重新打开")
	var close_button: Button = offer.get_node("%CloseButton")
	check(close_button.is_visible_in_tree(), "委托面板有右上角关闭按钮")
	click(close_button)
	await process_frame
	check(not view.is_quest_offer_open(), "点击 ✕ 关闭委托面板")
	check(await reopen_offer(view, dialogue, quest_person_id), "穿透测试前面板已打开")

	# 4c. 委托介绍语只在「这次真能领到委托」时补播：speech 的 offerable_quest 条目或旧 quest_greeting。
	var talk_person: Dictionary = {}
	for person: Dictionary in state.persons:
		if str(person.id) == quest_person_id:
			talk_person = person
			break
	var greet_line := ""
	for entry: Variant in talk_person.get("speech", []):
		if not (entry is Dictionary):
			continue
		var when: Variant = entry.get("when", {})
		if when is Dictionary and bool((when as Dictionary).get("offerable_quest", false)):
			var offer_lines: Variant = entry.get("lines", [])
			if offer_lines is Array and not (offer_lines as Array).is_empty():
				greet_line = str(offer_lines[0])
				break
	var greeting: Array = talk_person.get("quest_greeting", [])
	if greet_line.is_empty() and not greeting.is_empty():
		greet_line = str(greeting[0])
	var lines_before_accept: Array = port._conversation_lines(talk_person)
	if not greet_line.is_empty():
		check(lines_before_accept.has(greet_line), "有可接委托时补播委托介绍语")
	check(port._conversation_lines({"id": "nobody", "name": "路人", "quest_greeting": ["有份活给你"]}).has("有份活给你") == false,
		"没有委托可接时不播委托台词")

	# 5. 面板是模态：点击其他头像不会穿透。
	var before_person: String = str(session.get_state().selected_person)
	var other_person_id := ""
	for person: Dictionary in state.persons:
		if str(person.id) != quest_person_id:
			other_person_id = str(person.id)
			break
	if not other_person_id.is_empty():
		click(icon_of(view, other_person_id))
		await process_frame
		check(session.get_state().selected_person == before_person, "委托面板打开时头像点击不穿透")

	# 6. 接受委托（QuestManager 未就绪时只校验降级表现）。
	var manager: Node = game.get_node_or_null("QuestManager")
	if manager == null:
		check(accept.disabled, "任务系统缺失时接受按钮置灰")
		check(offer.get_node("%Notice").text.contains("未就绪"), "提示任务系统未就绪")
	else:
		check(not accept.disabled, "任务系统就绪时接受按钮可用")
		click(accept)
		await process_frame
		await process_frame
		var status: Dictionary = manager.state(quest_id)
		check(str(status.get("status", "")) == "active", "接受后委托进入 active：%s" % str(status))
		check(accept.disabled, "接取后接受按钮不可再点")
		check(offer.get_node("%Notice").text.contains("已接取"), "面板提示已接取")
		check(not bool(manager.accept(quest_person_id, "测试员", {"id": quest_id})), "重复接取被拒绝")
		check(int(manager.state(quest_id).get("progress", -1)) == int(status.get("progress", 0)), "重复接取不改变进度")

	# 7. 放弃面板后点击无委托人物：对话结束不弹面板。
	click(offer.get_node("%DeclineButton"))
	await process_frame
	check(not view.is_quest_offer_open(), "放弃后关闭面板")

	# 7b. 已接取后再对话：这份委托不再重复出现（该人物没有别的可接委托，就不弹面板）。
	if manager != null:
		check(port._pick_quest([{"id": quest_id}]).is_empty(), "已接取的委托不再被挑选")
		if not greet_line.is_empty():
			check(not port._conversation_lines(talk_person).has(greet_line), "已接取后不再补播委托介绍语")
		click(icon_of(view, quest_person_id))
		await process_frame
		check(dialogue.visible, "已接取的人物仍可再次对话")
		dialogue.clear_queue()
		dialogue.queue_finished.emit()
		await process_frame
		check(not view.is_quest_offer_open(), "已接取的委托不再弹面板")

	# 7e. 该人物的委托全被领走 / 办完之后，交谈结束不再弹委托面板。
	if manager != null:
		var person_quests: Array = []
		for person: Dictionary in state.persons:
			if str(person.id) == quest_person_id:
				person_quests = person.get("quests", [])
				break
		for quest: Dictionary in person_quests:
			if str(manager.state(str(quest.get("id", ""))).get("status", "")).is_empty():
				manager.accept(quest_person_id, "测试员", quest.duplicate(true))
		# 直接把已接取的那份结算成 completed，覆盖「已完成」这一路的判定。
		manager.call("_complete", quest_id, manager._quests[quest_id])
		check(manager.is_completed(quest_id), "测试把委托结算成 completed")
		click(icon_of(view, quest_person_id))
		await process_frame
		check(dialogue.visible, "委托全部处理完后仍能正常对话")
		dialogue.clear_queue()
		dialogue.queue_finished.emit()
		await process_frame
		check(not view.is_quest_offer_open(), "已领取/已完成的委托不再弹面板")

	if not plain_person_id.is_empty():
		var plain_icon := icon_of(view, plain_person_id)
		click(plain_icon)
		await process_frame
		check(dialogue.visible and dialogue.pending_count() > 0, "无委托人物同样开始对话")
		dialogue.clear_queue()
		dialogue.queue_finished.emit()
		await process_frame
		check(not view.is_quest_offer_open(), "没有委托的人物对话结束不弹面板")

	# 8. 会话与港口回归：起航仍然可用且清掉未完成交谈。
	# 起航要求原轨道参考有效，这里直接给出一条可离港的行星轨道。
	var source = game.planets[0]
	game.ship.arrival_source = source
	game.ship.departure_position = source.flight_position + Vector2(0, 60000)
	port._request_departure()
	await process_frame
	check(not port.active, "人物对话改动后起航仍可用")
	game.queue_free()
	await process_frame
	print("PORT_PEOPLE_TEST: %s (%d checks)" % ["PASS" if failures == 0 else "FAIL", checks])
	quit(0 if failures == 0 else 1)
