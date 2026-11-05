extends SceneTree
## 拆除装备：槽位清空后，对应的功能、快捷栏按钮与在轨实例必须一起失效。
## 覆盖捕捉网瞄准、机库舰载机、燃料仓容量、护盾状态、空槽与未停泊的拒绝路径、存档往返。

var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _viewport_rect(control: Control) -> Rect2:
	return control.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, control.size)


func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1200, 720)
	var game = load("res://scenes/game/star_map_demo.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame

	var ship = game.ships[0]
	var port = game.get_node("PortController")
	var session = port.session
	session.set_credits(5000)
	game.quest_manager._settle_reward({"reward_credits": 0, "reward_unlock": "hangar"})

	# 停泊在城市：船坞才可用。
	ship.voyage_finished = true
	ship.arrival_source = game.cities[0]
	port.enter_port(game.cities[0], ship)
	check(port._get_state().shipyard_available, "城市港口提供船坞")
	port._change_tab("shipyard")

	var remove_button: Button = port.view.get_node("%RemoveButton")
	check(remove_button != null, "船坞界面有拆除按钮")
	port._select_shipyard_slot(0)
	check(remove_button.disabled, "空槽位时拆除按钮禁用")

	# 1. 装四件不同的装备，验证安装提示会点明机库解锁了什么。
	port._select_shipyard_slot(0)
	port._install_upgrade("capture_net")
	port._select_shipyard_slot(1)
	port._install_upgrade("computer")
	port._select_shipyard_slot(2)
	port._install_upgrade("shield")
	port._select_shipyard_slot(3)
	port._install_upgrade("hangar")
	check(ship.upgrade_slots == ["capture_net", "computer", "shield", "hangar"], "四件装备各就各位")
	check(port.shipyard_notice.contains("工程机") and port.shipyard_notice.contains("近卫机"), "安装机库的提示点明解锁的两架舰载机")
	check(ship.shield_ready, "装护盾后护盾可用")
	check(not remove_button.disabled and remove_button.text == "拆除槽位 4", "选中已装槽位时拆除按钮可用且跟随槽位")

	# 2. 捕捉网瞄准中拆除：瞄准立即取消，快捷栏按钮跟着消失，且不返还信用点。
	game._select_target(ship)
	game._begin_capture_aim(1)
	check(game.capture_aim_active, "捕捉网进入瞄准状态")
	var credits_before: int = session.get_credits()
	port._select_shipyard_slot(0)
	port._remove_upgrade()
	check(str(ship.upgrade_slots[0]).is_empty(), "捕捉网槽位已清空")
	check(not game.capture_aim_active, "拆掉捕捉网后瞄准被取消")
	check(session.get_credits() == credits_before, "拆除不返还信用点")
	check(ship.skill_loadout() == ["drone_engineer", "drone_guard"], "快捷栏只剩两架舰载机")
	game._update_ui()
	check(game.skill_panel.buttons[1].text.begins_with("工程机"), "捕捉网按钮消失后工程机顺延到第 2 格：%s" % game.skill_panel.buttons[1].text)
	check(port.shipyard_notice.contains("捕捉网"), "拆除提示写明拆掉的装备")

	# 3. 机库拆除：在轨舰载机立刻回收，快捷栏两格一起消失。
	port.leave_port()
	game._select_target(ship)
	ship.voyage_finished = false
	var planet = game.planets[0]
	ship.flight_position = planet.flight_position + Vector2(0, -95000)
	ship.flight_velocity = Vector2(200, 0)
	ship.heading = Vector2.RIGHT
	game._release_drone("engineer")
	check(game.drones.size() == 1, "机库在轨时放出工程机")
	ship.voyage_finished = true
	ship.arrival_source = game.cities[0]
	port.enter_port(game.cities[0], ship)
	port._change_tab("shipyard")
	port._select_shipyard_slot(3)
	port._remove_upgrade()
	check(str(ship.upgrade_slots[3]).is_empty(), "机库槽位已清空")
	check(game.drones.is_empty(), "拆掉机库后在轨舰载机被回收")
	check(ship.skill_loadout().is_empty(), "机库拆掉后舰载机按钮全部消失")
	game._update_ui()
	for index in range(1, game.skill_panel.buttons.size()):
		check(game.skill_panel.buttons[index].text == "未绑定", "快捷栏第 %d 格回到未绑定" % (index + 1))

	# 4. 燃料仓拆除：油箱变小，多出来的燃料被截断，不留 fuel > capacity。
	port._select_shipyard_slot(0)
	port._install_upgrade("fuel")
	var expanded_capacity: float = ship.get_fuel_capacity()
	ship.fuel = expanded_capacity
	port._select_shipyard_slot(0)
	port._remove_upgrade()
	check(not ship.upgrade_slots.has("fuel"), "燃料仓已拆除")
	check(ship.fuel <= ship.get_fuel_capacity() + 0.001, "拆除燃料仓后燃料被截断到新容量")

	# 5. 护盾拆除：槽位清空，护盾状态一起失效。
	port._select_shipyard_slot(2)
	port._remove_upgrade()
	check(str(ship.upgrade_slots[2]).is_empty(), "护盾槽位已清空")
	check(not ship.shield_ready, "拆掉护盾后护盾不再可用")

	# 6. 拒绝路径：空槽位、未停泊。
	port._select_shipyard_slot(2)
	port._remove_upgrade()
	check(port.shipyard_notice.contains("本来就没有装"), "空槽位拆除给出明确提示")
	check(not session.remove_upgrade(ship, 2, true), "空槽位拆除返回 false")
	check(not session.remove_upgrade(ship, 1, false), "未停泊时不能拆除")

	# 7. 存档里不保留已拆掉的装备。
	var manager = load("res://scripts/persistence/save_manager.gd").new()
	var snapshot: Dictionary = manager.make_snapshot(game)
	var slots_in_save: Array = []
	for key: String in snapshot.get("ships", {}):
		slots_in_save = snapshot.ships[key].get("upgrade_slots", [])
	check(not slots_in_save.has("hangar") and not slots_in_save.has("fuel") and not slots_in_save.has("shield"), "存档里的槽位不再含已拆装备")
	check(slots_in_save.has("computer"), "没拆的装备仍在存档里")

	# 8. 拆除按钮状态跟随选中槽位，且展开候选后仍在视口内。
	port._select_shipyard_slot(1)
	check(not remove_button.disabled and remove_button.text == "拆除槽位 2", "选中仍有装备的槽位时按钮可用")
	await process_frame
	check(root.get_visible_rect().encloses(_viewport_rect(remove_button)), "候选展开时拆除按钮仍在视口内：%s" % _viewport_rect(remove_button))
	port._select_shipyard_slot(3)
	check(remove_button.disabled, "选中空槽位时按钮禁用")

	if failures == 0:
		print("EQUIPMENT_REMOVE_TEST: PASS (%d checks)" % checks)
	else:
		print("EQUIPMENT_REMOVE_TEST: FAIL (%d/%d)" % [failures, checks])
	quit(0)
