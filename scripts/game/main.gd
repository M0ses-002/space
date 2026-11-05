extends Node2D
## 仅真实物理步提交后发出；forward_delta_v为推进本身沿步前速度/航向的正向分量。
signal propulsion_committed(vessel: Node2D, forward_delta_v: float, source: StringName)
signal ship_selected(vessel: Node2D, player_initiated: bool)
signal simulation_step_committed(vessel: Node2D)
## 管理模拟、舰队注册与交互绑定；外观、布局与按钮模板定义在 .tscn 中。
## 编辑器布景原点（像素坐标），对应模拟世界的零点。首次读取行星/飞船节点布局时使用。
@export var layout_origin := Vector2(440.0, 360.0)
## 编辑器布景的换算比例：每米对应多少像素。仅用于首次初始化，物理计算不依赖窗口和相机。
@export var layout_pixels_per_meter := 0.004
var planets: Array[Node2D] = []
var cities: Array[Node2D] = []
const DOCK_SPEED_TOLERANCE := 0.1 # m/s
const SIM_STEP := 0.25
const TIME_SCALE := 20.0
const PREVIEW_REFRESH_INTERVAL := 0.1
const PREVIEW_SECONDS := 620.0
const PREVIEW_SAMPLE_STEPS := 4
const OrbitPlanner = preload("res://scripts/navigation/orbit_planner.gd")
const MapLoader = preload("res://scripts/navigation/map_loader.gd")
const CAPTURE_NET := preload("res://scenes/world/capture_net.tscn")
const DRONE := preload("res://scenes/world/drone.tscn")
## 无 user:// 自定义地图时是否回退加载打包内置地图；实际游戏入口开启，最小场景保持默认内容。
@export var allow_builtin_map := false
var map_hash := ""
var map_load_error := false
## 当前生效地图：路径、文件名（不含扩展名）与加载序号。CG 与事件按文件名判定「进入地图」，
## 序号每次加载自增，同一张地图重复加载也算一次新的进入。
var current_map_path := ""
var current_map_id := ""
## 当前地图绑定的 CG 配置文件（来自地图根节点 cg_data_path，可为空）。
var current_cg_path := ""
var map_epoch := 0
const INITIAL_FUEL := 3200.0
const START_POSITION := Vector2(0.0, -62000.0)
const START_VELOCITY := Vector2(655.0, 0.0)

const SHIP_BUTTON := preload("res://scenes/ui/ship_selector_button.tscn")
var ships: Array[Node2D] = []
var obstacles: Array[Node2D] = []
# 已发射的捕捉网：只在本次航行内有效，重置航行或切换地图时清空，不写入存档。
var capture_nets: Array[Node2D] = []
# 机库释放的舰载机：与捕捉网一样只在本次航行内有效，重置或换图时清空，不写入存档。
var drones: Array[Node2D] = []
var capture_aim_active := false
var capture_aim_angle := 0.0
var capture_aim_slot := -1
var paused_before_aim := false
# 本次航行由捕捉网捕获到的物资质量，供 HUD 提示与 recycle_mass 任务使用。
var recovered_mass_kg := 0.0
# 查看物体与控制飞船独立，点击物体不改变航行或导航。
var inspected_object: Node2D
var stopped_obstacles: Dictionary = {}
var ship_buttons: Dictionary = {}
var ship: Node2D
# 当前控制对象的兼容访问，实际状态归各飞船实例所有。
var ship_position: Vector2:
	get: return ship.flight_position if is_instance_valid(ship) else Vector2.ZERO
	set(value):
		if is_instance_valid(ship): ship.flight_position = value
var ship_velocity: Vector2:
	get: return ship.flight_velocity if is_instance_valid(ship) else Vector2.ZERO
	set(value):
		if is_instance_valid(ship): ship.flight_velocity = value
var fuel_mass: float:
	get: return ship.fuel if is_instance_valid(ship) else 0.0
	set(value):
		if is_instance_valid(ship): ship.fuel = value
var selected := false
var crashed: bool:
	get: return ship.crashed if is_instance_valid(ship) else false
	set(value):
		if is_instance_valid(ship): ship.crashed = value
var simulation_paused := false
var tutorial_pause := false
var tutorial_previous_pause := false
var selecting_orbit := false
var paused_before_selection := false
var orbit_candidates: Array[Node2D] = []
var pending_target: Node2D
var pending_plan: Dictionary = {}
var flight_message := ""
var simulation_speed := 1.0
var accumulator := 0.0
var preview_refresh_elapsed := 0.0
var preview_points := PackedVector2Array()
var preview_ship: Node2D
var preview_job: Dictionary = {}
const PREVIEW_STEPS_PER_FRAME := 400

# ── 航行电脑：选中目标的轨迹预测（独立于玩家自身预演，参数挂在目标侧） ──────────
## 重算周期（秒）。按主参考速度 600 m/s 估算，0.4 秒 ≈ 240 m ≈ 1.5 像素
## （近域 1 px ≈ 157 m），肉眼几乎不动；星图视角下轨迹线整体隐藏，不受此值影响。
const TARGET_PREVIEW_TTL := 0.4
## 每帧推进步数。相当于给桌面端预留 1600 步/秒，60 Hz 下平滑推进不卡帧。
const TARGET_PREVIEW_STEPS_PER_FRAME := 640
## 抽稀目标：相邻顶点至少 2 个画布像素，对应近域约 470 m。再密于视觉无收益，
## 却线性推高 Line2D 每次重建几何的顶点数。
const TARGET_SAMPLE_CANVAS_PX := 2.0
## 累计行程上限（画布像素）：超过约 3~4 屏即无意义，换算成米随视角自适应。
const TARGET_TRAVEL_CUTOFF_CANVAS_PX := 4000.0
## 屏幕像素门限：相邻顶点在屏幕上不足 6 px 就合并，避免星图/缩小视野下顶点堆积。
const TARGET_MIN_SCREEN_PX := 6.0
## 顶点硬上限：448 点 × 30 B ≈ 13 KB，是 Line2D 每帧重建几何的舒适区。
const TARGET_PREVIEW_MAX_POINTS := 448
## 密集采样上限：极端速度下防止步进循环本身失控（超出则强制降频，宁可粗不可卡）。
const TARGET_PREVIEW_DENSE_LIMIT := 4096
## 线条与端点标记的视觉规格（紫罗兰：与玩家琥珀色互补 180°，
## 且不占用星图线青、速度箭头绿、坠毁红这三个既有语义色）。
const TARGET_LINE_WIDTH := 1.2
const TARGET_LINE_COLOR := Color(0.63, 0.52, 0.95, 0.8)
const TARGET_END_COLOR := Color(0.80, 0.72, 1.0, 1.0)
const TARGET_END_IMPACT_COLOR := Color(0.92, 0.36, 0.30, 0.95)

var target_preview_job: Dictionary = {}
var target_preview_dense := PackedVector2Array()
var target_preview_object: Node2D
var target_preview_impact := false
var target_preview_static := false
var target_preview_dirty := true
var target_preview_ttl_elapsed := 0.0

@onready var fleet_buttons: HBoxContainer = $HUD/Root/FleetBar/Margin/Row/Scroll/Buttons
@onready var orbit_preview: Line2D = $World/OrbitPreview
@onready var target_preview: Line2D = $World/TargetPreview
@onready var target_preview_end: Node2D = $World/TargetPreviewEnd
@onready var target_end_continue: Node2D = $World/TargetPreviewEnd/Continue
@onready var target_end_impact: Node2D = $World/TargetPreviewEnd/Impact
@onready var autopilot_marker: Node2D = $World/AutopilotMarker
@onready var panel: PanelContainer = $HUD/Root/FlightPanel
@onready var info_label: Label = $HUD/Root/FlightPanel/Margin/Content/Info
@onready var selection_status: Label = $HUD/Root/FlightPanel/Margin/Content/SelectionStatus
@onready var accelerate_button: Button = $HUD/Root/ThrustDial/Layout/AccelerateButton
@onready var brake_button: Button = $HUD/Root/ThrustDial/Layout/BrakeButton


@onready var stay_button: Button = $HUD/Root/FlightPanel/Margin/Content/StayButton
@onready var speed_row: HBoxContainer = $HUD/Root/BottomActions/SpeedRow

@onready var pause_button: Button = $HUD/Root/BottomActions/PauseButton
@onready var orbit_actions: HBoxContainer = $HUD/Root/FlightPanel/Margin/Content/OrbitActions
@onready var skill_panel: VBoxContainer = get_node_or_null("HUD/Root/FlightPanel/Margin/Content/CaptureNetPanel") as VBoxContainer
## 回档按钮只在「卡死」时出现（撞毁，或燃料耗尽且已无法入轨）。
## 节点缺失不能阻断 HUD 初始化，所以允许为 null。
@onready var rollback_button: Button = get_node_or_null("HUD/Root/FlightPanel/Margin/Content/RollbackButton") as Button
@onready var capture_aim: CanvasLayer = $CaptureAim
## 入轨入口并入船载装置栏第 1 格；orbit_button 指向该格，兼容既有测试与教程引用。
## 场景节点缺失时降级为 null 而不是在 @onready 阶段抛空调用，避免整个 HUD 初始化中断。
@onready var orbit_button: Button = skill_panel.get_slot_button(0) if skill_panel != null else null
## 任务系统核心；其他脚本用 game.quest_manager 访问。
@onready var quest_manager: Node = $QuestManager

func _ready() -> void:
	$HUD/Root/ThrustDial.bind_game(self)
	$HUD/Root/SpaceObjectInfo.close_requested.connect(_clear_object_inspection)
	# 明确绑定交互，编辑器保存/实例化不再依赖丢失的外部信号连接。
	accelerate_button.button_down.connect(_start_thrust.bind(1.0))
	brake_button.button_down.connect(_start_thrust.bind(-1.0))
	accelerate_button.button_up.connect(_stop_manual_thrust)
	brake_button.button_up.connect(_stop_manual_thrust)
	accelerate_button.mouse_exited.connect(_stop_manual_thrust)
	brake_button.mouse_exited.connect(_stop_manual_thrust)
	get_window().focus_exited.connect(_stop_thrust)
	pause_button.pressed.connect(_toggle_pause)
	if skill_panel != null:
		skill_panel.slot_pressed.connect(_on_skill_slot_pressed)
	capture_aim.angle_submitted.connect(_set_capture_aim_angle)
	orbit_actions.get_node("Confirm").pressed.connect(_confirm_orbit)
	orbit_actions.get_node("Cancel").pressed.connect(_cancel_orbit_selection)
	$HUD/Root/FlightPanel/Margin/Content/DepartButton.pressed.connect(_depart)
	if rollback_button != null:
		rollback_button.pressed.connect(_rollback_to_departure)
	$PortController.bind_game(self)
	# 原停留占位保留；确认入轨使用行星上的独立按钮。
	for index in range(4):
		speed_row.get_child(index).pressed.connect(_set_simulation_speed.bind([0.5, 1.0, 1.5, 2.0][index]))
	$HUD/Root/BottomActions/ResetButton.pressed.connect(_reset)
	var map_result := MapLoader.load_map(allow_builtin_map)
	var custom_map: Dictionary = map_result.map
	if not custom_map.is_empty():
		MapLoader.apply_map(self, custom_map)
		map_hash = custom_map.hash
		_set_current_map(str(map_result.get("path", "")), str(custom_map.get("cg_data_path", "")))
	elif bool(map_result.error):
		map_load_error = true
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)
	for source in get_tree().get_nodes_in_group("gravity_sources"):
		_register_planet(source, true)
	for node in $World.get_children():
		if node.has_method("get_dock_position") and node.has_method("contains_docking_point"):
			_register_city(node, true)
	for candidate in get_tree().get_nodes_in_group("flight_ships"):
		_register_ship(candidate)
	for object in get_tree().get_nodes_in_group("flight_obstacles"):
		_register_obstacle(object)
	get_viewport().size_changed.connect(_sync_visuals)
	_refresh_preview()
	_update_ui()
	_sync_visuals()
	$TaskManager.bind_game(self)
	$TutorialController.bind_game(self)
	$OrbitTutorialController.bind_game(self)
	$ProgressionManager.bind_game(self)
	quest_manager.bind_game(self)
	# CG 触发依赖港口入港信号与任务完成信号，必须在两者绑定之后。
	$CgController.bind_game(self)
	# 任务清单只订阅 QuestManager 的信号，不反向读取航行状态。
	$HUD/Root/QuestList.bind(quest_manager)
	# 物体信息面板与会占用左上角，弹出时清单下移让位。
	$HUD/Root/SpaceObjectInfo.panel_visibility_changed.connect($HUD/Root/QuestList.set_obstructed)


func _on_node_added(node: Node) -> void:
	if node.has_method("get_dock_position") and node.has_method("contains_docking_point"):
		_register_city.call_deferred(node, false)
	elif node.is_in_group("flight_ships"):
		_register_ship.call_deferred(node)
	elif node.is_in_group("gravity_sources"):
		_register_planet.call_deferred(node, false)
	elif node.is_in_group("flight_obstacles"):
		_register_obstacle.call_deferred(node)


func _register_city(city: Node, from_editor: bool) -> void:
	if not is_instance_valid(city) or not city.is_inside_tree() or not $World.is_ancestor_of(city) or cities.has(city):
		return
	var canvas_position: Vector2 = $World.to_local(city.global_position)
	city.flight_position = (canvas_position - layout_origin) / maxf(layout_pixels_per_meter, 0.000001) if from_editor else (canvas_position - _screen_center()) / _view_scale()
	cities.append(city)
	city.get_node("DockButton").pressed.connect(_dock_city.bind(city))
	_sync_visuals()


func _register_obstacle(object: Node) -> void:
	if not is_instance_valid(object) or not object.is_inside_tree() or not $World.is_ancestor_of(object) or obstacles.has(object):
		return
	obstacles.append(object)
	_sync_visuals()


func _register_planet(source: Node, from_editor: bool) -> void:
	if not is_instance_valid(source) or not source.is_inside_tree() or not $World.is_ancestor_of(source) or planets.has(source):
		return
	var canvas_position: Vector2 = $World.to_local(source.global_position)
	if from_editor:
		source.flight_position = (canvas_position - layout_origin) / maxf(layout_pixels_per_meter, 0.000001)
	else:
		# 运行时添加的节点使用当前世界画布坐标（不是鼠标屏幕坐标）。
		source.flight_position = (canvas_position - _screen_center()) / _view_scale()
	planets.append(source)
	source.get_node("ConfirmArrival").pressed.connect(_confirm_arrival.bind(source))
	_refresh_preview()
	_sync_visuals()


