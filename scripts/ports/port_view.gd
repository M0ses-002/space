extends Control

signal depart_requested()
signal tab_requested(tab: String)
signal event_selected(id: String)
signal person_selected(id: String)
signal shipyard_slot_selected(slot: int)
signal upgrade_requested(id: String)
signal upgrade_remove_requested()
signal quest_accept_requested(person_id: String, quest: Dictionary)

const PERSON_ICON = preload("res://scenes/ports/person_icon.tscn")
const EVENT_CARD = preload("res://scenes/ports/event_card.tscn")

var _state: Dictionary = {}
var _event_nodes: Dictionary = {}
var _person_nodes: Dictionary = {}

func _ready() -> void:
	%DepartButton.pressed.connect(func(): depart_requested.emit())
	%EventsButton.pressed.connect(func(): tab_requested.emit("events"))
	%RelationsButton.pressed.connect(func(): tab_requested.emit("relations"))
	%ShipyardButton.pressed.connect(func(): tab_requested.emit("shipyard"))
	for i in %Slots.get_child_count():
		%Slots.get_child(i).pressed.connect(_on_slot_pressed.bind(i))
	%Candidates.candidate_selected.connect(func(id: String): upgrade_requested.emit(id))
	%RemoveButton.pressed.connect(func(): upgrade_remove_requested.emit())
	%QuestOffer.accept_pressed.connect(_on_quest_accepted)
	%QuestOffer.decline_pressed.connect(_on_quest_offer_dismissed)
	%QuestOffer.close_pressed.connect(_on_quest_offer_dismissed)
	render(_state)

# 唯一渲染入口，视图只展示会话和控制器提供的快照。
func render(state: Dictionary) -> void:
	_state = state.duplicate(true)
	if not is_node_ready():
		return
	%PlanetName.text = str(state.get("planet_name", "港口"))
	%PlanetName.tooltip_text = %PlanetName.text
	var current_tab := str(state.get("tab", "events"))
	%EventsPage.visible = current_tab == "events"
	%RelationsPage.visible = current_tab == "relations"
	%ShipyardPage.visible = current_tab == "shipyard" and bool(state.get("shipyard_available", false))
	if not %ShipyardPage.visible:
		%Candidates.hide()
	%ShipyardButton.visible = bool(state.get("shipyard_available", false))
	%ShipyardButton.set_pressed_no_signal(current_tab == "shipyard")
	%EventsButton.set_pressed_no_signal(current_tab == "events")
	%RelationsButton.set_pressed_no_signal(current_tab == "relations")
	%Error.text = str(state.get("error", ""))
	%Error.visible = not %Error.text.is_empty()
	%ShipStatus.text = "%s · 舰队共享信用点 %d" % [str(state.get("ship_name", "当前船")), int(state.get("credits", 0))]
	%Status.text = str(state.get("departure_warning", "港口停泊中"))
	_render_events()
	_render_people()
	if current_tab == "shipyard":
		_render_shipyard()

func _render_shipyard() -> void:
	%ShipyardTitle.text = "%s · 船坞 · 信用点 %d" % [str(_state.get("ship_name", "当前船")), int(_state.get("credits", 0))]
	%ShipyardNotice.text = str(_state.get("shipyard_notice", "")) + "  改装价格取自 data/equipment.json；未解锁的装备不出现，护盾耗尽后在原槽位重充。"
	var slots: Array = _state.get("upgrade_slots", [])
	var slot_upgrades: Dictionary = _state.get("slot_upgrades", {})
	var selected := int(_state.get("shipyard_slot", 0))
	for i in %Slots.get_child_count():
		var button: Button = %Slots.get_child(i)
		button.visible = i < slots.size()
		if not button.visible:
			continue
		var id: String = slots[i]
		var name_text := str(slot_upgrades.get(id, {}).get("name", "空"))
		if id == "hangar":
			# 机库本身只是改装槽，真正能用的是它解锁的舰载机；标签里直接写出来，
			# 免得装完在船坞看不到任何变化、以为没生效。
			name_text += "\n工程机 · 近卫机"
		if id == "shield":
			name_text += "（可用）" if bool(_state.get("shield_ready", false)) else "（耗尽）"
		button.text = "槽位 %d\n%s" % [i + 1, name_text]
		button.set_pressed_no_signal(i == selected)
	# 拆除按钮跟着选中槽位走：空槽直接禁用，免得点了没反应。
	var selected_id := str(slots[selected]) if selected >= 0 and selected < slots.size() else ""
	%RemoveButton.text = "拆除槽位 %d" % (selected + 1)
	%RemoveButton.disabled = selected_id.is_empty()
	%RemoveButton.tooltip_text = "空槽位没有可拆的装备。" if selected_id.is_empty() else "拆除「%s」，免费且不返还信用点；对应功能立即失效。" % str(slot_upgrades.get(selected_id, {}).get("name", selected_id))
	%Candidates.render(slot_upgrades)

