extends SceneTree
## 捕捉网：船坞可重复安装、快捷栏按序启用、瞄准冻结时间、发射后膨胀并吸附碎片。

var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1200, 720)
	var game = load("res://scenes/game/main.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame

	var ship = game.ships[0]
	check(ship.capture_net_count() == 0, "初始没有捕捉网")
	var panel = game.skill_panel
	check(panel.slot_count() == 6, "快捷栏为横三竖二共六格")
	check(panel.buttons[0].text == "自动入轨", "第 1 格绑定自动入轨")
	check(panel.buttons[1].disabled and panel.buttons[5].disabled, "未安装捕捉网时其余格禁用")

	game._select_target(ship)
	game._update_ui()
	check(not panel.buttons[0].disabled, "选船后自动入轨格可用")

	# 快捷栏在常见窗口尺寸下完整可见、按钮互不重叠。
	for size in [Vector2i(900, 640), Vector2i(1600, 900)]:
		root.size = size
		for frame in range(4):
			await process_frame
		var bounds := Rect2(Vector2.ZERO, Vector2(size))
		check(bounds.encloses(panel.get_global_rect()), "快捷栏完整位于窗口内：%s" % size)
		for index in range(panel.slot_count()):
			var rect: Rect2 = panel.buttons[index].get_global_rect()
			check(bounds.encloses(rect), "快捷栏按钮完整可见：%s #%d" % [size, index])
			for other in range(index + 1, panel.slot_count()):
				check(not rect.intersects(panel.buttons[other].get_global_rect()), "快捷栏按钮不重叠：%s #%d" % [size, index])
	root.size = Vector2i(1200, 720)
	for frame in range(4):
		await process_frame

	# 船坞：捕捉网可重复安装到不同槽位。
	var session = game.get_node("PortController").session
	session.set_credits(1000)
	check(session.open_planet("res://data/planets/flat_nuclear_city.json"), "城市数据加载")
	check(session.get_slot_upgrades(0).has("capture_net"), "船坞候选包含捕捉网")
	check(session.install_upgrade(ship, 0, "capture_net", true), "安装第一张捕捉网")
	check(session.install_upgrade(ship, 1, "capture_net", true), "捕捉网可重复安装到其它槽位")
	check(ship.capture_net_count() == 2, "统计已安装的捕捉网数量")
	check(not session.install_upgrade(ship, 0, "capture_net", true), "已占用槽位不能重复安装")
	game._update_ui()
	check(not panel.buttons[1].disabled and not panel.buttons[2].disabled, "按安装数量依次启用两格")
	check(panel.buttons[3].disabled, "第三张网未安装时保持禁用")
	check(panel.buttons[1].text == "捕捉网 1", "启用格按顺序命名")

	# 多张捕捉网允许写入存档并通过兼容校验。
	var manager = load("res://scripts/persistence/save_manager.gd").new()
	var snapshot: Dictionary = manager.make_snapshot(game)
	check(manager._compatible(game, snapshot), "两张捕捉网的存档通过兼容校验")
	var broken: Dictionary = snapshot.duplicate(true)
	var ship_path: String = broken.ships.keys()[0]
	broken.ships[ship_path].upgrade_slots = ["fuel", "fuel", "", ""]
	check(not manager._compatible(game, broken), "其它改装仍禁止同类重复")

	# 瞄准：冻结时间、显示箭头、按航向初始化。
	game.simulation_paused = false
	game._on_skill_slot_pressed(1)
	check(game.capture_aim_active and game.simulation_paused, "按下捕捉网按钮冻结时间")
	check(game.capture_aim.is_aiming(), "显示瞄准箭头与角度面板")
	check(is_equal_approx(game.capture_aim_angle, wrapf(ship.heading.angle(), -PI, PI)), "箭头初始停留在航向角度")
	check(panel.buttons[1].text == "发射网 1", "瞄准中按钮切换为发射提示")

	game._set_capture_aim_angle(PI * 0.5)
	check(is_equal_approx(game.capture_aim_angle, PI * 0.5), "输入角度生效")
	check(is_equal_approx(game.capture_aim.angle(), PI * 0.5), "箭头旋转到指定角度")

	# 发射：恢复模拟、按箭头方向与配置速度射出。
	game._on_skill_slot_pressed(1)
	check(game.capture_nets.size() == 1, "再次按下发射一张捕捉网")
	check(not game.capture_aim_active and not game.simulation_paused, "发射后恢复模拟并关闭瞄准")
	var net = game.capture_nets[0]
	var expected_velocity: Vector2 = ship.flight_velocity + Vector2.DOWN * ship.capture_net_launch_speed
	check(net.flight_velocity.is_equal_approx(expected_velocity), "沿箭头方向以发射速度射出")
	check(is_equal_approx(net.mass_kg, net.initial_mass_kg), "网体初始质量来自配置")
	check(is_equal_approx(net.radius_m, net.initial_radius_m), "网体初始半径来自配置")

	# 半径按速率增长。
	var radius_before: float = net.radius_m
	game._update_capture_nets(game.SIM_STEP)
	check(is_equal_approx(net.radius_m, radius_before + net.growth_rate_m_per_s * game.SIM_STEP), "半径按速率×步长增长")

	# 橡皮擦式擦除：擦头覆盖多大一片就最多擦掉多大比例，质量渐进下降而不是整片消失。
	var debris = load("res://scenes/world/space_debris.tscn").instantiate()
	debris.initial_position = net.flight_position
	debris.initial_velocity = Vector2.ZERO
	game.get_node("World").add_child(debris)
	await process_frame
	debris.radius_m = 50.0
	debris.mass_kg = 1500.0
	debris.remaining_mass_kg = 1500.0
	debris.flight_position = net.flight_position
	var debris_total: float = debris.remaining_mass_kg
	check(is_equal_approx(debris.remaining_ratio(), 1.0), "新碎片整团完好")
	check(is_equal_approx(debris.coverage_of(net.flight_position, net.radius_m), 1.0), "网体完全罩住碎片时覆盖率为 1")
	check(debris.coverage_of(net.flight_position + Vector2(0.0, 100000.0), net.radius_m) == 0.0, "网体远离时覆盖率为 0")

	# 冻结半径增长，避免本段提前触发"到最大半径"提示。
	net.growth_rate_m_per_s = 0.0
	net.flight_velocity = Vector2.ZERO
	# 捕捉即回收：网擦到的质量当场推进「回收指定质量物资」任务，不需要把网送去哪。
	var quest_manager = game.get_node("QuestManager")
	check(quest_manager.accept("npc_recycle", "回收站", {
		"id": "q_recycle_net",
		"title": "回收物资",
		"description": "回收指定质量的物资。",
		"type": "recycle_mass",
		"count": 1000,
		"target_mass_kg": 1000,
		"reward_credits": 0,
	}), "接受回收质量任务")
	var progress_before: int = quest_manager.state("q_recycle_net").progress
	game._update_capture_nets(game.SIM_STEP)
	check(not debris.destroyed, "单步擦除不会让整团瞬间消失")
	check(debris.remaining_mass_kg < debris_total, "擦除一步后剩余质量下降")
	var single_loss: float = debris_total - debris.remaining_mass_kg
	var expected_loss: float = debris_total * (1.0 - exp(-net.erase_follow_rate_per_s * game.SIM_STEP))
	check(absf(single_loss - expected_loss) <= debris_total * 0.01, "擦除速度按指数逼近覆盖上限")
	check(is_equal_approx(net.absorbed_mass_kg, single_loss * net.capture_efficiency), "网体按捕获效率入账")
	check(is_equal_approx(game.recovered_mass_kg, net.absorbed_mass_kg), "进网的质量当场计入已回收物资")
	check(quest_manager.state("q_recycle_net").progress > progress_before, "擦除立刻推进回收任务进度")
	check(is_equal_approx(debris.current_radius_m(), debris.radius_m * sqrt(debris.remaining_ratio())), "当前碰撞半径按 sqrt(剩余比例) 收缩")

	# 网体停在原地持续擦除，直到剩余比例跌破溃散阈值。
	var steps := 0
	while not debris.destroyed and steps < 2000:
		net.flight_position = debris.flight_position
		net.flight_velocity = Vector2.ZERO
		game._update_capture_nets(game.SIM_STEP)
		steps += 1
	check(debris.destroyed, "持续擦除后整团溃散消失")
	check(debris.remaining_mass_kg == 0.0, "溃散后剩余质量归零")
	check(not game.stopped_obstacles.has(debris), "被擦空的碎片退出障碍处理")
	check(net.absorbed_count > 0, "记录被擦空的碎片数量")
	check(net.absorbed_mass_kg > 0.0, "网体累计记录擦除质量")
	net.growth_rate_m_per_s = 300.0

	# 网体状态写在快捷栏标题上（不额外占用 HUD 高度），质量等细节在提示框。
	game._update_ui()
	check(panel.title.text == "船载装置 · 网 1 张", "快捷栏标题显示在场网体数量")
	check(panel.title.tooltip_text.contains("已擦除") and panel.title.tooltip_text.contains("%.1f kg" % net.absorbed_mass_kg), "标题提示框显示已擦除质量")
	check(panel.title.get_minimum_size().x <= panel.get_global_rect().size.x, "标题不撑破快捷栏宽度")

	# 半径到上限只是停止扩张，网体继续留在太空（不会被回收）。
	var cap_radius: float = net.max_radius_m
	net.radius_m = cap_radius - 1.0
	for step in range(3):
		game._update_capture_nets(game.SIM_STEP)
	check(game.capture_nets.has(net), "半径到上限后网体仍在场")
	check(is_equal_approx(net.radius_m, cap_radius), "半径停在最大值不再增长")
	check(game.flight_message.contains("最大半径"), "到上限只提示停止扩张")

	# 寿命为 0 表示永久存在。
	net.lifetime_s = 0.0
	net.remaining_s = 0.0
	game._update_capture_nets(game.SIM_STEP)
	check(game.capture_nets.has(net), "寿命为 0 时网体永久存在")

	# 撞行星的销毁可配置：关闭时网体穿过行星继续存在，开启时才销毁。
	# 放在行星表面（而不是质心）以免积分在极端引力下退化。
	var planet = game.planets[0]
	var surface: Vector2 = planet.flight_position + Vector2(planet.radius_m + 0.05, 0.0)
	net.destroy_on_planet_impact = false
	net.flight_position = surface
	net.flight_velocity = Vector2.ZERO
	game._update_capture_nets(game.SIM_STEP)
	check(game.capture_nets.has(net), "关闭撞行星销毁后网体穿过行星仍存在")
	net.destroy_on_planet_impact = true
	net.flight_position = surface
	var recovered_at_destroy: float = game.recovered_mass_kg
	game._update_capture_nets(game.SIM_STEP)
	check(not game.capture_nets.has(net), "撞行星时网体被销毁")
	check(is_equal_approx(game.recovered_mass_kg, recovered_at_destroy), "网体销毁不再重复结算回收物资")

	# 有限寿命到期才回收（换一张新网验证）。
	game.capture_aim_active = true
	game._launch_capture_net()
	var timed_net = game.capture_nets[-1]
	timed_net.lifetime_s = 30.0
	timed_net.remaining_s = 0.01
	game._update_capture_nets(game.SIM_STEP)
	check(not game.capture_nets.has(timed_net), "有限寿命到期后从捕捉网列表移除")
	game._update_ui()
	check(panel.title.text == "船载装置", "无网体时标题还原")

	# 未绑定的格子点击无效。
	game._select_target(ship)
	game.capture_aim_active = false
	game._on_skill_slot_pressed(4)
	check(not game.capture_aim_active, "未绑定按钮点击不进入瞄准")

	# 第 1 格触发原有的自动入轨流程。
	game._on_skill_slot_pressed(0)
	check(game.selecting_orbit, "第 1 格触发自动入轨")
	game._cancel_orbit_selection()

	# 重置航行清空瞄准与网体。
	game._begin_capture_aim(1)
	game._launch_capture_net()
	check(game.capture_nets.size() == 1, "重置前存在一张捕捉网")
	game._reset()
	check(game.capture_nets.is_empty() and not game.capture_aim_active, "重置航行清空捕捉网与瞄准")
	check(ship.capture_net_count() == 0, "重置航行清空改装槽位")

	print("CAPTURE_NET_TEST: %s (%d checks, %d failures)" % ["PASS" if failures == 0 else "FAIL", checks, failures])
	quit(0 if failures == 0 else 1)
