extends SceneTree

const Manager = preload("res://scripts/save_manager.gd")
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func _run() -> void:
	var manager = Manager.new()
	root.add_child(manager)
	var game = load("res://star_map_demo.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	var ship = game.ships[0]
	var port = game.get_node("PortController")
	ship.voyage_finished = true
	ship.arrival_source = game.cities[0]
	port.enter_port(game.cities[0], ship)
	check(port._get_state().shipyard_available, "城市港口提供船坞")
	port.view.get_node("%ShipyardButton").pressed.emit()
	check(port.view.get_node("%ShipyardPage").visible, "船坞页面可打开")
	port.view.get_node("%Slots").get_child(1).pressed.emit()
	check(port.shipyard_slot == 1, "界面选择正确的槽位")
	port.view.get_node("%Candidates").get_child(1).pressed.emit()
	check(ship.upgrade_slots[1] == "fuel", "界面选择正确的改装")
	port.leave_port()
	ship.upgrade_slots = ["", "", "", ""]
	ship.voyage_finished = false
	var session = port.session
	session._credits = 1200
	session.select_ship(ship.get_instance_id())
	check(session.open_planet("res://data/planets/flat_nuclear_city.json"), "城市数据加载")
	var cargo: Dictionary = session._fleet_cargo[ship.get_instance_id()]
	cargo["circuits"] = 2
	cargo["alloy"] = 2
	check(not session.install_upgrade(ship, 0, "fuel", false), "未停靠时禁止安装")
	check(session.install_upgrade(ship, 0, "fuel", true), "安装燃料仓")
	check(is_equal_approx(ship.get_fuel_capacity(), ship.fuel_capacity * 1.2) and session._credits == 1100, "油箱容量与费用")
	check(not session.install_upgrade(ship, 1, "fuel", true), "禁止重复安装")
	check(session.install_upgrade(ship, 1, "computer", true), "安装航行电脑")
	var map_view = game.get_node("StarMapView")
	var reference: Label = game.get_node("HUD/Root/FlightPanel/Margin/Content/Reference")
	map_view._update_panel(true, false)
	check(reference.text.contains("预演 1800 s" if map_view.map_mode else "预演 930 s"), "预演时间显示航行电脑改装")
	game._set_simulation_speed(1.5)
	check(reference.text.contains("预演 1800 s" if map_view.map_mode else "预演 930 s"), "切换倍速保留正确预演时间")
	check(session.install_upgrade(ship, 2, "thruster", true), "安装加力喷口")
	check(session.install_upgrade(ship, 3, "shield", true), "安装霍普尔盾")
	check(not session.install_upgrade(ship, 0, "computer", true), "占用槽位不能安装")
	check(cargo.circuits == 0 and cargo.alloy == 0, "材料精确扣除")
	check(is_equal_approx(ship.get_effective_acceleration(), 15.0 / ship.get_mass_ratio()), "加速度改装生效")
	check(is_equal_approx(ship.get_effective_deceleration(), 15.0 / ship.get_mass_ratio()), "减速度改装按载重生效")
	check(is_equal_approx(ship.get_effective_steering_acceleration(), 15.0 / ship.get_mass_ratio()), "方向推进改装按载重生效")
	var cargo_mass: float = ship.cargo_mass
	ship.cargo_mass = ship.dry_mass
	check(is_equal_approx(ship.get_effective_deceleration(), 7.5) and is_equal_approx(ship.get_effective_steering_acceleration(), 7.5), "满干质量载重时加速度减半")
	ship.cargo_mass = cargo_mass
	var debris = load("res://scenes/space_debris.tscn").instantiate()
	root.add_child(debris)
	debris.hit_ship(ship)
	check(not ship.crashed and debris.destroyed and not ship.shield_ready, "护盾抵挡一次垃圾")
	check(not session.install_upgrade(ship, 3, "shield", true), "不足材料不能补充护盾")
	cargo.alloy = 1
	check(session.install_upgrade(ship, 3, "shield", true) and ship.shield_ready and cargo.alloy == 0, "消耗材料补充护盾")
	debris.queue_free()
	var snapshot: Dictionary = manager.make_snapshot(game)
	ship.upgrade_slots = ["", "", "", ""]
	ship.shield_ready = false
	check(manager.restore_snapshot(game, snapshot), "改装存档可恢复")
	check(ship.upgrade_slots == ["fuel", "computer", "thruster", "shield"] and ship.shield_ready, "改装与护盾状态恢复")
	var invalid: Dictionary = snapshot.duplicate(true)
	invalid.ships[invalid.ships.keys()[0]].upgrade_slots = ["fuel", "fuel", "", ""]
	check(not manager.restore_snapshot(game, invalid), "拒绝重复改装的损坏存档")
	game.queue_free()
	manager.queue_free()
	await process_frame
	print("SHIPYARD_TEST: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)
