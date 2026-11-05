extends SceneTree
## CG 窗口与触发调度回归：配置校验、四种播放条件、节奏推进、暂停恢复与存档状态。
var failures: int = 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func _run() -> void:
	check(ProjectSettings.globalize_path("user://").contains("space-cg-test"), "测试必须运行在隔离APPDATA")
	if failures > 0:
		quit(1)
		return
	root.get_node("BackgroundMusic").stop_music()
	var game: Node = load("res://scenes/game/star_map_demo.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame

	var window: Node = game.get_node_or_null("CgWindow")
	var cg: Node = game.get_node_or_null("CgController")
	check(window != null and window is CanvasLayer, "主场景内置 CG 窗口")
	check(cg != null, "主场景内置 CG 调度器")
	if window == null or cg == null:
		quit(1)
		return
	# 手动驱动，避免引擎每帧调用 _process 造成判定次数不确定。
	cg.set_process(false)

	# 一、窗口结构与「只含图片/文本两部分」
	check(window.layer == 45 and window.layer > game.get_node("DialogueWindow").layer, "CG 覆盖层位于对话框之上")
	check(window.has_node("Root/Image"), "CG 有图片区")
	check(window.has_node("Root/Bottom/Margin/Content/Text"), "CG 有文本区")
	check(window.get_node_or_null("Root/Portrait") == null, "CG 没有对话窗口的头像部分")
	check(window.get_node_or_null("Root/Panel") == null, "CG 没有对话窗口的面板部分")
	check(not window.visible and window.phase == window.Phase.IDLE, "未触发时不显示")

	# 二、数据接口与节奏
	window.fade_seconds = 0.0
	var started: Array = []
	var finished: Array = []
	window.cg_started.connect(func(data: Dictionary) -> void: started.append(str(data.id)))
	window.cg_finished.connect(func(data: Dictionary) -> void: finished.append(str(data.id)))
	check(not window.enqueue_cg({"id": "x", "text": "t", "duration": 1.0}), "缺少 image 拒绝入队")
	check(not window.enqueue_cg({"id": "x", "image": "", "text": "t", "duration": 1.0}), "空 image 拒绝入队")
	check(not window.enqueue_cg({"id": "x", "image": "res://a.png", "duration": 1.0}), "缺少 text 拒绝入队")
	check(not window.enqueue_cg({"id": "x", "image": "res://a.png", "text": "t", "duration": 0.0}), "duration 必须为正")
	check(not window.enqueue_cg({"id": "x", "image": "res://a.png", "text": "t", "duration": -1.0}), "duration 不能为负")
	check(window.pending_count() == 0, "非法数据不入队")

	check(window.enqueue_cg({"id": "a", "image": "res://assets/ui/tutorial_portrait.png", "text": "第一张", "duration": 0.2}), "合法 CG 入队")
	check(window.visible and window.phase == window.Phase.FADING_IN, "入队后立即淡入")
	check(started == ["a"], "开始信号带 CG id")
	window._phase_started_usec = Time.get_ticks_usec()
	window._process(0.0)
	check(window.phase == window.Phase.HOLDING, "淡入结束进入停留")
	check(window.get_node("Root/Bottom/Margin/Content/Text").text == "第一张", "文本写入文本区")
	check(window.get_node("Root/Image").texture != null, "图片载入图片区")
	window._phase_started_usec = Time.get_ticks_usec() - 1000000
	window._process(0.0)
	check(window.phase == window.Phase.FADING_OUT, "停留超时进入淡出")
	window._process(0.0)
	check(window.phase == window.Phase.IDLE and not window.visible, "淡出结束回到空闲")
	check(finished == ["a"], "完成信号带 CG id")

	# 队列：先入队的先播，一次性播完
	window.enqueue_cg({"id": "b", "image": "res://assets/ui/tutorial_portrait.png", "text": "B", "duration": 0.1})
	window.enqueue_cg({"id": "c", "image": "res://assets/ui/tutorial_portrait.png", "text": "C", "duration": 0.1})
	check(window.pending_count() == 2, "队列累计两条")
	check(window.current_cg.id == "b", "按入队顺序播放")
	window.clear_queue()
	cg._release_cg_pause()
	check(window.pending_count() == 0 and window.phase == window.Phase.IDLE, "清空队列回到空闲")

	# 图片缺失不阻断播放
	check(window.enqueue_cg({"id": "missing", "image": "res://assets/cg/not_found.png", "text": "缺图", "duration": 1.0}), "缺图仍可播放")
	check(window.get_node("Root/Image").texture == null, "缺图时保留黑底")
	window.clear_queue()
	cg._release_cg_pause()

	# 三、配置加载与校验
	cg.config_path = "res://tests/fixtures/cg.json"
	cg.bind_game(game)
	check(cg._cgs.size() == 4, "夹具四条 CG 全部载入")
	var valid: Dictionary = cg.make_state()
	check(cg.is_state_valid(valid), "空播放记录合法")
	check(not cg.is_state_valid({"version": 1, "played": {"a": false}}), "播放记录值必须是 true")
	check(not cg.is_state_valid({"version": 2, "played": {}}), "播放记录版本必须为 1")
	check(not cg.collect_errors({"version": 1, "cgs": [{"id": "bad", "image": "res://a.png", "text": "t", "duration": 1.0, "trigger": {"type": "nope"}}]}).is_empty(), "未知触发类型被拒绝")
	check(not cg.collect_errors({"version": 1, "cgs": [{"id": "bad", "image": "http://a.png", "text": "t", "duration": 1.0, "trigger": {"type": "map_enter", "map": "*"}}]}).is_empty(), "非 res:// 图片被拒绝")
	check(not cg.collect_errors({"version": 1, "cgs": [{"id": "bad", "image": "res://a.png", "text": "t", "duration": 1.0, "trigger": {"type": "reach_point", "position": [0, 0], "radius_m": 0}}]}).is_empty(), "到达地点半径必须为正")
	var duplicate_errors: Array = cg.collect_errors({"version": 1, "cgs": [
		{"id": "same", "image": "res://a.png", "text": "t", "duration": 1.0, "trigger": {"type": "map_enter", "map": "*"}},
		{"id": "same", "image": "res://a.png", "text": "t", "duration": 1.0, "trigger": {"type": "map_enter", "map": "*"}},
	]})
	check(duplicate_errors.any(func(text: String) -> bool: return text.contains("重复")), "重复 id 被拒绝")
	check(cg.collect_errors({"version": 1, "cgs": []}).is_empty(), "空列表合法")

	# 四、进入地图
	check(cg._map_matches("default_map", "default_map"), "地图名直接匹配")
	check(cg._map_matches("maps/default_map.json", "default_map"), "地图路径按文件名匹配")
	check(not cg._map_matches("plante_teach", "default_map"), "不同地图不匹配")
	check(game.load_map_file("res://maps/default_map.json"), "载入世界地图")
	cg._process(0.2)
	check(cg.played.has("map_intro"), "加载地图触发 map_enter")
	check(game.simulation_paused, "CG 播放时暂停模拟")
	window.clear_queue()
	cg._release_cg_pause()
	check(not game.simulation_paused, "CG 结束后恢复模拟")

	# 五、进入太空城（港口）
	var port: Node = game.get_node("PortController")
	var city: Node = game.cities[0]
	port.enter_port(city, game.ship)
	check(cg.played.has("city_arrive"), "入港触发 enter_object")
	port.leave_port()
	window.clear_queue()
	cg._release_cg_pause()

	# 六、完成任务
	game.quest_manager.quest_completed.emit("q_test_dock_city")
	check(cg.played.has("quest_done"), "委托完成触发 quest_complete")
	window.clear_queue()
	cg._release_cg_pause()

	# 七、到达地点（线段扫掠，高速穿过也不漏）
	game.ship.flight_position = Vector2(400000.0, -62000.0)
	cg._process(0.2)
	check(not cg.played.has("point_reach"), "远离圆心不触发")
	game.ship.flight_position = Vector2(-400000.0, -62000.0)
	cg._process(0.2)
	check(cg.played.has("point_reach"), "跨过圆范围触发 reach_point")
	window.clear_queue()
	cg._release_cg_pause()

	# once 语义：已播放的 CG 不重复
	game.ship.flight_position = Vector2(400000.0, -62000.0)
	cg._process(0.2)
	game.ship.flight_position = Vector2(-400000.0, -62000.0)
	cg._process(0.2)
	check(window.pending_count() == 0, "已播放的 CG 不重复入队")
	check(cg.played.size() == 4, "四条条件各记录一次")

	# 八、暂停语义：玩家原本暂停时，CG 结束不解除暂停
	game.simulation_paused = true
	cg._paused_for_cg = false
	cg._on_cg_started({})
	cg._on_cg_queue_finished()
	check(game.simulation_paused, "玩家原有暂停不被 CG 解除")
	game.simulation_paused = false

	# 九、存档状态往返
	var state: Dictionary = cg.make_state()
	check(cg.is_state_valid(state) and state.played.size() == 4, "播放记录可序列化")
	cg.reset_for_new_game()
	check(cg.played.is_empty() and window.pending_count() == 0, "新游戏清空播放记录")
	cg.restore_state(state)
	check(cg.played.size() == 4, "读档恢复播放记录")

	# 十、地图绑定：地图根节点 cg_data_path 决定加载哪份 CG，id 自动带地图前缀
	var loader: GDScript = load("res://scripts/navigation/map_loader.gd")
	var bound_map: Dictionary = loader.read_map("res://tests/fixtures/map_with_cg.json")
	check(not bound_map.is_empty(), "带 cg_data_path 的地图可读取")
	check(str(bound_map.get("cg_data_path", "")) == "res://data/cg/_fixture_unused.json", "地图保留自己的 cg_data_path")
	check(loader.read_map("res://tests/fixtures/map_bad_cg.json").is_empty(), "cg_data_path 含 .. 的地图被拒绝")
	check(loader.valid_cg_path("res://data/cg/default_map.json"), "合法 CG 路径放行")
	check(not loader.valid_cg_path("res://data/cg/sub/x.json"), "CG 路径不允许子目录")
	check(not loader.valid_cg_path("res://data/planets/x.json"), "CG 路径必须位于 data/cg")

	game.current_map_id = "default_map"
	game.current_cg_path = "res://tests/fixtures/cg_map.json"
	cg._sync_map_config()
	check(cg._map_cgs.size() == 2, "地图绑定的两条 CG 载入")
	check(cg._cgs.size() == 6, "全局与地图 CG 合并")
	var bound_ids: Array = cg._map_cgs.map(func(item: Dictionary) -> String: return str(item.id))
	check("default_map/map_city" in bound_ids and "default_map/map_quest" in bound_ids, "地图 CG id 带地图前缀，不与其他地图冲突")
	cg._on_quest_completed("q_test_dock_city")
	check(cg.played.has("default_map/map_quest"), "地图 CG 按 quest_complete 触发")
	window.clear_queue()
	cg._release_cg_pause()

	# 归属不一致的 CG 文件不挂到当前地图
	game.current_cg_path = "res://tests/fixtures/cg_wrong_map.json"
	cg._sync_map_config()
	check(cg._map_cgs.is_empty(), "归属不一致的 CG 文件被忽略")
	check(cg._cgs.size() == 4, "忽略后只剩全局 CG")

	game.current_cg_path = ""
	cg._sync_map_config()

	# 十一、隔离：项目真实配置保持空列表
	cg.config_path = "res://data/cg.json"
	cg._load_config()
	check(cg._cgs.is_empty(), "正式配置默认不含 CG，避免无图播放")

	if failures == 0:
		print("CG PASS")
		quit(0)
	else:
		print("CG FAIL %d" % failures)
		quit(1)
