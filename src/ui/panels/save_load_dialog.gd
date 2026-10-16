extends PanelContainer
## Save / load dialog. mode "load": pick a save from SaveSystem.list_saves().
## mode "save": type a name (or click an existing row to overwrite it).

signal closed
signal load_requested(path: String)
signal save_requested(save_name: String)

const K := preload("res://src/ui/ui_kit.gd")

var mode := "load"
var _name_edit: LineEdit
var _list: VBoxContainer


func setup(m: String) -> void:
	mode = m


func _ready() -> void:
	theme = K.get_theme()
	custom_minimum_size = Vector2(560, 0)
	add_theme_stylebox_override("panel", K.style(Color(0.10, 0.09, 0.075, 0.98), K.BORDER, 2, 4, 18))
	var v := K.vbox(10)
	add_child(v)
	v.add_child(K.lbl("Save Game" if mode == "save" else "Load Game", 22, K.GOLD))
	v.add_child(HSeparator.new())
	if mode == "save":
		var row := K.hbox(8)
		row.add_child(K.lbl("Name", 14))
		_name_edit = LineEdit.new()
		_name_edit.text = "save_" + Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
		_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_name_edit.select_all_on_focus = true
		_name_edit.text_submitted.connect(func(_t): _do_save())
		row.add_child(_name_edit)
		row.add_child(K.btn("Save", "Write the save file", _do_save))
		v.add_child(row)
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 280)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	_list = K.vbox(4)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_list)
	_fill()
	var bottom := K.hbox(8)
	bottom.add_child(K.spacer())
	var back := K.btn("Back", "", closed.emit)
	back.custom_minimum_size = Vector2(110, 30)
	bottom.add_child(back)
	v.add_child(bottom)
	if mode == "save":
		_name_edit.grab_focus.call_deferred()


func _fill() -> void:
	K.clear(_list)
	var saves: Array = K.session().list_saves()
	if saves.is_empty():
		_list.add_child(K.lbl("No saved games yet.", 14, K.DIM))
		return
	for s: Dictionary in saves:
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = "%s    -    %s    -    %s" % [str(s.get("name", "?")), str(s.get("country", "")), str(s.get("date", ""))]
		b.tooltip_text = str(s.get("path", ""))
		b.custom_minimum_size = Vector2(0, 30)
		var p: String = str(s.get("path", ""))
		var n: String = str(s.get("name", ""))
		if mode == "load":
			b.pressed.connect(func(): load_requested.emit(p))
		else:
			b.pressed.connect(func(): _name_edit.text = n)
		_list.add_child(b)


func _do_save() -> void:
	var n := _name_edit.text.strip_edges().validate_filename()
	if n == "":
		return
	save_requested.emit(n)
