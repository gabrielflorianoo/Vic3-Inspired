extends Control
## In-game HUD: top bar (date, speed, key national stats), tab row opening one
## panel at a time, selected-province card, hover tooltip and toast feed.
##
## Panels are created when their tab opens and freed when it closes. They are
## refreshed only on the weekly tick (throttled to REFRESH_MIN seconds), on a
## new selection, or right after a user action -- never every frame.

signal map_mode_requested(mode: int)
signal focus_requested(world_pos: Vector2)
signal select_requested(province: int)
signal deselect_requested
signal perf_toggle_requested
signal menu_requested

const K := preload("res://src/ui/ui_kit.gd")
const Biome := preload("res://src/world/biome.gd")
const ProvincePanel := preload("res://src/ui/panels/province_panel.gd")

const TIERS := ["", "Village", "Market Town", "Town", "City", "Capital"]
const RANKS := {"great": "Great Power", "major": "Major Power", "minor": "Minor Power"}
const TABS := [
	["overview", "Overview", "res://src/ui/panels/overview.gd"],
	["market", "Market", "res://src/ui/panels/market.gd"],
	["buildings", "Buildings", "res://src/ui/panels/buildings.gd"],
	["population", "Population", "res://src/ui/panels/population.gd"],
	["politics", "Politics", "res://src/ui/panels/politics.gd"],
	["technology", "Technology", "res://src/ui/panels/technology.gd"],
	["diplomacy", "Diplomacy", "res://src/ui/panels/diplomacy.gd"],
	["military", "Military", "res://src/ui/panels/military.gd"],
	["events", "Events", "res://src/ui/panels/events_log.gd"],
]
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const MONTH_DAYS := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
const REFRESH_MIN := 0.5
const HISTORY := 26
const MAX_TOASTS := 5
const TOP_H := 36.0
const TABS_Y := 40.0
const PANEL_Y := 74.0

var world: RefCounted
var state: RefCounted
var ctrl: Node
var selected_province := 0
var diplo_target := -1
var current_tab := ""

var _bar_date: Label
var _bar_treasury: Label
var _bar_pop: Label
var _bar_gdp: Label
var _bar_leg: Label
var _bar_rad: Label
var _bar_res: Label
var _speed_btns: Array[Button] = []
var _tab_btns := {}
var _mode_btns: Array[Button] = []
var _host: PanelContainer
var _scroll: ScrollContainer
var _panel: Control
var _panel_h := 0.0
var _province_panel: PanelContainer
var _toasts: VBoxContainer
var _tooltip: PanelContainer
var _tip_label: Label
var _status: Label
var _dirty := false
var _last_other_toast := -100000
var _last_refresh := 0.0
var _hist: Array = []     # per good: PackedFloat32Array of recent prices
var _tabs_row: HBoxContainer
var _top: PanelContainer
var _top_row: HBoxContainer


func setup(w: RefCounted, s: RefCounted, c: Node) -> void:
	world = w
	state = s
	ctrl = c
	theme = K.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_top_bar()
	_build_tabs()
	_build_host()
	_province_panel = ProvincePanel.new()
	add_child(_province_panel)
	_province_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_province_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_province_panel.offset_top = PANEL_Y
	_province_panel.offset_right = -8
	_province_panel.setup(self)
	_build_toasts()
	_build_tooltip()
	_build_status()
	_init_history()
	ctrl.stepped.connect(_on_stepped)
	ctrl.speed_changed.connect(_on_speed_changed)
	ctrl.events_arrived.connect(_on_events)
	_on_speed_changed(ctrl.speed)
	update_bar(true)


# ------------------------------------------------------------------ building

