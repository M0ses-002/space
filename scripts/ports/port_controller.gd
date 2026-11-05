extends CanvasLayer
## 航行与港口的适配层，负责场景生命周期、信号转发与人物对话→领取委托的流程。
## 入港成功后发出 port_entered，供 CG 等外部系统按地图对象 id 判定「进入行星/太空城」。
signal port_entered(object_id: String, source: Node2D)
const Session = preload("res://scripts/ports/port_session.gd")
const PORT_LINE_MIN := 2.0
const PORT_LINE_MAX := 5.5
var session = Session.new()
var active := false
var game: Node
var docked_ship: Node2D
var saved_nodes: Array[Dictionary] = []
var shipyard_slot := 0
var shipyard_notice := "请选择槽位和改装。"
# 一次港口交谈的状态：正在播报的人物与交谈结束后要展示的委托。
var _talk_person := ""
var _talk_name := ""
var _talk_quests: Array = []
@onready var view = $PortView

func _ready() -> void:
	visible = false
	view.depart_requested.connect(_request_departure)
	view.tab_requested.connect(_change_tab)
	view.event_selected.connect(_select_event)
	view.person_selected.connect(_select_person)
	view.shipyard_slot_selected.connect(_select_shipyard_slot)
	view.upgrade_requested.connect(_install_upgrade)
	view.upgrade_remove_requested.connect(_remove_upgrade)
	view.quest_accept_requested.connect(_accept_quest)

func bind_game(owner_game: Node) -> void:
	game = owner_game
	var dialogue := _dialogue_window()
	if dialogue != null and not dialogue.queue_finished.is_connected(_on_dialogue_queue_finished):
		dialogue.queue_finished.connect(_on_dialogue_queue_finished)

func enter_port(source: Node2D, vessel: Node2D) -> void:
	if active:
		return
	game._clear_object_inspection()
	docked_ship = vessel
	shipyard_slot = 0
	shipyard_notice = "请选择槽位和改装。"
	_end_conversation()
	view.hide_quest_offer()
	session.open_planet(source.interaction_data_path)
	# 进港即记为「到过这里」：对话条件里的 visited 靠它，读档时也会被快照覆盖回来。
	var story := _story_state()
	if story != null:
		story.call("mark_visited", session.planet_id())
	# 保留航行树及其他舰船模拟；屏蔽隐藏界面的处理与所有相机快捷键。
	for path in ["World", "HUD", "StarMapView", "StarMapView/HUD", "NavigationCamera"]:
		var node: Node = game.get_node(path)
		var entry: Dictionary = {"node": node, "process_mode": node.process_mode}
		if node is CanvasItem or node is CanvasLayer:
			entry["visible"] = node.visible
			node.hide()
		if path != "World":
			node.process_mode = Node.PROCESS_MODE_DISABLED
		saved_nodes.append(entry)
	active = true
	visible = true
	refresh()
	port_entered.emit(_map_object_id(source), source)

## 地图加载时节点名是 Map_<对象id>；编辑器布景节点保持原名。
func _map_object_id(source: Node) -> String:
	if not is_instance_valid(source):
		return ""
	var node_name := str(source.name)
	return node_name.trim_prefix("Map_") if node_name.begins_with("Map_") else node_name

func leave_port() -> void:
	visible = false
	active = false
	docked_ship = null
	_end_conversation()
	view.hide_quest_offer()
	for entry in saved_nodes:
		var node = entry.node
		if is_instance_valid(node):
			node.process_mode = entry.process_mode
			if entry.has("visible"):
				node.visible = entry.visible
	saved_nodes.clear()

func refresh() -> void:
	if active:
		view.render(_get_state())

func _is_docked() -> bool:
	return active and is_instance_valid(docked_ship) and docked_ship.voyage_finished

func _get_state() -> Dictionary:
	var state: Dictionary = session.get_state()
	state["shipyard_available"] = _is_docked() and game.cities.has(docked_ship.arrival_source)
	state["shipyard_slot"] = shipyard_slot
	state["shipyard_notice"] = shipyard_notice
	state["slot_upgrades"] = session.get_slot_upgrades(shipyard_slot)
	state["departure_warning"] = "停泊中 · 起航自动补满燃料，无需结算。"
	if is_instance_valid(docked_ship):
		state["ship_name"] = docked_ship.display_name
		state["upgrade_slots"] = docked_ship.upgrade_slots.duplicate()
		state["shield_ready"] = docked_ship.shield_ready
	return state

