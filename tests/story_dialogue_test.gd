extends SceneTree
## 条件台词：候选顺序、when 求值、once 记账、set_flags 落标记、存档往返与旧字段兼容。
## 只测「谁在什么条件下说什么」，不重复测委托领取（那在 port_people / quest_* 里）。
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func lines_of(picked: Dictionary) -> Array:
	var out: Array = []
	for line: Variant in picked.get("lines", []):
		out.append(str(line))
	return out

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
	var story = game.get_node_or_null("StoryState")
	check(story != null, "主场景挂了 StoryState 节点")
	game.ship.voyage_finished = true
	port.enter_port(game.planets[0], game.ship)
	await process_frame

	# --- 1. 条件求值器：每个键的成立与不成立 ---
	var ctx := {
		"quests": {"q_done": "completed", "q_active": "active", "q_wait": "awaiting_return"},
		"flags": {"met": true, "left": false},
		"stage": 2,
		"planet_id": "planet_a",
		"credits": 150,
		"equipment": ["fuel"],
		"unlocked": ["hangar"],
		"visited": ["planet_a"],
		"offerable_quest": false,
	}
	check(StoryConditions.evaluate({}, ctx), "空条件无条件成立")
	check(StoryConditions.evaluate({"quests_done": ["q_done"]}, ctx), "quests_done 命中已完成")
	check(not StoryConditions.evaluate({"quests_done": ["q_active"]}, ctx), "quests_done 不接受进行中")
	check(StoryConditions.evaluate({"quests_active": ["q_done", "q_active"]}, ctx), "quests_active 任一成立")
	check(StoryConditions.evaluate({"quests_awaiting": ["q_wait"]}, ctx), "quests_awaiting 命中待复命")
	check(StoryConditions.evaluate({"quests_untouched": ["q_new"]}, ctx), "quests_untouched 命中从未接取")
	check(not StoryConditions.evaluate({"quests_untouched": ["q_done"]}, ctx), "quests_untouched 不接受已完成")
	check(StoryConditions.evaluate({"flags": {"met": true}}, ctx), "flags 匹配 true")
	check(StoryConditions.evaluate({"flags": {"left": false}}, ctx), "flags 匹配 false")
	check(not StoryConditions.evaluate({"flags": {"met": false}}, ctx), "flags 反向不成立")
	check(StoryConditions.evaluate({"stage_min": 2}, ctx), "stage_min 等于也算成立")
	check(not StoryConditions.evaluate({"stage_min": 3}, ctx), "stage_min 超过阶段不成立")
	check(StoryConditions.evaluate({"credits_min": 150}, ctx), "credits_min 等于成立")
	check(StoryConditions.evaluate({"has_equipment": ["fuel"]}, ctx), "has_equipment 命中已装")
	check(not StoryConditions.evaluate({"has_equipment": ["hangar"]}, ctx), "未安装的装备不算")
	check(StoryConditions.evaluate({"unlocked_equipment": ["hangar"]}, ctx), "unlocked_equipment 命中已解锁")
	check(StoryConditions.evaluate({"planet_id": "planet_a"}, ctx), "planet_id 匹配当前所在")
	check(not StoryConditions.evaluate({"planet_id": "planet_b"}, ctx), "planet_id 不同不成立")
	check(StoryConditions.evaluate({"visited": ["planet_a"]}, ctx), "visited 命中去过的地方")
	check(StoryConditions.evaluate({"offerable_quest": false}, ctx), "offerable_quest 匹配 false")
	check(StoryConditions.evaluate({"quests_done": ["q_done"], "stage_min": 1, "flags": {"met": true}}, ctx), "多个键 AND 成立")
	check(not StoryConditions.evaluate({"quests_done": ["q_done"], "stage_min": 9}, ctx), "任一键不成立即整体不成立")
	check(not StoryConditions.evaluate({"typo_key": ["x"]}, ctx), "未知条件键直接不成立，不会误命中")

	# --- 2. 候选匹配：顺序、once、set_flags ---
	var person := {
		"id": "p_story", "name": "测试员", "quests": [],
		"speech": [
			{"id": "after", "when": {"flags": {"talked": true}}, "lines": ["阶段之后的台词"], "once": true},
			{"id": "first", "when": {"offerable_quest": false}, "lines": ["初次见面"], "once": true, "set_flags": {"talked": true}},
			{"id": "idle", "lines": ["兜底招呼"]},
		],
	}
	var first: Dictionary = port._pick_speech(person)
	check(lines_of(first) == ["初次见面"], "按数组顺序取第一条成立的：%s" % str(lines_of(first)))
	check(str(first.get("key", "")) == "p_story/first", "命中的键是 person_id/speech_id")
	check(not bool(first.get("legacy", true)), "speech 走的是新路径")
	port._commit_speech(first)
	check(story.has_flag("talked"), "set_flags 写入剧情标记")
	check(story.is_seen("p_story/first"), "once 条目记账")

	var second: Dictionary = port._pick_speech(person)
	check(lines_of(second) == ["阶段之后的台词"], "标记生效后换到下一条：%s" % str(lines_of(second)))
	port._commit_speech(second)
	var third: Dictionary = port._pick_speech(person)
	check(lines_of(third) == ["兜底招呼"], "没有 once 的条目可以重复命中")
	port._commit_speech(third)
	check(not story.is_seen("p_story/idle"), "非 once 条目不记账")
	check(lines_of(port._pick_speech(person)) == ["兜底招呼"], "兜底条目每次都还能说")

	# --- 2b. 真实数据：planet_a 的 a_test 在任务完成后换台词 ---
	var real_person: Dictionary = {}
	for candidate: Dictionary in port.session.get_state().get("persons", []):
		if str(candidate.get("id", "")) == "a_test":
			real_person = candidate
			break
	check(not real_person.is_empty(), "真实数据里有 a_test")
	if not real_person.is_empty():
		var before: Dictionary = port._pick_speech(real_person)
		check(str(before.get("key", "")) == "a_test/test_offer", "未接委托时命中推销台词：%s" % str(before.get("key", "")))
		check(lines_of(before).has("这里有一份委托：去平面核城市找机库管理员聊聊。"), "推销台词内容正确")
		var manager: Node = game.get_node_or_null("QuestManager")
		var quest_data: Dictionary = {}
		for quest: Dictionary in real_person.get("quests", []):
			if str(quest.get("id", "")) == "q_test_dock_city":
				quest_data = quest.duplicate(true)
		check(not quest_data.is_empty(), "a_test 身上有 q_test_dock_city")
		if manager != null and not quest_data.is_empty():
			check(bool(manager.accept("a_test", "长官", quest_data)), "接取 q_test_dock_city")
			manager.call("_complete", "q_test_dock_city", manager._quests["q_test_dock_city"])
			var after: Dictionary = port._pick_speech(real_person)
			check(str(after.get("key", "")) == "a_test/test_thanked", "完成任务后命中新台词：%s" % str(after.get("key", "")))
			check(lines_of(after).has("你回来得正好。机库那边说有人来问过，我就知道这趟有戏。"), "新台词内容正确")

	# --- 3. 一条都不成立就安静，不回落到旧字段 ---
	var silent := {"id": "p_silent", "name": "沉默者", "dialogue": ["老台词"], "speech": [
		{"id": "never", "when": {"flags": {"nobody": true}}, "lines": ["不会出现"]},
	]}
	check(lines_of(port._pick_speech(silent)).is_empty(), "speech 全不成立时不回落到 dialogue")
	check(not bool(port._pick_speech(silent).get("legacy", true)), "仍标记为新路径")

	# --- 4. 没写 speech 的老数据走旧路径 ---
	var legacy := {"id": "p_old", "name": "老角色", "dialogue": ["老招呼"], "quest_greeting": ["有份活"]}
	var legacy_picked: Dictionary = port._pick_speech(legacy)
	check(bool(legacy_picked.get("legacy", false)), "无 speech 时走旧路径")
	check(lines_of(legacy_picked).has("老招呼"), "旧路径保留 dialogue")
	check(not lines_of(legacy_picked).has("有份活"), "没有可接委托时不补播委托台词")

	# --- 5. 剧情状态存档往返 ---
	var state = story.make_state()
	check(story.is_state_valid(state), "剧情状态自校验通过")
	var copy = load("res://scripts/story/story_state.gd").new()
	copy.restore_state(state)
	check(copy.has_flag("talked"), "标记随存档恢复")
	check(copy.is_seen("p_story/first"), "已播台词随存档恢复")
	check(copy.has_visited(session_planet(port)), "进港记下了 visited")
	copy.reset()
	check(not copy.has_flag("talked") and not copy.is_seen("p_story/first"), "reset 清空全部状态")
	copy.restore_state({"version": 1, "flags": {}, "seen": [1], "visited": []})
	check(not copy.has_flag("talked"), "非法状态整体拒绝，不会灌半套数据")
	check(not copy.is_state_valid({"version": 9, "flags": {}, "seen": [], "visited": []}), "版本不符判非法")

	# --- 6. 快照确实带上剧情状态（回档点复用同一份快照） ---
	var saves := root.get_node_or_null("SaveManager")
	check(saves != null, "SaveManager 自动加载存在")
	var snapshot: Dictionary = saves.make_snapshot(game) if saves != null else {}
	check(snapshot.has("story_state"), "存档快照包含 story_state")
	check(int(snapshot.get("version", 0)) == 6, "存档版本升到 6：%s" % str(snapshot.get("version")))
	check(snapshot.story_state.get("flags", {}).has("talked"), "快照里带着标记")

	print("STORY_DIALOGUE_TEST: %s (%d checks)" % ["FAIL" if failures > 0 else "PASS", checks])
	quit(1 if failures > 0 else 0)

func session_planet(port) -> String:
	return str(port.session.planet_id())
