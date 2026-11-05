extends SceneTree

const Session = preload("res://scripts/ports/port_session.gd")
const A := "res://data/planets/planet_a.json"
const B := "res://data/planets/planet_b.json"
const TEMP := "user://port_session_invalid_test.json"
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func _run() -> void:
	var model = Session.new()
	check(model.get_credits() == 1200, "初始共享信用点")
	check(model.open_planet(A), "A 港数据有效")
	var initial: Dictionary = model.get_state()
	check(initial.credits == 1200 and initial.tab == "events", "初始事件页面与信用点")
	for method in ["register_ship", "select_ship", "confirm_trade", "set_trade_quantity", "buy_fuel", "get_fuel_state", "settle_supply", "get_supply_state", "collect_mineral", "get_ship_cargo_mass"]:
		check(not model.has_method(method), "删除旧经济接口：" + method)
	for field in ["trade_rows", "cargo_used", "fuel_stock", "supply_pending", "can_trade"]:
		check(not initial.has(field), "状态不含旧经济字段：" + field)
	for tab in ["relations", "shipyard", "events"]:
		model.set_tab(tab)
		check(model.get_state().tab == tab, "保留页面：" + tab)
	model.set_tab("trade")
	check(model.get_state().tab == "events", "贸易页不可访问")
	var first_person: String = str(initial.persons[0].id)
	model.select_person(first_person)
	check(model.get_state().selected_person == first_person, "人物选择")
	model.select_event("a_greenhouse")
	check(model.get_state().selected_event == "a_greenhouse", "事件选择")
	check(model.add_credits(1000) and model.get_credits() == 2200, "调试加款更新共享余额")
	check(model.open_planet(B) and model.get_credits() == 2200 and model.get_state().planet_name != initial.planet_name, "跨港共享余额且数据独立")
	for invalid in [-1, 1.5, INF, NAN, "100", 1000000000001]:
		check(not model.set_credits(invalid) and model.get_credits() == 2200, "非法信用点不能改变余额")
	check(not model.add_credits(-2201) and model.get_credits() == 2200, "余额不允许负数")
	var bad: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(A))
	bad.events[0].erase("id")
	var file := FileAccess.open(TEMP, FileAccess.WRITE)
	file.store_string(JSON.stringify(bad))
	file.close()
	check(not model.open_planet(TEMP) and not model.get_state().error.is_empty(), "损坏事件被拒绝")
	DirAccess.remove_absolute(TEMP)
	check(not model.open_planet("res://../invalid.json"), "越级路径被拒绝")
	model.reset_session()
	check(model.open_planet(A) and model.get_credits() == 1200, "重置恢复共享信用点")
	for path in [A, B, "res://data/planets/flat_nuclear_city.json"]:
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		check(not data.has("trade"), "港口配置删除贸易燃料库存：" + path)
	var player: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/player_start.json"))
	check(not player.has("cargo") and not player.has("cargo_capacity"), "玩家配置不含货舱")
	print("PORT_SESSION_TEST: %s (%d checks)" % ["PASS" if failures == 0 else "FAIL", checks])
	quit(0 if failures == 0 else 1)