func _select_shipyard_slot(slot: int) -> void:
	if is_instance_valid(docked_ship) and slot >= 0 and slot < docked_ship.upgrade_slots.size():
		shipyard_slot = slot
		refresh()

func _install_upgrade(id: String) -> void:
	if not _get_state().shipyard_available:
		return
	if session.install_upgrade(docked_ship, shipyard_slot, id, true):
		shipyard_notice = _install_notice(id)
		# 安装成功即视为一次任务事件；装哪件由任务自身的 target 过滤，这里不做判断。
		var manager := _quest_manager()
		if manager != null and manager.has_method("note_upgrade"):
			manager.note_upgrade(id)
	elif not session.is_unlocked(id):
		shipyard_notice = "「%s」尚未解锁：完成对应委托后才能安装。" % EquipmentCatalog.display_name(id)
	else:
		shipyard_notice = "无法安装：槽位已占用、同类已安装或信用点不足（需要 100）。"
	refresh()


## 安装成功的提示。机库这类会解锁新按钮的装备必须说清楚解锁了什么，
## 否则起飞前在船坞里看不出任何变化，像是没生效。
func _install_notice(id: String) -> String:
	if id == "hangar":
		var names: Array[String] = []
		for kind: String in EquipmentCatalog.values("hangar").get("drones", {}):
			names.append(EquipmentCatalog.text_from(EquipmentCatalog.drone_def(kind), "name", kind))
		if not names.is_empty():
			return "已安装机库：%s已加入船载装置栏，起航后可用（工程机需行星引力区）。" % " / ".join(names)
	return "改装已安装或护盾已重充，消耗信用点。"


## 拆除：先清会话层状态，再让航行侧收掉对应功能与实例，避免"装备没了功能还在"。
func _remove_upgrade() -> void:
	if not _get_state().shipyard_available:
		return
	if not is_instance_valid(docked_ship) or shipyard_slot < 0 or shipyard_slot >= docked_ship.upgrade_slots.size():
		return
	var id := str(docked_ship.upgrade_slots[shipyard_slot])
	if id.is_empty():
		shipyard_notice = "槽位 %d 本来就没有装东西。" % (shipyard_slot + 1)
		refresh()
		return
	if not session.remove_upgrade(docked_ship, shipyard_slot, true):
		shipyard_notice = "无法拆除：槽位 %d 没有可拆的装备。" % (shipyard_slot + 1)
		refresh()
		return
	if game != null and game.has_method("on_equipment_removed"):
		game.on_equipment_removed(id)
	shipyard_notice = "已拆除「%s」：对应功能与快捷栏按钮一并失效（不返还信用点）。" % EquipmentCatalog.display_name(id)
	refresh()

func can_depart(vessel: Node2D) -> bool:
	return is_instance_valid(vessel) and vessel.voyage_finished and (not active or docked_ship == vessel)

func _request_departure() -> void:
	if not active or not is_instance_valid(docked_ship):
		return
	# 起航优先于未播完的人物对话：先撤销待领取的委托，再走航行模型。
	_end_conversation()
	view.hide_quest_offer()
	# 港口期间不可切船；所有起航资格仍由航行模型校验。
	game._depart()
	if active:
		var state: Dictionary = _get_state()
		state["error"] = game.flight_message
		view.render(state)

func _change_tab(tab: String) -> void:
	session.set_tab(tab)
	refresh()

func _select_event(id: String) -> void:
	session.select_event(id)
	refresh()

func _select_person(id: String) -> void:
	# 对话与委托面板期间不再响应头像点击，避免叠对话或隔着面板选中人物。
	if not _talk_person.is_empty() or view.is_quest_offer_open():
		return
	var person := _person_by_id(id)
	if person.is_empty():
		return
	session.select_person(id)
	refresh()
	_start_conversation(person)