func _register_ship(candidate: Node) -> void:
	if not is_instance_valid(candidate) or not candidate.is_inside_tree() or not $World.is_ancestor_of(candidate) or ships.has(candidate):
		return
	ships.append(candidate)
	candidate.region_source = _dominant_source(candidate.flight_position)
	if not is_instance_valid(ship):
		ship = candidate
	var button: Button = SHIP_BUTTON.instantiate()
	fleet_buttons.add_child(button)
	button.pressed.connect(_select_target.bind(candidate))
	candidate.get_node("SelectButton").pressed.connect(_select_target.bind(candidate))
	ship_buttons[candidate] = button
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _on_node_removed(node: Node) -> void:
	if node is Node2D and cities.has(node):
		cities.erase(node)
		return
	if node is Node2D and obstacles.has(node):
		if inspected_object == node:
			_clear_object_inspection()
		obstacles.erase(node)
		stopped_obstacles.erase(node)
		return
	if node is Node2D and planets.has(node):
		planets.erase(node)
		orbit_candidates.erase(node)
		if pending_target == node:
			pending_target = null
			pending_plan.clear()
			flight_message = "入轨目标已移除，请重新选择。"
		if is_inside_tree() and is_instance_valid(orbit_preview) and orbit_preview.is_inside_tree():
			_refresh_preview()
		return
	if not node is Node2D or not ships.has(node) or not is_instance_valid(fleet_buttons) or not fleet_buttons.is_inside_tree():
		return
	ships.erase(node)
	var button: Button = ship_buttons[node]
	fleet_buttons.remove_child(button)
	button.queue_free()
	ship_buttons.erase(node)
	if ship == node:
		ship = ships[0] if not ships.is_empty() else null
		selected = false
	if not is_inside_tree():
		return
	_refresh_preview()
	_update_ui()
	_sync_visuals()


## 运行时切换指定地图文件（教程地图用）；返回是否成功。
func load_map_file(path: String) -> bool:
	var map := MapLoader.read_map(path)
	if map.is_empty():
		map_load_error = true
		return false
	# 旧港口先恢复航行树，再替换其停靠目标，避免港口状态跨地图残留。
	$PortController.leave_port()
	_cancel_capture_aim()
	_clear_capture_nets()
	_clear_drones()
	_stop_autopilot()
	MapLoader.apply_map(self, map)
	map_hash = map.hash
	map_load_error = false
	_set_current_map(path, str(map.get("cg_data_path", "")))
	# 同步注册（编辑器坐标风格），避免依赖下一帧的 deferred 注册。
	_register_world_objects(true)
	_refresh_preview()
	_update_ui()
	_sync_visuals()
	return true


## 加载世界地图：优先 user:// 自定义地图，否则回退内置 default_map.json。
func load_world_map() -> bool:
	var result := MapLoader.load_map(true)
	if result.map.is_empty():
		map_load_error = true
		return false
	$PortController.leave_port()
	_cancel_capture_aim()
	_clear_capture_nets()
	_clear_drones()
	_stop_autopilot()
	MapLoader.apply_map(self, result.map)
	map_hash = result.map.hash
	map_load_error = false
	_set_current_map(str(result.get("path", "")), str(result.map.get("cg_data_path", "")))
	_register_world_objects(true)
	_refresh_preview()
	_update_ui()
	_sync_visuals()
	return not map_load_error


## 记录生效地图并递增加载序号；CG 的「进入地图」条件按文件名与序号判定。
## cg_path 是地图根节点 cg_data_path，地图绑定哪份 CG 配置由地图自己决定。
func _set_current_map(path: String, cg_path: String = "") -> void:
	current_map_path = path
	current_map_id = path.get_file().get_basename() if not path.is_empty() else ""
	current_cg_path = cg_path
	map_epoch += 1


## 遍历场景树同步注册所有世界对象；from_editor 决定坐标换算方式。
func _register_world_objects(from_editor: bool) -> void:
	for source in get_tree().get_nodes_in_group("gravity_sources"):
		_register_planet(source, from_editor)
	for node in $World.get_children():
		if node.has_method("get_dock_position") and node.has_method("contains_docking_point"):
			_register_city(node, from_editor)
	for candidate in get_tree().get_nodes_in_group("flight_ships"):
		_register_ship(candidate)
	for object in get_tree().get_nodes_in_group("flight_obstacles"):
		_register_obstacle(object)


func _select_target(target: Node2D, player_initiated: bool = true) -> void:
	if $PortController.active:
		return
	if not is_instance_valid(target) or not ships.has(target):
		return
	_clear_object_inspection()
	_stop_thrust()
	_stop_autopilot()
	_cancel_capture_aim()
	if selecting_orbit:
		_cancel_orbit_selection()
	flight_message = ""
	ship = target
	selected = true
	$StarMapView.on_ship_selected()
	ship_selected.emit(ship, player_initiated)
	if ship.voyage_finished and is_instance_valid(ship.arrival_source) and cities.has(ship.arrival_source):
		$PortController.enter_port(ship.arrival_source, ship)
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _process(_delta: float) -> void:
	_update_capture_aim()
	_advance_preview_job()
	_advance_target_preview(_delta)
	_sync_city_buttons()
	_refresh_object_inspection()


func _physics_process(delta: float) -> void:
	for vessel in ships:
		_validate_navigation(vessel)
		_update_region(vessel, vessel.flight_position)
	if simulation_paused or tutorial_pause:
		return
	accumulator += delta * TIME_SCALE * simulation_speed
	preview_refresh_elapsed += delta
	while accumulator >= SIM_STEP and not simulation_paused and not tutorial_pause:
		accumulator -= SIM_STEP
		var obstacle_paths: Dictionary = {}
		for object in obstacles:
			if object.destroyed:
				continue
			var start: Vector2 = object.flight_position
			if stopped_obstacles.has(object):
				object.flight_velocity = Vector2.ZERO
				obstacle_paths[object] = [start, start]
				continue
			for source in planets:
				var offset: Vector2 = start - source.flight_position
				if offset.length() < source.radius_m:
					start = source.flight_position + (offset.normalized() if offset.length_squared() > 0.0 else Vector2.RIGHT) * source.radius_m
					object.flight_velocity = Vector2.ZERO
			var next := _integrate(start, object.flight_velocity, SIM_STEP)
			object.flight_position = next[0]
			object.flight_velocity = next[1]
			if _touches_planet(object.flight_position):
				stopped_obstacles[object] = true
				object.flight_velocity = Vector2.ZERO
			obstacle_paths[object] = [start, next[0]]
		_update_capture_nets(SIM_STEP)
		_update_drones(SIM_STEP)
		for vessel in ships:
			if vessel.crashed or vessel.voyage_finished:
				continue
			if vessel.autopilot_enabled and _is_in_gravity_region(vessel.flight_position):
				_stop_autopilot("进入引力区，自动航行已关闭。", vessel)
			var command: float = vessel.manual_thrust * 5.0
			var automatic_maneuver: bool = vessel.maneuver_index < vessel.maneuver_commands.size()
			if vessel.maneuver_index < vessel.maneuver_commands.size():
				if not is_instance_valid(vessel.maneuver_target) or not planets.has(vessel.maneuver_target) or vessel.maneuver_target.acceleration_at(vessel.flight_position).length_squared() <= 0.0:
					vessel.maneuver_commands.clear()
					flight_message = "目标已移除或已失去其有效引力，入轨机动取消。"
				else:
					command = vessel.maneuver_commands[vessel.maneuver_index]
					if vessel.fuel + 0.00001 < absf(command) * SIM_STEP * vessel.get_effective_propulsion_fuel_per_delta_v():
						vessel.maneuver_commands.clear()
						command = 0.0
						flight_message = "燃料不足，入轨机动中止。"
					else:
						vessel.maneuver_index += 1
						if vessel.maneuver_index == vessel.maneuver_commands.size():
							flight_message = "入轨机动已执行完成；继续自由绕行。"
			if vessel.thrust_lock_enabled:
				vessel.thrust_direction = _thrust_reference(vessel.flight_velocity, vessel.heading).rotated(vessel.thrust_lock_angle)
			var previous_position: Vector2 = vessel.flight_position
			if is_instance_valid(vessel.departed_city) and not vessel.departed_city.contains_docking_point(previous_position):
				vessel.departed_city = null
			var previous_fuel: float = vessel.fuel
			var was_steering: bool = vessel.steering
			var forward_alignment: float = vessel.thrust_direction.normalized().dot(_thrust_reference(vessel.flight_velocity, vessel.heading)) if was_steering else 1.0
			var operation_source: StringName = &"autopilot" if vessel.autopilot_active else (&"directional_thrust" if was_steering else (&"manual_button" if vessel.manual_thrust > 0.0 and not automatic_maneuver else &""))
			var state: Dictionary
			if vessel.autopilot_active:
				state = _autopilot_step(vessel, SIM_STEP)
				forward_alignment = vessel.autopilot_acceleration.normalized().dot(_thrust_reference(vessel.flight_velocity, vessel.heading))
				vessel.reset_orbit()
			elif vessel.steering:
				state = _steering_step(vessel, SIM_STEP)
				vessel.reset_orbit()
			else:
				state = _propulsion_step(vessel.flight_position, vessel.flight_velocity, vessel.fuel, SIM_STEP, command, vessel.heading, vessel.get_effective_propulsion_fuel_per_delta_v())
			if absf(command) > 0.0:
				vessel.reset_orbit()
			if state.velocity.length() > 0.01:
				vessel.heading = state.velocity.normalized()
			vessel.flight_position = state.position
			vessel.flight_velocity = state.velocity
			vessel.fuel = state.fuel
			if vessel.thrust_lock_enabled:
				vessel.thrust_direction = _thrust_reference(vessel.flight_velocity, vessel.heading).rotated(vessel.thrust_lock_angle)
			var first_hit: Node2D
			var first_fraction := INF
			for object in obstacle_paths:
				if not is_instance_valid(object) or object.destroyed or not object.is_in_group("space_debris"):
					continue
				var path: Array = obstacle_paths[object]
				var fraction := _swept_fraction(previous_position - path[0], vessel.flight_position - path[1], maxf(_obstacle_radius(object), 0.0))
				if fraction >= 0.0 and fraction < first_fraction:
					first_fraction = fraction
					first_hit = object
			if is_instance_valid(first_hit):
				vessel.flight_position = previous_position.lerp(vessel.flight_position, first_fraction)
				first_hit.hit_ship(vessel)
				if vessel == ship:
					flight_message = vessel.navigation_status
			vessel.current_voyage_distance_m += previous_position.distance_to(vessel.flight_position)
			_update_region(vessel, previous_position)
			if _touches_planet(vessel.flight_position):
				vessel.crashed = true
				vessel.steering = false
				vessel.thrust_throttle = 0.0
				vessel.manual_thrust = 0.0
				vessel.navigation_status = "飞船撞击损毁，可点「回档」返回上次起航。"
				vessel.flight_velocity = Vector2.ZERO
			if vessel.autopilot_enabled and (vessel.crashed or vessel.voyage_finished or _crosses_gravity_region(previous_position, vessel.flight_position)):
				_stop_autopilot("飞船已损毁。" if vessel.crashed else "进入引力区，自动航行已关闭。", vessel)
			elif vessel.autopilot_active and state.get("stopped", false):
				if state.get("arrived", false):
					vessel.autopilot_active = false
					vessel.autopilot_acceleration = Vector2.ZERO
					vessel.navigation_status = state.reason
					if vessel == ship:
						flight_message = state.reason
				else:
					_stop_autopilot(state.get("reason", "自动航行结束"), vessel)
			if not vessel.crashed and not operation_source.is_empty() and forward_alignment > 0.000001:
				var committed_delta_v: float = maxf(0.0, previous_fuel - vessel.fuel) / maxf(vessel.get_effective_propulsion_fuel_per_delta_v(), 0.000001)
				if committed_delta_v > 0.000001:
					propulsion_committed.emit(vessel, committed_delta_v * forward_alignment, operation_source)
			if vessel.steering or absf(command) > 0.0 or vessel.maneuver_index < vessel.maneuver_commands.size():
				vessel.reset_orbit()
			else:
				_update_orbit_eligibility(vessel, SIM_STEP)
			simulation_step_committed.emit(vessel)
			if tutorial_pause:
				break
	if preview_refresh_elapsed >= PREVIEW_REFRESH_INTERVAL or crashed:
		preview_refresh_elapsed = 0.0
		if preview_job.is_empty() or crashed:
			_refresh_preview()
	_update_ui()
	_sync_visuals()


func _set_simulation_speed(value: float) -> void:
	if value not in [0.5, 1.0, 1.5, 2.0]:
		return
	simulation_speed = value
	for index in range(4):
		speed_row.get_child(index).set_pressed_no_signal(is_equal_approx(value, [0.5, 1.0, 1.5, 2.0][index]))


func _dominant_source(position: Vector2) -> Node2D:
	var result: Node2D
	var strongest := 0.0
	for source in planets:
		var strength: float = source.acceleration_at(position).length()
		if strength > strongest:
			strongest = strength
			result = source
	return result


func _gravity_at(position: Vector2) -> Vector2:
	var acceleration := Vector2.ZERO
	for source in planets:
		acceleration += source.acceleration_at(position)
	for city in cities:
		if is_instance_valid(city):
			acceleration += city.acceleration_at(position)
	return acceleration


func _is_in_gravity_region(position: Vector2) -> bool:
	for source in planets:
		if is_instance_valid(source) and source.contains_gravity_point(position):
			return true
	for city in cities:
		if is_instance_valid(city) and city.contains_gravity_point(position):
			return true
	return false


func _crosses_gravity_region(start: Vector2, end: Vector2) -> bool:
	if _is_in_gravity_region(start) or _is_in_gravity_region(end):
		return true
	for source in planets:
		if is_instance_valid(source) and _swept_fraction(start - source.flight_position, end - source.flight_position, source.max_gravity_radius_m) >= 0.0:
			return true
	for city in cities:
		if not is_instance_valid(city):
			continue
		var angle: float = deg_to_rad(city.rotation_degrees_m)
		var center := Vector2(0.0, -(city.city_size_m.y + city.gravity_height_m) * 0.5)
		if not _rectangle_interval((start - city.flight_position).rotated(-angle), (end - city.flight_position).rotated(-angle), center, Vector2(city.city_size_m.x, city.gravity_height_m) * 0.5).is_empty():
			return true
	return false


