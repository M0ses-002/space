extends SceneTree
## 任务系统端到端测试：真实实例化主场景，跑接取 → 停泊/到达/对话 → 奖励 → UI → 存档。
## 运行：APPDATA=<隔离目录> godot --headless --path . --script res://tests/quest_system_test.gd

var failures := 0
var completed_events: Array[String] = []
var progress_events: Array[String] = []

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
	check(ProjectSettings.globalize_path("user://").contains("space-quest-core"), "测试必须运行在隔离APPDATA")
	if failures > 0:
		quit(1)
		return
	# 音频不属于本测试；headless dummy 后端退出时会保留循环 WAV 播放引用。
	root.get_node("BackgroundMusic").stop_music()
	root.size = Vector2i(1200, 720)
	var game: Node = load("res://scenes/game/star_map_demo.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame

	var manager: Node = game.get_node_or_null("QuestManager")
	var quest_list: Control = game.get_node_or_null("HUD/Root/QuestList")
	var port: Node = game.get_node("PortController")
	var save: Node = root.get_node("SaveManager")
	check(is_instance_valid(manager), "QuestManager 挂在主场景根下")
	check(quest_list != null and quest_list.has_node("Margin/Layout/Header") and quest_list.has_node("Margin/Layout/Scroll/Rows"), "任务清单是场景里的编辑器节点")
	if not is_instance_valid(manager) or quest_list == null:
		quit(1)
		return
	check(manager._game == game, "主场景 _ready 已 bind_game")
	check(quest_list._manager == manager, "QuestList 已绑定同一个 QuestManager")
	check(not quest_list.visible, "没有进行中任务时清单整块隐藏")
	check(manager.state("nope").is_empty(), "未知任务 state 返回空字典")

	# --- 1. planet_a.json 的委托由编辑器维护：测试只校验「能读到合法委托」，不写死具体条目 ---
	var file := FileAccess.open("res://data/planets/planet_a.json", FileAccess.READ)
	check(file != null, "能读取 planet_a.json")
	var parsed: Variant = JSON.parse_string(file.get_as_text()) if file != null else null
	check(parsed is Dictionary and parsed.get("diplomacy") is Dictionary, "planet_a.json 结构可解析")
	var person: Dictionary = {}
	if parsed is Dictionary and parsed.get("diplomacy") is Dictionary:
		for item: Variant in parsed.diplomacy.get("persons", []):
			if item is Dictionary and item.get("quests") is Array and not item.quests.is_empty():
				person = item
				break
	check(not person.is_empty(), "planet_a.json 至少存在一位带委托的人物")
	var person_id := str(person.get("id", "a_test"))
	var person_name := str(person.get("name", "测试员"))
	var data_quest: Dictionary = person.get("quests", [])[0] if not person.is_empty() else {}
	check(not str(data_quest.get("id", "")).is_empty(), "人物委托含 id")
	check(manager.TYPES.has(str(data_quest.get("type", ""))), "人物委托类型在 QuestManager 注册表内：%s" % data_quest.get("type"))
	# 后续流程用一条测试自带的 dock_city 委托，不随编辑器里的数据改动而失效。
	var dock_quest := {
		"id": "q_test_dock_city", "title": "回城交货", "description": "在任意太空城停泊。",
		"type": "dock_city", "target": "", "count": 1, "reward_credits": 200,
	}

	# --- 2. 接取与 state 字段 ---
	var credits_before: int = port.session.get_credits()
	manager.quest_completed.connect(func(id: String) -> void: completed_events.append(id))
	manager.quest_progressed.connect(func(id: String, progress: int, required: int) -> void: progress_events.append("%s:%d/%d" % [id, progress, required]))
	check(manager.accept(person_id, person_name, dock_quest), "接取停泊委托成功")
	check(manager.is_accepted("q_test_dock_city") and not manager.is_completed("q_test_dock_city"), "接取后为进行中")
	check(manager.active_quests().size() == 1, "进行中任务列表长度为 1")
	var state: Dictionary = manager.state("q_test_dock_city")
	for key in ["id", "title", "description", "type", "status", "progress", "required", "reward_credits"]:
		check(state.has(key), "state 含字段 %s" % key)
	check(state.id == "q_test_dock_city" and state.title == dock_quest.title and state.description == dock_quest.description, "state 标题与描述来自委托数据")
	check(state.type == "dock_city" and state.status == "active" and state.progress == 0 and state.required == 1, "state 进度字段初始正确")
	check(state.reward_credits == 200, "state 带奖励额度")

	# --- 3. UI：接取后显示、标题计数、折叠 ---
	await process_frame
	check(quest_list.visible, "有进行中任务时清单显示")
	check(quest_list.header.text == "任务 (1)", "标题栏显示任务数量")
	check(quest_list.rows.get_child_count() == 1, "清单渲染一行")
	var row: Node = quest_list.rows.get_child(0) if quest_list.rows.get_child_count() > 0 else null
	check(row != null, "清单第一行可访问")
	if row != null:
		check(row.get_node("Title").text == dock_quest.title, "行标题正确")
		check(row.get_node("Count").text == "0/1", "行计数显示 0/1")
		check(not row.get_node("Done").visible, "未完成时不显示完成标记")
	var body_visible: bool = quest_list.body.visible
	quest_list.header.pressed.emit()
	await process_frame
	check(quest_list.body.visible != body_visible, "点击标题栏翻转 body 可见性")
	quest_list.header.pressed.emit()
	await process_frame
	check(quest_list.body.visible == body_visible, "再次点击恢复展开")

	# --- 4. dock_city：真实停泊推进 1/1 并只结算一次奖励 ---
	var city: Node2D = game.get_node_or_null("World/Map_city_1")
	check(city != null, "内置地图城市节点名为 Map_city_1")
	var vessel: Node2D = game.ship
	vessel.flight_position = city.get_dock_position()
	vessel.flight_velocity = Vector2.ZERO
	vessel.crashed = false
	# 直接走停泊状态收尾函数，避免与正在改动中的港口 UI 互相耦合。
	game._finish_city_arrival(vessel, city)
	check(vessel.voyage_finished and vessel.arrival_source == city, "飞船进入停泊态")
	evaluate(manager)
	check(manager.state("q_test_dock_city").progress == 1, "停泊推进到 1/1")
	check(manager.is_completed("q_test_dock_city"), "进度达标后置为 completed")
	check(completed_events == ["q_test_dock_city"], "quest_completed 只发一次")
	check(progress_events.has("q_test_dock_city:1/1"), "quest_progressed 报告 1/1")
	check(port.session.get_credits() == credits_before + 200, "奖励 200 信用点真的到账")
	evaluate(manager)
	evaluate(manager)
	check(completed_events.size() == 1 and port.session.get_credits() == credits_before + 200, "完成后轮询不再重复奖励")
	await process_frame
	check(not quest_list.visible and quest_list.rows.get_child_count() == 0, "任务清空后清单整块隐藏并清行")
	# 停泊会打开港口并隐藏 HUD；离港恢复界面，后续断言才检查得到 HUD 布局。
	port.leave_port()

	# --- 4.5 install_upgrade：船坞安装装备推进委托 ---
	var install_quest := {"id": "q_install", "title": "装上护盾", "description": "在船坞装上霍普尔盾", "type": "install_upgrade", "target": "shield", "count": 1}
	check(manager.accept("a_test", "测试员", install_quest), "接取安装装备任务")
	manager.note_upgrade("fuel")
	check(manager.state("q_install").progress == 0, "装其它装备不推进")
	manager.note_upgrade("shield")
	check(manager.state("q_install").progress == 1 and manager.is_completed("q_install"), "装上指定装备推进到 1/1")
	check(not manager.accept("a_test", "测试员", {"id": "q_install_bad", "title": "坏装备", "description": "", "type": "install_upgrade", "target": "warp_drive"}), "未知装备 id 的安装任务被拒绝")
	# 真实船坞路径：重新停泊后由 PortController 安装，仍要能推进另一份委托。
	var any_install := {"id": "q_install_any", "title": "随便装一件", "description": "", "type": "install_upgrade", "target": "", "count": 1}
	check(manager.accept("a_test", "测试员", any_install), "接取任意装备任务")
	game._finish_city_arrival(vessel, city)
	check(port.active and port._get_state().shipyard_available, "重新停泊后船坞可用")
	var credits_before_yard: int = port.session.get_credits()
	port.shipyard_slot = 0
	vessel.upgrade_slots[0] = ""
	port._install_upgrade("shield")
	check(vessel.upgrade_slots[0] == "shield", "真实船坞安装护盾成功")
	check(port.session.get_credits() == credits_before_yard - 100, "安装消耗 100 信用点")
	check(manager.state("q_install_any").progress == 1 and manager.is_completed("q_install_any"), "船坞安装动作经 PortController 推进委托")
	port.leave_port()
	# 后续断言用的期望余额：奖励 200 到账后再花掉 100 改装费。
	var credits_expected: int = credits_before + 100

	# --- 5. arrive_point：latch 只在进入时计数，离开再进入才累计 ---
	vessel.voyage_finished = false
	vessel.arrival_source = null
	var target_point := Vector2(12345.0, -6789.0)
	var point_quest := {"id": "q_point", "title": "抵达补给点", "description": "飞到标记点", "type": "arrive_point", "position": [12345.0, -6789.0], "radius_m": 500.0, "count": 2, "reward_credits": 0}
	check(manager.accept("a_test", "测试员", point_quest), "接取到达点任务")
	game.ship_position = target_point + Vector2(2000.0, 0.0)
	evaluate(manager)
	check(manager.state("q_point").progress == 0, "半径外不计数")
	game.ship_position = target_point + Vector2(100.0, 0.0)
	evaluate(manager)
	check(manager.state("q_point").progress == 1, "进入半径 +1")
	evaluate(manager)
	evaluate(manager)
	check(manager.state("q_point").progress == 1, "持续停留不重复计数（latch 生效）")
	game.ship_position = target_point + Vector2(2000.0, 0.0)
	evaluate(manager)
	check(manager.state("q_point").progress == 1, "离开不解锁进度也不回退")
	game.ship_position = target_point
	evaluate(manager)
	check(manager.state("q_point").progress == 2 and manager.is_completed("q_point"), "离开再进入累计到 2/2")

	# --- 6. arrive_target：城市半径内/外，以及不存在的 target 被拒绝 ---
	var city_quest := {"id": "q_city", "title": "抵达城市", "description": "", "type": "arrive_target", "target": "city_1", "radius_m": 0, "count": 1}
	check(manager.accept("a_test", "测试员", city_quest), "接取目标城市任务")
	game.ship_position = city.flight_position + Vector2(city.docking_radius_m + 5000.0, 0.0)
	evaluate(manager)
	check(manager.state("q_city").progress == 0, "城市自身半径之外不计数")
	game.ship_position = city.flight_position + Vector2(city.docking_radius_m - 1000.0, 0.0)
	evaluate(manager)
	check(manager.state("q_city").progress == 1 and manager.is_completed("q_city"), "进入城市自身半径内 +1")
	var bad_quest := {"id": "q_bad", "title": "坏目标", "description": "", "type": "arrive_target", "target": "nope_city", "radius_m": 0}
	check(not manager.accept("a_test", "测试员", bad_quest), "不存在的 target 校验失败并拒绝接取")
	check(not manager.is_accepted("q_bad"), "被拒绝的任务不写入任务表")
	var bad_point := {"id": "q_bad_point", "title": "坏坐标", "description": "", "type": "arrive_point", "position": "x", "radius_m": 10}
	check(not manager.accept("a_test", "测试员", bad_point), "非法 arrive_point 配置被拒绝")

	# --- 7. talk_to_person：note_talk 推动进度 ---
	var talk_quest := {"id": "q_talk", "title": "与测试员交谈", "description": "", "type": "talk_to_person", "target": "a_test", "count": 2}
	check(manager.accept("a_test", "测试员", talk_quest), "接取对话任务")
	manager.note_talk("a_lan")
	check(manager.state("q_talk").progress == 0, "其他人对话不推进")
	manager.note_talk("a_test")
	check(manager.state("q_talk").progress == 1, "匹配人物对话 +1")
	manager.note_talk("a_test")
	check(manager.state("q_talk").progress == 2 and manager.is_completed("q_talk"), "对话累计到 2/2 完成")

	# --- 7b. 交谈目标可以在别的行星上：只按人物 id 匹配，不要求当前港口里有这个人 ---
	var remote_quest := {"id": "q_talk_remote", "title": "去潮汐港找人", "description": "", "type": "talk_to_person",
		"target": "b_yu", "target_name": "雨", "target_planet": "潮汐港", "count": 1}
	check(manager.accept("a_test", "测试员", remote_quest), "接取跨行星对话任务")
	var remote_state: Dictionary = manager.state("q_talk_remote")
	check(remote_state.target_name == "雨" and remote_state.target_planet == "潮汐港", "快照带出目标人物与所在地，供任务清单提示")
	manager.note_talk("b_yu")
	check(manager.is_completed("q_talk_remote"), "在别的行星与目标人物对话同样推进")

	# --- 7c. 港口侧：交谈结束时只把「正在说话的人」交给任务系统，不要求他在委托人所在行星 ---
	var remote_port_quest := {"id": "q_talk_remote_port", "title": "去城里找人", "description": "", "type": "talk_to_person",
		"target": "person_1", "target_name": "机库管理员", "target_planet": "平面核城市", "count": 1}
	check(manager.accept("a_test", "测试员", remote_port_quest), "接取指向别处港口人物的对话任务")
	port._talk_person = "person_1"
	port._talk_name = "机库管理员"
	port._talk_quests = []
	port._on_dialogue_queue_finished()
	check(manager.is_completed("q_talk_remote_port"), "在另一个港口与目标人物对话后结算")

	# --- 7d. 人物 id 跨行星重名：配了 target_planet_id 就只在同一颗星上算数 ---
	var dup_quest := {"id": "q_talk_dup", "title": "找行星 1 上的人", "description": "", "type": "talk_to_person",
		"target": "person_1", "target_planet_id": "planet_1", "count": 1}
	check(manager.accept("a_test", "测试员", dup_quest), "接取带行星的同名人物对话任务")
	manager.note_talk("person_1", "planet_2")
	check(manager.state("q_talk_dup").progress == 0, "别颗星上的同名人物对话不推进")
	manager.note_talk("person_1", "planet_1")
	check(manager.is_completed("q_talk_dup"), "同一颗星上的同名人物对话才推进")

	# --- 8. 拒绝重复与未知类型 ---
	check(not manager.accept("a_test", "测试员", dock_quest), "重复接取同一任务返回 false")
	check(not manager.accept("a_test", "测试员", {"id": "q_unknown", "title": "未知", "description": "", "type": "nope"}), "未知类型返回 false")
	check(not manager.is_accepted("q_unknown"), "未知类型不写入任务表")
	check(not manager.accept("", "", {}), "空任务返回 false 且不崩溃")
	var talk_bad := {"id": "q_talk_bad", "title": "缺目标", "description": "", "type": "talk_to_person", "count": 1}
	check(not manager.accept("a_test", "测试员", talk_bad), "缺少 target 的对话任务被拒绝")

	# --- 9. UI 计数任务：1/3 的进度条与计数标签 ---
	var ui_quest := {"id": "q_ui", "title": "巡检三处", "description": "依次进入三个补给点", "type": "arrive_point", "position": [0.0, 0.0], "radius_m": 1000.0, "count": 3}
	check(manager.accept("a_test", "测试员", ui_quest), "接取三处巡检任务")
	game.ship_position = Vector2.ZERO
	evaluate(manager)
	game.ship_position = Vector2(900000.0, 900000.0)
	await process_frame
	check(manager.state("q_ui").progress == 1, "巡检任务推进到 1/3")
	check(quest_list.visible and quest_list.rows.get_child_count() == 1, "清单只剩一条进行中任务")
	var ui_row: Node = quest_list.rows.get_child(0) if quest_list.rows.get_child_count() > 0 else null
	check(ui_row != null, "巡检任务行可访问")
	if ui_row != null:
		check(ui_row.get_node("Count").text == "1/3", "计数标签显示 1/3")
		check(ui_row.get_node("Bar").max_value == 3.0 and ui_row.get_node("Bar").value == 1.0, "进度条按 required 与 progress 渲染")
		check(not ui_row.get_node("Bar").show_percentage, "进度条不显示百分比文字")
	check(quest_list.header.text == "任务 (1)", "标题数量随进行中任务变化")

	# --- 10. HUD 布局：任务清单不遮仪表、舰队栏、右侧信息栏 ---
	await process_frame
	var list_rect: Rect2 = quest_list.get_global_rect()
	check(list_rect.size.x > 200.0 and is_equal_approx(list_rect.position.x, 8.0) and is_equal_approx(list_rect.position.y, 60.0), "任务清单锚在舰队栏下方左上角 %s" % list_rect)
	check(not list_rect.intersects(game.get_node("HUD/Root/ThrustDial").get_global_rect()), "不遮左下推力仪表")
	check(not list_rect.intersects(game.get_node("HUD/Root/FleetBar").get_global_rect()), "不遮顶部舰队栏")
	check(not list_rect.intersects(game.panel.get_global_rect()), "不遮右侧航行控制面板")
	check(not list_rect.intersects(game.get_node("HUD/Root/BottomActions").get_global_rect()), "不遮底部快捷栏")
	check(Rect2(Vector2.ZERO, Vector2(root.size)).encloses(list_rect), "任务清单完整位于窗口内")

	# --- 11. 存档往返：任务进度保留、不重发奖励 ---
	var snapshot: Dictionary = save.make_snapshot(game)
	check(snapshot.has("quest_state") and snapshot.quest_state.quests.size() >= 4, "存档快照包含任务状态")
	check(save.restore_snapshot(game, snapshot), "任务存档快照可恢复")
	var credits_after_restore: int = port.session.get_credits()
	check(manager.state("q_ui").progress == 1 and manager.is_accepted("q_ui"), "读档保留进行中任务进度")
	check(manager.is_completed("q_test_dock_city"), "读档保留已完成任务")
	check(port.session.get_credits() == credits_after_restore and credits_after_restore == credits_expected, "读档不重复发放任务奖励")
	var malformed: Dictionary = snapshot.duplicate(true)
	malformed.quest_state.quests[0].progress = 99
	check(not save.restore_snapshot(game, malformed), "非法任务存档在修改游戏前被拒绝")
	var legacy: Dictionary = snapshot.duplicate(true)
	legacy.erase("quest_state")
	check(save.restore_snapshot(game, legacy) and manager.active_quests().is_empty(), "旧存档无任务字段时清空任务且不崩溃")

	print("QUEST_SYSTEM_TEST: %s (%d failures); events=%s; isolated_user=%s" % ["PASS" if failures == 0 else "FAIL", failures, progress_events, ProjectSettings.globalize_path("user://")])
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