func _on_slot_pressed(slot: int) -> void:
	%Candidates.show()
	shipyard_slot_selected.emit(slot)

func _render_events() -> void:
	var events: Array = _state.get("events", [])
	var selected := str(_state.get("selected_event", ""))
	var present: Array[String] = []
	%EventsEmpty.visible = events.is_empty()
	%EventTitle.text = "等待选择事件"
	%EventBody.text = "当前没有选中的事件。"
	for data: Dictionary in events:
		var id := str(data.get("id", ""))
		present.append(id)
		if not _event_nodes.has(id):
			var card = EVENT_CARD.instantiate()
			%EventList.add_child(card)
			card.event_pressed.connect(_on_event_selected)
			_event_nodes[id] = card
		var card = _event_nodes[id]
		card.render(data, id == selected)
		%EventList.move_child(card, -1)
		if id == selected:
			%EventTitle.text = str(data.get("title", ""))
			%EventBody.text = str(data.get("body", ""))
	_remove_missing(_event_nodes, present)

func _render_people() -> void:
	var persons: Array = _state.get("persons", [])
	var selected := str(_state.get("selected_person", ""))
	var present: Array[String] = []
	%PersonsEmpty.visible = persons.is_empty()
	%GraphScroll.visible = not persons.is_empty()
	%PersonTitle.text = "选择一位人物"
	%PersonRole.text = ""
	%PersonDetail.text = str(_state.get("person_detail", "点击头像与人物交谈，对话结束后可以领取委托。"))
	for data: Dictionary in persons:
		var id := str(data.get("id", ""))
		present.append(id)
		if not _person_nodes.has(id):
			var icon = PERSON_ICON.instantiate()
			%People.add_child(icon)
			icon.person_pressed.connect(_on_person_selected)
			_person_nodes[id] = icon
		_person_nodes[id].render(data, id == selected)
		if id == selected:
			%PersonTitle.text = str(data.get("name", ""))
			%PersonRole.text = str(data.get("role", ""))
			if %PersonDetail.text.is_empty():
				%PersonDetail.text = str(data.get("description", ""))
	_remove_missing(_person_nodes, present)

func _remove_missing(nodes: Dictionary, present: Array[String]) -> void:
	for id in nodes.keys():
		if not present.has(id):
			var node: Node = nodes[id]
			node.get_parent().remove_child(node)
			node.queue_free()
			nodes.erase(id)

func _on_event_selected(id: String) -> void:
	event_selected.emit(id)

func _on_person_selected(id: String) -> void:
	person_selected.emit(id)

# 任务领取面板：视图只负责显示，接取与查状态由控制器问任务系统。
func show_quest_offer(person_id: String, person_name: String, quest: Dictionary, status: Dictionary, quest_system_ready: bool) -> void:
	%QuestOffer.open(person_id, person_name, quest, status, quest_system_ready)

func set_quest_offer_notice(text: String, allow_accept: bool) -> void:
	%QuestOffer.set_notice(text, allow_accept)

func hide_quest_offer() -> void:
	%QuestOffer.close()

func is_quest_offer_open() -> bool:
	return %QuestOffer.visible

func _on_quest_accepted(person_id: String, quest: Dictionary) -> void:
	quest_accept_requested.emit(person_id, quest)

# 放弃与 ✕/Esc 都只是关闭窗口，不动委托状态；是否接取完全由控制器问任务系统。
func _on_quest_offer_dismissed() -> void:
	hide_quest_offer()