func _can_enable_autopilot(vessel: Node2D = null) -> bool:
	if vessel == null:
		vessel = ship
	return selected and is_instance_valid(vessel) and vessel == ship and not tutorial_pause and not $TutorialController.active and not $OrbitTutorialController.active and not selecting_orbit and not $PortController.active and not vessel.crashed and not vessel.voyage_finished and vessel.fuel > 0.0 and not _is_in_gravity_region(vessel.flight_position)


func _toggle_autopilot_mode() -> void:
	if is_instance_valid(ship) and ship.autopilot_enabled:
		_stop_autopilot("已返回手动模式，保持当前速度。")
		return
	if not _can_enable_autopilot():
		return
	_stop_thrust()
	ship.maneuver_commands.clear()
	ship.maneuver_index = 0
	ship.autopilot_enabled = true
	ship.autopilot_active = false
	ship.autopilot_acceleration = Vector2.ZERO
	ship.reset_orbit()
	ship.navigation_status = "自动航行待命：右键空白处设置导航点。"
	flight_message = ship.navigation_status
	_update_ui()
	_refresh_preview()


func _set_autopilot_target(point: Vector2) -> void:
	if not _can_enable_autopilot() or not ship.autopilot_enabled or not point.is_finite() or simulation_paused:
		return
	if _is_in_gravity_region(point):
		flight_message = "导航点处于引力区内，无法自动航行。"
		_update_ui()
		return
	ship.autopilot_target = point
	ship.autopilot_active = true
	ship.autopilot_phase = 0
	ship.autopilot_acceleration = Vector2.ZERO
	ship.navigation_status = "自动航行执行中：右键可更换导航点。"
	flight_message = ship.navigation_status
	_sync_visuals()
	_update_ui()
	_refresh_preview()


func _set_autopilot_max_speed(value: float) -> void:
	if not is_instance_valid(ship) or tutorial_pause or not is_finite(value):
		return
	ship.autopilot_max_speed = clampf(value, 1.0, 100000.0)
	_refresh_preview()


func _touches_planet(position: Vector2) -> bool:
	for source in planets:
		if position.distance_to(source.flight_position) <= source.radius_m + 0.1:
			return true
	for city in cities:
		if is_instance_valid(city):
			var local: Vector2 = (position - city.flight_position).rotated(-deg_to_rad(city.rotation_degrees_m))
			if absf(local.x) <= city.city_size_m.x * 0.5 + 0.1 and absf(local.y) <= city.city_size_m.y * 0.5 + 0.1:
				return true
	return false


# 相对位移上的圆形扫掠，返回首次接触时刻；-1 表示未接触。
func _swept_fraction(start: Vector2, end: Vector2, radius: float) -> float:
	var c := start.length_squared() - radius * radius
	if c <= 0.0:
		return 0.0
	var movement := end - start
	var a := movement.length_squared()
	if a < 0.000001:
		return -1.0
	var b := 2.0 * start.dot(movement)
	var discriminant := b * b - 4.0 * a * c
	if discriminant < 0.0:
		return -1.0
	var fraction := (-b - sqrt(discriminant)) / (2.0 * a)
	return fraction if fraction >= 0.0 and fraction <= 1.0 else -1.0


# 同一步内扫过多个星体时取最早接触点，避免高速穿透。
func _collision_fraction(start: Vector2, end: Vector2) -> float:
	var earliest := 1.0
	var movement := end - start
	var a := movement.length_squared()
	for source in planets:
		var offset: Vector2 = start - source.flight_position
		var c: float = offset.length_squared() - source.radius_m * source.radius_m
		if c <= 0.0:
			return 0.0
		if a < 0.000001:
			continue
		var b := 2.0 * offset.dot(movement)
		var discriminant := b * b - 4.0 * a * c
		if discriminant < 0.0:
			continue
		var fraction := (-b - sqrt(discriminant)) / (2.0 * a)
		if fraction >= 0.0 and fraction <= earliest:
			earliest = fraction
	for city in cities:
		if is_instance_valid(city):
			var angle: float = deg_to_rad(city.rotation_degrees_m)
			var interval := _rectangle_interval((start - city.flight_position).rotated(-angle), (end - city.flight_position).rotated(-angle), Vector2.ZERO, city.city_size_m * 0.5)
			if not interval.is_empty():
				earliest = minf(earliest, interval[0])
	return earliest


# 返回线段在矩形内的参数区间，空数组表示没有交集。
func _rectangle_interval(start: Vector2, end: Vector2, center: Vector2, half_size: Vector2) -> Array[float]:
	var local := start - center
	var delta := end - start
	var enter := 0.0
	var exit := 1.0
	for axis in range(2):
		if absf(delta[axis]) < 0.000001:
			if absf(local[axis]) > half_size[axis]:
				return []
		else:
			var a := (-half_size[axis] - local[axis]) / delta[axis]
			var b := (half_size[axis] - local[axis]) / delta[axis]
			enter = maxf(enter, minf(a, b))
			exit = minf(exit, maxf(a, b))
			if enter > exit:
				return []
	return [enter, exit]


# 实飞与预览共用引力叠加、固定步长半隐式欧拉及全行星撞击裁剪。
func _integrate(position: Vector2, velocity: Vector2, step: float) -> Array[Vector2]:
	# 普通航行维持原固定步；跨引力边界按扫掠交点分段，避免两端圈外漏算整段引力。
	var projected_end := position + (velocity + _gravity_at(position) * step) * step
	var cuts: Array[float] = [0.0, 1.0]
	for source in planets:
		for fraction in _circle_crossings(position, projected_end, source.flight_position, source.max_gravity_radius_m):
			if fraction > 0.000001 and fraction < 0.999999:
				cuts.append(fraction)
	for city in cities:
		if is_instance_valid(city):
			var angle: float = deg_to_rad(city.rotation_degrees_m)
			var center := Vector2(0.0, -(city.city_size_m.y + city.gravity_height_m) * 0.5)
			var bounds := _rectangle_interval((position - city.flight_position).rotated(-angle), (projected_end - city.flight_position).rotated(-angle), center, Vector2(city.city_size_m.x, city.gravity_height_m) * 0.5)
			for fraction in bounds:
				if fraction > 0.000001 and fraction < 0.999999:
					cuts.append(fraction)
	cuts.sort()
	for index in range(1, cuts.size()):
		var interval := step * (cuts[index] - cuts[index - 1])
		if interval <= 0.0:
			continue
		var sample := position if cuts.size() == 2 and cities.is_empty() else position + velocity * interval * 0.5
		# 快速穿越时再细分，各段最大行程约为最小星体半径的1/4；上限约束极端输入。
		var slices := 1
		if cuts.size() > 2:
			for source in planets:
				slices = maxi(slices, mini(128, int(ceil(velocity.length() * interval / maxf(source.radius_m * 0.25, 1.0)))))
		var dt := interval / slices
		for substep in range(slices):
			if cuts.size() > 2:
				sample = position + velocity * dt * 0.5
			var new_velocity := velocity + _gravity_at(sample) * dt
			var end := position + new_velocity * dt
			var fraction := _collision_fraction(position, end)
			if fraction < 1.0 or _touches_planet(end):
				return [position.lerp(end, fraction), Vector2.ZERO]
			position = end
			velocity = new_velocity
	return [position, velocity]


func _circle_crossings(start: Vector2, end: Vector2, center: Vector2, radius: float) -> Array[float]:
	var result: Array[float] = []
	var delta := end - start
	var a := delta.length_squared()
	if a < 0.000001:
		return result
	var offset := start - center
	var b := 2.0 * offset.dot(delta)
	var discriminant := b * b - 4.0 * a * (offset.length_squared() - radius * radius)
	if discriminant < 0.0:
		return result
	for value in [(-b - sqrt(discriminant)) / (2.0 * a), (-b + sqrt(discriminant)) / (2.0 * a)]:
		if value >= 0.0 and value <= 1.0:
			result.append(value)
	return result


func get_preview_horizon() -> float:
	var map_view := get_node_or_null("StarMapView")
	if map_view != null and map_view.is_initialized and map_view.map_mode:
		return map_view.preview_seconds
	return PREVIEW_SECONDS * (EquipmentCatalog.number("computer", "preview_seconds_scale", 1.5) if is_instance_valid(ship) and ship.upgrade_slots.has("computer") else 1.0)


func _preview_world_state() -> Array:
	var state: Array = []
	for source in planets:
		if is_instance_valid(source):
			state.append([source, source.flight_position, source.radius_m, source.field_height_m, source.surface_gravity, source.max_gravity_radius_m])
	for city in cities:
		if is_instance_valid(city):
			state.append([city, city.flight_position, city.city_size_m, city.gravity_height_m, city.rotation_degrees_m])
	return state


func _refresh_preview() -> void:
	preview_job.clear()
	if preview_ship != ship:
		preview_points.clear()
		preview_ship = ship
	if not is_instance_valid(ship) or crashed or ship.voyage_finished:
		preview_points.clear()
		return
	var map_view := get_node_or_null("StarMapView")
	var map_mode: bool = map_view != null and map_view.is_initialized and map_view.map_mode
	preview_job = {
		"ship": ship, "map_mode": map_mode, "paused": simulation_paused, "world": _preview_world_state(),
		"position": ship_position, "velocity": ship_velocity, "fuel": fuel_mass,
		"heading": ship.heading, "coefficient": ship.get_effective_propulsion_fuel_per_delta_v(),
		"steering": ship.steering, "throttle": ship.thrust_throttle,
		"acceleration": ship.get_effective_steering_acceleration(), "direction": ship.thrust_direction,
		"lock": ship.thrust_lock_enabled, "lock_angle": ship.thrust_lock_angle,
		"commands": ship.maneuver_commands.duplicate(), "command_index": ship.maneuver_index,
		"autopilot": ship.autopilot_active, "autopilot_active": ship.autopilot_active,
		"autopilot_enabled": ship.autopilot_enabled,
		"autopilot_phase": ship.autopilot_phase, "autopilot_target": ship.autopilot_target,
		"autopilot_max_speed": ship.autopilot_max_speed,
		"autopilot_decel": ship.get_effective_deceleration(), "autopilot_accel": ship.get_effective_acceleration(),
		"index": 0, "steps": int(get_preview_horizon() / SIM_STEP),
		"points": PackedVector2Array([ship_position])
	}
	if not map_mode:
		_advance_preview_job(int(get_preview_horizon() / SIM_STEP))


func _advance_preview_job(budget: int = PREVIEW_STEPS_PER_FRAME) -> void:
	if preview_job.is_empty():
		return
	var vessel = preview_job.ship
	if not is_instance_valid(vessel) or vessel != ship or vessel.crashed or vessel.voyage_finished:
		preview_job.clear()
		preview_points.clear()
		return
	var map_view := get_node_or_null("StarMapView")
	var map_mode: bool = map_view != null and map_view.is_initialized and map_view.map_mode
	if vessel.maneuver_commands != preview_job.commands or simulation_paused != preview_job.paused or map_mode != preview_job.map_mode or _preview_world_state() != preview_job.world or vessel.autopilot_enabled != preview_job.autopilot_enabled or vessel.autopilot_active != preview_job.autopilot or vessel.autopilot_target != preview_job.autopilot_target or vessel.autopilot_max_speed != preview_job.autopilot_max_speed or vessel.get_effective_deceleration() != preview_job.autopilot_decel or vessel.get_effective_acceleration() != preview_job.autopilot_accel or vessel.get_effective_propulsion_fuel_per_delta_v() != preview_job.coefficient:
		_refresh_preview()
		return
	var position: Vector2 = preview_job.position
	var velocity: Vector2 = preview_job.velocity
	var fuel: float = preview_job.fuel
	var heading: Vector2 = preview_job.heading
	var points: PackedVector2Array = preview_job.points
	var index: int = preview_job.index
	var auto_active: bool = preview_job.autopilot_active
	var auto_phase: int = preview_job.autopilot_phase
	var finished := false
	for unused in range(budget):
		if index >= preview_job.steps:
			finished = true
			break
		var command_index: int = preview_job.command_index + index
		var command: float = preview_job.commands[command_index] if command_index < preview_job.commands.size() else 0.0
		if auto_active:
			var auto: Dictionary = _autopilot_integrate(position, velocity, fuel, preview_job.autopilot_target, auto_phase, preview_job.autopilot_max_speed, preview_job.autopilot_decel, preview_job.autopilot_accel, preview_job.coefficient, SIM_STEP)
			position = auto.position
			velocity = auto.velocity
			fuel = auto.fuel
			auto_phase = auto.phase
			if auto.stopped:
				auto_active = false
				if auto.get("arrived", false):
					points.append(position)
					finished = true
					break
		elif preview_job.steering and fuel > 0.0:
			var direction: Vector2 = _thrust_reference(velocity, heading).rotated(preview_job.lock_angle) if preview_job.lock else preview_job.direction
			var delta_v: float = minf(preview_job.acceleration * preview_job.throttle * SIM_STEP, fuel / maxf(preview_job.coefficient, 0.000001))
			velocity += direction * delta_v
			fuel = maxf(0.0, fuel - delta_v * maxf(preview_job.coefficient, 0.000001))
			var next := _integrate(position, velocity, SIM_STEP)
			position = next[0]
			velocity = next[1]
		elif command == 0.0:
			var next := _integrate(position, velocity, SIM_STEP)
			position = next[0]
			velocity = next[1]
		else:
			var state: Dictionary = _propulsion_step(position, velocity, fuel, SIM_STEP, command, heading, preview_job.coefficient)
			position = state.position
			velocity = state.velocity
			fuel = state.fuel
		if velocity.length() > 0.01:
			heading = velocity.normalized()
		index += 1
		if _touches_planet(position):
			points.append(position)
			finished = true
			break
		if index % PREVIEW_SAMPLE_STEPS == 0:
			points.append(position)
	if finished or index >= preview_job.steps:
		preview_points = points
		preview_job.clear()
		_sync_visuals()
	else:
		preview_job.position = position
		preview_job.velocity = velocity
		preview_job.fuel = fuel
		preview_job.heading = heading
		preview_job.points = points
		preview_job.index = index
		preview_job.autopilot_active = auto_active
		preview_job.autopilot_phase = auto_phase


# ─────────────────────────────────────────────────────────────────────────────
# 航行电脑：选中目标的轨迹预测
# 目标是无动力被动弹道，与玩家自身预演（含燃料/指令/自动驾驶）语义不同，
# 因此独立成一枚 job，独立失效、独立预算，互不抢占。
# ─────────────────────────────────────────────────────────────────────────────

