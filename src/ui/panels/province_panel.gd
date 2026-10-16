extends PanelContainer
## Selected-province card (right edge): owner, terrain, population by
## profession, occupation, buildings. Rebuilt on selection change and weekly.

const K := preload("res://src/ui/ui_kit.gd")
const Biome := preload("res://src/world/biome.gd")

var hud: Control
var state: RefCounted
var world: RefCounted
var province := 0
var _body: VBoxContainer
var _scroll: ScrollContainer


func setup(h: Control) -> void:
	hud = h
	state = h.state
	world = h.world
	add_theme_stylebox_override("panel", K.panel_style(10))
	custom_minimum_size = Vector2(316, 0)
	visible = false
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_body = K.vbox(4)
	_body.custom_minimum_size = Vector2(290, 0)
	_scroll.add_child(_body)


func show_province(p: int) -> void:
	province = p
	refresh()


func refresh() -> void:
	K.clear(_body)
	var p := province
	if p <= 0 or world.p_owner[p] < 0:
		visible = false
		return
	visible = true
	var o: int = world.p_owner[p]
	var me: int = state.player
	var head := K.hbox(8)
	head.add_child(K.flag(world.c_color[o], Vector2(30, 22)))
	var hv := K.vbox(0)
	hv.add_child(K.lbl(world.p_name[p] + ("  *" if world.p_capital[p] else ""), 16, K.GOLD))
	var ob := K.btn(world.c_name[o] + ("  (you)" if o == me else ""), "Open diplomacy" if o != me else "Your nation", func():
		if o != me:
			hud.open_diplomacy(o))
	ob.flat = true
	ob.alignment = HORIZONTAL_ALIGNMENT_LEFT
	ob.add_theme_font_size_override("font_size", 12)
	hv.add_child(ob)
	head.add_child(hv)
	head.add_child(K.spacer())
	head.add_child(K.btn("x", "Close (click empty sea)", func(): hud.deselect_requested.emit()))
	_body.add_child(head)

	var g := K.grid(2, 14, 2)
	var ctrl: int = state.military.controller(p)
	for kv in [["Terrain", Biome.NAMES[world.p_terrain[p]]], ["Settlement", hud.TIERS[world.p_tier[p]] + (" - Port" if world.p_port[p].x >= 0 else "")],
			["Population", K.num(state.pops.province_pop(p))]]:
		g.add_child(K.lbl(kv[0], 12, K.DIM))
		g.add_child(K.lbl(kv[1], 12))
	if ctrl != o and ctrl >= 0:
		g.add_child(K.lbl("Occupied by", 12, K.BAD))
		g.add_child(K.lbl(world.c_name[ctrl], 12, K.BAD))
	_body.add_child(g)

	# Population by profession
	var cohorts: Array = state.pops.cohorts_in(p)
	if not cohorts.is_empty():
		_body.add_child(K.lbl("People", 13, K.GOLD))
		var pg := K.grid(4, 10, 1)
		for co: Dictionary in cohorts:
			if float(co.get("size", 0.0)) < 1.0:
				continue
			pg.add_child(K.lbl(str(co.get("name", "")), 11, K.DIM))
			pg.add_child(K.lbl(K.num(float(co.get("size", 0.0))), 11))
			pg.add_child(K.lbl("SoL %.1f" % float(co.get("sol", 0.0)), 11, K.DIM))
			var rad: float = float(co.get("radicalism", 0.0))
			pg.add_child(K.lbl("rad %d%%" % int(rad * 100.0), 11, K.BAD if rad > 0.3 else K.DIM))
		_body.add_child(pg)

	# Buildings
	_body.add_child(K.lbl("Buildings", 13, K.GOLD))
	var bl: Array = state.econ.buildings_in(p)
	if bl.is_empty():
		_body.add_child(K.lbl("None", 11, K.DIM))
	for b: Dictionary in bl:
		var pf: float = float(b.get("profit", 0.0))
		var row := K.hbox(6)
		row.add_child(K.lbl("%s  lv %d" % [str(b.get("name", "?")), int(b.get("level", 1))], 12))
		row.add_child(K.spacer())
		row.add_child(K.lbl(K.signed_money(pf), 11, K.sign_color(pf), "Weekly profit"))
		_body.add_child(row)
	if o == me:
		var bb := K.btn("Build here...", "Open the Buildings tab for this province", func(): hud.open_tab("buildings"))
		_body.add_child(bb)
	else:
		_body.add_child(K.btn("Diplomacy...", "Open diplomacy with %s" % world.c_short[o], func(): hud.open_diplomacy(o)))
	_fit.call_deferred()


func _fit() -> void:
	var avail: float = hud.size.y - hud.PANEL_Y - 60.0
	_scroll.custom_minimum_size.y = clampf(_body.get_combined_minimum_size().y + 2.0, 40.0, avail)
	reset_size()
