extends Control
## Strategic HUD: top bar, country/province panel, hover tooltip, zoom/LOD readout.
## Built in code so it stays diff-friendly; panels rebuild only when the
## selection changes, the tooltip only when the hovered province changes.

signal map_mode_requested(mode: int)
signal country_clicked(country: int)
signal focus_requested(world_pos: Vector2)
signal perf_toggle_requested
signal benchmark_requested
signal deselect_requested

const Biome := preload("res://src/world/biome.gd")
const GOLD := Color(0.86, 0.72, 0.42)
const INK := Color(0.93, 0.90, 0.82)
const DIM := Color(0.68, 0.64, 0.56)
const TIERS := ["", "Village", "Market Town", "Town", "City", "Capital"]
const RANKS := {"great": "Great Power", "major": "Major Power", "minor": "Minor Power"}

var world: RefCounted
var _panel: PanelContainer
var _body: VBoxContainer
var _tooltip: PanelContainer
var _tip_label: Label
var _status: Label
var _mode_buttons: Array[Button] = []


func setup(w: RefCounted) -> void:
	world = w
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_top_bar()
	_build_panel()
	_build_tooltip()
	_build_status()


static func style(bg: Color, border: Color, bw := 1, radius := 3, pad := 8) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(pad)
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 4
	return sb


func _lbl(t: String, fs := 13, col := INK) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", col)
	return l


func _btn(t: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_stylebox_override("normal", style(Color(0.17, 0.15, 0.12), Color(0.42, 0.35, 0.22), 1, 2, 5))
	b.add_theme_stylebox_override("hover", style(Color(0.26, 0.22, 0.16), GOLD, 1, 2, 5))
	b.add_theme_stylebox_override("pressed", style(Color(0.36, 0.29, 0.17), GOLD, 1, 2, 5))
	b.add_theme_color_override("font_color", INK)
	b.add_theme_color_override("font_pressed_color", Color(1, 0.92, 0.7))
	b.pressed.connect(cb)
	return b


func _build_top_bar() -> void:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", style(Color(0.10, 0.09, 0.075, 0.94), Color(0.45, 0.37, 0.22), 1, 0, 5))
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	add_child(bar)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	bar.add_child(h)
	h.add_child(_lbl("  IRON & SOCIETY", 17, GOLD))
	h.add_child(_lbl("  ·  Map Prototype (Milestone 1)  ", 12, DIM))
	var group := ButtonGroup.new()
	for i in 3:
		var b := _btn(["Political", "Terrain", "Provinces"][i], "Map mode (key %d)" % (i + 1), map_mode_requested.emit.bind(i))
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = i == 0
		_mode_buttons.append(b)
		h.add_child(b)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sp)
	h.add_child(_btn("Performance [F3]", "Cycle performance overlay", perf_toggle_requested.emit))
	h.add_child(_btn("Benchmark [F9]", "Run the scripted map benchmark", benchmark_requested.emit))


func set_mode_button(m: int) -> void:
	_mode_buttons[m].button_pressed = true


func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", style(Color(0.11, 0.10, 0.085, 0.95), Color(0.50, 0.41, 0.24), 1, 4, 12))
	_panel.position = Vector2(10, 48)
	_panel.custom_minimum_size = Vector2(310, 0)
	_panel.visible = false
	add_child(_panel)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 5)
	_panel.add_child(_body)


func _build_tooltip() -> void:
	_tooltip = PanelContainer.new()
	_tooltip.add_theme_stylebox_override("panel", style(Color(0.08, 0.07, 0.06, 0.92), Color(0.45, 0.37, 0.22), 1, 3, 6))
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.visible = false
	_tip_label = _lbl("", 12)
	_tooltip.add_child(_tip_label)
	add_child(_tooltip)


func _build_status() -> void:
	_status = _lbl("", 12, DIM)
	_status.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_status.offset_top = -24
	_status.offset_left = 12
	add_child(_status)


func set_status(zoom: float, lod: int) -> void:
	_status.text = "LMB select · drag/RMB pan · wheel zoom · WASD · 1-3 modes · L labels · Esc clear      Zoom ×%.2f · %s" % [zoom, ["Strategic", "Regional", "Local"][lod]]


func show_tooltip(province: int, at: Vector2) -> void:
	if province <= 0:
		_tooltip.visible = false
		return
	var o: int = world.p_owner[province]
	var txt := "%s\n%s" % [world.p_name[province], world.c_name[o] if o >= 0 else "Unclaimed"]
	txt += "\n%s · %s%s" % [Biome.NAMES[world.p_terrain[province]], TIERS[world.p_tier[province]], " · Port" if world.p_port[province].x >= 0 else ""]
	_tip_label.text = txt
	_tooltip.visible = true
	_tooltip.reset_size()
	move_tooltip(at)