## 门禁：装了航行电脑，且选中的是活着的碎片/小行星，且处于近域视角。
## 放在数据层而不是可视化层——未安装时连一次 _integrate 都不会跑。
func _target_preview_allowed(target: Node2D) -> bool:
	if not is_instance_valid(ship) or not ship.upgrade_slots.has("computer"):
		return false
	if not is_instance_valid(target) or not obstacles.has(target) or target.destroyed:
		return false
	if not (target.is_in_group("space_debris") or target.is_in_group("asteroids")):
		return false
	var map_view := get_node_or_null("StarMapView")
	# 星图视角下船体预演本身也不推进，目标轨迹跟着隐藏，避免两套新鲜度。
	if map_view != null and map_view.is_initialized and map_view.map_mode:
		return false
	return true


## 目标是否"没有未来"：已撞星冻结，或自身没有相对运动。
func _target_is_static(target: Node2D) -> bool:
	if stopped_obstacles.has(target):
		return true
	var velocity: Variant = target.get("flight_velocity")
	if velocity is Vector2:
		return (velocity as Vector2).length_squared() < 0.0001
	return true


## 世界指纹：换图或重新注册天体时预测必须作废。
## 行星与城市在单张地图内静止，因此天体数量足以代表整个引力场。
func _target_preview_world_token() -> int:
	return map_epoch * 1024 + planets.size() * 32 + cities.size()


## 让预测在下一帧重建。不立刻清空已发布结果，避免重算时线条闪断。
func _invalidate_target_preview() -> void:
	target_preview_ttl_elapsed = TARGET_PREVIEW_TTL
	target_preview_dirty = true


## 新建一次预测任务。目标换了就丢弃旧点；同一目标重算时保留旧点直到新结果就绪。
func _refresh_target_preview() -> void:
	var target := inspected_object
	if not _target_preview_allowed(target):
		_clear_target_preview()
		return
	if target_preview_object != target:
		target_preview_dense = PackedVector2Array()
		target_preview_impact = false
		target_preview_dirty = true
		target_preview_object = target
	target_preview_static = _target_is_static(target)
	if target_preview_static:
		# 静止目标没有未来可画：清空轨迹，只靠端点标记与文字提示说明"它就停在这"。
		target_preview_dense = PackedVector2Array()
		target_preview_impact = false
		target_preview_job.clear()
		target_preview_dirty = false
		target_preview_ttl_elapsed = 0.0
		_publish_target_preview()
		return
	if not target_preview_dirty and not target_preview_job.is_empty():
		return
	var horizon := get_preview_horizon()
	target_preview_job = {
		"object": target,
		"token": _target_preview_world_token(),
		"horizon": horizon,
		"steps": maxi(int(horizon / SIM_STEP), 1),
		"index": 0,
		"position": target.flight_position,
		"velocity": target.flight_velocity,
		# 首点必须固定为选中时刻的位置：跨帧累积点，绝不让"推进后的位置"顶替起点，
		# 否则整条轨迹会整体漂移到物体前方，看起来像画在了别处。
		"points": PackedVector2Array([target.flight_position]),
	}
	target_preview_dirty = false
	target_preview_ttl_elapsed = 0.0


## 推进预测：每帧有步数预算；算完整条后抽稀、整段赋值。
## 不在 Line2D 上逐帧追加点：PackedVector2Array 写时复制，循环 append 会退化成 O(n²)，
## 且每次赋值都会触发整条折线重新三角化。
func _advance_target_preview(delta: float) -> void:
	if target_preview_job.is_empty():
		target_preview_ttl_elapsed += delta
		if target_preview_ttl_elapsed >= TARGET_PREVIEW_TTL:
			_refresh_target_preview()
		return
	var target: Node2D = target_preview_job.object
	if not _target_preview_allowed(target):
		_clear_target_preview()
		return
	var position: Vector2 = target_preview_job.position
	var velocity: Vector2 = target_preview_job.velocity
	var index: int = target_preview_job.index
	var steps: int = target_preview_job.steps
	var budget := TARGET_PREVIEW_STEPS_PER_FRAME
	var dense: PackedVector2Array = target_preview_job.points
	var impact := false
	var finished := false
	while budget > 0:
		if index >= steps or dense.size() >= TARGET_PREVIEW_DENSE_LIMIT:
			finished = true
			break
		var next := _integrate(position, velocity, SIM_STEP)
		position = next[0]
		velocity = next[1]
		index += 1
		dense.append(position)
		budget -= 1
		if _touches_planet(position):
			impact = true
			finished = true
			break
	if finished:
		target_preview_dense = dense
		target_preview_impact = impact
		target_preview_job.clear()
		target_preview_ttl_elapsed = 0.0
		_publish_target_preview()
	else:
		target_preview_job.position = position
		target_preview_job.velocity = velocity
		target_preview_job.index = index
		target_preview_job.points = dense


## 把密集点按屏幕像素抽稀后一次性写进 Line2D。
## 抽稀阈值是像素单位，因此在世界坐标里算、在画布坐标里判断，
## 同一份数据在不同视角缩放下都能保持恒定的顶点密度。
func _publish_target_preview() -> void:
	if not is_instance_valid(target_preview):
		return
	var dense := target_preview_dense
	if dense.size() < 2:
		target_preview.points = PackedVector2Array()
		target_preview.visible = false
		if is_instance_valid(target_preview_end):
			target_preview_end.visible = false
		return
	var zoom_factor := maxf($NavigationCamera.zoom.x, 0.0001)
	var view_scale := _view_scale()
	var view_offset := _screen_center()
	var pixel_gap := maxf(TARGET_SAMPLE_CANVAS_PX, TARGET_MIN_SCREEN_PX / zoom_factor)
	var min_step_sq := pixel_gap * pixel_gap
	var travel_limit := minf(TARGET_TRAVEL_CUTOFF_CANVAS_PX, get_viewport_rect().size.x * 3.0)
	var capacity := mini(dense.size(), TARGET_PREVIEW_MAX_POINTS)
	var pts := PackedVector2Array()
	pts.resize(capacity)
	var count := 1
	pts[0] = view_offset + dense[0] * view_scale
	var previous: Vector2 = pts[0]
	var travelled := 0.0
	for i in range(1, dense.size()):
		var canvas_point: Vector2 = view_offset + dense[i] * view_scale
		var delta_px: Vector2 = canvas_point - previous
		var distance_sq := delta_px.length_squared()
		if distance_sq < min_step_sq:
			continue
		travelled += sqrt(distance_sq)
		if travelled > travel_limit or count >= capacity:
			break
		previous = canvas_point
		pts[count] = canvas_point
		count += 1
	if count < 2:
		target_preview.points = PackedVector2Array()
		target_preview.visible = false
		if is_instance_valid(target_preview_end):
			target_preview_end.visible = false
		return
	pts.resize(count)
	# 整段替换：调用内不持有 Line2D.points 的引用，避免写时复制的额外拷贝。
	target_preview.points = pts
	# 近域相机支持 0.025~4.0 滚轮缩放，线宽必须反向补偿才能保持屏幕像素恒定。
	target_preview.width = TARGET_LINE_WIDTH / zoom_factor
	target_preview.default_color = TARGET_LINE_COLOR
	target_preview.visible = true
	_sync_target_preview_end(pts[count - 1])


## 末端标记：普通终点画空心小环，预测会撞上行星时换成醒目的红色实心点。
func _sync_target_preview_end(canvas_point: Vector2) -> void:
	if not is_instance_valid(target_preview_end):
		return
	target_preview_end.visible = true
	target_preview_end.position = canvas_point
	# 反向补偿相机缩放，标记在屏幕上始终是同样大小。
	target_preview_end.scale = Vector2.ONE / maxf($NavigationCamera.zoom.x, 0.0001)
	if is_instance_valid(target_end_continue):
		target_end_continue.visible = not target_preview_impact
	if is_instance_valid(target_end_impact):
		target_end_impact.visible = target_preview_impact
	var ring := target_end_continue.get_node_or_null("Ring") as Line2D
	if ring != null:
		ring.default_color = TARGET_END_COLOR
	var impact_ring := target_end_impact.get_node_or_null("Ring") as Line2D
	if impact_ring != null:
		impact_ring.default_color = TARGET_END_IMPACT_COLOR
	var dot := target_end_impact.get_node_or_null("Dot") as Polygon2D
	if dot != null:
		dot.color = TARGET_END_IMPACT_COLOR


## 清空预测与绘制。切换目标、取消选中、重置航行、进入星图时调用。
func _clear_target_preview() -> void:
	target_preview_job.clear()
	target_preview_dense = PackedVector2Array()
	target_preview_object = null
	target_preview_impact = false
	target_preview_static = false
	target_preview_dirty = true
	target_preview_ttl_elapsed = 0.0
	if is_instance_valid(target_preview):
		target_preview.points = PackedVector2Array()
		target_preview.visible = false
	if is_instance_valid(target_preview_end):
		target_preview_end.visible = false


## 供 SpaceObjectInfo 显示轨迹状态；返回空串表示不需要额外提示。
## UI 只读文案，不参与任何物理判定。
func get_target_trajectory_hint() -> String:
	if not is_instance_valid(inspected_object):
		return ""
	if not is_instance_valid(ship) or not ship.upgrade_slots.has("computer"):
		return ""
	if not obstacles.has(inspected_object):
		return ""
	if not (inspected_object.is_in_group("space_debris") or inspected_object.is_in_group("asteroids")):
		return ""
	if stopped_obstacles.has(inspected_object):
		return "已撞击行星，停止运动"
	if target_preview_static:
		return "静止目标，没有未来轨迹"
	if target_preview_impact:
		return "预测将撞击行星"
	return ""


func _view_scale() -> float:
	return maxf(0.0001, minf((get_viewport_rect().size.x - panel.size.x - 40.0) / 170000.0, get_viewport_rect().size.y / 170000.0))


func _screen_center() -> Vector2:
	return Vector2((get_viewport_rect().size.x - panel.size.x) * 0.5, get_viewport_rect().size.y * 0.5)


func _to_screen(world_position: Vector2) -> Vector2:
	return _screen_center() + world_position * _view_scale()


func _sync_visuals() -> void:
	if not is_node_ready():
		return
	for source in planets:
		# 显示映射绝不写回物理坐标；窗口变化不会改变天体间距。
		source.global_position = $World.to_global(_to_screen(source.flight_position))
		source.scale = Vector2.ONE * source.radius_m * _view_scale() / 200.0
		source.update_boundary()
		source.get_node("OrbitHighlight").visible = selecting_orbit and orbit_candidates.has(source)
	for city in cities:
		if is_instance_valid(city):
			city.global_position = $World.to_global(_to_screen(city.flight_position))
			city.scale = Vector2.ONE * _view_scale() / maxf(city.pixels_per_meter, 0.000001)
	for object in obstacles:
		object.global_position = $World.to_global(_to_screen(object.flight_position))
		object.sync_view($StarMapView.map_mode, _view_scale())
	for net in capture_nets:
		if is_instance_valid(net):
			net.global_position = $World.to_global(_to_screen(net.flight_position))
			net.sync_view($StarMapView.map_mode, _view_scale())
	for drone in drones:
		if is_instance_valid(drone):
			drone.global_position = $World.to_global(_to_screen(drone.flight_position))
			var owner_ship = drone.launched_by
			var facing: Vector2 = owner_ship.heading if is_instance_valid(owner_ship) else Vector2.RIGHT
			drone.sync_view($StarMapView.map_mode, _view_scale(), facing)
	for vessel in ships:
		vessel.position = _to_screen(vessel.flight_position)
		vessel.get_node("Visual").rotation = vessel.heading.angle()
		vessel.get_node("Visual").modulate = Color("e48579") if vessel.crashed else Color.WHITE
		vessel.get_node("SelectionRing").visible = selected and vessel == ship
		vessel.get_node("SelectButton").disabled = false
	var mapped := PackedVector2Array()
	var display_points: PackedVector2Array = pending_plan.points if selecting_orbit and pending_plan.get("ok", false) else preview_points
	for point in display_points:
		mapped.append(_to_screen(point))
	orbit_preview.points = mapped
	var marker_active: bool = is_instance_valid(ship) and ship.autopilot_active
	autopilot_marker.visible = marker_active
	if marker_active:
		autopilot_marker.position = _to_screen(ship.autopilot_target)
	# 轨迹显示是门禁的投影：切到星图、卸装备、目标失效时，这里兜底隐藏，
	# 避免"预测已算完、job 已清空"时 _advance_target_preview 的 TTL 分支迟迟不刷新。
	if not _target_preview_allowed(inspected_object):
		if is_instance_valid(target_preview) and target_preview.visible:
			target_preview.visible = false
		if is_instance_valid(target_preview_end) and target_preview_end.visible:
			target_preview_end.visible = false
	$StarMapView.sync_visuals()
	_refresh_object_inspection()


func _select_ship() -> void:
	if is_instance_valid(ship):
		_select_target(ship)


func _accelerate() -> void:
	_start_thrust(1.0)


func _brake() -> void:
	_start_thrust(-1.0)


func _start_thrust(direction: float) -> void:
	if is_instance_valid(ship) and ship.autopilot_enabled:
		_stop_autopilot("手动推力，自动航行已取消。")
	if tutorial_pause or simulation_paused or selecting_orbit or not selected or not is_instance_valid(ship) or crashed or ship.voyage_finished or fuel_mass <= 0.0:
		return
	_stop_thrust()
	ship.maneuver_commands.clear()
	ship.manual_thrust = direction
	ship.reset_orbit()
	flight_message = ""
	_refresh_preview()
	_update_ui()


func _stop_thrust() -> void:
	for vessel in ships:
		vessel.manual_thrust = 0.0
		if vessel.steering:
			vessel.navigation_status = "修向已停止，按当前速度惯性滑行。"
		vessel.steering = false
		vessel.thrust_throttle = 0.0


func _stop_manual_thrust() -> void:
	for vessel in ships:
		vessel.manual_thrust = 0.0


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		# 长按顺逆推仍随松手结束；油门是持续设定，不能被仪表拖动释放清零。
		_stop_manual_thrust()


