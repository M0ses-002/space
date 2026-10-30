extends PanelContainer

signal quantity_changed(item_id: String, quantity: int)

var item_id: String = ""
@onready var quantity_input: SpinBox = %Quantity

func _ready() -> void:
	quantity_input.value_changed.connect(_on_quantity_changed)

# 仅映射数据到控件；库存约束与结算由外部状态提供。
func render(data: Dictionary) -> void:
	item_id = str(data.get("id", ""))
	%ItemName.text = str(data.get("name", ""))
	%Description.text = "%s · 单位质量 %s kg" % [str(data.get("description", "")), str(data.get("unit_mass", 0.0))]
	%StationStock.text = "港口 %s" % str(data.get("station_stock", 0))
	%Prices.text = "卖 / 买 %d / %d" % [int(data.get("sell_price", 0)), int(data.get("buy_price", 0))]
	%ShipStock.text = "船上 %s" % str(data.get("ship_stock", 0))
	quantity_input.set_block_signals(true)
	quantity_input.min_value = float(data.get("min_quantity", 0))
	quantity_input.max_value = float(data.get("max_quantity", 0))
	quantity_input.value = float(data.get("quantity", 0))
	quantity_input.editable = quantity_input.min_value != quantity_input.max_value
	quantity_input.set_block_signals(false)

func _on_quantity_changed(value: float) -> void:
	quantity_changed.emit(item_id, int(value))
