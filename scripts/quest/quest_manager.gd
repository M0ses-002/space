extends Node
## 任务系统核心：接取、进度推进、完成结算与存档状态。
## 只读取 game 的公开状态（ship_position / ships / cities / planets），不写入航行逻辑。
signal quest_accepted(quest_id: String)
signal quest_progressed(quest_id: String, progress: int, required: int)
## 目标已达成但还需要回到委托人处复命；此时不结算奖励、不发 quest_completed。
signal quest_ready_to_return(quest_id: String)
signal quest_completed(quest_id: String)

## 委托状态机：active（进行中）→ awaiting_return（待复命，仅 requires_return 委托）
## → completed（完成）。待复命期间奖励不发放，玩家必须回到委托人处交谈。
const STATUS_ACTIVE := "active"
const STATUS_AWAITING_RETURN := "awaiting_return"
const STATUS_COMPLETED := "completed"
const STATUSES: Array[String] = [STATUS_ACTIVE, STATUS_AWAITING_RETURN, STATUS_COMPLETED]

## 类型注册表：键是 JSON 里的 quest.type，值是目标脚本。
## 新增类型 = 在 scripts/quest/objectives/ 加一个 extends QuestObjective 的脚本 + 这里注册一行。
const TYPES := {
	"arrive_point": preload("res://scripts/quest/objectives/arrive_point.gd"),
	"arrive_target": preload("res://scripts/quest/objectives/arrive_target.gd"),
	"talk_to_person": preload("res://scripts/quest/objectives/talk_to_person.gd"),
	"dock_city": preload("res://scripts/quest/objectives/dock_city.gd"),
	"install_upgrade": preload("res://scripts/quest/objectives/install_upgrade.gd"),
	"recycle_mass": preload("res://scripts/quest/objectives/recycle_mass.gd"),
}
## 轮询间隔（现实秒）；自己累计 delta，不逐帧判定。
const EVAL_INTERVAL := 0.25

var _game: Node = null
## quest_id -> {quest, objective, progress, required, status, latched, person_id, person_name}
var _quests: Dictionary = {}
var _elapsed := 0.0

func bind_game(game: Node) -> void:
	_game = game
	_elapsed = 0.0

func _process(delta: float) -> void:
	if not is_instance_valid(_game):
		return
	_elapsed += delta
	if _elapsed < EVAL_INTERVAL:
		return
	_elapsed = fmod(_elapsed, EVAL_INTERVAL)
	_evaluate()

## 接取任务：重复接取、未知类型、配置非法都返回 false 且不改动任何状态。
func accept(person_id: String, person_name: String, quest: Dictionary) -> bool:
	if not is_instance_valid(_game) or quest.is_empty():
		return false
	var id := str(quest.get("id", ""))
	if id.is_empty() or _quests.has(id):
		return false
	var type := str(quest.get("type", ""))
	if not TYPES.has(type):
		push_warning("任务类型未注册：%s" % type)
		return false
	var objective = TYPES[type].new()
	objective.setup(quest, _game)
	var error: String = objective.validate()
	if not error.is_empty():
		push_warning("任务配置无效（%s）：%s" % [id, error])
		return false
	var required: int = maxi(1, objective.count)
	_quests[id] = {
		"quest": quest.duplicate(true),
		"objective": objective,
		"progress": 0,
		"required": required,
		"status": STATUS_ACTIVE,
		"latched": false,
		"person_id": person_id,
		"person_name": person_name,
	}
	# 事件型目标在接取瞬间可能已满足（例如在港口内领取停泊任务）；视为已消费，
	# 需要真正离开再重新满足才计数，避免原地立刻完成。
	_quests[id].latched = objective.is_edge_triggered() and objective.is_satisfied(_context())
	quest_accepted.emit(id)
	return true

## 对话事件入口：先结算「待复命」的委托（回到委托人处交谈才算真正完成、才发奖励），
## 再推进匹配该人物 id 的 talk_to_person 目标。
## planet_id 是交谈发生的行星：人物 id 允许跨行星重名，目标配了 target_planet_id 时只有同星才计数。
func note_talk(person_id: String, planet_id: String = "") -> void:
	for id in _quests.keys():
		var entry: Dictionary = _quests[id]
		if entry.status != STATUS_AWAITING_RETURN:
			continue
		if str(entry.get("person_id", "")) == person_id:
			_complete(id, entry)
	for id in _quests.keys():
		var entry: Dictionary = _quests[id]
		if entry.status != STATUS_ACTIVE:
			continue
		if entry.objective.matches_talk(person_id, planet_id):
			_advance(id, entry, 1)