# 以真实积分器预演一圈；限制计算量，超出预算时保守地不授予资格。
func _verify_arrival_orbit(vessel: Node2D, source: Node2D) -> bool:
	var position: Vector2 = vessel.flight_position
	var velocity: Vector2 = vessel.flight_velocity
	var start_position := position
	var start_velocity := velocity
	var radius: float = position.distance_to(source.flight_position)
	var direction := signf((position - source.flight_position).cross(velocity))
	if direction == 0.0 or radius <= 0.0:
		return false
	var speed: float = sqrt(source.acceleration_at(position).length() * radius)
	if speed <= 0.0:
		return false
	var steps := mini(int(ceil(TAU * radius / speed * 1.5 / SIM_STEP)), 20000)
	var angle: float = (position - source.flight_position).angle()
	var swept := 0.0
	for index in range(steps):
		var previous_position := position
		var previous_velocity := velocity
		var next := _integrate(position, velocity, SIM_STEP)
		position = next[0]
		velocity = next[1]
		var offset: Vector2 = position - source.flight_position
		var own: Vector2 = source.acceleration_at(position)
		if offset.length() > source.max_gravity_radius_m or own.length() <= 0.0 or velocity.length() <= 0.01 or _touches_planet(position):
			return false
		if (_gravity_at(position) - own).length() / own.length() > vessel.orbit_perturbation_tolerance:
			return false
		var next_angle := offset.angle()
		var increment := wrapf(next_angle - angle, -PI, PI) * direction
		if increment <= 0.0 or signf(offset.cross(velocity)) != direction:
			return false
		if swept + increment >= TAU:
			var fraction := clampf((TAU - swept) / increment, 0.0, 1.0)
			var closing_position := previous_position.lerp(position, fraction)
			var closing_velocity := previous_velocity.lerp(velocity, fraction)
			return closing_position.distance_to(start_position) / radius <= 0.05 and closing_velocity.distance_to(start_velocity) / start_velocity.length() <= 0.05
		swept += increment
		angle = next_angle
	return false


func _update_orbit_eligibility(vessel: Node2D, step: float, force_verify: bool = false) -> void:
	vessel.track_orbit(_dominant_source(vessel.flight_position), _gravity_at(vessel.flight_position), step)
	if not is_instance_valid(vessel.orbit_source) or vessel.orbit_stable_time < 30.0:
		return
	var world_state := _preview_world_state()
	vessel.orbit_verify_elapsed += maxf(step, 0.0)
	if force_verify or vessel.orbit_world_state != world_state or vessel.orbit_world_state.is_empty() or vessel.orbit_verify_elapsed >= 30.0:
		vessel.stay_available = _verify_arrival_orbit(vessel, vessel.orbit_source)
		vessel.orbit_world_state = world_state
		vessel.orbit_verify_elapsed = 0.0


func _can_confirm_arrival(source: Node2D) -> bool:
	return selected and is_instance_valid(ship) and not ship.voyage_finished and not ship.crashed and not ship.steering and ship.manual_thrust == 0.0 and ship.maneuver_index >= ship.maneuver_commands.size() and not selecting_orbit and is_instance_valid(source) and planets.has(source) and ship.orbit_source == source and ship.orbit_stable_time >= 30.0 and ship.stay_available


func _sync_arrival_buttons() -> void:
	for source in planets:
		var button: Button = source.get_node("ConfirmArrival")
		button.visible = _can_confirm_arrival(source)
		# 抵消行星自身缩放和相机缩放，按钮始终保持屏幕像素大小。
		var inverse_scale: float = 1.0 / maxf(absf(source.global_scale.x) * $NavigationCamera.zoom.x, 0.000001)
		button.scale = Vector2.ONE * inverse_scale
		button.position = -button.size * inverse_scale * 0.5


func _confirm_arrival(source: Node2D) -> void:
	if not _can_confirm_arrival(source):
		return
	# 点击时复核当前轨道，避免过期资格或编辑器调整后仍可确认。
	_update_orbit_eligibility(ship, 0.0, true)
	if not _can_confirm_arrival(source):
		_sync_arrival_buttons()
		return
	_stop_thrust()
	_stop_autopilot()
	ship.departure_position = ship_position
	ship.departure_velocity = ship_velocity
	ship.arrival_source = source
	ship.voyage_finished = true
	ship.last_voyage_distance_m = ship.current_voyage_distance_m
	ship.completed_voyage_count += 1
	ship.flight_velocity = Vector2.ZERO
	ship.maneuver_commands.clear()
	ship.reset_orbit()
	ship.navigation_status = "本次航行已结束；成功起航时将补满当前飞船燃料并恢复原轨道。"
	flight_message = ship.navigation_status
	_refresh_preview()
	_update_ui()
	_sync_visuals()
	$PortController.enter_port(source, ship)
	_save_checkpoint()


func _depart() -> void:
	if tutorial_pause:
		# 港口起航按钮由 port_controller 回显 flight_message，兜底给出可执行提示。
		flight_message = "教程进行中，请先完成当前步骤，或用教程面板跳过本阶段。"
		_update_ui()
		return
	_clear_object_inspection()
	if not selected or not is_instance_valid(ship) or ship.crashed or not ship.voyage_finished:
		return
	var city_departure := is_instance_valid(ship.arrival_source) and cities.has(ship.arrival_source)
	if not city_departure and (not is_instance_valid(ship.arrival_source) or not planets.has(ship.arrival_source) or ship.arrival_source.acceleration_at(ship.departure_position).length_squared() <= 0.0 or _touches_planet(ship.departure_position)):
		flight_message = "原轨道参考行星失效，无法起航；请重置航行。"
		_update_ui()
		return
	if not city_departure:
		ship.flight_position = ship.departure_position
	ship.flight_velocity = Vector2.ZERO if city_departure else ship.departure_velocity
	ship.fuel = ship.get_fuel_capacity()
	ship.departed_city = ship.arrival_source if city_departure else null
	ship.voyage_finished = false
	ship.current_voyage_distance_m = 0.0
	ship.arrival_source = null
	ship.reset_orbit()
	ship.navigation_status = "已从城市停靠位置起航，燃料已补满。" if city_departure else "已起航：恢复原轨道，燃料已补满。"
	flight_message = ship.navigation_status
	$PortController.leave_port()
	_refresh_preview()
	_update_ui()
	_sync_visuals()
	_save_checkpoint()
	# 起航 = 本局新的回档点；与自动存档同一时机抓取，教程同帧换图时才不会抓到中间态。
	_stash_departure()


## 记录「上次起航」的完整快照，供撞毁 / 燃油耗尽时回档。
## 连推两个帧末：起航本身会先注册一次 deferred（存档），而教程「本课完成」也是 deferred，
## 且换图排在存档之后——只等一次会抓到「教程已结束、地图还是旧那张」的中间态，
## 回档后玩家会卡在旧地图上没有教程可走。等两轮让换图先生效。
func _stash_departure() -> void:
	_stash_departure_after_switch.call_deferred()


func _stash_departure_after_switch() -> void:
	_stash_departure_now.call_deferred()


func _stash_departure_now() -> void:
	if not is_inside_tree():
		return
	var saves := get_node_or_null("/root/SaveManager")
	if saves == null or not saves.has_method("stash_departure"):
		return
	saves.stash_departure()


## 是否需要回档：撞毁，或燃料耗尽且已不可能入轨（入轨进港会补满燃料，还能继续玩）。
## 返回空串表示当前仍能自己救回来，不提供回档。
func _rollback_reason() -> String:
	if not is_instance_valid(ship):
		return ""
	if ship.crashed:
		return "飞船已损毁"
	if ship.voyage_finished or ship.fuel > 0.0001:
		return ""
	# 已在可确认的稳定轨道上：还能入港补给，不算卡死。
	if is_instance_valid(ship.orbit_source) and ship.stay_available:
		return ""
	return "燃料耗尽且未入轨"


func _has_departure() -> bool:
	var saves := get_node_or_null("/root/SaveManager")
	return saves != null and saves.has_method("has_departure") and saves.has_departure()


## 回档到上次起航。恢复的是整份快照，所以信用点、装备解锁、任务进度会一起回到起航时；
## 网体、舰载机、瞄准与查看面板属于本次航行的临时态（不入存档），在这里一并清掉。
func _rollback_to_departure() -> void:
	if _rollback_reason().is_empty():
		flight_message = "当前仍可继续航行，无需回档。"
		_update_ui()
		return
	var saves := get_node_or_null("/root/SaveManager")
	if saves == null or not saves.has_method("restore_departure") or not _has_departure():
		flight_message = "还没有起航记录，无法回档；可点「重置」回到初始状态。"
		_update_ui()
		return
	_clear_object_inspection()
	_cancel_capture_aim()
	_clear_capture_nets()
	_clear_drones()
	_stop_autopilot()
	simulation_paused = false
	selecting_orbit = false
	orbit_candidates.clear()
	pending_target = null
	pending_plan.clear()
	if not saves.restore_departure():
		flight_message = "回档失败：回档点与当前场景不匹配；可点「重置」回到初始状态。"
		_update_ui()
		_sync_visuals()
		return
	flight_message = "已回档到上次起航。"
	_update_ui()
	_sync_visuals()


## 停泊/起航时的自动存档：延到帧末再抓快照。
## 教程阶段切换会在同一帧重新加载地图（load_map_file 还会顺手 leave_port），
## 立刻 snapshot 有可能存下「阶段已经变了、地图还是旧的那张」的中间态，
## 读档时 map_hash 对不上就会判成损坏存档。所以统一等这一帧收尾后再写。
func _save_checkpoint() -> void:
	_save_checkpoint_now.call_deferred()


func _save_checkpoint_now() -> void:
	if not is_inside_tree():
		return
	var saves := get_node_or_null("/root/SaveManager")
	if saves == null or not saves.has_method("save_checkpoint"):
		return
	if saves.save_checkpoint():
		return
	# 存档没启用时（地图无效、或没有走主菜单的测试环境）保持静默；
	# 本该能存却失败了才把提示追加到航行消息里，不吞掉起航/停泊本身的信息。
	if not bool(saves.get("enabled")):
		return
	var hint := "自动存档失败，原存档已保留。"
	flight_message = hint if flight_message.is_empty() else "%s %s" % [flight_message, hint]


func set_tutorial_pause(value: bool) -> void:
	if tutorial_pause == value:
		return
	var menu := get_node_or_null("PauseMenu")
	var menu_open: bool = menu != null and menu.is_open()
	if value:
		tutorial_previous_pause = menu.was_paused if menu_open else simulation_paused
		_stop_thrust()
		_stop_autopilot()
		_cancel_capture_aim()
		tutorial_pause = true
		simulation_paused = true
		accumulator = 0.0
	else:
		tutorial_pause = false
		if menu_open:
			menu.was_paused = tutorial_previous_pause
			simulation_paused = true
		else:
			simulation_paused = tutorial_previous_pause


func _toggle_pause() -> void:
	if capture_aim_active:
		_cancel_capture_aim("已取消捕捉网瞄准。")
	elif tutorial_pause:
		flight_message = "教程暂停中，请确认当前说明后继续；也可跳过本阶段教学。"
	elif selecting_orbit:
		flight_message = "请先确认或取消入轨选星。"
	else:
		simulation_paused = not simulation_paused
		if simulation_paused:
			_stop_thrust()
	_update_ui()


func _tutorial_allows_docking() -> bool:
	return $TutorialController.allows_docking() and $OrbitTutorialController.allows_docking()


func _can_dock_city(city: Node2D) -> bool:
	return selected and is_instance_valid(ship) and is_instance_valid(city) and cities.has(city) and not $PortController.active and not selecting_orbit and not ship.crashed and not ship.voyage_finished and ship.departed_city != city and city.contains_docking_point(ship.flight_position) and ship.flight_velocity.length_squared() <= DOCK_SPEED_TOLERANCE * DOCK_SPEED_TOLERANCE and not _touches_planet(ship.flight_position) and _tutorial_allows_docking()


func _sync_city_buttons() -> void:
	var select_button: Button = ship.get_node_or_null("SelectButton") if is_instance_valid(ship) else null
	var dock_button_shown := false
	for city in cities:
		if not is_instance_valid(city):
			continue
		var button: Button = city.get_node("DockButton")
		button.visible = _can_dock_city(city)
		dock_button_shown = dock_button_shown or button.visible
		var inverse_scale: float = 1.0 / maxf(absf(city.global_scale.x) * $NavigationCamera.zoom.x, 0.000001)
		button.scale = Vector2.ONE * inverse_scale
		button.rotation = -city.rotation
		button.position = (city.port_offset_m + city.dock_offset_m) * city.pixels_per_meter - (button.size * inverse_scale * 0.5).rotated(button.rotation)
	# 飞船的选择按钮（50×50 且完全透明）会盖住同位置的「泊船」按钮并吃掉点击，
	# 此时飞船必然已被选中，让出鼠标命中即可。
	if select_button:
		select_button.mouse_filter = Control.MOUSE_FILTER_IGNORE if dock_button_shown else Control.MOUSE_FILTER_STOP


func _dock_city(city: Node2D) -> void:
	if not _can_dock_city(city):
		_sync_city_buttons()
		return
	_stop_thrust()
	_finish_city_arrival(ship, city)
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _begin_orbit_selection() -> void:
	if tutorial_pause:
		return
	if capture_aim_active:
		_cancel_capture_aim("已取消捕捉网瞄准。")
	_clear_object_inspection()
	if not selected or not is_instance_valid(ship) or crashed or ship.voyage_finished:
		return
	if ship.maneuver_index < ship.maneuver_commands.size():
		ship.maneuver_commands.clear()
		flight_message = "已取消入轨；保留已产生的速度和已消耗的燃料。"
		_update_ui()
		return
	_stop_thrust()
	paused_before_selection = simulation_paused
	simulation_paused = true
	selecting_orbit = true
	pending_plan.clear()
	pending_target = null
	orbit_candidates.clear()
	for source in planets:
		if ship_position.distance_to(source.flight_position) <= ship.orbit_search_radius and source.acceleration_at(ship_position).length_squared() > 0.0:
			orbit_candidates.append(source)
	flight_message = "点击高亮行星，计算顺逆推入轨方案。" if not orbit_candidates.is_empty() else "搜索范围内没有提供有效引力的行星，可取消后接近目标。"
	_update_ui()
	_sync_visuals()


func _choose_orbit_target(target: Node2D) -> void:
	if not selecting_orbit or not orbit_candidates.has(target) or not planets.has(target):
		return
	pending_target = target
	pending_plan = OrbitPlanner.plan(self, ship, target)
	if pending_plan.get("ok", false):
		flight_message = "预计 %.1f 模拟秒 / %.1f m/s Δv\n最终高度 %.2f km，确认后恢复运行。" % [pending_plan.duration, ship.fuel_to_delta_v(pending_plan.fuel_cost), (pending_plan.final_radius - target.radius_m) / 1000.0]
	else:
		flight_message = pending_plan.get("reason", "未找到安全入轨方案。")
	_update_ui()
	_sync_visuals()


func _cancel_orbit_selection() -> void:
	if not selecting_orbit:
		return
	selecting_orbit = false
	simulation_paused = paused_before_selection
	pending_plan.clear()
	pending_target = null
	orbit_candidates.clear()
	flight_message = "已取消选星，未扣油。"
	_update_ui()
	_sync_visuals()