func _build_top_bar() -> void:
	_top = PanelContainer.new()
	_top.add_theme_stylebox_override("panel", K.style(Color(0.10, 0.09, 0.075, 0.95), Color(0.45, 0.37, 0.22), 1, 0, 4))
	_top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_top.custom_minimum_size = Vector2(0, TOP_H)
	add_child(_top)
	var h := K.hbox(10)
	_top.add_child(h)
	var p: int = state.player
	h.add_child(K.flag(world.c_color[p], Vector2(26, 18)))
	h.add_child(K.lbl(world.c_short[p], 16, K.GOLD))
	h.add_child(VSeparator.new())
	_bar_date = K.lbl("", 14, K.INK, "Current date")
	_bar_date.custom_minimum_size = Vector2(112, 0)
	h.add_child(_bar_date)
	var pause := K.btn("II", "Pause / resume (Space)", func(): ctrl.toggle_pause())
	pause.toggle_mode = true
	pause.custom_minimum_size = Vector2(30, 0)
	_speed_btns.append(pause)
	h.add_child(pause)
	for i in range(1, 6):
		var b := K.btn(str(i), "%s (key %d)" % [ctrl.SPEED_NAMES[i], i], func(): ctrl.set_speed(i))
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(26, 0)
		_speed_btns.append(b)
		h.add_child(b)
	h.add_child(VSeparator.new())
	_bar_treasury = K.lbl("", 13)
	_bar_pop = K.lbl("", 13)
	_bar_gdp = K.lbl("", 13)
	_bar_leg = K.lbl("", 13)
	_bar_rad = K.lbl("", 13)
	_bar_res = K.lbl("", 13)
	for l in [_bar_treasury, _bar_pop, _bar_gdp, _bar_leg, _bar_rad, _bar_res]:
		l.mouse_filter = Control.MOUSE_FILTER_STOP
		h.add_child(l)
	h.add_child(K.spacer())
	h.add_child(K.btn("Menu", "Pause menu (Esc)", menu_requested.emit))
	_top_row = h
	resized.connect(_fit_top_bar)


func _build_tabs() -> void:
	_tabs_row = K.hbox(4)
	_tabs_row.position = Vector2(8, TABS_Y)
	add_child(_tabs_row)
	for t in TABS:
		var b := K.btn(t[1], "Open the %s panel" % t[1], open_tab.bind(t[0]))
		b.toggle_mode = true
		b.add_theme_stylebox_override("normal", K.style(Color(0.12, 0.105, 0.085, 0.94), Color(0.42, 0.35, 0.22), 1, 2, 5))
		_tab_btns[t[0]] = b
		_tabs_row.add_child(b)
	var modes := ["Political", "Terrain", "Provinces", "SoL", "Pop", "GDP", "Unrest", "War"]
	var tips := [
		"Political map (F5)",
		"Terrain & biomes (F6)",
		"Province borders (F7)",
		"Standard of Living heatmap (red = poor, green = prosperous)",
		"Population density heatmap",
		"Province GDP / industrial output heatmap",
		"Radicals & unrest heatmap (green = calm, red = turbulent)",
		"War map: battles (red), sieges (orange), occupations and frontline provinces"
	]
	var grp := ButtonGroup.new()
	var mrow := K.hbox(3)
	mrow.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	mrow.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	mrow.offset_top = TABS_Y
	mrow.offset_right = -8
	add_child(mrow)
	for i in modes.size():
		var b := K.btn(modes[i], tips[i], map_mode_requested.emit.bind(i))
		b.toggle_mode = true
		b.button_group = grp
		b.button_pressed = i == 0
		b.add_theme_font_size_override("font_size", 11)
		_mode_btns.append(b)
		mrow.add_child(b)


func _build_host() -> void:
	_host = PanelContainer.new()
	_host.position = Vector2(8, PANEL_Y)
	_host.custom_minimum_size = Vector2(572, 0)
	_host.visible = false
	add_child(_host)
	var v := K.vbox(4)
	_host.add_child(v)
	var head := K.hbox(6)
	head.add_child(K.spacer())
	head.add_child(K.btn("Close", "Close panel", close_tab))
	v.add_child(head)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size = Vector2(548, 200)
	v.add_child(_scroll)


func _build_toasts() -> void:
	_toasts = VBoxContainer.new()
	_toasts.add_theme_constant_override("separation", 4)
	_toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toasts.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_toasts.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_toasts.anchor_left = 0.0
	_toasts.anchor_right = 1.0
	_toasts.offset_left = 590
	_toasts.offset_right = -330
	_toasts.offset_bottom = -34
	_toasts.alignment = BoxContainer.ALIGNMENT_END
	add_child(_toasts)


func _build_tooltip() -> void:
	_tooltip = PanelContainer.new()
	_tooltip.add_theme_stylebox_override("panel", K.style(Color(0.08, 0.07, 0.06, 0.92), Color(0.45, 0.37, 0.22), 1, 3, 6))
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.visible = false
	_tip_label = K.lbl("", 12)
	_tooltip.add_child(_tip_label)
	add_child(_tooltip)