func _person_by_id(id: String) -> Dictionary:
	for person: Dictionary in session.get_state().get("persons", []):
		if str(person.get("id", "")) == id:
			return person
	return {}

func _start_conversation(person: Dictionary) -> void:
	var dialogue := _dialogue_window()
	if dialogue == null:
		return
	var picked := _pick_speech(person)
	var lines: Array = picked.get("lines", [])
	if lines.is_empty():
		return
	# 只有港口交谈才接管弹窗的点击，教程对话仍保持原有行为。
	if dialogue.panel != null:
		dialogue.panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var portrait := str(person.get("portrait", ""))
	var queued := 0
	for line in lines:
		var duration := clampf(1.4 + 0.05 * float(line.length()), PORT_LINE_MIN, PORT_LINE_MAX)
		if dialogue.enqueue_dialogue({"text": line, "duration": duration, "portrait": portrait}):
			queued += 1
	if queued == 0:
		return
	# 真正入队之后才记账：单纯求值（预览、测试）不该把一次性台词标成已播。
	_commit_speech(picked)
	_talk_person = str(person.get("id", ""))
	_talk_name = str(person.get("name", ""))
	var quests: Array = person.get("quests", [])
	_talk_quests = quests.duplicate(true)

## 本次交谈要说的话。注意这里有两条路：
## - 人物写了 speech：完全由候选表决定，按数组顺序取第一条 when 成立的（once 播过就跳过）；
## - 没写 speech：沿用 dialogue + quest_greeting + 复命台词的老行为，老数据零迁移。
func _conversation_lines(person: Dictionary) -> Array[String]:
	var lines: Array[String] = []
	for line: Variant in _pick_speech(person).get("lines", []):
		lines.append(str(line))
	return lines

func _pick_speech(person: Dictionary) -> Dictionary:
	var speech := _person_speech(person)
	if speech.is_empty():
		return {"lines": _legacy_lines(person), "entry": {}, "key": "", "legacy": true}
	var person_id := str(person.get("id", ""))
	var story := _story_state()
	var ctx := _story_context(person)
	for index in range(speech.size()):
		var item: Variant = speech[index]
		if not (item is Dictionary):
			continue
		var entry: Dictionary = item
		var lines := _text_lines(entry.get("lines", []))
		if lines.is_empty():
			continue
		var key := "%s/%s" % [person_id, _speech_id(entry, index)]
		if bool(entry.get("once", false)) and story != null and bool(story.call("is_seen", key)):
			continue
		if not StoryConditions.evaluate(entry.get("when", {}), ctx):
			continue
		return {"lines": lines, "entry": entry, "key": key, "legacy": false}
	# 写了 speech 就完全接管：一条都不成立就安静地不说话，不回落到旧字段。
	return {"lines": [], "entry": {}, "key": "", "legacy": false}

## 一次性记账与标记写入。只有台词真的进了播放队列才调用。
func _commit_speech(picked: Dictionary) -> void:
	if bool(picked.get("legacy", true)):
		return
	var story := _story_state()
	if story == null:
		return
	var entry: Dictionary = picked.get("entry", {})
	var flags: Variant = entry.get("set_flags", {})
	if flags is Dictionary:
		for name: Variant in (flags as Dictionary).keys():
			story.call("set_flag", str(name), bool(flags[name]))
	if bool(entry.get("once", false)):
		story.call("mark_seen", str(picked.get("key", "")))

## 条件求值用的扁平快照：任务状态、剧情标记、阶段、所在地、经济与装备。
func _story_context(person: Dictionary) -> Dictionary:
	var manager := _quest_manager()
	var story := _story_state()
	var progression := _progression_manager()
	var equipped: Array[String] = []
	if is_instance_valid(docked_ship):
		for id: Variant in docked_ship.upgrade_slots:
			var text := str(id).strip_edges()
			if not text.is_empty():
				equipped.append(text)
	var quests: Dictionary = {}
	if manager != null and manager.has_method("status_map"):
		var table: Variant = manager.call("status_map")
		quests = table if table is Dictionary else {}
	return {
		"quests": quests,
		"flags": story.call("get_flags") if story != null else {},
		"stage": int(progression.get("stage")) if progression != null else 0,
		"planet_id": session.planet_id(),
		"credits": session.get_credits(),
		"equipment": equipped,
		"unlocked": session.get_unlocked_equipment(),
		"visited": story.call("visited_list") if story != null else [],
		"offerable_quest": not _pick_quest(person.get("quests", [])).is_empty(),
	}