## 船载装置快捷栏：第 0 格固定为自动入轨，其余按槽位顺序绑定捕捉网，一件装备占一格。
func _on_skill_slot_pressed(index: int) -> void:
	if index == 0:
		_begin_orbit_selection()
		return
	if index < 1 or not selected or not is_instance_valid(ship) or ship.crashed or ship.voyage_finished:
		return
	if $PortController.active or tutorial_pause or selecting_orbit:
		return
	var loadout: Array = ship.skill_loadout()
	var loadout_index := index - 1
	if loadout_index < 0 or loadout_index >= loadout.size():
		return
	match str(loadout[loadout_index]):
		"capture_net":
			if capture_aim_active and capture_aim_slot == index:
				_launch_capture_net()
			else:
				_begin_capture_aim(index)
		"drone_engineer":
			_toggle_drone("engineer")
		"drone_guard":
			_toggle_drone("guard")


## 船坞拆除装备后的清理：把该装备在航行中的功能与实例一起收掉，
## 保证"槽位里没东西了，按钮和效果也不会残留"。
func on_equipment_removed(id: String) -> void:
	match id:
		"capture_net":
			# 瞄准是这件装备的功能，拆掉立即取消；已经发射的网是独立物体，留在太空继续工作。
			var loadout: Array = ship.skill_loadout() if is_instance_valid(ship) else []
			var aiming_index := capture_aim_slot - 1
			if capture_aim_active and (aiming_index < 0 or aiming_index >= loadout.size() or str(loadout[aiming_index]) != "capture_net"):
				_cancel_capture_aim("捕捉网已拆除，瞄准取消。")
		"hangar":
			if not drones.is_empty():
				_clear_drones()
				flight_message = "机库已拆除，舰载机全部回收。"
		"computer":
			# 轨迹预演用的是航行电脑的算力，拆掉后已算出的预测立刻作废。
			_clear_object_inspection()
		"fuel":
			if is_instance_valid(ship):
				ship.clamp_fuel_to_capacity()
		"shield":
			if is_instance_valid(ship):
				ship.shield_ready = false
	_update_ui()
	_sync_visuals()


## 冻结时间并显示瞄准箭头；箭头初始指向飞船航向。
func _begin_capture_aim(slot: int) -> void:
	_clear_object_inspection()
	_stop_thrust()
	_stop_autopilot("捕捉网瞄准，自动航行已暂停。")
	paused_before_aim = simulation_paused
	simulation_paused = true
	capture_aim_active = true
	capture_aim_slot = slot
	capture_aim_angle = wrapf(ship.heading.angle(), -PI, PI)
	capture_aim.show_aim(_ship_screen_position(), capture_aim_angle)
	flight_message = "捕捉网已就位：拖动箭头或用输入框设定方向，再次点击该按钮发射。"
	_update_ui()
	_sync_visuals()


func _cancel_capture_aim(message: String = "") -> void:
	if not capture_aim_active:
		return
	capture_aim_active = false
	capture_aim_slot = -1
	capture_aim.hide_aim()
	simulation_paused = paused_before_aim
	if not message.is_empty():
		flight_message = message
	_update_ui()


func _set_capture_aim_angle(radians: float) -> void:
	if not capture_aim_active:
		return
	capture_aim_angle = wrapf(radians, -PI, PI)
	capture_aim.set_angle(capture_aim_angle)
	flight_message = "捕捉网瞄准：%.1f°" % rad_to_deg(capture_aim_angle)


## 瞄准期间每帧跟随飞船；飞船失去可操作状态时自动取消。
func _update_capture_aim() -> void:
	if not capture_aim_active:
		return
	if not selected or not is_instance_valid(ship) or ship.crashed or ship.voyage_finished or $PortController.active:
		_cancel_capture_aim("捕捉网瞄准已取消。")
		return
	capture_aim.set_placement(_ship_screen_position())


func _ship_screen_position() -> Vector2:
	return get_canvas_transform() * ship.global_position


func _update_capture_aim_from_mouse(point: Vector2) -> void:
	var offset := point - _ship_screen_position()
	if offset.length_squared() <= 4.0:
		return
	_set_capture_aim_angle(offset.angle())


## 沿箭头方向发射；网体继承飞船速度，再加飞船配置的发射速度。
func _launch_capture_net() -> void:
	if not capture_aim_active or not is_instance_valid(ship):
		return
	var net := CAPTURE_NET.instantiate()
	$World.add_child(net)
	net.launch(ship, Vector2.from_angle(capture_aim_angle), EquipmentCatalog.values("capture_net"))
	capture_nets.append(net)
	capture_aim_active = false
	capture_aim_slot = -1
	capture_aim.hide_aim()
	simulation_paused = paused_before_aim
	flight_message = "捕捉网已发射：灰色网体持续扩张，吸附接触到的太空碎片。"
	_update_ui()
	_sync_visuals()


func _clear_capture_nets() -> void:
	for net in capture_nets:
		if is_instance_valid(net):
			net.queue_free()
	capture_nets.clear()
	recovered_mass_kg = 0.0


## 推进捕捉网：自由飞行、半径膨胀、按几何覆盖率橡皮擦式擦除碎片，捕获到的质量当场记入回收。
func _update_capture_nets(step: float) -> void:
	for net in capture_nets.duplicate():
		if not is_instance_valid(net):
			capture_nets.erase(net)
			continue
		if net.destroyed:
			capture_nets.erase(net)
			net.queue_free()
			continue
		var start: Vector2 = net.flight_position
		# 网体走统一的引力积分，不做特判；擦到的质量在进网那一刻就已经记账。
		var next := _integrate(net.flight_position, net.flight_velocity, step)
		net.flight_position = next[0]
		net.flight_velocity = next[1]
		net.expand(step)
		var erased_mass := 0.0
		var wiped_fragments := 0
		if not net.is_full():
			for object in obstacles:
				if not is_instance_valid(object) or object.destroyed or not object.is_in_group("space_debris"):
					continue
				if not net.reaches_along(start, object):
					continue
				# 擦头盖住多大一片，就最多能擦掉多大比例；擦过的比例不会因为网体移动而恢复。
				var coverage: float = object.coverage_of(net.flight_position, net.radius_m)
				if coverage <= 0.0:
					continue
				var wiped_before: int = object.wiped_fragment_count
				erased_mass += object.erase_towards(coverage, step, net.erase_follow_rate_per_s, net.flight_position, net.radius_m)
				wiped_fragments += object.wiped_fragment_count - wiped_before
				# 整团还在时保留 stopped 状态；只有被擦空才退出障碍处理。
				if object.destroyed:
					stopped_obstacles.erase(object)
		if erased_mass > 0.0 or wiped_fragments > 0:
			var absorbed_before: float = net.absorbed_mass_kg
			net.absorb_erased(erased_mass, wiped_fragments)
			# 捕捉即回收：真正进网的那部分质量当场记账，不等网体飞去哪、也不等它落点。
			var gained: float = net.absorbed_mass_kg - absorbed_before
			if gained > 0.0:
				_note_recovered(gained)
			flight_message = "捕捉网已擦除 %.1f kg / 上限 %.0f kg。" % [net.absorbed_mass_kg, net.capture_capacity_kg]
		if net.is_full() and not net.full_notified:
			net.full_notified = true
			flight_message = "捕捉网已达最大擦除质量 %.0f kg，停止擦除。" % net.capture_capacity_kg
		# 半径到上限只是停止扩张，网体继续留在太空中；只有有限寿命到期或（可配置的）撞行星才回收。
		if net.capped and not net.cap_notified:
			net.cap_notified = true
			flight_message = "捕捉网已扩张到最大半径 %.0f m，停止扩张。" % net.radius_m
		var touched_planet: bool = _touches_planet(net.flight_position) and bool(net.destroy_on_planet_impact)
		if touched_planet:
			_discard_capture_net(net)
			continue
		if net.has_lifetime() and net.remaining_s <= 0.0:
			flight_message = "捕捉网寿命结束，已回收。"
			net.shutdown()
			capture_nets.erase(net)
			net.queue_free()


## 把真正进网的质量记为已回收物资，并推进 recycle_mass 任务。
## 空网、被容量上限挡掉的部分都不会走到这里。
func _note_recovered(mass: float) -> void:
	if mass <= 0.0:
		return
	recovered_mass_kg += mass
	var manager := get_node_or_null("QuestManager")
	if manager != null and manager.has_method("note_recycle"):
		manager.note_recycle(mass)


## 网体坠入行星：只销毁网体。捕获的质量在进网那一刻已经记账，这里不重复结算。
func _discard_capture_net(net: Node2D) -> void:
	net.shutdown()
	capture_nets.erase(net)
	net.queue_free()
	flight_message = "捕捉网落入行星，已销毁。"


# --- 舰载机：机库释放的工程机 / 近卫机。参数全部来自 data/equipment.json。 ---

## 某型舰载机的配置；机库没装或目录缺该机型时返回空字典。
func _drone_definition(kind: String) -> Dictionary:
	if not is_instance_valid(ship) or not ship.has_hangar():
		return {}
	return EquipmentCatalog.drone_def(kind)


func _drone_label(kind: String) -> String:
	var fallback := "近卫机" if kind == "guard" else "工程机"
	return EquipmentCatalog.text_from(_drone_definition(kind), "name", fallback)


func _has_drone(kind: String) -> bool:
	for drone in drones:
		if is_instance_valid(drone) and not drone.recalled and drone.kind == kind:
			return true
	return false


## 工程机只能在行星引力区内释放；近卫机只受飞船可操作状态限制。
func _can_release_drone(kind: String) -> bool:
	if not selected or not is_instance_valid(ship) or ship.crashed or ship.voyage_finished:
		return false
	if $PortController.active or tutorial_pause or selecting_orbit:
		return false
	var definition := _drone_definition(kind)
	if definition.is_empty():
		return false
	if kind == "engineer" and bool(definition.get("release_requires_gravity", true)):
		return _is_in_gravity_region(ship.flight_position)
	return true


## 同一机型同时在轨只允许一架：再点一次就是召回。
func _toggle_drone(kind: String) -> void:
	for drone in drones.duplicate():
		if is_instance_valid(drone) and not drone.recalled and drone.kind == kind:
			_recall_drone(drone, "%s已回收。" % _drone_label(kind))
			return
	if not _can_release_drone(kind):
		if kind == "engineer":
			flight_message = "工程机只能在行星引力区内释放。"
		return
	_release_drone(kind)


func _release_drone(kind: String) -> void:
	var definition := _drone_definition(kind)
	if definition.is_empty():
		return
	var drone := DRONE.instantiate()
	$World.add_child(drone)
	drone.configure(kind, definition, ship)
	drone.flight_position = ship.flight_position
	if kind == "engineer":
		# 释放即入轨：位置取飞船当前半径，速度取该半径的圆轨道速度（顺行）。
		drone.flight_velocity = _circular_velocity_at(ship.flight_position)
	else:
		var offset := maxf(float(definition.get("offset_m", 0.0)), 0.0)
		drone.flight_position = ship.flight_position + ship.heading.normalized() * offset
		drone.flight_velocity = ship.flight_velocity
	drones.append(drone)
	flight_message = "%s已释放。" % _drone_label(kind)
	_update_ui()
	_sync_visuals()


## 行星的引力不是标准 mu/r²：恒强层内 g 恒定，层外按 (层顶/距离)² 衰减。
## 圆轨道速度因此分两段，这里统一换算，避免工程机被释放进一个必然坠落的轨道。
func _circular_velocity_at(point: Vector2) -> Vector2:
	var source := _dominant_source(point)
	if not is_instance_valid(source):
		return ship.flight_velocity
	var offset: Vector2 = point - source.flight_position
	var radius := offset.length()
	if radius <= source.radius_m or radius <= 0.001:
		return ship.flight_velocity
	var field_top: float = source.radius_m + source.field_height_m
	var speed := 0.0
	if radius < field_top:
		speed = sqrt(maxf(source.surface_gravity, 0.0) * radius)
	else:
		var mu: float = source.surface_gravity * field_top * field_top
		speed = sqrt(mu / radius)
	var source_velocity := _source_velocity(source)
	# 顺行：与当前相对速度同向；相对速度为零时取切向（半径逆时针转 90°）。
	var tangent := Vector2(-offset.y, offset.x).normalized()
	var relative: Vector2 = ship.flight_velocity - source_velocity
	if relative.dot(tangent) < 0.0:
		tangent = -tangent
	return source_velocity + tangent * speed


func _source_velocity(source: Node) -> Vector2:
	var value: Variant = source.get("flight_velocity")
	return value if value is Vector2 else Vector2.ZERO


func _recall_drone(drone: Node2D, message: String = "") -> void:
	if not is_instance_valid(drone):
		drones.erase(drone)
		return
	drone.recalled = true
	drones.erase(drone)
	drone.queue_free()
	if not message.is_empty():
		flight_message = message
	_update_ui()
	_sync_visuals()


func _clear_drones() -> void:
	for drone in drones:
		if is_instance_valid(drone):
			drone.recalled = true
			drone.queue_free()
	drones.clear()


func _update_drones(step: float) -> void:
	for drone in drones.duplicate():
		if not is_instance_valid(drone) or drone.recalled:
			drones.erase(drone)
			if is_instance_valid(drone):
				drone.queue_free()
			continue
		var owner_ship = drone.launched_by
		if not is_instance_valid(owner_ship) or owner_ship.crashed or owner_ship.voyage_finished:
			_recall_drone(drone, "母船已失去作业能力，舰载机已回收。")
			continue
		if drone.kind == "guard":
			_update_guard_drone(drone, owner_ship, step)
		else:
			_update_engineer_drone(drone, step)
		if drone.tick_lifetime(step):
			_recall_drone(drone, "%s作业时间结束，已回收。" % _drone_label(drone.kind))


## 工程机：按统一积分器自由飞行（所以会自动绕行星运行），对作业半径内的碎片做橡皮擦式回收。
func _update_engineer_drone(drone: Node2D, step: float) -> void:
	var next := _integrate(drone.flight_position, drone.flight_velocity, step)
	drone.flight_position = next[0]
	drone.flight_velocity = next[1]
	if drone.is_exhausted():
		_recall_drone(drone, "工程机回收仓已满，已回收。")
		return
	var radius := maxf(float(drone.definition.get("recycle_radius_m", 0.0)), 0.0)
	var rate := maxf(float(drone.definition.get("recycle_rate_per_s", 0.0)), 0.0)
	if radius <= 0.0 or rate <= 0.0:
		return
	var gained := 0.0
	for object in obstacles:
		if not is_instance_valid(object) or object.destroyed or not object.is_in_group("space_debris"):
			continue
		if drone.flight_position.distance_to(object.flight_position) > radius + object.current_radius_m():
			continue
		var coverage: float = object.coverage_of(drone.flight_position, radius)
		if coverage <= 0.0:
			continue
		var erased: float = object.erase_towards(coverage, step, rate, drone.flight_position, radius)
		if erased > 0.0:
			gained += drone.absorb(erased)
			if object.destroyed:
				stopped_obstacles.erase(object)
	if gained > 0.0:
		_note_recovered(gained)
		flight_message = "工程机回收 %.1f kg / 本次上限 %.0f kg。" % [drone.absorbed_mass_kg, float(drone.definition.get("recycle_capacity_kg", 0.0))]


