extends "res://main.gd"
## 双星试玩入口：只覆盖演示初始条件，不改变单星主场景或航行规则。

func _ready() -> void:
	super._ready()
	_prepare_demo.call_deferred()

func _prepare_demo() -> void:
	if not is_inside_tree() or ships.is_empty():
		return
	_select_target(ships[0])
	if map_hash.is_empty():
		_set_navigation_target(Vector2(650000, -140000))
		ship.navigation_status = "双星试玩：目标仅作参考。拖动橙针定方向，再推油门。"
	$StarMapView.set_map_mode(true)

func _reset() -> void:
	super._reset()
	_prepare_demo.call_deferred()
