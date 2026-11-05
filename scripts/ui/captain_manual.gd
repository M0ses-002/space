extends CanvasLayer
## 每页只显示一张可替换图片；分类、章节与图片路径均由JSON定义。
signal closed
@export_file("*.json") var config_path := "res://data/manual.json"
var categories: Array = []
var category_index := 0
var page_index := 0
var current_page_id := ""
var zoom_factor := 1.0
var _input_nodes: Array[Dictionary] = []
@onready var root: Control = $Root
@onready var tabs: TabBar = $Root/Panel/Margin/Layout/Categories
@onready var chapters: ItemList = $Root/Panel/Margin/Layout/Body/Chapters
@onready var scroll: ScrollContainer = $Root/Panel/Margin/Layout/Body/Reader
@onready var page_image: TextureRect = $Root/Panel/Margin/Layout/Body/Reader/PageImage
@onready var status: Label = $Root/Panel/Margin/Layout/Toolbar/Status

func _ready() -> void:
	root.hide()
	_load_config()
	tabs.tab_changed.connect(select_category)
	chapters.item_selected.connect(select_page)
	$Root/Panel/Margin/Layout/Header/Close.pressed.connect(close)
	$Root/Panel/Margin/Layout/Toolbar/ZoomOut.pressed.connect(_set_zoom.bind(-0.25))
	$Root/Panel/Margin/Layout/Toolbar/ZoomIn.pressed.connect(_set_zoom.bind(0.25))
	$Root/Panel/Margin/Layout/Toolbar/Fit.pressed.connect(fit_page)
	scroll.resized.connect(_resize_image)
	if not categories.is_empty():
		select_category(0)

func _load_config() -> void:
	categories.clear()
	var file := FileAccess.open(config_path, FileAccess.READ)
	if file == null:
		status.text = "手册目录无法读取。"
		return
	var data: Variant = JSON.parse_string(file.get_as_text())
	if not data is Dictionary or not data.get("categories") is Array:
		status.text = "手册目录格式无效。"
		return
	for category: Variant in data.categories:
		if not category is Dictionary or not category.get("title") is String or not category.get("chapters") is Array:
			continue
		var valid: Array = []
		for page: Variant in category.chapters:
			if page is Dictionary and page.get("page_id") is String and page.get("title") is String and page.get("image") is String:
				valid.append(page)
		if not valid.is_empty():
			categories.append({"title": category.title, "chapters": valid})
			tabs.add_tab(category.title)

func is_open() -> bool:
	return root.visible

func open() -> void:
	if is_open():
		return
	# WASD由相机_process轮询，不能只吞事件；关闭后精确恢复原处理模式。
	var game := get_parent().get_parent() if get_parent() != null else null
	for path in ["NavigationCamera", "StarMapView"]:
		var node := game.get_node_or_null(path) if game != null else null
		if node != null:
			_input_nodes.append({"node": node, "mode": node.process_mode})
			node.process_mode = Node.PROCESS_MODE_DISABLED
	root.show()
	_resize_image.call_deferred()
	$Root/Panel/Margin/Layout/Header/Close.grab_focus()

func close() -> void:
	if not is_open():
		return
	root.hide()
	for entry: Dictionary in _input_nodes:
		if is_instance_valid(entry.node):
			entry.node.process_mode = entry.mode
	_input_nodes.clear()
	closed.emit()

func select_category(index: int) -> void:
	if index < 0 or index >= categories.size():
		return
	category_index = index
	if tabs.current_tab != index:
		tabs.current_tab = index
	chapters.clear()
	for page: Dictionary in categories[index].chapters:
		chapters.add_item(page.title)
	chapters.select(0)
	select_page(0)

func select_page(index: int) -> void:
	if categories.is_empty() or index < 0 or index >= categories[category_index].chapters.size():
		return
	page_index = index
	var page: Dictionary = categories[category_index].chapters[index]
	current_page_id = page.page_id
	page_image.texture = load(page.image) as Texture2D if page.image.begins_with("res://") and ResourceLoader.exists(page.image) else null
	status.text = "%s · 图片无法读取，请检查目录路径" % page.title if page_image.texture == null else "%s · 整页图片" % page.title
	fit_page()

func fit_page() -> void:
	zoom_factor = 1.0
	scroll.scroll_horizontal = 0
	scroll.scroll_vertical = 0
	_resize_image.call_deferred()

func _set_zoom(change: float) -> void:
	zoom_factor = clampf(zoom_factor + change, 0.5, 3.0)
	_resize_image()

func _resize_image() -> void:
	if page_image.texture == null:
		page_image.custom_minimum_size = Vector2.ZERO
		return
	var available := (scroll.size - Vector2(20.0, 20.0)).max(Vector2.ONE)
	var image_size := page_image.texture.get_size()
	var fit := minf(available.x / image_size.x, available.y / image_size.y)
	page_image.custom_minimum_size = image_size * fit * zoom_factor
	$Root/Panel/Margin/Layout/Toolbar/Scale.text = "%d%%" % roundi(zoom_factor * 100.0)

func _input(event: InputEvent) -> void:
	if not is_open():
		return
	if event is InputEventKey:
		if event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			close()
		# 手册内部鼠标控件负责翻页；所有快捷键均不传到世界。
		get_viewport().set_input_as_handled()

func _unhandled_input(_event: InputEvent) -> void:
	if is_open():
		get_viewport().set_input_as_handled()
