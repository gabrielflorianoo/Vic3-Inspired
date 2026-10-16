extends Control
## Main menu: slowly panning, darkened political map as backdrop (the same
## single-quad map shader the game uses), title, and the primary buttons.
##
## Command line: `-- --benchmark` and `-- --autostart=<id>` skip straight into
## the game scene; `-- --shot=path` screenshots the menu (docs/CI);
## `-- --open=settings|load` opens that dialog first.

const K := preload("res://src/ui/ui_kit.gd")
const MapView := preload("res://src/map/map_view.gd")
const SettingsScreen := preload("res://src/ui/settings_screen.gd")
const SaveLoadDialog := preload("res://src/ui/panels/save_load_dialog.gd")
const Settings := preload("res://src/game/settings.gd")

var world: RefCounted
var map_view: Sprite2D
var _t := 0.0
var _column: VBoxContainer
var _modal: Control
var _continue: Button


func _ready() -> void:
	theme = K.get_theme()
	var args := OS.get_cmdline_user_args()
	if "--benchmark" in args:
		K.session().start_benchmark()
		return
	for a: String in args:
		if a.begins_with("--autostart="):
			K.session().start_autostart(int(a.get_slice("=", 1)))
			return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	world = K.session().load_world()
	if world != null:
		map_view = MapView.new()
		add_child(map_view)
		map_view.setup(world)
		map_view.set_detail(bool(Settings.get_value("map_detail")))
	_build_shade()
	_build_ui()
	for a: String in args:
		var v := a.get_slice("=", 1)
		if a == "--open=settings":
			_open_settings()
		elif a == "--open=load":
			_open_load()
		elif a.begins_with("--shot="):
			get_tree().create_timer(2.0).timeout.connect(func():
				get_viewport().get_texture().get_image().save_png(v)
				get_tree().quit(0))


func _build_shade() -> void:
	var dark := ColorRect.new()
	dark.color = Color(0.03, 0.025, 0.02, 0.36)
	dark.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dark)
	# Left-to-right gradient so the button column always reads clearly.
	var grad := Gradient.new()
	grad.colors = PackedColorArray([Color(0.02, 0.015, 0.01, 0.88), Color(0.02, 0.015, 0.01, 0.55), Color(0.02, 0.015, 0.01, 0.0)])
	grad.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(1, 0)
	var tr := TextureRect.new()
	tr.texture = gt
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(tr)


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 90)
	margin.add_theme_constant_override("margin_top", 0)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)
	var center := VBoxContainer.new()
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_theme_constant_override("separation", 0)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(center)

	var title := K.lbl("IRON & SOCIETY", 58, K.GOLD)
	title.add_theme_color_override("font_outline_color", Color(0.05, 0.03, 0.01, 0.95))
	title.add_theme_constant_override("outline_size", 10)
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 4)
	center.add_child(title)
	var rule := ColorRect.new()
	rule.color = Color(0.86, 0.72, 0.42, 0.85)
	rule.custom_minimum_size = Vector2(420, 2)
	rule.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	center.add_child(rule)
	var sub := K.lbl("A  GRAND  STRATEGY  OF  THE  AGE  OF  IRON  ·  1836", 13, Color(0.82, 0.76, 0.62))
	sub.add_theme_constant_override("outline_size", 4)
	sub.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	center.add_child(sub)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 38)
	center.add_child(gap)

	_column = K.vbox(10)
	_column.custom_minimum_size = Vector2(300, 0)
	_column.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	center.add_child(_column)
	var has_sim: bool = K.session().sim_available()
	var newb := _menu_button("New Game", "Choose a nation on the map and begin in 1836", K.session().start_new)
	newb.disabled = not has_sim
	_continue = _menu_button("Continue", "Load the most recent save", func(): K.session().start_continue())
	var latest: String = K.session().latest_save()
	_continue.disabled = latest == ""
	if latest == "":
		_continue.tooltip_text = "No saved game found"
	_menu_button("Load Game", "Choose a saved game", _open_load).disabled = K.session().list_saves().is_empty()
	_menu_button("Settings", "Display, performance and autosave options", _open_settings)
	_menu_button("Quit", "Exit to desktop", K.session().quit_game)

	var foot := K.lbl("v0.2  ·  Godot 4.3  ·  Space pause  ·  1-5 speed  ·  Esc menu", 11, K.DIM)
	foot.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	foot.offset_left = 14
	foot.offset_top = -26
	add_child(foot)


func _menu_button(text: String, tip: String, cb: Callable) -> Button:
	var b := K.btn(text, tip, cb)
	b.custom_minimum_size = Vector2(300, 46)
	b.add_theme_font_size_override("font_size", 19)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_stylebox_override("normal", K.style(Color(0.10, 0.09, 0.075, 0.82), Color(0.42, 0.35, 0.22), 1, 2, 12))
	b.add_theme_stylebox_override("hover", K.style(Color(0.24, 0.20, 0.13, 0.92), K.GOLD, 1, 2, 12))
	b.add_theme_stylebox_override("pressed", K.style(Color(0.36, 0.29, 0.17), K.GOLD, 1, 2, 12))
	b.add_theme_stylebox_override("disabled", K.style(Color(0.08, 0.075, 0.065, 0.7), Color(0.25, 0.21, 0.15), 1, 2, 12))
	_column.add_child(b)
	return b


# ------------------------------------------------------------------ dialogs

func _show_modal(c: Control) -> void:
	_close_modal()
	_modal = Control.new()
	_modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_modal.add_child(dim)
	var cc := CenterContainer.new()
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cc.add_child(c)
	_modal.add_child(cc)
	add_child(_modal)


func _close_modal() -> void:
	if _modal != null:
		_modal.queue_free()
		_modal = null


func _open_settings() -> void:
	var s := SettingsScreen.new()
	s.closed.connect(_close_modal)
	s.changed.connect(func(key):
		if key == "map_detail" and map_view != null:
			map_view.set_detail(bool(Settings.get_value("map_detail"))))
	_show_modal(s)


func _open_load() -> void:
	var d := SaveLoadDialog.new()
	d.setup("load")
	d.closed.connect(_close_modal)
	d.load_requested.connect(func(p): K.session().start_load(p))
	_show_modal(d)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE and _modal != null:
		_close_modal()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if map_view == null:
		return
	_t += delta
	var vs := get_viewport_rect().size
	var s := maxf(vs.y / world.height, vs.x / world.width) * 1.35
	var span := Vector2(world.width, world.height) * s - vs
	# Slow Lissajous drift across the map.
	var u := 0.5 + 0.5 * sin(_t * 0.035)
	var w := 0.5 + 0.5 * sin(_t * 0.023 + 1.3)
	map_view.scale = Vector2(s, s)
	map_view.position = -Vector2(span.x * u, span.y * w)
	map_view.set_zoom(s)
