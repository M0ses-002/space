extends Node2D
## 星图与近域共享模拟坐标；这里只改变相机和显示，不写回任何航行状态。
## 演示场景可开启此选项，以星图视角启动；普通场景默认保持近域。
@export var start_in_map := false
var map_mode := false
var is_initialized := false
var preview_seconds: float:
	get: return 1800.0 if map_mode else 620.0

var game: Node2D
var camera: Camera2D
var observed_ship_id := 0
var stable_region_id := 0
var pending_region_id := 0
var pending_since_msec := 0

@onready var map_panel: PanelContainer = $HUD/Root/MapPanel
@onready var title: Label = $HUD/Root/MapPanel/Margin/Content/Title
@onready var information: Label = $HUD/Root/MapPanel/Margin/Content/Information
@onready var map_button: Button = $HUD/Root/MapPanel/Margin/Content/ViewButtons/MapButton
@onready var return_button: Button = $HUD/Root/MapPanel/Margin/Content/ViewButtons/ReturnButton
@onready var clear_button: Button = $HUD/Root/MapPanel/Margin/Content/NavigationButtons/ClearButton
@onready var target_line: Line2D = $TargetLine
@onready var velocity_line: Line2D = $VelocityLine
@onready var velocity_arrow: Polygon2D = $VelocityArrow
@onready var target_marker: Node2D = $TargetMarker

func _ready() -> void:
	call_deferred("initialize")

func initialize() -> void:
	game = get_parent() as Node2D
	camera = game.get_node("NavigationCamera") as Camera2D
	map_button.pressed.connect(_toggle_map)
	return_button.pressed.connect(_return_to_ship)
	clear_button.pressed.connect(_clear_target)
	is_initialized = true
	on_ship_selected()
	if start_in_map:
		set_map_mode(true)
	sync_visuals()

func _process(_delta: float) -> void:
	if not is_initialized:
		return
	if is_instance_valid(game.ship):
		if observed_ship_id != game.ship.get_instance_id():
			on_ship_selected()
		_observe_region()
		if camera.following:
			_center_on_ship()
	sync_visuals()

func _region_id() -> int:
	if is_instance_valid(game.ship) and is_instance_valid(game.ship.region_source):
		return game.ship.region_source.get_instance_id()
	return 0

func on_ship_selected() -> void:
	if not is_initialized:
		return
	observed_ship_id = game.ship.get_instance_id() if is_instance_valid(game.ship) else 0
	stable_region_id = _region_id()
	pending_region_id = stable_region_id
	pending_since_msec = Time.get_ticks_msec()
	if camera.following and is_instance_valid(game.ship):
		_center_on_ship()
	sync_visuals()

func _observe_region() -> void:
	if game.selecting_orbit:
		return
	var current_id := _region_id()
	if current_id == stable_region_id:
		pending_region_id = current_id
		pending_since_msec = Time.get_ticks_msec()
		return
	if current_id != pending_region_id:
		pending_region_id = current_id
		pending_since_msec = Time.get_ticks_msec()
		return
	if Time.get_ticks_msec() - pending_since_msec < 500:
		return
	stable_region_id = current_id
	# 只响应受控船跨越有效引力区；手动切图不会被相同区域反复覆盖。
	set_map_mode(current_id == 0)

func set_map_mode(enabled: bool) -> void:
	if not is_initialized or map_mode == enabled:
		return
	game._stop_thrust()
	map_mode = enabled
	camera.following = false
	if map_mode:
		_fit_star_map()
	else:
		_set_zoom(1.0)
		if is_instance_valid(game.ship):
			# 近域切换先展示参考行星与船，不只把250km边界上的船放大到中央。
			if is_instance_valid(game.ship.region_source):
				var source: Node2D = game.ship.region_source
				var center := _world_point(source.flight_position)
				var radius: float = source.radius_m * game._view_scale()
				var bounds := Rect2(center - Vector2.ONE * radius, Vector2.ONE * radius * 2.0).expand(_world_point(game.ship.flight_position))
				_fit_bounds(bounds)
			else:
				_center_on_ship()
	game._refresh_preview()
	game._update_ui()
	game._sync_visuals()
	sync_visuals()