## 近卫机：贴着母船前侧跟随，持续熔掉前方扇形内的碎片，不计入回收物资（是摧毁不是打捞）。
func _update_guard_drone(drone: Node2D, owner_ship: Node2D, step: float) -> void:
	var offset := maxf(float(drone.definition.get("offset_m", 0.0)), 0.0)
	var facing: Vector2 = owner_ship.heading
	if facing.length_squared() <= 0.000001:
		return
	facing = facing.normalized()
	drone.flight_position = owner_ship.flight_position + facing * offset
	drone.flight_velocity = owner_ship.flight_velocity
	var range_m := maxf(float(drone.definition.get("range_m", 0.0)), 0.0)
	var half_angle := deg_to_rad(clampf(float(drone.definition.get("cone_angle_deg", 0.0)), 0.0, 360.0) * 0.5)
	var melt := maxf(float(drone.definition.get("melt_kg_per_s", 0.0)), 0.0) * maxf(step, 0.0)
	if range_m <= 0.0 or half_angle <= 0.0 or melt <= 0.0:
		return
	for object in obstacles:
		if not is_instance_valid(object) or object.destroyed or not object.is_in_group("space_debris"):
			continue
		var to_object: Vector2 = object.flight_position - drone.flight_position
		var distance := to_object.length()
		if distance > range_m + object.current_radius_m():
			continue
		if distance > 0.0001 and absf(facing.angle_to(to_object / distance)) > half_angle:
			continue
		var was_destroyed: bool = object.destroyed
		object.melt_mass(melt, drone.flight_position, range_m * 0.15)
		if object.destroyed and not was_destroyed:
			stopped_obstacles.erase(object)
			flight_message = "近卫机摧毁了一团太空碎片。"


func _confirm_orbit() -> void:
	if not selecting_orbit or not is_instance_valid(pending_target) or not planets.has(pending_target):
		return
	# 再计算一次，避免检查器编辑/状态变化使旧预算失效。
	pending_plan = OrbitPlanner.plan(self, ship, pending_target)
	if not pending_plan.get("ok", false):
		flight_message = pending_plan.get("reason", "方案已失效。")
		_update_ui()
		return
	ship.maneuver_commands = pending_plan.commands.duplicate()
	ship.maneuver_index = 0
	ship.maneuver_target = pending_target
	ship.reset_orbit()
	selecting_orbit = false
	simulation_paused = false
	orbit_candidates.clear()
	flight_message = "执行顺逆推入轨，可点击取消入轨中断。"
	pending_plan.clear()
	_refresh_preview()
	_update_ui()
	_sync_visuals()


func _clear_object_inspection() -> void:
	inspected_object = null
	_clear_target_preview()
	if is_instance_valid(get_node_or_null("HUD/Root/SpaceObjectInfo")):
		$HUD/Root/SpaceObjectInfo.refresh(null, _view_scale(), $NavigationCamera.zoom.x, "")


func _refresh_object_inspection() -> void:
	if not is_instance_valid(inspected_object) or not inspected_object.is_inside_tree() or inspected_object.is_queued_for_deletion() or not obstacles.has(inspected_object) or inspected_object.destroyed or $PortController.active:
		inspected_object = null
		_clear_target_preview()
	$HUD/Root/SpaceObjectInfo.refresh(inspected_object, _view_scale(), $NavigationCamera.zoom.x, get_target_trajectory_hint())


func _object_at_screen(screen_position: Vector2) -> Node2D:
	# 保留星图行星导航的命中优先级，飞船和港口按钮由 GUI 先消费。
	if $StarMapView.map_mode and selected:
		for source in planets:
			var point: Vector2 = get_canvas_transform() * source.global_position
			if screen_position.distance_to(point) <= maxf(18.0, source.radius_m * _view_scale() * $NavigationCamera.zoom.x):
				return null
	var nearest: Node2D
	var nearest_distance := INF
	for object in obstacles:
		if not is_instance_valid(object) or object.destroyed or object.is_queued_for_deletion() or not object.is_visible_in_tree():
			continue
		var point: Vector2 = object.get_global_transform_with_canvas().origin
		var distance := screen_position.distance_to(point)
		var radius: float = maxf(12.0, _obstacle_radius(object) * _view_scale() * $NavigationCamera.zoom.x)
		if distance <= radius and distance < nearest_distance:
			nearest = object
			nearest_distance = distance
	return nearest


## 障碍物的当前半径：太空垃圾被擦除后会缩小，小行星保持配置半径。
func _obstacle_radius(object: Node) -> float:
	if object != null and object.has_method("current_radius_m"):
		return float(object.current_radius_m())
	return float(object.radius_m)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if capture_aim_active:
			_cancel_capture_aim("已取消捕捉网瞄准。")
		elif selecting_orbit:
			_cancel_orbit_selection()
		else:
			var pause_menu := get_node_or_null("PauseMenu")
			if pause_menu and pause_menu.has_method("toggle"):
				pause_menu.toggle()
		get_viewport().set_input_as_handled()
		return
	if capture_aim_active:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if not capture_aim.contains_point(event.position):
				_update_capture_aim_from_mouse(event.position)
				get_viewport().set_input_as_handled()
				return
		elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
			if not capture_aim.contains_point(event.position):
				_update_capture_aim_from_mouse(event.position)
				get_viewport().set_input_as_handled()
				return
	if $PortController.active:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if selecting_orbit or tutorial_pause or simulation_paused:
			return
		if not selected or not is_instance_valid(ship):
			return
		if ship.crashed or ship.voyage_finished:
			flight_message = "飞船当前无法自动航行。"
			_update_ui()
			return
		if not ship.autopilot_enabled:
			return
		if _is_in_gravity_region(ship.flight_position):
			flight_message = "处于引力区内，无法自动航行。"
			_update_ui()
			return
		# 点在障碍物/对象上时不设自动航行点，避免与对象查看混淆。
		if is_instance_valid(_object_at_screen(event.position)):
			return
		# 近域与星图共用同一画布→世界坐标换算（与左键星图导航一致）。
		var canvas_point: Vector2 = $World.to_local(get_canvas_transform().affine_inverse() * event.position)
		var meters := (canvas_point - _screen_center()) / _view_scale()
		_set_autopilot_target(meters)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if selecting_orbit:
			var mouse_world: Vector2 = get_canvas_transform().affine_inverse() * event.position
			for source in orbit_candidates:
				if is_instance_valid(source) and mouse_world.distance_to(source.global_position) <= source.radius_m * _view_scale():
					_choose_orbit_target(source)
					break
			return
		var object := _object_at_screen(event.position)
		if is_instance_valid(object):
			inspected_object = object
			_refresh_target_preview()
			_refresh_object_inspection()
			get_viewport().set_input_as_handled()
			return
		_clear_object_inspection()
		if $StarMapView.map_mode and selected and is_instance_valid(ship):
			var canvas_point: Vector2 = $World.to_local(get_canvas_transform().affine_inverse() * event.position)
			var meters := (canvas_point - _screen_center()) / _view_scale()
			var target_planet: Node2D
			for source in planets:
				var screen_point: Vector2 = get_canvas_transform() * source.global_position
				if event.position.distance_to(screen_point) <= maxf(18.0, source.radius_m * _view_scale() * $NavigationCamera.zoom.x):
					target_planet = source
					meters = source.flight_position
					break
			_set_navigation_target(meters, target_planet)
			get_viewport().set_input_as_handled()
			return
		_stop_thrust()
		flight_message = ""
		selected = false
		_update_ui()
		_sync_visuals()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_reset()


func _set_navigation_target(point: Vector2, target_planet: Node2D = null) -> void:
	if not selected or not is_instance_valid(ship) or selecting_orbit:
		return
	ship.navigation_target = point
	ship.navigation_planet = target_planet
	ship.navigation_tracks_planet = is_instance_valid(target_planet)
	ship.has_navigation_target = true
	ship.navigation_status = "已标记星心：不会自动避撞或制动，建议瞄准星体旁的空间点。" if is_instance_valid(target_planet) else "目标仅作导航参考；推力由仪表方向与油门控制。"
	_sync_visuals()


func _clear_navigation_target() -> void:
	_stop_thrust()
	if is_instance_valid(ship):
		ship.has_navigation_target = false
		ship.navigation_planet = null
		ship.navigation_tracks_planet = false
		ship.navigation_status = "目标已清除；保持当前速度。"
	_sync_visuals()


func _validate_navigation(vessel: Node2D) -> void:
	# 空间点允许永久保留；行星引用被释放时不能把旧位置当作仍有效的行星目标。
	if vessel.navigation_tracks_planet:
		if not is_instance_valid(vessel.navigation_planet) or not planets.has(vessel.navigation_planet):
			vessel.navigation_planet = null
			vessel.navigation_tracks_planet = false
			vessel.has_navigation_target = false
			vessel.navigation_status = "导航标记已失效；手动推力方向不受影响。"
		else:
			vessel.navigation_target = vessel.navigation_planet.flight_position
	if vessel.crashed or vessel.fuel <= 0.0:
		if vessel.steering:
			vessel.navigation_status = "修向停止：损毁或燃料不足。"
		vessel.steering = false
		vessel.thrust_throttle = 0.0
		if vessel.autopilot_enabled or vessel.autopilot_active:
			_stop_autopilot("自动航行停止：损毁或燃料耗尽。", vessel)
	elif vessel.autopilot_enabled and (vessel.voyage_finished or _is_in_gravity_region(vessel.flight_position)):
		_stop_autopilot("进入引力区或已停泊，自动航行已关闭。", vessel)


func _thrust_reference(velocity: Vector2, heading: Vector2) -> Vector2:
	if velocity.length() > 0.01:
		return velocity.normalized()
	return heading.normalized() if heading.length_squared() > 0.000001 else Vector2.RIGHT


func _set_thrust_lock(enabled: bool) -> void:
	if is_instance_valid(ship) and ship.autopilot_enabled:
		_stop_autopilot("手动推力，自动航行已取消。")
	if tutorial_pause or not selected or not is_instance_valid(ship) or selecting_orbit or ship.crashed or ship.voyage_finished:
		return
	ship.thrust_lock_enabled = enabled
	if enabled:
		ship.thrust_lock_angle = _thrust_reference(ship.flight_velocity, ship.heading).angle_to(ship.thrust_direction)
	_refresh_preview()


func _set_thrust_direction(direction: Vector2) -> void:
	if is_instance_valid(ship) and ship.autopilot_enabled:
		_stop_autopilot("手动推力，自动航行已取消。")
	if tutorial_pause or not selected or not is_instance_valid(ship) or selecting_orbit or ship.crashed or ship.voyage_finished or direction.length_squared() < 0.000001:
		return
	ship.thrust_direction = direction.normalized()
	if ship.thrust_lock_enabled:
		ship.thrust_lock_angle = _thrust_reference(ship.flight_velocity, ship.heading).angle_to(ship.thrust_direction)
	_refresh_preview()


func _set_throttle(value: float) -> void:
	if is_instance_valid(ship) and ship.autopilot_enabled:
		_stop_autopilot("手动推力，自动航行已取消。")
	if tutorial_pause or not is_instance_valid(ship):
		return
	if value <= 0.0:
		_stop_thrust()
		return
	if selecting_orbit or not selected or crashed or ship.voyage_finished or fuel_mass <= 0.0 or ship.get_effective_steering_acceleration() <= 0.0:
		return
	ship.manual_thrust = 0.0
	ship.maneuver_commands.clear()
	ship.thrust_throttle = clampf(value, 0.0, 1.0)
	ship.steering = true
	ship.reset_orbit()
	ship.navigation_status = "推力已预设，解除暂停后生效。" if simulation_paused else "手动推力持续生效；油门归零停止。"
	_refresh_preview()


func _finish_city_arrival(vessel: Node2D, city: Node2D) -> void:
	_stop_autopilot("", vessel)
	vessel.departure_position = vessel.flight_position
	vessel.departure_velocity = Vector2.ZERO
	vessel.arrival_source = city
	vessel.voyage_finished = true
	vessel.last_voyage_distance_m = vessel.current_voyage_distance_m
	vessel.completed_voyage_count += 1
	vessel.flight_velocity = Vector2.ZERO
	vessel.maneuver_commands.clear()
	vessel.reset_orbit()
	vessel.navigation_status = "已停靠城市港口。"
	if vessel == ship and selected and not $PortController.active:
		flight_message = vessel.navigation_status
		$PortController.enter_port(city, vessel)
		_save_checkpoint()


func _steering_step(vessel: Node2D, step: float) -> Dictionary:
	var delta_v := maxf(0.0, vessel.get_effective_steering_acceleration()) * clampf(vessel.thrust_throttle, 0.0, 1.0) * step
	var coefficient := maxf(vessel.get_effective_propulsion_fuel_per_delta_v(), 0.000001)
	delta_v = minf(delta_v, maxf(0.0, vessel.fuel) / coefficient)
	var velocity: Vector2 = vessel.flight_velocity + vessel.thrust_direction.normalized() * delta_v
	var fuel: float = maxf(0.0, vessel.fuel - delta_v * coefficient)
	if fuel <= 0.0:
		vessel.steering = false
		vessel.thrust_throttle = 0.0
		vessel.navigation_status = "燃料耗尽，惯性滑行。"
	var next := _integrate(vessel.flight_position, velocity, step)
	return {"position": next[0], "velocity": next[1], "fuel": fuel}


func _update_region(vessel: Node2D, previous_position: Vector2) -> void:
	var old_source: Node2D
	if is_instance_valid(vessel.region_source):
		old_source = vessel.region_source
	var next_source: Node2D = old_source
	# 只稳定显示归属，不筛选引力：所有有效星体仍参与合力计算。
	if not is_instance_valid(old_source) or not planets.has(old_source) or not old_source.contains_gravity_point(vessel.flight_position):
		next_source = _dominant_source(vessel.flight_position)
	if next_source != old_source:
		vessel.region_source = next_source
		vessel.region_event = "进入 %s 引力区（不等于入轨）" % next_source.display_name if is_instance_valid(next_source) else "已离开行星引力区，星际滑行。"
	elif not is_instance_valid(next_source):
		vessel.region_source = null
	# 一步从圈外穿到圈外仍报告掠过，但不切到已经离开的局部镜头。
	for source in planets:
		if not source.contains_gravity_point(previous_position) and not source.contains_gravity_point(vessel.flight_position):
			if _circle_crossings(previous_position, vessel.flight_position, source.flight_position, source.max_gravity_radius_m).size() == 2:
				vessel.region_event = "高速掠过 %s 引力区；未停靠。" % source.display_name


