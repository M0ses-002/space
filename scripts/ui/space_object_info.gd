extends Control
## 面板与屏幕空间选中环独立于飞船控制；不保留物体引用。
signal close_requested
## 面板显示状态变化；任务清单等左上 HUD 据此让位。
## 注意不能叫 visibility_changed，Control 原生已有同名声号。
signal panel_visibility_changed(shown: bool)

@onready var panel: PanelContainer = $Panel
@onready var category: Label = $Panel/Margin/Content/Category
@onready var mass: Label = $Panel/Margin/Content/Mass
@onready var trajectory_status: Label = $Panel/Margin/Content/TrajectoryStatus
@onready var selection_ring: Line2D = $SelectionRing
var ring_center := Vector2.ZERO
var ring_radius := 0.0

func _ready() -> void:
	$Panel/Margin/Content/Header/Close.pressed.connect(func(): close_requested.emit())

func refresh(target: Node2D, pixels_per_meter: float, zoom: float, trajectory_hint: String = "") -> void:
	var was_visible := panel.visible
	panel.visible = is_instance_valid(target)
	if panel.visible != was_visible:
		panel_visibility_changed.emit(panel.visible)
	ring_radius = 0.0
	# 轨迹状态由 main 判定后传入；这里只负责显示，不参与任何物理判断。
	trajectory_status.text = trajectory_hint
	trajectory_status.visible = panel.visible and not trajectory_hint.is_empty()
	if panel.visible:
		category.text = "类别：太空垃圾" if target.is_in_group("space_debris") else "类别：小行星"
		if target.is_in_group("asteroids"):
			mass.text = "质量：%s kg" % String.num(target.mass_kg)
			mass.tooltip_text = "小行星岩体质量；不影响其受引力产生的加速度。"
			ring_radius = maxf(12.0, target.radius_m * pixels_per_meter * zoom + 5.0)
		else:
			# 太空垃圾会被捕捉网逐步擦除：显示剩余/总质量，环半径跟随当前碰撞半径。
			mass.text = "质量：%s / %s kg" % [String.num(target.remaining_mass_kg), String.num(target.mass_kg)]
			mass.tooltip_text = "整团太空垃圾的剩余质量 / 固定总质量；捕捉网擦除后剩余值下降，不影响其受引力产生的加速度。"
			ring_radius = maxf(12.0, target.current_radius_m() * pixels_per_meter * zoom + 5.0)
		ring_center = target.get_global_transform_with_canvas().origin
	selection_ring.visible = ring_radius > 0.0
	selection_ring.position = ring_center
	selection_ring.scale = Vector2.ONE * ring_radius
	selection_ring.width = 2.0 / maxf(ring_radius, 1.0)