## 待复命的委托快照（只列当前人物可交的），港口据此决定要不要播"回来复命"的对话。
func pending_returns(person_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for id in _quests.keys():
		var entry: Dictionary = _quests[id]
		if entry.status != STATUS_AWAITING_RETURN:
			continue
		if not person_id.is_empty() and str(entry.get("person_id", "")) != person_id:
			continue
		result.append(state(id))
	return result

## 该人物身上是否有需要复命的目标；港口对话用它决定是否补一句复命台词。
func has_pending_return(person_id: String) -> bool:
	return not pending_returns(person_id).is_empty()

## 安装事件入口：船坞成功装上一件装备时调用，只推进匹配该装备 id 的 install_upgrade 目标。
func note_upgrade(upgrade_id: String) -> void:
	for id in _quests.keys():
		var entry: Dictionary = _quests[id]
		if entry.status != STATUS_ACTIVE:
			continue
		if entry.objective.matches_upgrade(upgrade_id):
			_advance(id, entry, 1)

## 回收事件入口：捕捉网擦到碎片、质量进网时调用，按 kg 累加 recycle_mass 目标的进度。
## 由目标自己决定折算量（返回 0 表示不响应），因此新增其它按质量统计的任务不用再改这里。
func note_recycle(mass_kg: float) -> void:
	if mass_kg <= 0.0:
		return
	for id in _quests.keys():
		var entry: Dictionary = _quests[id]
		if entry.status != STATUS_ACTIVE:
			continue
		var amount: int = entry.objective.recycle_amount(mass_kg)
		if amount > 0:
			_advance(id, entry, amount)

## 任务快照，字段固定，供 UI 直接渲染。
func state(quest_id: String) -> Dictionary:
	if not _quests.has(quest_id):
		return {}
	var entry: Dictionary = _quests[quest_id]
	var data: Dictionary = entry.quest
	return {
		"id": quest_id,
		"title": str(data.get("title", "")),
		"description": str(data.get("description", "")),
		"type": str(data.get("type", "")),
		"status": entry.status,
		"progress": entry.progress,
		"required": entry.required,
		"reward_credits": int(data.get("reward_credits", 0)),
		"reward_unlock": str(data.get("reward_unlock", "")),
		# 需复命委托：目标达成后停在这里，直到玩家回到 person_id 处交谈。
		"requires_return": requires_return(data),
		"return_line": str(data.get("return_line", "")),
		"person_id": str(entry.get("person_id", "")),
		"person_name": str(entry.get("person_name", "")),
		# 交谈目标的可读提示：编辑器按全项目人物索引填好，只用于界面，不参与匹配。
		# 目标人物可以在别的行星上，所以清单要能告诉玩家该去哪儿找人。
		"target_name": str(data.get("target_name", "")),
		"target_planet": str(data.get("target_planet", "")),
	}

## 清单要显示的委托：进行中 + 待复命（待复命仍在玩家头上，不能从 HUD 消失）。
func active_quests() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for id in _quests.keys():
		var status := str(_quests[id].status)
		if status in [STATUS_ACTIVE, STATUS_AWAITING_RETURN]:
			result.append(state(id))
	return result

## 条件系统用的只读状态表：quest_id -> status。从未接取的委托不在表里（取不到即空串）。
func status_map() -> Dictionary:
	var table := {}
	for id in _quests.keys():
		table[str(id)] = str(_quests[id].status)
	return table

## 委托配置是否要求回到委托人处复命；缺省 false，旧数据行为不变。
static func requires_return(quest: Dictionary) -> bool:
	return bool(quest.get("requires_return", false))

func is_accepted(quest_id: String) -> bool:
	return _quests.has(quest_id)

func is_completed(quest_id: String) -> bool:
	return _quests.has(quest_id) and _quests[quest_id].status == STATUS_COMPLETED

## 目标已达成但还在等玩家复命。
func is_awaiting_return(quest_id: String) -> bool:
	return _quests.has(quest_id) and _quests[quest_id].status == STATUS_AWAITING_RETURN

## 轮询判定：连续型与可观察的事件型都走 latch——进入满足态 +1 并锁定，
## 离开满足态后解锁；因此同一区间内不会重复计数，离开再进入才会累计。
func _evaluate() -> void:
	var ctx := _context()
	for id in _quests.keys():
		var entry: Dictionary = _quests[id]
		if entry.status != STATUS_ACTIVE:
			continue
		if not entry.objective.is_satisfied(ctx):
			entry.latched = false
			continue
		if entry.latched:
			continue
		entry.latched = true
		_advance(id, entry, 1)

func _advance(id: String, entry: Dictionary, amount: int) -> void:
	if entry.status != STATUS_ACTIVE or amount <= 0:
		return
	entry.progress = mini(entry.progress + amount, entry.required)
	quest_progressed.emit(id, entry.progress, entry.required)
	if entry.progress >= entry.required:
		_finish_objective(id, entry)

## 目标达成的分流点：需复命的委托在此停在 awaiting_return，
## 奖励与 quest_completed 都推迟到玩家找委托人交谈时（note_talk）才发生。
func _finish_objective(id: String, entry: Dictionary) -> void:
	if requires_return(entry.quest):
		entry.status = STATUS_AWAITING_RETURN
		quest_ready_to_return.emit(id)
		return
	_complete(id, entry)

func _complete(id: String, entry: Dictionary) -> void:
	entry.status = STATUS_COMPLETED
	# 奖励只在此处结算一次；信号订阅者不应重复加信用点。
	_settle_reward(entry.quest)
	quest_completed.emit(id)

func _settle_reward(quest: Dictionary) -> void:
	_settle_credits(quest)
	_settle_unlock(quest)

func _settle_credits(quest: Dictionary) -> void:
	var reward := int(quest.get("reward_credits", 0))
	if reward <= 0:
		return
	var session = _session()
	if session == null or not session.has_method("add_credits"):
		push_warning("任务奖励无法结算：找不到港口信用点接口。")
		return
	session.add_credits(reward)

## 装备解锁奖励：reward_unlock 填 data/equipment.json 里的装备 id。
## 只接受 requires_unlock=true 的条目，重复解锁不报错但也不计入任务进度之外的任何东西。
func _settle_unlock(quest: Dictionary) -> void:
	var id := str(quest.get("reward_unlock", "")).strip_edges()
	if id.is_empty():
		return
	var session = _session()
	if session == null or not session.has_method("unlock_equipment"):
		push_warning("任务解锁奖励无法结算：找不到港口会话接口。")
		return
	if not session.unlock_equipment(id):
		push_warning("任务解锁奖励未生效：装备 %s 不存在、无需解锁或已解锁。" % id)

## 信用点归港口的共享会话，不另建钱包。
func _session() -> Variant:
	if not is_instance_valid(_game):
		return null
	var port := _game.get_node_or_null("PortController")
	if port == null:
		return null
	return port.get("session")

func _context() -> Dictionary:
	if not is_instance_valid(_game):
		return {}
	return {
		"ship_position": _game.get("ship_position"),
		"ships": _game.get("ships"),
		"cities": _game.get("cities"),
		"planets": _game.get("planets"),
	}

# --- 存档：任务原始配置与进度一起保存，读档不重发完成信号、不重复发奖励。 ---

func make_state() -> Dictionary:
	var list: Array[Dictionary] = []
	for id in _quests.keys():
		var entry: Dictionary = _quests[id]
		list.append({
			"quest": entry.quest.duplicate(true),
			"progress": entry.progress,
			"status": entry.status,
			# 委托人要存下来：待复命的委托读档后还得能认出该找谁。
			"person": str(entry.get("person_id", "")),
			"person_name": str(entry.get("person_name", "")),
		})
	return {"version": 1, "quests": list}

func is_state_valid(state: Variant) -> bool:
	if not state is Dictionary or state.get("version") != 1 or not state.get("quests") is Array:
		return false
	var seen: Dictionary = {}
	for item: Variant in state.quests:
		if not item is Dictionary or not item.get("quest") is Dictionary:
			return false
		var quest: Dictionary = item.quest
		var id := str(quest.get("id", ""))
		if id.is_empty() or seen.has(id):
			return false
		seen[id] = true
		if not TYPES.has(str(quest.get("type", ""))):
			return false
		if not item.get("progress") is int or item.progress < 0:
			return false
		if not item.get("status") is String or not item.status in STATUSES:
			return false
		if item.get("person") != null and not item.get("person") is String:
			return false
		if item.progress > maxi(1, int(quest.get("count", 1))):
			return false
	return true

func restore_state(state: Variant) -> void:
	_quests.clear()
	_elapsed = 0.0
	if not is_state_valid(state):
		return
	for item: Dictionary in state.quests:
		var quest: Dictionary = item.quest.duplicate(true)
		var objective = TYPES[str(quest.type)].new()
		objective.setup(quest, _game)
		var required: int = maxi(1, objective.count)
		_quests[str(quest.id)] = {
			"quest": quest,
			"objective": objective,
			"progress": mini(int(item.progress), required),
			"required": required,
			"status": str(item.status),
			"latched": false,
			"person_id": str(item.get("person", "")),
			"person_name": str(item.get("person_name", "")),
		}
		# 与接取一致：读档时已处于停泊态视为已消费，不额外计数。
		_quests[str(quest.id)].latched = objective.is_edge_triggered() and objective.is_satisfied(_context())