func _propulsion_step(position: Vector2, velocity: Vector2, fuel: float, step: float, accel_command: float, heading: Vector2, fuel_coefficient: float) -> Dictionary:
	var coefficient := maxf(fuel_coefficient, 0.000001)
	var delta_v := minf(absf(accel_command) * step, maxf(fuel, 0.0) / coefficient)
	if accel_command < 0.0:
		delta_v = minf(delta_v, velocity.length())
	var direction := velocity.normalized() if velocity.length() > 0.00001 else heading.normalized()
	velocity += direction * delta_v * signf(accel_command)
	fuel = maxf(0.0, fuel - delta_v * coefficient)
	var next := _integrate(position, velocity, step)
	return {"position": next[0], "velocity": next[1], "fuel": fuel}


## 完整速度矢量闭环；相位仅作显示，任何阶段均可重新修向和补推。
func _autopilot_integrate(position: Vector2, velocity: Vector2, fuel: float, target: Vector2, phase: int, max_speed: float, decel: float, accel: float, coefficient: float, step: float) -> Dictionary:
	var result := {"position": position, "velocity": velocity, "fuel": fuel, "phase": phase, "stopped": false, "arrived": false, "reason": "", "acceleration": Vector2.ZERO}
	if step <= 0.0:
		return result
	var reason := ""
	if _is_in_gravity_region(position):
		reason = "进入引力区，自动航行已关闭。"
	elif fuel <= 0.0:
		reason = "燃料耗尽，自动航行结束。"
	elif not is_finite(max_speed) or max_speed <= 0.0:
		reason = "最大速度必须为有限正数，自动航行已关闭。"
	if not reason.is_empty():
		var coast := _integrate(position, velocity, step)
		result.position = coast[0]
		result.velocity = coast[1]
		result.stopped = true
		result.reason = reason
		return result
	var offset := target - position
	var distance := offset.length()
	# 保守的矢量预算同时满足加速/制动额定能力，横向修正也计入同一预算。
	var authority := maxf(0.0, minf(accel, decel))
	var brake_step := authority * step
	# v²/(2a) + v*dt <= distance，给固定步制动留一整步余量。
	var envelope := sqrt(brake_step * brake_step + 2.0 * authority * distance) - brake_step
	var desired_speed := minf(max_speed, minf(envelope, distance / step)) if distance > 0.1 else 0.0
	var desired_velocity := offset.normalized() * desired_speed
	var request := desired_velocity - velocity
	coefficient = maxf(coefficient, 0.000001)
	var budget := minf(brake_step, maxf(fuel, 0.0) / coefficient)
	var delta_v := request.limit_length(budget)
	var new_velocity := velocity + delta_v
	phase = 1 if request.length() <= 0.00001 else (2 if delta_v.dot(velocity) < 0.0 else 0)
	var next := _integrate(position, new_velocity, step)
	result.position = next[0]
	result.velocity = next[1]
	result.fuel = maxf(0.0, fuel - delta_v.length() * coefficient)
	result.phase = phase
	result.acceleration = delta_v / step
	if _crosses_gravity_region(position, next[0]) or _crosses_gravity_region(position, position + new_velocity * step):
		result.stopped = true
		result.reason = "进入引力区，自动航行已关闭。"
	elif result.fuel <= 0.0:
		result.stopped = true
		result.reason = "燃料耗尽，自动航行结束。"
	elif next[0].distance_to(target) <= 0.2 and next[1].length_squared() <= 0.000000000001:
		# 速度已由有限且付费的Δv归零，不吸附位置，也不删除高速动量。
		result.stopped = true
		result.arrived = true
		result.reason = "已到达导航点，自动航行待命。"
	return result


## 自动航行推进：沿目标方向直线加速/巡航/减速，直到停在导航点或燃料耗尽。
func _autopilot_step(vessel: Node2D, step: float) -> Dictionary:
	var result: Dictionary = _autopilot_integrate(
		vessel.flight_position, vessel.flight_velocity, vessel.fuel, vessel.autopilot_target,
		vessel.autopilot_phase, vessel.autopilot_max_speed, vessel.get_effective_deceleration(),
		vessel.get_effective_acceleration(), vessel.get_effective_propulsion_fuel_per_delta_v(), step)
	vessel.autopilot_phase = result.phase
	vessel.autopilot_acceleration = result.acceleration
	return result


## 退出模式保留位置、速度和燃料；可指定非受控船，避免多船清错状态。
func _stop_autopilot(reason: String = "", vessel: Node2D = null) -> void:
	if vessel == null:
		vessel = ship
	if not is_instance_valid(vessel):
		return
	var was_enabled: bool = vessel.autopilot_enabled or vessel.autopilot_active
	vessel.autopilot_enabled = false
	vessel.autopilot_active = false
	vessel.autopilot_phase = 0
	vessel.autopilot_acceleration = Vector2.ZERO
	vessel.autopilot_target = Vector2.ZERO
	if not was_enabled:
		return
	vessel.manual_thrust = 0.0
	vessel.steering = false
	vessel.thrust_throttle = 0.0
	if not reason.is_empty():
		vessel.navigation_status = reason
		if vessel == ship:
			flight_message = reason
	if vessel == ship:
		_sync_visuals()
		_refresh_preview()


func _reset() -> void:
	_clear_object_inspection()
	_cancel_capture_aim()
	_clear_capture_nets()
	_clear_drones()
	# 重置航行不是新游戏：撤下旧通知，但本局已触发的任务不再重复。
	$TaskManager.clear_dialogues()
	$PortController.leave_port()
	_stop_autopilot()
	$NavigationCamera.reset_view()
	simulation_paused = false
	selecting_orbit = false
	orbit_candidates.clear()
	pending_plan.clear()
	pending_target = null
	flight_message = ""
	_set_simulation_speed(1.0)
	for vessel in ships:
		vessel.reset_flight()
		vessel.region_source = _dominant_source(vessel.flight_position)
	stopped_obstacles.clear()
	for object in obstacles:
		object.reset_motion()
	$PortController.session.reset_session()
	$StarMapView.reset_view()
	selected = false
	accumulator = 0.0
	preview_refresh_elapsed = 0.0
	# 教程中重置航行 = 重做本阶段当前课，不推进阶段、不切换地图。
	if $TutorialController.active:
		$TutorialController.restart()
	elif $OrbitTutorialController.active:
		$OrbitTutorialController.restart()
	_refresh_preview()
	_update_ui()
	_sync_visuals()


## 舰载机格的文案 / 可用性 / 提示；overrides 的索引与快捷栏一致（loadout 下标 +1）。
## 工程机的按钮可用性取决于"是否在行星引力区"，只有 main 知道这个状态，所以由这里下发。
func _drone_slot_state() -> Dictionary:
	var overrides: Dictionary = {}
	var active_labels: Array[String] = []
	if is_instance_valid(ship):
		var loadout: Array = ship.skill_loadout()
		for index in range(loadout.size()):
			var entry := str(loadout[index])
			if not entry.begins_with("drone_"):
				continue
			var kind := entry.substr(6)
			var label := _drone_label(kind)
			var active := _has_drone(kind)
			var enabled := active or _can_release_drone(kind)
			var tip := ""
			var text := ("回收%s" if active else "释放%s") % label
			if active:
				tip = "%s作业中；再次点击回收。" % label
			elif not enabled and kind == "engineer":
				# 禁用按钮的 tooltip 在 Godot 里不弹出，原因必须直接写在按钮上，
				# 否则玩家只会看到一格点不动的按钮，像是没解锁。
				tip = "工程机只能在行星引力区内释放。"
				text = "%s\n需引力区" % label
			else:
				tip = "释放%s。" % label
			overrides[index + 1] = {
				"text": text,
				"enabled": enabled,
				"tip": tip,
			}
			if active:
				active_labels.append(label)
	return {"overrides": overrides, "status": " · ".join(active_labels), "tip": _drone_tip_text()}


func _drone_tip_text() -> String:
	var lines: Array[String] = []
	for drone in drones:
		if not is_instance_valid(drone):
			continue
		var label := _drone_label(drone.kind)
		if drone.kind == "engineer":
			lines.append("%s：剩余作业 %.0f s · 已回收 %.1f kg · 仓容余量 %.1f kg" % [
				label, drone.remaining_s, drone.absorbed_mass_kg, drone.capacity_left_kg])
		else:
			lines.append("%s：剩余作业 %.0f s · 扇形 %.0f° / %.0f m" % [
				label, drone.remaining_s,
				float(drone.definition.get("cone_angle_deg", 0.0)),
				float(drone.definition.get("range_m", 0.0))])
	return "\n".join(lines)


func _update_ui() -> void:
	$HUD/Root/FlightPanel/Margin/Content/DepartButton.visible = false # 起航统一由行星交互场景提供。
	# 回档只在卡死状态下露出来，避免正常航行时误触回到起航点。
	var rollback_reason := _rollback_reason()
	if rollback_button != null:
		rollback_button.visible = not rollback_reason.is_empty()
		if rollback_button.visible:
			var can_rollback := _has_departure()
			rollback_button.disabled = not can_rollback
			rollback_button.text = "回档到上次起航" if can_rollback else "无起航记录"
	_sync_arrival_buttons()
	_sync_city_buttons()
	pause_button.text = "继续" if simulation_paused else "暂停"
	pause_button.tooltip_text = "继续模拟，按暂停期间预设的方向与油门推进。" if simulation_paused else "暂停模拟；暂停时可预设方向与油门，继续后生效。"
	orbit_actions.visible = selecting_orbit
	orbit_actions.get_node("Confirm").disabled = not pending_plan.get("ok", false)
	# 入轨入口并入船载装置栏第 1 格；按钮文案与可用性由 skill_panel.render 统一维护。
	# 网体状态写在快捷栏标题上：不额外增高 HUD；标题只放数量和钩状态，质量等细节进提示框。
	var net_status := ""
	var net_tip := ""
	if not capture_nets.is_empty():
		var net_erased := 0.0
		var net_wiped := 0
		for net in capture_nets:
			net_erased += net.absorbed_mass_kg
			net_wiped += net.absorbed_count
		net_status = "网 %d 张" % capture_nets.size()
		net_tip = "捕捉网 %d 张 · 已擦除 %.1f kg · 擦空 %d 片碎片" % [capture_nets.size(), net_erased, net_wiped]
	if recovered_mass_kg > 0.0:
		net_tip = ("%s\n" % net_tip if not net_tip.is_empty() else "") + "已回收物资 %.1f kg" % recovered_mass_kg
	var orbit_text := "自动入轨"
	if is_instance_valid(ship) and ship.maneuver_index < ship.maneuver_commands.size():
		orbit_text = "取消入轨"
	var drone_state := _drone_slot_state()
	if not str(drone_state.status).is_empty():
		net_status = str(drone_state.status) if net_status.is_empty() else "%s · %s" % [net_status, str(drone_state.status)]
	if not str(drone_state.tip).is_empty():
		net_tip = ("%s\n" % net_tip if not net_tip.is_empty() else "") + str(drone_state.tip)
	if skill_panel != null:
		skill_panel.render({
			"orbit_enabled": selected and is_instance_valid(ship) and not crashed and not ship.voyage_finished and not selecting_orbit and not tutorial_pause and not capture_aim_active,
			"orbit_text": orbit_text,
			"net_count": ship.capture_net_count() if is_instance_valid(ship) else 0,
			"slots": ship.skill_loadout() if is_instance_valid(ship) else [],
			"aiming_slot": capture_aim_slot,
			"status_text": net_status,
			"status_tip": net_tip,
			"slot_overrides": drone_state.overrides,
		})
	fleet_buttons.get_node("Empty").visible = ships.is_empty()
	for index in range(ships.size()):
		var vessel := ships[index]
		var button: Button = ship_buttons[vessel]
		button.text = "%02d · %s%s" % [index + 1, vessel.display_name, "（损毁）" if vessel.crashed else ""]
		button.set_pressed_no_signal(selected and vessel == ship)
	stay_button.visible = false # 原停留占位由行星上的“确认入轨”入口取代。
	if not is_instance_valid(ship):
		info_label.text = "暂无飞船"
		selection_status.text = "未选中"
		accelerate_button.disabled = true
		brake_button.disabled = true
		return
	var nearest_height := INF
	for source in planets:
		nearest_height = minf(nearest_height, ship_position.distance_to(source.flight_position) - source.radius_m)
	var height_text := "最近表面  %.2f km" % (nearest_height / 1000.0) if not planets.is_empty() else "最近表面  无行星"
	info_label.text = "速度 %.1f m/s · 质量 %.1f kg\n%s\n燃料 Δv %.1f / %.1f m/s" % [ship_velocity.length(), ship.get_total_mass(), height_text, ship.fuel_to_delta_v(fuel_mass), ship.fuel_to_delta_v(ship.get_fuel_capacity())]
	info_label.text += "\n本航程 %.2f km · 上航程 %.2f km" % [ship.current_voyage_distance_m / 1000.0, ship.last_voyage_distance_m / 1000.0]
	info_label.tooltip_text = "飞船质量 %.1f kg（燃料不计重）。Δv为推进速度变化预算，不是当前速度。" % ship.dry_mass
	accelerate_button.text = "沿速度方向加速"
	accelerate_button.tooltip_text = "按住以 5 m/s² 沿当前速度方向加速"
	brake_button.text = "沿速度方向减速"
	brake_button.tooltip_text = "按住以 5 m/s² 沿当前速度方向减速"
	var unavailable: bool = not selected or crashed or ship.voyage_finished or simulation_paused or selecting_orbit or fuel_mass <= 0.0
	accelerate_button.disabled = unavailable
	brake_button.disabled = unavailable or ship_velocity.length() < 0.01
	selection_status.text = "已选中 · %s" % ship.display_name if selected else "未选中 · 点击顶部飞船按钮"
	# 卡死时把原因直接写在选中状态行：损毁/没油时按钮全灰，只靠飞船变红玩家会以为卡住了。
	if not rollback_reason.is_empty():
		selection_status.text = "%s · 可回档到上次起航" % rollback_reason
