extends Control
## Esc menu: Resume, Save, Load, Settings, Main Menu, Quit. Sub-dialogs replace
## the button column in place. Main Menu / Quit ask for confirmation.

signal resume_requested
signal setting_changed(key: String)
signal toast_requested(text: String, kind: String)

const K := preload("res://src/ui/ui_kit.gd")
const SettingsScreen := preload("res://src/ui/settings_screen.gd")
const SaveLoadDialog := preload("res://src/ui/panels/save_load_dialog.gd")

var state: RefCounted
var _center: CenterContainer
var _main_box: PanelContainer


func setup(s: RefCounted) -> void:
	state = s
	theme = K.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.58)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	_center = CenterContainer.new()
	_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center)
	visible = false


func open() -> void:
	visible = true
	_show_main()


func close() -> void:
	visible = false
	_clear()


func _clear() -> void:
	for c in _center.get_children():
		_center.remove_child(c)
		c.queue_free()


func _show_main() -> void:
	_clear()
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", K.style(Color(0.10, 0.09, 0.075, 0.98), K.BORDER, 2, 4, 20))
	_center.add_child(p)
	var v := K.vbox(8)
	v.custom_minimum_size = Vector2(280, 0)
	p.add_child(v)
	var t := K.lbl("PAUSED", 24, K.GOLD)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var d := K.lbl(state.date_string(), 13, K.DIM)
	d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(d)
	v.add_child(HSeparator.new())
	_add(v, "Resume", "Back to the game (Esc)", func(): resume_requested.emit())
	_add(v, "Save Game", "Write a save file", _show_save)
	_add(v, "Load Game", "Load a saved game", _show_load)
	_add(v, "Settings", "Display and gameplay options", _show_settings)
	_add(v, "Main Menu", "Leave this game", func(): _confirm("Return to the main menu? Unsaved progress will be lost.", func(): K.session().to_menu()))
	_add(v, "Quit", "Exit to desktop", func(): _confirm("Quit to desktop? Unsaved progress will be lost.", func(): K.session().quit_game()))


func _add(parent: Control, text: String, tip: String, cb: Callable) -> void:
	var b := K.btn(text, tip, cb)
	b.custom_minimum_size = Vector2(0, 38)
	b.add_theme_font_size_override("font_size", 16)
	parent.add_child(b)


func _confirm(msg: String, yes: Callable) -> void:
	_clear()
	var p := PanelContainer.new()
	_center.add_child(p)
	var v := K.vbox(10)
	p.add_child(v)
	var l := K.lbl(msg, 14)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(320, 0)
	v.add_child(l)
	var h := K.hbox(8)
	h.add_child(K.btn("Yes", "", yes))
	h.add_child(K.btn("Cancel", "", _show_main))
	v.add_child(h)


func _show_save() -> void:
	_clear()
	var d := SaveLoadDialog.new()
	d.setup("save")
	d.closed.connect(_show_main)
	d.save_requested.connect(func(n):
		var path: String = K.session().save_game(state, n)
		toast_requested.emit(("Saved: " + n) if path != "" else "Saving failed", "ok" if path != "" else "error")
		resume_requested.emit())
	_center.add_child(d)


func _show_load() -> void:
	_clear()
	var d := SaveLoadDialog.new()
	d.setup("load")
	d.closed.connect(_show_main)
	d.load_requested.connect(func(p): K.session().start_load(p))
	_center.add_child(d)


func _show_settings() -> void:
	_clear()
	var s := SettingsScreen.new()
	s.closed.connect(_show_main)
	s.changed.connect(func(k): setting_changed.emit(k))
	_center.add_child(s)
