extends "res://src/ui/panels/panel_base.gd"
## Event log: the last events from state.events, newest first, colour-coded by kind.

var only_mine := true


func rebuild() -> void:
	var c := player
	var head := K.hbox(10)
	head.add_child(K.lbl("Event log", 16, K.GOLD))
	head.add_child(K.spacer())
	var cb := CheckBox.new()
	cb.text = "My nation only"
	cb.focus_mode = Control.FOCUS_NONE
	cb.button_pressed = only_mine
	cb.toggled.connect(func(on):
		only_mine = on
		refresh())
	head.add_child(cb)
	add_child(head)
	var n := 0
	for i in range(state.events.size() - 1, -1, -1):
		var e: Dictionary = state.events[i]
		var ec: int = int(e.get("country", -1))
		if only_mine and ec != c and ec != -1:
			continue
		var row := K.hbox(8)
		var d := K.lbl(hud.short_date(int(e.get("day", 0))), 11, K.DIM)
		d.custom_minimum_size = Vector2(78, 0)
		d.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(d)
		var who := ""
		if ec >= 0 and ec != c:
			who = "[%s] " % world.c_short[ec]
		var t := K.lbl(who + str(e.get("text", "")), 12, hud.kind_color(str(e.get("kind", ""))))
		t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		t.custom_minimum_size = Vector2(380, 0)
		row.add_child(t)
		add_child(row)
		n += 1
		if n >= 120:
			break
	if n == 0:
		add_child(K.lbl("No events yet.", 13, K.DIM))