func reset_view() -> void:
	if not is_initialized:
		return
	game._stop_thrust()
	map_mode = false
	camera.reset_view()
	on_ship_selected()
	game._refresh_preview()
	game._sync_visuals()

func _toggle_map() -> void:
	if not game.selecting_orbit:
		set_map_mode(not map_mode)

func _set_zoom(value: float) -> void:
	camera.zoom_level = clampf(value, camera.minimum_zoom, camera.maximum_zoom)
	camera.zoom = Vector2.ONE * camera.zoom_level
	camera.force_update_scroll()

func _world_point(meters: Vector2) -> Vector2:
	return game.get_node("World").to_global(game._to_screen(meters))

func _center_on_ship() -> void:
	var viewport_size := get_viewport_rect().size
	var usable_center := Vector2(maxf(viewport_size.x - 320.0, 100.0) * 0.5, viewport_size.y * 0.5)
	camera.global_position = _world_point(game.ship.flight_position) - (usable_center - viewport_size * 0.5) / camera.zoom.x
	camera.force_update_scroll()

func _return_to_ship() -> void:
	if not is_initialized or not is_instance_valid(game.ship) or game.selecting_orbit:
		return
	camera.following = true
	_center_on_ship()

func _fit_star_map() -> void:
	var bounds := Rect2()
	var has_bounds := false
	for planet in game.planets:
		if not is_instance_valid(planet):
			continue
		var center := _world_point(planet.flight_position)
		var radius: float = maxf(planet.max_gravity_radius_m, planet.radius_m) * game._view_scale()
		var circle_bounds := Rect2(center - Vector2.ONE * radius, Vector2.ONE * radius * 2.0)
		bounds = bounds.merge(circle_bounds) if has_bounds else circle_bounds
		has_bounds = true
	if is_instance_valid(game.ship):
		var ship_point := _world_point(game.ship.flight_position)
		bounds = bounds.expand(ship_point) if has_bounds else Rect2(ship_point - Vector2.ONE * 100.0, Vector2.ONE * 200.0)
		has_bounds = true
	if not has_bounds:
		return
	_fit_bounds(bounds)

func _fit_bounds(bounds: Rect2) -> void:
	# 将范围放进面板上方的安全矩形，右侧另留飞行 HUD 空间。
	var viewport_size := get_viewport_rect().size
	var safe_top := 58.0
	var safe_bottom := maxf(safe_top + 80.0, map_panel.get_global_rect().position.y - 22.0)
	var safe_rect := Rect2(32.0, safe_top, maxf(120.0, viewport_size.x - 384.0), safe_bottom - safe_top)
	var fit_zoom := minf(safe_rect.size.x / maxf(bounds.size.x, 1.0), safe_rect.size.y / maxf(bounds.size.y, 1.0)) * 0.9
	_set_zoom(minf(fit_zoom, 1.0))
	camera.global_position = bounds.get_center() - (safe_rect.get_center() - viewport_size * 0.5) / camera.zoom.x
	camera.force_update_scroll()

func _clear_target() -> void:
	if not game.selecting_orbit:
		game._clear_navigation_target()

func _unhandled_key_input(event: InputEvent) -> void:
	if not is_initialized or not event is InputEventKey or not event.pressed or event.echo:
		return
	if game.selecting_orbit:
		return
	var focused := get_viewport().gui_get_focus_owner()
	if focused is LineEdit or focused is TextEdit:
		return
	match event.physical_keycode:
		KEY_M:
			_toggle_map()
		KEY_F:
			_return_to_ship()
		_:
			return
	get_viewport().set_input_as_handled()

