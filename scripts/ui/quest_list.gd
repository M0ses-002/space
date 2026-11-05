extends PanelContainer
## 任务清单 HUD：标题栏按钮折叠/展开，body 用 quest_row.tscn 逐条渲染。
## 只在有进行中任务时显示整块面板；数据全部来自 QuestManager 的三个信号刷新。
const ROW_SCENE := preload("res://scenes/ui/quest_row.tscn")
## 默认贴在舰队栏下方；物体信息面板（左上 16..256 × 58..184）弹出时整体下移让位。
const PANEL_TOP := 60.0
const OBSTRUCTED_TOP := 192.0
## 面板高度跟随内容：标题 24 + 上下边距 12 + 4 分隔，单行 22、行距 2；超过上限才滚动。
const HEADER_HEIGHT := 24.0
const PADDING := 16.0
const ROW_HEIGHT := 22.0
const ROW_GAP := 2.0
const BODY_MAX := 208.0

@onready var header: Button = $Margin/Layout/Header
@onready var body: ScrollContainer = $Margin/Layout/Scroll
@onready var rows: VBoxContainer = $Margin/Layout/Scroll/Rows

var _manager: Node = null

func _ready() -> void:
	header.pressed.connect(_toggle)
	_refresh()

## 由主场景在 _ready 里显式绑定；信号在绑定处连接，避免依赖编辑器保存的外部连接。
func bind(manager: Node) -> void:
	_manager = manager
	if manager == null:
		_refresh()
		return
	if not manager.quest_accepted.is_connected(_on_quest_accepted):
		manager.quest_accepted.connect(_on_quest_accepted)
	if not manager.quest_progressed.is_connected(_on_quest_progressed):
		manager.quest_progressed.connect(_on_quest_progressed)
	# 目标达成但需复命时状态会变成 awaiting_return，这一次翻转也要刷新，否则行里还停在“1/1 进行中”。
	if not manager.quest_ready_to_return.is_connected(_on_quest_ready_to_return):
		manager.quest_ready_to_return.connect(_on_quest_ready_to_return)
	if not manager.quest_completed.is_connected(_on_quest_completed):
		manager.quest_completed.connect(_on_quest_completed)
	_refresh()

func _toggle() -> void:
	body.visible = not body.visible
	_fit_height()

## 面板高度只包住标题与任务行，行数多时在 BODY_MAX 处截断并滚动。
func _fit_height() -> void:
	var count := rows.get_child_count()
	var content := 0.0 if count == 0 else count * ROW_HEIGHT + (count - 1) * ROW_GAP
	var body_height := 0.0
	if body.visible:
		body_height = minf(content, BODY_MAX)
	body.custom_minimum_size.y = body_height
	offset_bottom = offset_top + PADDING + HEADER_HEIGHT + body_height

## 空间物体信息面板会占用同一块左上区域，展开时把清单整体下移，收起后还原。
func set_obstructed(obstructed: bool) -> void:
	var top := OBSTRUCTED_TOP if obstructed else PANEL_TOP
	var height := offset_bottom - offset_top
	offset_top = top
	offset_bottom = top + height

func _on_quest_accepted(_quest_id: String) -> void:
	_refresh()

func _on_quest_progressed(_quest_id: String, _progress: int, _required: int) -> void:
	_refresh()

func _on_quest_ready_to_return(_quest_id: String) -> void:
	_refresh()

func _on_quest_completed(_quest_id: String) -> void:
	_refresh()

func _refresh() -> void:
	for child in rows.get_children():
		rows.remove_child(child)
		child.queue_free()
	var list: Array = _manager.active_quests() if is_instance_valid(_manager) else []
	for data in list:
		var row := ROW_SCENE.instantiate()
		rows.add_child(row)
		row.render(data)
	header.text = "任务 (%d)" % list.size() if not list.is_empty() else "任务"
	visible = not list.is_empty()
	_fit_height()
