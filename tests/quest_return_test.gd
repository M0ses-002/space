extends SceneTree
## 需复命委托（quest.requires_return）端到端测试：
## 目标达成 → 停在 awaiting_return（不发奖励）→ 回委托人处交谈 → completed 并结算奖励。
## 运行：APPDATA=<隔离目录> godot --headless --path . --script res://tests/quest_return_test.gd

var failures := 0
var completed_events: Array[String] = []
var ready_events: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

## 确定性推进一次 0.25 秒轮询：先清零累计，避免引擎帧与手动调用互相干扰。
func evaluate(manager: Node) -> void:
	manager._elapsed = 0.0
	manager._process(manager.EVAL_INTERVAL)

func _run() -> void:
	check(ProjectSettings.globalize_path("user://").contains("space-quest-return"), "测试必须运行在隔离APPDATA")
	if failures > 0:
		quit(1)
		return
	root.get_node("BackgroundMusic").stop_music()
	root.size = Vector2i(1200, 720)
	var game: Node = load("res://scenes/game/star_map_demo.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame

	var manager: Node = game.get_node_or_null("QuestManager")
	var port: Node = game.get_node("PortController")
	var save: Node = root.get_node("SaveManager")
	var quest_list: Control = game.get_node_or_null("HUD/Root/QuestList")
	check(is_instance_valid(manager), "QuestManager 挂在主场景根下")
	if not is_instance_valid(manager):
		quit(1)
		return

	var return_quest := {
		"id": "q_return_dock", "title": "带回停泊记录", "description": "在太空城停泊后回来复命。",
		"type": "dock_city", "target": "", "count": 1, "reward_credits": 300,
		"requires_return": true, "return_line": "记录我收下了。",
	}
	var plain_quest := {
		"id": "q_plain_dock", "title": "普通停泊", "description": "不需要复命。",
		"type": "dock_city", "target": "", "count": 1, "reward_credits": 50,
	}
	manager.quest_completed.connect(func(id: String) -> void: completed_events.append(id))
	manager.quest_ready_to_return.connect(func(id: String) -> void: ready_events.append(id))

	var city: Node2D = game.get_node_or_null("World/Map_city_1")
	check(city != null, "内置地图城市节点名为 Map_city_1")
	if city == null:
		quit(1)
		return
	var vessel: Node2D = game.ship
	var credits_before: int = port.session.get_credits()

	# --- 1. 接取需复命的委托并真正停泊：目标达成后停在待复命，不发奖励 ---
	check(manager.accept("a_test", "长官", return_quest), "接取需复命委托成功")
	vessel.flight_position = city.get_dock_position()
	vessel.flight_velocity = Vector2.ZERO
	vessel.crashed = false
	game._finish_city_arrival(vessel, city)
	evaluate(manager)
	var state: Dictionary = manager.state("q_return_dock")
	check(state.status == "awaiting_return", "目标达成后状态为 awaiting_return，而不是 completed")
	check(state.progress == 1 and state.required == 1, "待复命时进度已满 1/1")
	check(manager.is_awaiting_return("q_return_dock") and not manager.is_completed("q_return_dock"), "待复命不算完成")
	check(ready_events == ["q_return_dock"], "目标达成发 quest_ready_to_return")
	check(completed_events.is_empty(), "待复命期间不发 quest_completed")
	check(port.session.get_credits() == credits_before, "待复命期间不发放奖励")
	check(state.requires_return and state.person_id == "a_test", "state 带 requires_return 与委托人 id")
	var active: Array = manager.active_quests()
	check(active.size() == 1 and str(active[0].id) == "q_return_dock", "待复命委托仍留在进行中列表")

	# --- 2. HUD：待复命显示“待复命 / 回报”，不是打勾的完成态 ---
	port.leave_port()
	await process_frame
	check(quest_list != null and quest_list.visible, "待复命时任务清单仍显示")
	var row: Node = quest_list.rows.get_child(0) if quest_list.rows.get_child_count() > 0 else null
	check(row != null, "清单渲染待复命行")
	if row != null:
		check(row.get_node("Count").text == "待复命", "计数格改为「待复命」")
		check(row.get_node("Done").visible and row.get_node("Done").text == "回报", "右侧标记为「回报」")
		check(row.get_node("Bar").value == 1.0, "进度条已满")

	# --- 3. 交谈内容：有待复命时补播复命台词 ---
	# 停泊的城市可能加载另一份行星数据，找不到委托人节点时用最小记录代替（只用到 id / name）。
	var person: Dictionary = port._person_by_id("a_test")
	if str(person.get("id", "")) != "a_test":
		person = {"id": "a_test", "name": "长官", "dialogue": []}
	var pending: Array = port._pending_returns("a_test")
	check(pending.size() == 1 and str(pending[0].id) == "q_return_dock", "港口能查到此人待复命的委托")
	var lines: Array = port._conversation_lines(person)
	check(not lines.is_empty() and str(lines[lines.size() - 1]) == "记录我收下了。", "复命台词排在对话末尾：%s" % [lines])
	var other_lines: Array = port._conversation_lines({"id": "someone_else", "name": "旁人"})
	check(not other_lines.has("记录我收下了。"), "别人的对话不会播这段复命台词")

	# --- 4. 找错人、说错话都不算交任务 ---
	manager.note_talk("a_lan")
	check(manager.is_awaiting_return("q_return_dock"), "和无关人物交谈不会结算")
	check(port.session.get_credits() == credits_before, "无关交谈不发奖励")

	# --- 5. 普通委托仍然即时完成，不受新状态影响 ---
	vessel.voyage_finished = false
	vessel.arrival_source = null
	check(manager.accept("a_test", "长官", plain_quest), "接取普通委托")
	game._finish_city_arrival(vessel, city)
	evaluate(manager)
	check(manager.is_completed("q_plain_dock"), "未勾需复命的委托达成即完成")
	check(port.session.get_credits() == credits_before + 50, "普通委托奖励立刻到账")
	port.leave_port()

	# --- 6. 存档往返：待复命状态与委托人一起恢复，读档不重复发奖励 ---
	var snapshot: Dictionary = save.make_snapshot(game)
	check(save.restore_snapshot(game, snapshot), "含待复命委托的存档可恢复")
	var restored: Dictionary = manager.state("q_return_dock")
	check(restored.status == "awaiting_return" and restored.person_id == "a_test", "读档保留待复命状态与委托人")
	check(port.session.get_credits() == credits_before + 50, "读档不为待复命委托发奖励")
	check(manager.active_quests().size() == 1, "读档后待复命委托仍在清单里")

	# --- 7. 回到委托人处交谈：这一刻才完成并结算 ---
	manager.note_talk("a_test")
	check(manager.is_completed("q_return_dock"), "找委托人交谈后置为 completed")
	check(not completed_events.is_empty() and completed_events[completed_events.size() - 1] == "q_return_dock", "复命时补发 quest_completed")
	check(completed_events.count("q_return_dock") == 1, "quest_completed 只发一次")
	check(port.session.get_credits() == credits_before + 50 + 300, "复命后才发放 300 信用点")
	evaluate(manager)
	evaluate(manager)
	manager.note_talk("a_test")
	check(port.session.get_credits() == credits_before + 50 + 300, "重复交谈不会重复发奖励")
	await process_frame
	check(quest_list.rows.get_child_count() == 0 and not quest_list.visible, "全部完成后清单隐藏")

	# --- 8. talk_to_person + requires_return：说一次算达标，再说一次才复命 ---
	var talk_quest := {
		"id": "q_talk_return", "title": "当面汇报", "description": "聊完再交差。",
		"type": "talk_to_person", "target": "a_test", "count": 1,
		"reward_credits": 10, "requires_return": true,
	}
	check(manager.accept("a_test", "长官", talk_quest), "接取对话型需复命委托")
	manager.note_talk("a_test")
	check(manager.is_awaiting_return("q_talk_return"), "对话达标后先待复命（同一次对话不直接结算）")
	manager.note_talk("a_test")
	check(manager.is_completed("q_talk_return"), "再交谈一次才完成")

	# --- 9. 委托面板文案：接取前提示需复命，完成后显示已复命 ---
	var panel: Control = load("res://scenes/ports/quest_offer.tscn").instantiate()
	root.add_child(panel)
	await process_frame
	panel.open("a_test", "长官", return_quest, {}, true)
	check(panel.get_node("%Notice").text.contains("需回来复命"), "接取前提示完成后要回来复命")
	panel.open("a_test", "长官", return_quest, {"status": "completed"}, true)
	check(panel.get_node("%Notice").text.contains("已复命"), "已完成且需复命的委托显示「已复命」")
	panel.open("a_test", "长官", return_quest, {"status": "awaiting_return"}, true)
	check(panel.get_node("%Notice").text.contains("复命"), "待复命状态提示回去复命")
	panel.queue_free()

	print("QUEST_RETURN_TEST: %s (%d failures); completed=%s ready=%s" % [
		"PASS" if failures == 0 else "FAIL", failures, completed_events, ready_events])
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