func sync_visuals() -> void:
	if not is_initialized:
		return
	var inverse_zoom := 1.0 / camera.zoom.x
	for planet in game.planets:
		if not is_instance_valid(planet):
			continue
		var boundary := planet.get_node_or_null("GravityBoundary") as Sprite2D
		if boundary != null:
			boundary.visible = map_mode
			boundary.scale = Vector2.ONE * planet.max_gravity_radius_m / maxf(planet.radius_m, 1.0)
		var label := planet.get_node_or_null("MapLabel") as Label
		if label != null:
			label.visible = map_mode
			label.text = planet.display_name
			var label_scale: float = inverse_zoom / maxf(absf(planet.global_scale.x), 0.000001)
			label.scale = Vector2.ONE * label_scale
			label.position = Vector2(-60.0 * label_scale, 200.0 + 8.0 * label_scale)
	for vessel in game.ships:
		if is_instance_valid(vessel):
			vessel.scale = Vector2.ONE * (inverse_zoom if map_mode else 1.0)
	var preview := game.get_node_or_null("World/OrbitPreview") as Line2D
	if preview != null:
		preview.width = 2.0 * inverse_zoom
	target_line.width = 1.5 * inverse_zoom
	velocity_line.width = 2.0 * inverse_zoom
	target_marker.scale = Vector2.ONE * inverse_zoom
	velocity_arrow.scale = Vector2.ONE * inverse_zoom
	var valid_ship := is_instance_valid(game.ship)
	var has_target: bool = valid_ship and game.ship.has_navigation_target
	target_line.visible = map_mode and has_target
	target_marker.visible = map_mode and has_target
	velocity_line.visible = map_mode and valid_ship
	velocity_arrow.visible = map_mode and valid_ship
	if valid_ship:
		var origin := to_local(_world_point(game.ship.flight_position))
		if has_target:
			var destination := to_local(_world_point(game.ship.navigation_target))
			target_line.points = PackedVector2Array([origin, destination])
			target_marker.position = destination
		var velocity: Vector2 = game.ship.flight_velocity
		var arrow_length: float = clampf(velocity.length() * game._view_scale() * 80.0 * camera.zoom.x, 28.0, 100.0)
		var arrow_end := origin + velocity.normalized() * arrow_length * inverse_zoom
		velocity_line.points = PackedVector2Array([origin, arrow_end])
		velocity_arrow.position = arrow_end
		velocity_arrow.rotation = velocity.angle()
		velocity_line.visible = map_mode and velocity.length_squared() > 0.01
		velocity_arrow.visible = velocity_line.visible
	_update_panel(valid_ship, has_target)
	game._sync_arrival_buttons()

func _update_panel(valid_ship: bool, has_target: bool) -> void:
	var reference := game.get_node("HUD/Root/FlightPanel/Margin/Content/Reference") as Label
	var preview_note := "起算快照，分帧更新有延迟" if map_mode else "耗油按模拟秒"
	reference.text = "WASD 移动 · 滚轮缩放\n运行 %.1f× · 基础 20 模拟秒/秒\n预演 %.0f s · %s" % [game.simulation_speed, game.get_preview_horizon(), preview_note]
	var mode_text := "星图 · 自由巡航" if map_mode else "近域 · 引力航行"
	title.text = mode_text
	map_button.text = "切换近域 [M]" if map_mode else "打开星图 [M]"
	map_button.disabled = game.selecting_orbit
	return_button.disabled = not valid_ship or game.selecting_orbit
	clear_button.disabled = not has_target or game.selecting_orbit
	if not valid_ship:
		information.text = "未注册飞船\n请在场景中添加飞船。"
		return
	var region := "无有效引力 · 自由空间"
	if is_instance_valid(game.ship.region_source):
		region = "%s · 有效引力区" % game.ship.region_source.display_name
	var navigation := "目标：未设置"
	if has_target:
		var offset: Vector2 = game.ship.navigation_target - game.ship.flight_position
		var radial_dot: float = offset.dot(game.ship.flight_velocity)
		var trend := "接近" if radial_dot > 0.01 else ("远离" if radial_dot < -0.01 else "横向 / 静止")
		navigation = "目标 %.1f km · %s" % [offset.length() / 1000.0, trend]
	var event_text: String = game.ship.region_event
	if event_text.is_empty():
		event_text = "区域稳定"
	var status: String = game.ship.navigation_status
	if status.is_empty():
		status = "拖动橙针定方向，滑条控制持续油门。"
	var meters_per_pixel: float = 1.0 / (game._view_scale() * camera.zoom.x)
	information.text = "%s\n%s\n速度 %.1f m/s · %s\n%s\n%s\n缩放 %.3f× · 100 px ≈ %.1f km" % [region, navigation, game.ship.flight_velocity.length(), "跟随" if camera.following else "自由视角", event_text, status, camera.zoom.x, meters_per_pixel * 0.1]
