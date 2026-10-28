extends Node2D
## 每个实例独立保存航行状态，编辑器中可配置名称与初始条件。
@export var display_name := "运输船"
@export var initial_position := Vector2(0, -62000)
@export var initial_velocity := Vector2(655, 0)
@export var initial_fuel := 3200.0
## 单个引力源产生的加速度低于此值时忽略，单位 m/s²。0 表示全部计入。
@export_range(0.0, 1000.0, 0.001, "or_greater") var gravity_threshold := 0.0
var flight_position := Vector2.ZERO
var flight_velocity := Vector2.ZERO
var fuel := 0.0
var crashed := false

func _ready() -> void:
	reset_flight()

func reset_flight() -> void:
	flight_position = initial_position
	flight_velocity = initial_velocity
	fuel = initial_fuel
	crashed = false