func _build_status() -> void:
	_status = K.lbl("LMB select  -  drag/RMB pan  -  wheel zoom  -  WASD  -  Space pause  -  1-5 speed  -  F5-F7 map mode  -  L labels  -  Esc menu", 11, K.DIM)
	_status.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_status.offset_left = 12
	_status.offset_top = -22
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_status)


# ------------------------------------------------------------------- helpers

func short_date(day: int) -> String:
	var y := day / 365
	var d := day % 365
	var m := 0
	while d >= MONTH_DAYS[m]:
		d -= MONTH_DAYS[m]
		m += 1
	return "%d %s %d" % [d + 1, MONTHS[m], 1836 + y]


func kind_color(kind: String) -> Color:
	match kind:
		"economy": return Color(0.90, 0.80, 0.50)
		"politics": return Color(0.75, 0.62, 0.92)
		"diplomacy": return Color(0.55, 0.78, 0.95)
		"war": return Color(0.96, 0.50, 0.44)
		"tech": return Color(0.55, 0.88, 0.62)
		"pop": return Color(0.95, 0.70, 0.48)
	return K.INK


func price_history(g: int) -> PackedFloat32Array:
	return _hist[g] if g < _hist.size() else PackedFloat32Array()


func _init_history() -> void:
	_hist.clear()
	for g in state.econ.goods_count():
		_hist.append(PackedFloat32Array([state.econ.price(state.player, g)]))


func _record_prices() -> void:
	for g in _hist.size():
		var a: PackedFloat32Array = _hist[g]
		if a.size() >= HISTORY:
			a.remove_at(0)
		a.append(state.econ.price(state.player, g))
		_hist[g] = a


func mouse_over_ui(pos: Vector2) -> bool:
	if pos.y < TOP_H or _tabs_row.get_global_rect().has_point(pos):
		return true
	if _host.visible and _host.get_global_rect().has_point(pos):
		return true
	if _province_panel.visible and _province_panel.get_global_rect().has_point(pos):
		return true
	return pos.x > size.x - 470 and pos.y < TABS_Y + 28


# --------------------------------------------------------------- top bar

var _last_fit_w := -1.0
var _last_bar_day := -1
var _last_bar_msec := -10000

## Keeps the Menu button on screen at any window size / UI scale: lowest-priority stats are hidden
## (their numbers live in the Overview panel) until the whole row fits.
func _fit_top_bar() -> void:
	if _top_row == null or _bar_res == null:
		return
	_last_fit_w = size.x
	var order: Array = [_bar_res, _bar_gdp, _bar_pop, _bar_rad, _bar_leg]   # hidden first -> last
	for l: Control in order:
		l.visible = true
	var avail := size.x - 24.0
	for l: Control in order:
		if _top_row.get_combined_minimum_size().x <= avail:
			break
		l.visible = false


