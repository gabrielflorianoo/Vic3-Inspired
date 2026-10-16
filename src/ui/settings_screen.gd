extends PanelContainer
## Settings dialog shared by the main menu and the in-game pause menu.
## Every change is applied immediately and persisted through Settings.

signal closed
signal changed(key: String)

const K := preload("res://src/ui/ui_kit.gd")
const Settings := preload("res://src/game/settings.gd")

var _res_opt: OptionButton


func _ready() -> void:
	theme = K.get_theme()
	custom_minimum_size = Vector2(460, 0)
	add_theme_stylebox_override("panel", K.style(Color(0.10, 0.09, 0.075, 0.98), K.BORDER, 2, 4, 18))
	var v := K.vbox(10)
	add_child(v)
	v.add_child(K.lbl("Settings", 22, K.GOLD))
	v.add_child(HSeparator.new())
	var g := K.grid(2, 24, 10)
	v.add_child(g)

	_row(g, "Window mode", _option(["Windowed", "Fullscreen"], int(Settings.get_value("window_mode")), func(i):
		Settings.set_value("window_mode", i)
		_res_opt.disabled = i == 1
		changed.emit("window_mode")))
	var res_names: Array = []
	for r in Settings.RESOLUTIONS:
		res_names.append("%d x %d" % [r.x, r.y])
	_res_opt = _option(res_names, int(Settings.get_value("resolution")), func(i):
		Settings.set_value("resolution", i)
		changed.emit("resolution"))
	_res_opt.disabled = int(Settings.get_value("window_mode")) == 1
	_row(g, "Resolution", _res_opt)
	_row(g, "VSync", _check(bool(Settings.get_value("vsync")), func(on):
		Settings.set_value("vsync", on)
		changed.emit("vsync")))
	var scales: Array = []
	var cur_scale := 1
	for i in Settings.UI_SCALES.size():
		scales.append("%d%%" % int(Settings.UI_SCALES[i] * 100.0))
		if is_equal_approx(Settings.UI_SCALES[i], float(Settings.get_value("ui_scale"))):
			cur_scale = i
	_row(g, "UI scale", _option(scales, cur_scale, func(i):
		Settings.set_value("ui_scale", Settings.UI_SCALES[i])
		changed.emit("ui_scale")))
	_row(g, "Map detail (ocean animation, vignette)", _check(bool(Settings.get_value("map_detail")), func(on):
		Settings.set_value("map_detail", on)
		changed.emit("map_detail")))
	_row(g, "Performance overlay", _option(["Off", "Compact", "Detailed"], int(Settings.get_value("perf_overlay")), func(i):
		Settings.set_value("perf_overlay", i)
		changed.emit("perf_overlay")))
	_row(g, "Autosave", _option(["Off", "Monthly", "Yearly"], int(Settings.get_value("autosave")), func(i):
		Settings.set_value("autosave", i)
		changed.emit("autosave")))
	v.add_child(HSeparator.new())
	var done := K.btn("Done", "", closed.emit)
	done.custom_minimum_size = Vector2(120, 32)
	done.size_flags_horizontal = Control.SIZE_SHRINK_END
	v.add_child(done)


func _row(g: GridContainer, text: String, ctl: Control) -> void:
	var l := K.lbl(text, 14)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	g.add_child(l)
	g.add_child(ctl)


func _option(items: Array, selected: int, cb: Callable) -> OptionButton:
	var o := OptionButton.new()
	o.focus_mode = Control.FOCUS_NONE
	o.custom_minimum_size = Vector2(150, 0)
	for it in items:
		o.add_item(str(it))
	o.selected = clampi(selected, 0, items.size() - 1)
	o.item_selected.connect(cb)
	return o


func _check(on: bool, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.focus_mode = Control.FOCUS_NONE
	c.text = "On"
	c.button_pressed = on
	c.toggled.connect(cb)
	return c
