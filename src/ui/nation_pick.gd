extends Control
## Nation-pick overlay for a new game: banner, and a card for the country that
## owns the clicked province with "Play as X" / "Back". Stats come from a
## preview GameState (initial conditions of the scenario).

signal confirmed(country: int)
signal menu_requested

const K := preload("res://src/ui/ui_kit.gd")
const RANKS := {"great": "Great Power", "major": "Major Power", "minor": "Minor Power"}
const HINTS := {
	"great": "Vast economy and army. A forgiving start with many rivals watching.",
	"major": "A solid base with room to grow. Balanced risk and reward.",
	"minor": "Small and exposed. Industry, alliances and careful diplomacy are essential.",
}

var world: RefCounted
var preview: RefCounted
var _card: PanelContainer
var _body: VBoxContainer
var _banner_hint: Label
var _tooltip: PanelContainer
var _tip_label: Label


func setup(w: RefCounted, preview_state: RefCounted) -> void:
	world = w
	preview = preview_state
	theme = K.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var banner := PanelContainer.new()
	banner.add_theme_stylebox_override("panel", K.style(Color(0.09, 0.08, 0.065, 0.94), Color(0.62, 0.50, 0.28), 2, 3, 12))
	banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	banner.offset_top = 14
	add_child(banner)
	var bv := K.vbox(2)
	banner.add_child(bv)
	var t := K.lbl("Select a province to choose your nation", 22, K.GOLD)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bv.add_child(t)
	_banner_hint = K.lbl("You will rule the country that owns it.  January 1836.  The game starts paused.", 12, K.DIM)
	_banner_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bv.add_child(_banner_hint)
	var mb := K.btn("< Main Menu", "Return to the main menu", menu_requested.emit)
	mb.position = Vector2(12, 14)
	add_child(mb)

	_card = PanelContainer.new()
	_card.add_theme_stylebox_override("panel", K.style(Color(0.10, 0.09, 0.075, 0.97), K.BORDER, 2, 4, 14))
	_card.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	_card.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_card.grow_vertical = Control.GROW_DIRECTION_BOTH
	_card.offset_right = -18
	_card.custom_minimum_size = Vector2(340, 0)
	_card.visible = false
	add_child(_card)
	_body = K.vbox(6)
	_card.add_child(_body)
	_tooltip = PanelContainer.new()
	_tooltip.add_theme_stylebox_override("panel", K.style(Color(0.08, 0.07, 0.06, 0.92), Color(0.45, 0.37, 0.22), 1, 3, 6))
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.visible = false
	_tip_label = K.lbl("", 12)
	_tooltip.add_child(_tip_label)
	add_child(_tooltip)


func hide_card() -> void:
	_card.visible = false


func show_country(c: int) -> void:
	K.clear(_body)
	if c < 0:
		_card.visible = false
		return
	_card.visible = true
	var head := K.hbox(10)
	head.add_child(K.flag(world.c_color[c], Vector2(46, 32)))
	var hv := K.vbox(0)
	hv.add_child(K.lbl(world.c_name[c], 19, K.GOLD))
	hv.add_child(K.lbl("%s  -  %s" % [RANKS.get(world.c_rank[c], ""), world.c_gov[c]], 12, K.DIM))
	head.add_child(hv)
	_body.add_child(head)
	_body.add_child(HSeparator.new())
	var g := K.grid(2, 18, 3)
	var rows := [["Capital", world.p_name[world.c_capital[c]]], ["Provinces", str(world.c_provinces[c].size())]]
	if preview != null:
		var army: Dictionary = preview.military.army(c)
		rows.append(["Population", K.num(preview.pops.country_pop(c))])
		rows.append(["GDP", K.money(preview.econ.gdp(c)) + "  / yr"])
		rows.append(["Army", "%d battalions  (power %.0f)" % [int(army.get("battalions", 0)), float(army.get("power", 0.0))]])
		rows.append(["Literacy", K.pct(preview.pops.literacy_of(c), 0)])
	var nb: PackedInt32Array = world.country_neighbors(c)
	var names: PackedStringArray = []
	for n in nb:
		names.append(world.c_short[n])
	rows.append(["Neighbours", ", ".join(names) if not names.is_empty() else "None (island)"])
	for kv in rows:
		g.add_child(K.lbl(kv[0], 12, K.DIM))
		var v := K.lbl(kv[1], 13)
		v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.custom_minimum_size = Vector2(210, 0)
		g.add_child(v)
	_body.add_child(g)
	var hint := K.lbl(HINTS.get(world.c_rank[c], ""), 12, K.DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(300, 0)
	_body.add_child(hint)
	_body.add_child(HSeparator.new())
	var play := K.btn("Play as %s" % world.c_short[c], "Begin the game as %s" % world.c_name[c], func(): confirmed.emit(c))
	play.custom_minimum_size = Vector2(0, 40)
	play.add_theme_font_size_override("font_size", 16)
	play.add_theme_stylebox_override("normal", K.style(Color(0.30, 0.24, 0.12), K.GOLD, 2, 3, 8))
	play.add_theme_stylebox_override("hover", K.style(Color(0.42, 0.33, 0.15), Color(1, 0.88, 0.5), 2, 3, 8))
	_body.add_child(play)
	_body.add_child(K.btn("Back", "Choose a different nation", hide_card))
	_card.reset_size()


func show_tooltip(province: int, at: Vector2) -> void:
	var o: int = world.p_owner[province]
	if province <= 0 or o < 0:
		_tooltip.visible = false
		return
	_tip_label.text = "%s\n%s  (%s)" % [world.p_name[province], world.c_name[o], RANKS.get(world.c_rank[o], "")]
	_tooltip.visible = true
	_tooltip.reset_size()
	move_tooltip(at)


func hide_tooltip() -> void:
	_tooltip.visible = false


func move_tooltip(at: Vector2) -> void:
	if _tooltip.visible:
		var p := at + Vector2(18, 18)
		var vs := get_viewport_rect().size
		_tooltip.position = Vector2(minf(p.x, vs.x - _tooltip.size.x - 4), minf(p.y, vs.y - _tooltip.size.y - 4))