func update_bar(full: bool) -> void:
	_bar_date.text = state.date_string()
	if not full:
		return
	_last_bar_day = state.day
	_last_bar_msec = Time.get_ticks_msec()
	var c: int = state.player
	var econ = state.econ
	var np: int = state.diplo.proposals_for(c).size()
	_tab_btns["diplomacy"].text = "Diplomacy (%d)" % np if np > 0 else "Diplomacy"
	_tab_btns["diplomacy"].add_theme_color_override("font_color", K.WARN if np > 0 else K.INK)
	var sh_cnt: int = econ.shortage_goods(c).size()
	_tab_btns["market"].text = "Market (!%d)" % sh_cnt if sh_cnt > 0 else "Market"
	_tab_btns["market"].add_theme_color_override("font_color", K.BAD if sh_cnt > 0 else K.INK)
	var q_sz: int = econ.queue_size(c)
	_tab_btns["buildings"].text = "Buildings (%d)" % q_sz if q_sz > 0 else "Buildings"
	var bud: Dictionary = econ.budget(c)
	var bal: float = float(bud.get("balance", 0.0))
	var tr: float = K.treasury(econ, c)
	_bar_treasury.text = "%s (%s/wk)" % [K.money(tr), K.signed_money(bal)]
	_bar_treasury.add_theme_color_override("font_color", K.BAD if tr < 0.0 else (K.GOOD if bal >= 0.0 else K.WARN))
	_bar_treasury.tooltip_text = "Treasury %s\nWeekly: taxes %s, tariffs %s, admin -%s, military -%s, construction -%s, interest -%s\nBalance %s" % [
		K.money(tr), K.num(float(bud.get("tax", 0.0))), K.num(float(bud.get("tariffs", 0.0))), K.num(absf(float(bud.get("admin", 0.0)))),
		K.num(absf(float(bud.get("military", 0.0)))), K.num(absf(float(bud.get("construction", 0.0)))), K.num(absf(float(bud.get("interest", 0.0)))), K.signed_money(bal)]
	_bar_treasury.tooltip_text += "\n\n" + econ.budget_explanation(c)
	_bar_pop.text = "Pop " + K.num(state.pops.country_pop(c))
	_bar_pop.tooltip_text = "Total population\n" + econ.jobs_explanation(c)
	_bar_gdp.text = "GDP " + K.money(econ.gdp(c))
	_bar_gdp.tooltip_text = "Gross domestic product (annual value added)"
	var leg: float = state.politics.legitimacy(c)
	_bar_leg.text = "Legit %d" % int(leg)
	_bar_leg.add_theme_color_override("font_color", K.GOOD if leg >= 50.0 else (K.WARN if leg >= 25.0 else K.BAD))
	_bar_leg.tooltip_text = "Government legitimacy (0-100)"
	var rad: float = state.pops.radical_share(c)
	_bar_rad.text = "Rad %s" % K.pct(rad, 1)
	_bar_rad.add_theme_color_override("font_color", K.BAD if rad > 0.25 else (K.WARN if rad > 0.12 else K.INK))
	_bar_rad.tooltip_text = "Share of radical citizens. Above 35% for three months risks revolution."
	var rid: String = state.tech.researching(c)
	if rid == "":
		_bar_res.text = "Research: none!"
		_bar_res.add_theme_color_override("font_color", K.WARN)
		_bar_res.tooltip_text = "Pick a technology in the Technology tab."
	else:
		_bar_res.text = "%s %d%%" % [state.tech.tech_name(rid), int(state.tech.progress(c) * 100.0)]
		_bar_res.add_theme_color_override("font_color", K.INK)
		_bar_res.tooltip_text = "Researching %s\n%.1f points / week" % [state.tech.tech_name(rid), state.tech.points_per_week(c)]
	if size.x != _last_fit_w:
		_fit_top_bar.call_deferred()


func _on_speed_changed(speed: int) -> void:
	for i in _speed_btns.size():
		_speed_btns[i].set_pressed_no_signal((i == 0 and speed == 0) or (i > 0 and i == speed))


func set_mode_button(m: int) -> void:
	if m >= 0 and m < _mode_btns.size():
		_mode_btns[m].set_pressed_no_signal(true)


# ---------------------------------------------------------- stepping hooks

func _on_stepped(_days: int, week: bool, month: bool) -> void:
	var fast: bool = ctrl != null and int(ctrl.speed) >= 4
	if week or month:
		var now_ms := Time.get_ticks_msec()
		update_bar(not fast or (now_ms - _last_bar_msec >= 220))
	elif not fast or (int(state.day) & 1) == 0:
		_bar_date.text = state.date_string()
	if week:
		_record_prices()
		_dirty = true


func _on_events(evs: Array) -> void:
	var me: int = state.player
	var shown := 0
	var others := 0
	for e: Dictionary in evs:
		var ec: int = int(e.get("country", -1))
		var kind: String = str(e.get("kind", ""))
		if ec == me or ec == -1:
			if shown < 4:
				toast(str(e.get("text", "")), kind)
			shown += 1
		elif kind == "war" and others < 1 and Time.get_ticks_msec() - _last_other_toast > 5000:
			toast("[%s] %s" % [world.c_short[ec], str(e.get("text", ""))], kind)
			_last_other_toast = Time.get_ticks_msec()
			others += 1
	if shown > 4:
		toast("+%d more events (see Events tab)" % (shown - 4), "system")
	_dirty = true