## 旧路径：招呼语 + （有委托可接时的委托台词）+ （待复命时的复命台词）。
func _legacy_lines(person: Dictionary) -> Array[String]:
	var lines := _lines_for(person)
	var person_id := str(person.get("id", ""))
	var pending := _pending_returns(person_id)
	# 有委托可接才提"有活给你"；已接取、待复命、已完成的都不该再重复介绍旧委托。
	if pending.is_empty() and not _pick_quest(person.get("quests", [])).is_empty():
		for line in _quest_greeting_lines(person):
			lines.append(line)
	for awaiting: Dictionary in pending:
		var line := str(awaiting.get("return_line", "")).strip_edges()
		if line.is_empty():
			line = "「%s」的事，办妥了？" % str(person.get("name", ""))
		lines.append(line)
	return lines

func _person_speech(person: Dictionary) -> Array:
	var raw: Variant = person.get("speech", [])
	return raw if raw is Array else []

func _speech_id(entry: Dictionary, index: int) -> String:
	var id := str(entry.get("id", "")).strip_edges()
	return id if not id.is_empty() else "speech_%d" % index

## 台词数组统一按「字符串或字符串数组」解析，写单个字符串也认。
func _text_lines(value: Variant) -> Array[String]:
	var lines: Array[String] = []
	if value is String:
		value = [value]
	if not value is Array:
		return lines
	for line: Variant in value:
		if line is String and not str(line).strip_edges().is_empty():
			lines.append(str(line))
	return lines

## 可选字段 quest_greeting：只在「这次能领到新委托」时补播，避免任务接完之后还在推销。
func _quest_greeting_lines(person: Dictionary) -> Array[String]:
	var lines: Array[String] = []
	var raw: Variant = person.get("quest_greeting", [])
	if raw is String:
		raw = [raw]
	if not raw is Array:
		return lines
	for line: Variant in raw:
		if line is String and not str(line).strip_edges().is_empty():
			lines.append(str(line))
	return lines

func _lines_for(person: Dictionary) -> Array[String]:
	var lines: Array[String] = []
	var raw: Array = person.get("dialogue", [])
	for line: Variant in raw:
		if line is String and not str(line).strip_edges().is_empty():
			lines.append(str(line))
	if lines.is_empty():
		lines.append("「%s」%s" % [str(person.get("name", "")), str(person.get("description", ""))])
	return lines

func _on_dialogue_queue_finished() -> void:
	if _talk_person.is_empty():
		return
	var person_id := _talk_person
	var person_name := _talk_name
	var quests := _talk_quests
	var manager := _quest_manager()
	# 这次交谈前就处于“待复命”的委托 id：note_talk 会把它结算掉，之后要从原列表里取回数据展示。
	var returned_id := ""
	if manager != null and manager.has_method("pending_returns"):
		var pending: Array = manager.call("pending_returns", person_id)
		if not pending.is_empty():
			returned_id = str(pending[0].get("id", ""))
	_end_conversation()
	if manager != null and manager.has_method("note_talk"):
		# 带上行星 id：人物 id 允许跨行星重名，目标若指定了行星就只在同星计入。
		manager.note_talk(person_id, session.planet_id())
	var quest := _find_quest(quests, returned_id) if not returned_id.is_empty() else {}
	# 没有复命时才是常规流程：挑一份还能接的委托展示。
	if quest.is_empty():
		quest = _pick_quest(quests)
	if quest.is_empty():
		return
	view.show_quest_offer(person_id, person_name, quest, _quest_status(quest), manager != null)

