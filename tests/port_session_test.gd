extends SceneTree

const Session = preload("res://scripts/port_session.gd")
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

func row(state: Dictionary, id: String) -> Dictionary:
	for item in state.trade_rows:
		if item.id == id:
			return item
	return {}

func _run() -> void:
	var model = Session.new()
	check(model.get_state().cargo_used == 10, "初始货舱只含合金")
	model.register_ship(101)
	model.register_ship(202)
	check(model.open_planet(A), "A 港数据有效")
	var initial: Dictionary = model.get_state()
	check(initial.credits == 1200 and initial.trade_rows.size() == 5 and row(initial, "water").is_empty(), "移除生活商品，保留贸易商品")
	check(not initial.can_trade and not model.confirm_trade(), "空购物车不能交易")
	model.set_trade_quantity("alloy", 1)
	check(model.get_state().credits == 1200 and model.get_state().trade_total == 100, "购物车仅预览")
	check(model.confirm_trade() and model.get_state().credits == 1100 and model.get_ship_cargo_mass(101) == 20, "买入更新资金和货舱")
	model.set_trade_quantity("alloy", -1)
	check(model.confirm_trade() and model.get_state().credits == 1170, "出售按卖价结算")
	model.set_trade_quantity("circuits", 100)
	check(not model.confirm_trade() and model.get_state().credits == 1170, "库存不足拒绝且不扣款")
	model.select_ship(202)
	check(model.get_ship_cargo_mass(202) == 0, "舰船货舱独立")
	check(model.open_planet(B) and row(model.get_state(), "alloy").buy_price == 125, "港口价格独立")
	model.open_planet(A)
	check(row(model.get_state(), "alloy").station_stock == 20, "交易后库存跨港保留")
	var before: int = model.get_state().credits
	var supply: Dictionary = model.get_supply_state(202, 0, 0, true)
	check(not supply.supply_pending and not supply.can_settle_supply and supply.supply_cost == 0, "首次无航程不收费")
	supply = model.get_supply_state(202, 1, 1500000, true)
	check(supply.supply_pending and supply.can_settle_supply and supply.supply_cost == 2, "航程收费按占位单价向上取整")
	check(not model.settle_supply(202, 1, 1500000, false) and model.get_state().credits == before, "非停靠不能结算")
	check(model.settle_supply(202, 1, 1500000, true) and model.get_state().credits == before - 2, "结算扣款")
	check(not model.settle_supply(202, 1, 1500000, true) and model.get_state().credits == before - 2, "重复结算不扣款")
	check(model.get_supply_state(101, 1, 1500000, true).can_settle_supply, "不同船航程分别结算")
	check(model.get_supply_state(202, 2, 1500000, true).can_settle_supply, "相同距离的新航程可结算")
	check(not model.settle_supply(202, 2, 1000000000000.0, true) and model.get_state().credits == before - 2, "余额不足不扣款")
	check(not model.get_supply_state(202, 2, INF, true).can_settle_supply, "无效航程不可结算")
	var fuel_before: int = model.get_fuel_state(0, 6000, true).fuel_stock
	model.set_fuel_quantity(100)
	var bought: Dictionary = model.buy_fuel(0, 6000, true)
	check(bought.ok and bought.fuel_after == 100 and bought.total == 10, "燃料单独购买")
	check(model.get_fuel_state(0, 6000, true).fuel_stock == fuel_before - 100 and not model.buy_fuel(100, 6000, true).ok, "燃料库存扣减且防止重复购买")
	check(model.get_state().cargo_used == 0, "燃料和生活补给不占货舱")
	check(model.collect_mineral(202, "gray_ore", 2, 5) == 0 and model.collect_mineral(202, "unknown", 1, 5) == 0, "矿物质量和类型必须匹配")
	check(model.collect_mineral(202, "gray_ore", 1, 100) == 80 and model.get_ship_cargo_mass(202) == 80, "矿物采集受货舱容量限制")
	model.set_trade_quantity("gray_ore", -20)
	var before_sale: int = model.get_state().credits
	check(model.confirm_trade() and model.get_state().credits == before_sale + 100 and model.get_ship_cargo_mass(202) == 60, "矿物可在港口出售")
	model.select_person("a_lan")
	check(model.get_state().selected_person == "a_lan", "人物选择")
	model.select_event("a_greenhouse")
	check(model.get_state().selected_event == "a_greenhouse", "事件选择")
	var bad: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(A))
	bad.trade.items[0].stock = -1
	var file := FileAccess.open(TEMP, FileAccess.WRITE)
	file.store_string(JSON.stringify(bad))
	file.close()
	check(not model.open_planet(TEMP) and not model.get_state().error.is_empty(), "非法库存被拒绝")
	DirAccess.remove_absolute(TEMP)
	check(not model.open_planet("res://../invalid.json"), "越级路径被拒绝")
	model.reset_session()
	model.register_ship(101)
	model.register_ship(202)
	model.open_planet(A)
	check(model.get_state().credits == 1200 and model.get_ship_cargo_mass(101) == 10 and model.get_ship_cargo_mass(202) == 0, "重置资金货舱")
	check(model.get_supply_state(202, 1, 1500000, true).can_settle_supply, "重置清除结算记录")
	print("PORT_SESSION_TEST: %s (%d checks)" % ["PASS" if failures == 0 else "FAIL", checks])
	quit(0 if failures == 0 else 1)