func move_tooltip(at: Vector2) -> void:
	if _tooltip.visible:
		var p := at + Vector2(18, 18)
		var vs := get_viewport_rect().size
		_tooltip.position = Vector2(minf(p.x, vs.x - _tooltip.size.x - 4), minf(p.y, vs.y - _tooltip.size.y - 4))


## Rebuild the info panel. Called only on selection change.
func show_selection(province: int) -> void:
	for c in _body.get_children():
		c.queue_free()
	var country: int = world.p_owner[province] if province > 0 else -1
	if country < 0:
		_panel.visible = false
		return
	_panel.visible = true
	_country_section(country)
	_body.add_child(HSeparator.new())
	_province_section(province)
	var row := HBoxContainer.new()
	row.add_child(_btn("Focus Capital", "Center the map on the capital", func(): focus_requested.emit(world.p_anchor[world.c_capital[country]])))
	row.add_child(_btn("Close", "Clear selection (Esc)", deselect_requested.emit))
	_body.add_child(row)
	_panel.reset_size()


func _country_section(c: int) -> void:
	var head := HBoxContainer.new()
	var flag := ColorRect.new()
	flag.color = world.c_color[c]
	flag.custom_minimum_size = Vector2(34, 24)
	head.add_child(flag)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.add_child(_lbl(world.c_name[c], 16, GOLD))
	v.add_child(_lbl("%s · %s" % [RANKS.get(world.c_rank[c], ""), world.c_gov[c]], 11, DIM))
	head.add_child(v)
	_body.add_child(head)
	var provs: PackedInt32Array = world.c_provinces[c]
	var coastal := 0
	var ports := 0
	for p in provs:
		if world.p_port[p].x >= 0:
			ports += 1
	coastal = ports
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	for kv in [["Capital", world.p_name[world.c_capital[c]]], ["Provinces", str(provs.size())],
			["Land area", "%s km²" % _thousands(world.area_km2(world.c_area[c]))],
			["Ports", "%d of %d provinces" % [ports, provs.size()]], ["Tag", world.c_tag[c]]]:
		grid.add_child(_lbl(kv[0], 12, DIM))
		grid.add_child(_lbl(kv[1], 12))
	_body.add_child(grid)
	_body.add_child(_lbl("Terrain composition", 12, GOLD))
	_body.add_child(_terrain_bar(world.country_terrain_mix(c)))
	_body.add_child(_lbl("Neighbours", 12, GOLD))
	var flow := HFlowContainer.new()
	flow.custom_minimum_size = Vector2(300, 0)
	for n in world.country_neighbors(c):
		var b := _btn(world.c_short[n], world.c_name[n], country_clicked.emit.bind(n))
		b.add_theme_stylebox_override("normal", style(world.c_color[n].darkened(0.45), world.c_color[n], 1, 2, 4))
		flow.add_child(b)
	if flow.get_child_count() == 0:
		flow.add_child(_lbl("None (isolated by sea)", 12, DIM))
	_body.add_child(flow)
	if coastal == 0:
		_body.add_child(_lbl("Landlocked", 11, DIM))


func _province_section(p: int) -> void:
	_body.add_child(_lbl(world.p_name[p] + ("  ★" if world.p_capital[p] else ""), 15, INK))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	for kv in [["Settlement", TIERS[world.p_tier[p]]], ["Terrain", Biome.NAMES[world.p_terrain[p]]],
			["Mean elevation", "%d m" % int(world.p_elev[p] * 3800.0)],
			["Area", "%s km²" % _thousands(world.area_km2(world.p_area[p]))],
			["Coast", "Port" if world.p_port[p].x >= 0 else "Inland"],
			["Bordering provinces", str(world.p_neighbors[p].size())]]:
		grid.add_child(_lbl(kv[0], 12, DIM))
		grid.add_child(_lbl(kv[1], 12))
	_body.add_child(grid)
	_body.add_child(_terrain_bar(world.p_terrain_mix[p]))


func _terrain_bar(mix: PackedFloat32Array) -> Control:
	var v := VBoxContainer.new()
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 0)
	bar.custom_minimum_size = Vector2(290, 10)
	var legend := ""
	var order := []
	for b in range(1, Biome.COUNT):
		if mix[b] > 0.01:
			order.append([mix[b], b])
	order.sort_custom(func(x, y): return x[0] > y[0])
	for e in order:
		var r := ColorRect.new()
		r.color = Biome.COLORS[e[1]]
		r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r.size_flags_stretch_ratio = e[0]
		r.tooltip_text = "%s %d%%" % [Biome.NAMES[e[1]], int(e[0] * 100)]
		bar.add_child(r)
	for i in mini(4, order.size()):
		legend += "%s %d%%   " % [Biome.NAMES[order[i][1]], int(order[i][0] * 100)]
	v.add_child(bar)
	v.add_child(_lbl(legend, 11, DIM))
	return v


static func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return s + out