func _accept_quest(person_id: String, quest: Dictionary) -> void:
	var manager := _quest_manager()
	if manager == null or not manager.has_method("accept"):
		view.set_quest_offer_notice("任务系统未就绪，暂时无法接取。", false)
		return
	var quest_id := str(quest.get("id", ""))
	if quest_id.is_empty():
		view.set_quest_offer_notice("委托数据不完整，无法接取。", false)
		return
	var status := _quest_status(quest)
	if not str(status.get("status", "")).is_empty():
		view.set_quest_offer_notice(_status_text(status, quest), false)
		return
	if not bool(manager.accept(person_id, _name_of(person_id), quest.duplicate(true))):
		view.set_quest_offer_notice("接取失败，委托可能已被接受。", false)
		return
	var reward_text := "已接取「%s」，奖励 %d 信用点。" % [str(quest.get("title", "")), int(quest.get("reward_credits", 0))]
	var unlock := str(quest.get("reward_unlock", "")).strip_edges()
	if not unlock.is_empty():
		reward_text += "另解锁「%s」。" % EquipmentCatalog.display_name(unlock)
	if bool(quest.get("requires_return", false)):
		reward_text += "完成目标后回到委托人处复命才算完成。"
	# 交谈目标可能在别的行星上：接取时就说清去哪儿找谁，别让玩家满地图猜。
	if str(quest.get("type", "")) == "talk_to_person":
		var target_name := str(quest.get("target_name", "")).strip_edges()
		var target_planet := str(quest.get("target_planet", "")).strip_edges()
		if not target_name.is_empty():
			var where := ""
			if not target_planet.is_empty():
				where = "（%s）" % target_planet
			reward_text += "目标人物：%s%s。" % [target_name, where]
	view.set_quest_offer_notice(reward_text, false)
	# 任务清单由任务系统自身刷新；有此接口时主动催一次。
	if manager.has_method("refresh_ui"):
		manager.call("refresh_ui")
	refresh()

## 只挑「还没接取、还没完成」的委托：接过或办完的再来搭话不该重播旧委托。
## 一份都不剩就返回空字典，交谈结束不弹面板（进度和已完成的记录看 HUD 任务清单）。
func _pick_quest(quests: Array) -> Dictionary:
	for quest: Variant in quests:
		if not (quest is Dictionary):
			continue
		if str(_quest_status(quest).get("status", "")).is_empty():
			return (quest as Dictionary).duplicate(true)
	return {}

func _find_quest(quests: Array, quest_id: String) -> Dictionary:
	for quest: Dictionary in quests:
		if str(quest.get("id", "")) == quest_id:
			return quest.duplicate(true)
	return {}

## 待复命的委托快照；任务系统未就绪时返回空数组，对话照常进行。
func _pending_returns(person_id: String) -> Array:
	var manager := _quest_manager()
	if manager == null or not manager.has_method("pending_returns"):
		return []
	var pending: Variant = manager.call("pending_returns", person_id)
	return pending if pending is Array else []

func _status_text(status: Dictionary, quest: Dictionary) -> String:
	match str(status.get("status", "")):
		"completed":
			return "这份委托已完成，奖励已发放。"
		"awaiting_return":
			return "目标已完成 · 回到委托人处复命后才会结算奖励。"
	return "已接取 · 进度 %d/%d" % [int(status.get("progress", 0)), int(status.get("required", quest.get("count", 1)))]

func _name_of(person_id: String) -> String:
	return str(_person_by_id(person_id).get("name", person_id))

func _quest_status(quest: Dictionary) -> Dictionary:
	var manager := _quest_manager()
	if manager == null or not manager.has_method("state"):
		return {}
	var quest_id := str(quest.get("id", ""))
	if quest_id.is_empty():
		return {}
	var status: Variant = manager.state(quest_id)
	return status if status is Dictionary else {}

func _quest_manager() -> Node:
	if not is_instance_valid(game):
		return null
	return game.get_node_or_null("QuestManager")

## 剧情状态节点；老场景/测试精简版可能没挂，缺省按「没有任何标记」处理。
func _story_state() -> Node:
	if not is_instance_valid(game):
		return null
	return game.get_node_or_null("StoryState")

func _progression_manager() -> Node:
	if not is_instance_valid(game):
		return null
	return game.get_node_or_null("ProgressionManager")

func _dialogue_window() -> Node:
	if not is_instance_valid(game):
		return null
	return game.get_node_or_null("DialogueWindow")

func _end_conversation() -> void:
	_talk_person = ""
	_talk_name = ""
	_talk_quests = []