func toast(text: String, kind := "system") -> void:
	if text == "":
		return
	for t in _toasts.get_children():
		if t.has_meta("text") and t.get_meta("text") == text:
			return  # identical toast already on screen
	while _toasts.get_child_count() >= MAX_TOASTS:
		var old := _toasts.get_child(0)
		_toasts.remove_child(old)
		old.queue_free()
	var col := K.INK
	var border := Color(0.45, 0.37, 0.22)
	match kind:
		"error":
			col = K.BAD
			border = K.BAD
		"ok":
			col = K.GOOD
			border = K.GOOD
		_:
			col = kind_color(kind)
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", K.style(Color(0.08, 0.07, 0.06, 0.93), border, 1, 3, 7))
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.set_meta("text", text)
	pc.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var l := K.lbl(text, 13, col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(300, 0)
	pc.add_child(l)
	_toasts.add_child(pc)
	var tw := pc.create_tween()
	tw.tween_interval(6.0 if kind != "error" else 7.0)
	tw.tween_property(pc, "modulate:a", 0.0, 0.8)
	tw.tween_callback(pc.queue_free)


# ------------------------------------------------------------------- tabs

func open_tab(tab: String) -> void:
	hide_tooltip()
	if tab == current_tab:
		close_tab()
		return
	_destroy_panel()
	current_tab = tab
	for k in _tab_btns:
		_tab_btns[k].set_pressed_no_signal(k == tab)
	for t in TABS:
		if t[0] == tab:
			_panel = load(t[2]).new()
	_scroll.add_child(_panel)
	_panel.setup(self)
	_host.visible = true
	_panel_h = 0.0
	_scroll.scroll_vertical = 0
	_fit_host.call_deferred()
	_last_refresh = Time.get_ticks_msec() / 1000.0


func close_tab() -> void:
	_destroy_panel()
	current_tab = ""
	for k in _tab_btns:
		_tab_btns[k].set_pressed_no_signal(false)
	_host.visible = false


func _destroy_panel() -> void:
	if _panel != null:
		_scroll.remove_child(_panel)
		_panel.queue_free()
		_panel = null


func _fit_host() -> void:
	if _panel == null:
		return
	var avail := size.y - PANEL_Y - 34.0 - 70.0
	_panel_h = maxf(_panel_h, _panel.get_combined_minimum_size().y + 4.0)
	_scroll.custom_minimum_size.y = clampf(_panel_h, 120.0, avail)
	_host.reset_size()


func open_diplomacy(country: int) -> void:
	diplo_target = country
	if current_tab != "diplomacy":
		open_tab("diplomacy")
	else:
		refresh_now()


func select_country_on_map(c: int) -> void:
	select_requested.emit(world.c_capital[c])


func focus_province(p: int) -> void:
	select_requested.emit(p)
	focus_requested.emit(world.p_anchor[p])


var _refresh_pending := false

## Re-render open panels immediately (after a user action).
func refresh_now() -> void:
	if not _refresh_pending:
		_refresh_pending = true
		_do_refresh_now.call_deferred()


func _do_refresh_now() -> void:
	_refresh_pending = false
	_dirty = false
	_last_refresh = Time.get_ticks_msec() / 1000.0
	if _last_bar_day != state.day:
		update_bar(true)
	if _panel != null:
		var sy: int = _scroll.scroll_vertical
		_panel.refresh()
		_fit_host()
		_scroll.scroll_vertical = sy
	if _province_panel.visible:
		_province_panel.refresh()


func _process(_delta: float) -> void:
	if _dirty and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var now := Time.get_ticks_msec() / 1000.0
		var min_interval := 1.0 if (ctrl != null and ctrl.speed >= 4) else REFRESH_MIN
		if now - _last_refresh >= min_interval:
			_do_refresh_now()


# --------------------------------------------------- selection and tooltips

func show_selection(province: int) -> void:
	selected_province = province
	_province_panel.show_province(province)
	if current_tab == "buildings" and _panel != null:
		_panel.refresh()
		_fit_host.call_deferred()


func show_tooltip(province: int, at: Vector2) -> void:
	if province <= 0:
		_tooltip.visible = false
		return
	var o: int = world.p_owner[province]
	var txt := "%s\n%s" % [world.p_name[province], world.c_name[o] if o >= 0 else "Unclaimed"]
	txt += "\n%s - %s%s" % [Biome.NAMES[world.p_terrain[province]], TIERS[world.p_tier[province]], " - Port" if world.p_port[province].x >= 0 else ""]
	if o >= 0:
		var pop: float = state.pops.province_pop(province)
		var sol: float = state.pops.province_sol(province)
		var rad: float = state.pops.province_radical(province)
		var gdp: float = state.econ.province_gdp(province)
		txt += "\nPop %s  |  SoL %.1f  |  Rad %d%%  |  GDP %s" % [K.num(pop), sol, int(round(rad * 100.0)), K.money(gdp)]
		var ctl: int = state.military.controller(province)
		if ctl != o and ctl >= 0:
			txt += "\nOccupied by %s" % world.c_short[ctl]
	_tip_label.text = txt
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
