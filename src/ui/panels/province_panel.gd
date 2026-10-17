extends PanelContainer
## Selected-province card (right edge): owner, terrain, population by
## profession, occupation, buildings. Rebuilt on selection change and weekly.

const K := preload("res://src/ui/ui_kit.gd")
const Biome := preload("res://src/world/biome.gd")

var hud: Control
var state: RefCounted
var world: RefCounted
var province := 0
var country := -1
var mode := 0 # 0 = province, 1 = country
var _claim_idx := 0
var _war_confirm := -1
var _body: VBoxContainer
var _scroll: ScrollContainer


func setup(h: Control) -> void:
	hud = h
	state = h.state
	world = h.world
	add_theme_stylebox_override("panel", K.panel_style(10))
	custom_minimum_size = Vector2(326, 0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_body = K.vbox(4)
	_body.custom_minimum_size = Vector2(300, 0)
	_scroll.add_child(_body)


func show_province(p: int) -> void:
	mode = 0
	province = p
	country = world.p_owner[p] if p > 0 else -1
	if _scroll != null:
		_scroll.scroll_vertical = 0
	refresh()


func show_country(c: int) -> void:
	mode = 1
	if c != country:
		_claim_idx = 0
		_war_confirm = -1
		if _scroll != null:
			_scroll.scroll_vertical = 0
	country = c
	province = 0
	refresh()


func _act(res: Variant, ok_msg: String) -> void:
	hud.toast(K.result_text(res, ok_msg), "ok" if K.result_ok(res) else "error")
	hud.refresh_now()


func refresh() -> void:
	var sy: int = _scroll.scroll_vertical if _scroll != null else 0
	K.clear(_body)
	if mode == 1:
		_refresh_country()
		_fit()
		_scroll.scroll_vertical = sy
		return
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
	var ob := K.btn(world.c_name[o] + ("  (you)" if o == me else "") + "  [Right-click]",
		"Click or right-click on map to view country & diplomacy",
		func(): hud.select_country_requested.emit(o))
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
	var econ = state.econ
	var sol: float = state.pops.province_sol(p)
	var rad: float = state.pops.province_radical(p)
	var gdp_p: float = econ.province_gdp(p)
	var coal_cap: int = int(econ.cap[p * econ.B + econ.i_coal])
	var iron_cap: int = int(econ.cap[p * econ.B + econ.i_iron])
	for kv in [
			["Terrain", Biome.NAMES[world.p_terrain[p]]],
			["Settlement", hud.TIERS[world.p_tier[p]] + (" - Port" if world.p_port[p].x >= 0 else "")],
			["Population", K.num(state.pops.province_pop(p))],
			["Std. of Living", "%.1f  (Radicals %d%%)" % [sol, int(round(rad * 100.0))]],
			["Province GDP", K.money(gdp_p)],
			["Deposits", "Coal cap %d  |  Iron cap %d" % [coal_cap, iron_cap]]]:
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
			var c_rad: float = float(co.get("radicalism", 0.0))
			pg.add_child(K.lbl("rad %d%%" % int(c_rad * 100.0), 11, K.BAD if c_rad > 0.3 else K.DIM))
		_body.add_child(pg)

	# Buildings
	_body.add_child(K.lbl("Buildings", 13, K.GOLD))
	var bl: Array = econ.buildings_in(p)
	var q_counts := {}
	if o >= 0:
		for qe: Dictionary in econ.queues[o]:
			if int(qe["province"]) == p:
				var qt: int = int(qe["type"])
				q_counts[qt] = int(q_counts.get(qt, 0)) + 1
	if bl.is_empty():
		_body.add_child(K.lbl("None", 11, K.DIM))
	for b: Dictionary in bl:
		var pf: float = float(b.get("profit", 0.0))
		var bt_id: int = int(b.get("type", 0))
		var q_add: int = int(q_counts.get(bt_id, 0))
		var q_str := (" (+%d)" % q_add) if q_add > 0 else ""
		var row := K.hbox(6)
		row.add_child(K.lbl("%s  lv %d%s/%d" % [str(b.get("name", "?")), int(b.get("level", 1)), q_str, int(econ.cap[p * econ.B + bt_id])], 12))
		row.add_child(K.spacer())
		row.add_child(K.lbl(K.signed_money(pf), 11, K.sign_color(pf), "Weekly profit\n" + econ.building_diagnosis(p, bt_id)))
		if o == me:
			var can_exp: bool = econ.can_build_fast(me, p, bt_id)
			var eb := K.btn("+", "Expand %s in %s" % [econ.building_name(bt_id), world.p_name[p]], func():
				if econ.queue_build(me, p, bt_id):
					hud.toast("%s queued in %s." % [econ.building_name(bt_id), world.p_name[p]], "ok")
					hud.refresh_now(), can_exp)
			eb.custom_minimum_size = Vector2(24, 0)
			row.add_child(eb)
		_body.add_child(row)
	if o == me:
		var act_row := K.hbox(6)
		act_row.add_child(K.btn("Build here...", "Open the Buildings tab for this province", func(): hud.open_tab("buildings")))
		var best_loc: Dictionary = econ.best_build_candidate(me, p)
		if bool(best_loc.get("ok", false)):
			var l_bt: int = int(best_loc["type"])
			act_row.add_child(K.btn("Best: %s" % econ.building_name(l_bt),
				"Queue most profitable building in %s (%s/wk)" % [world.p_name[p], K.signed_money(float(best_loc["profit"]))],
				func():
					if econ.queue_build(me, p, l_bt):
						hud.toast("%s queued in %s." % [econ.building_name(l_bt), world.p_name[p]], "ok")
						hud.refresh_now()))
		_body.add_child(act_row)
	else:
		var f_row := K.hbox(6)
		f_row.add_child(K.btn("Country & Diplomacy", "View %s overview and diplomatic actions" % world.c_short[o], func(): hud.select_country_requested.emit(o)))
		f_row.add_child(K.btn("Full Tab...", "Open full Diplomacy tab", func(): hud.open_diplomacy(o)))
		_body.add_child(f_row)
	_fit()
	_scroll.scroll_vertical = sy


func _refresh_country() -> void:
	var c := country
	if c < 0 or c >= world.country_count or state.alive[c] == 0:
		visible = false
		return
	visible = true
	var me: int = state.player
	var econ = state.econ
	var pops = state.pops
	var dip = state.diplo
	var mil = state.military
	var cap: int = world.c_capital[c]

	var head := K.hbox(8)
	head.add_child(K.flag(world.c_color[c], Vector2(34, 24)))
	var hv := K.vbox(0)
	hv.add_child(K.lbl(world.c_name[c] + ("  (you)" if c == me else ""), 16, K.GOLD))
	hv.add_child(K.lbl("%s  -  %s" % [hud.RANKS.get(world.c_rank[c], ""), world.c_gov[c]], 11, K.DIM))
	head.add_child(hv)
	head.add_child(K.spacer())
	head.add_child(K.btn("x", "Close", func(): hud.deselect_requested.emit()))
	_body.add_child(head)

	# Country overview stats
	var g := K.grid(2, 12, 2)
	var unemp: int = int(round(pops.unemployment(c) * 100.0))
	var lit: int = int(round(pops.literacy_rate(c) * 100.0))
	var rad: int = int(round(pops.radical_share(c) * 100.0))
	var leg: int = int(state.politics.legitimacy(c))
	var bat_cur: float = float(mil.bat[c])
	var bat_max: int = int(mil.max_battalions(c))
	var pwr: float = float(mil.power(c))
	var mor: int = int(round(float(mil.morale[c]) * 100.0))
	for kv in [
			["Capital", "%s (%d provinces)" % [world.p_name[cap] if cap > 0 else "-", world.c_provinces[c].size()]],
			["Population", "%s  (%d%% jobless)" % [K.num(pops.country_pop(c)), unemp]],
			["Living / Lit.", "SoL %.1f  |  Literacy %d%%" % [pops.avg_sol(c), lit]],
			["Politics", "Legit %d  |  Radicals %d%%" % [leg, rad]],
			["Economy", "GDP %s  |  Treas. %s" % [K.money(econ.gdp(c)), K.money(econ.treasury(c))]],
			["Army", "%.0f/%d bat  |  Pwr %.0f (%d%%)" % [bat_cur, bat_max, pwr, mor]]]:
		g.add_child(K.lbl(kv[0], 11, K.DIM))
		g.add_child(K.lbl(kv[1], 11))
	var al_names: PackedStringArray = []
	for a_id in dip.allies(c):
		al_names.append(world.c_short[int(a_id)])
	var tr_names: PackedStringArray = []
	for tr_id in dip.trade_partners(c):
		tr_names.append(world.c_short[int(tr_id)])
	g.add_child(K.lbl("Allies", 11, K.DIM))
	g.add_child(K.lbl(", ".join(al_names) if not al_names.is_empty() else "None", 11))
	g.add_child(K.lbl("Trade", 11, K.DIM))
	g.add_child(K.lbl(", ".join(tr_names) if not tr_names.is_empty() else "None", 11))
	_body.add_child(g)

	if cap > 0:
		var nav := K.hbox(6)
		nav.add_child(K.btn("Inspect Capital (%s)" % world.p_name[cap], "Switch to capital province view", func(): hud.select_requested.emit(cap)))
		nav.add_child(K.btn("Focus", "Center camera on capital", func(): hud.focus_requested.emit(world.p_anchor[cap])))
		_body.add_child(nav)

	# Own nation shortcuts
	if c == me:
		_body.add_child(K.section("National Shortcuts"))
		var best: Dictionary = econ.best_build_candidate(me, 0)
		if bool(best.get("ok", false)):
			var bp: int = int(best["province"])
			var bt: int = int(best["type"])
			_body.add_child(_wide(K.btn("Auto-Invest: %s in %s (%s/wk)" % [econ.building_name(bt), world.p_name[bp], K.signed_money(float(best["profit"]))],
				"Queue the highest-return building across your nation",
				func():
					if econ.queue_build(me, bp, bt):
						hud.toast("%s queued in %s." % [econ.building_name(bt), world.p_name[bp]], "ok")
						hud.refresh_now())))
		var qr := K.hbox(4)
		for tab_pair in [["overview", "Overview"], ["market", "Market"], ["politics", "Politics"], ["military", "Military"]]:
			var tk: String = tab_pair[0]
			qr.add_child(K.btn(tab_pair[1], "Open %s tab" % tab_pair[1], func(): hud.open_tab(tk)))
		_body.add_child(qr)
		return

	# Foreign nation: Direct Diplomacy section
	_body.add_child(K.section("Diplomacy  (DP %.0f/%d)" % [dip.diplomatic_points(me), int(dip.DP_CAP)]))

	# Pending proposals from this country
	for pr: Dictionary in dip.proposals_for(me):
		if int(pr.get("from", -1)) == c:
			var prow := K.hbox(6)
			var what: String = {"alliance": "Offers Alliance", "trade": "Offers Trade", "peace": "Offers Peace (%s)" % str(pr.get("terms", ""))}.get(str(pr.get("kind", "")), "Proposal")
			prow.add_child(K.lbl(what, 12, K.WARN))
			prow.add_child(K.spacer())
			var pid: int = int(pr["id"])
			prow.add_child(K.btn("Accept", "", func(): _act(dip.respond_proposal(pid, true), "Accepted.")))
			prow.add_child(K.btn("Decline", "", func(): _act(dip.respond_proposal(pid, false), "Declined.")))
			_body.add_child(prow)

	var rel_t: int = dip.relation(me, c)
	var rtip: String = K.breakdown_text("Relations with %s" % world.c_short[c], dip.relation_breakdown(me, c))
	var rr := K.hbox(8)
	rr.add_child(K.lbl("Relation %+d" % rel_t, 13, K.sign_color(float(rel_t)), rtip))
	rr.add_child(K.bar((rel_t + 100.0) / 200.0, K.GOOD if rel_t >= 0 else K.BAD, 100.0, 10.0, rtip))
	var tags := ""
	if dip.at_war(me, c): tags += " [WAR]"
	if dip.is_allied(me, c): tags += " [ALLY]"
	if dip.has_trade_agreement(me, c): tags += " [TRADE]"
	if dip.is_rival(me, c): tags += " [RIVAL]"
	if tags != "":
		rr.add_child(K.lbl(tags, 11, K.GOLD))
	_body.add_child(rr)

	var truce: int = dip.truce_days_left(me, c)
	if truce > 0:
		_body.add_child(K.lbl("Truce: %d days left" % truce, 11, K.WARN))

	var ab := K.vbox(4)
	_body.add_child(ab)
	ab.add_child(_wide(K.btn("Improve relations (-%d DP)" % int(dip.DP_IMPROVE),
		"Spend %d diplomatic points to raise relations over several months" % int(dip.DP_IMPROVE),
		func(): _act(dip.improve_relations(me, c), "Relations will improve."))))

	var row_pacts := K.hbox(4)
	if dip.is_allied(me, c):
		row_pacts.add_child(_wide(K.btn("Break alliance", "End the alliance", func(): _act(dip.break_alliance(me, c), "Alliance ended."))))
	else:
		var ca: Dictionary = dip.can_ally(me, c)
		row_pacts.add_child(_wide(K.btn("Alliance", "Allies join wars" if bool(ca["ok"]) else str(ca["reason"]),
			func(): _act(dip.propose_alliance(me, c), "%s accepted the alliance." % world.c_short[c]), bool(ca["ok"]))))
	if dip.has_trade_agreement(me, c):
		row_pacts.add_child(_wide(K.btn("Cancel trade", "Markets stop sharing surplus", func(): _act(dip.cancel_trade_agreement(me, c), "Trade agreement cancelled."))))
	else:
		var ct: Dictionary = dip.can_trade(me, c)
		row_pacts.add_child(_wide(K.btn("Trade pact", "Partner markets share surplus goods" if bool(ct["ok"]) else str(ct["reason"]),
			func(): _act(dip.propose_trade_agreement(me, c), "Trade agreement signed."), bool(ct["ok"]))))
	ab.add_child(row_pacts)

	if dip.is_rival(me, c):
		ab.add_child(_wide(K.btn("Drop rivalry", "End the rivalry", func(): _act(dip.drop_rival(me, c), "Rivalry ended."))))
	else:
		ab.add_child(_wide(K.btn("Declare rival", "Rivals may be attacked without a claim, but cannot ally or trade",
			func(): _act(dip.declare_rival(me, c), "%s is now your rival." % world.c_short[c]))))

	# Border claims & War / Peace
	var border := _border_provinces(me, c)
	var cr := K.hbox(4)
	var opt := OptionButton.new()
	opt.focus_mode = Control.FOCUS_NONE
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for bp: int in border:
		opt.add_item(world.p_name[bp] + (" (claimed)" if dip.has_claim(me, bp) else ""))
	_claim_idx = clampi(_claim_idx, 0, maxi(border.size() - 1, 0))
	if not border.is_empty():
		opt.selected = _claim_idx
	opt.item_selected.connect(func(i): _claim_idx = i)
	opt.disabled = border.is_empty()
	cr.add_child(opt)
	cr.add_child(K.btn("Claim (-%d)" % int(dip.DP_CLAIM),
		"Fabricate claim on selected border province" if not border.is_empty() else "No shared border province",
		func():
			if not border.is_empty():
				_act(dip.fabricate_claim(me, border[clampi(_claim_idx, 0, border.size() - 1)]), "Claim fabricated."),
		not border.is_empty()))
	ab.add_child(cr)

	var at_war: bool = dip.at_war(me, c)
	if not at_war:
		var goals := PackedInt32Array()
		for bp: int in border:
			if dip.has_claim(me, bp) and goals.size() < 4:
				goals.append(bp)
		if goals.is_empty() and dip.is_rival(me, c):
			for bp: int in border:
				if goals.size() < 4:
					goals.append(bp)
		var g_names: PackedStringArray = []
		for gp in goals:
			g_names.append(world.p_name[gp])
		var cw: Dictionary = dip.can_declare_war(me, c, goals) if not goals.is_empty() else {"ok": false, "reason": "War needs a claim on a border province (or a rivalry)."}
		var armed: bool = _war_confirm == c
		var tip: String = ("War goals: " + ", ".join(g_names)) if bool(cw["ok"]) else str(cw["reason"])
		var wb := K.btn("CLICK AGAIN TO DECLARE WAR" if armed else "Declare War", tip,
			func():
				if _war_confirm == c:
					_war_confirm = -1
					_act(dip.declare_war(me, c, goals), "War declared on %s!" % world.c_name[c])
				else:
					_war_confirm = c
					refresh(),
			bool(cw["ok"]))
		wb.add_theme_color_override("font_color", K.BAD)
		wb.add_theme_color_override("font_hover_color", Color(1, 0.6, 0.5))
		ab.add_child(_wide(wb))
	else:
		for w: Dictionary in dip.wars_of(me):
			var att: Array = w.get("attackers", [])
			var def: Array = w.get("defenders", [])
			if (att.has(me) and def.has(c)) or (def.has(me) and att.has(c)):
				var ws: float = dip.warscore_for(w, me)
				var wid: int = int(w.get("id", 0))
				ab.add_child(K.lbl("%s  (Warscore %+d)" % [dip.war_name(w), int(ws)], 12, K.sign_color(ws), dip.war_summary(wid)))
				var pr := K.hbox(4)
				pr.add_child(_wide(K.btn("White Peace", "End war with no territory changes", func(): _act(dip.offer_peace(wid, me, "white_peace"), "Peace agreed."))))
				pr.add_child(_wide(K.btn("Enforce Goals", "Demand war goals", func(): _act(dip.offer_peace(wid, me, "cede_goals"), "Peace agreed."))))
				ab.add_child(pr)

	ab.add_child(_wide(K.btn("Open Full Diplomacy Tab...", "Open the full Diplomacy panel", func(): hud.open_diplomacy(c))))


func _wide(b: Button) -> Button:
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return b


func _border_provinces(c_a: int, c_b: int) -> Array:
	var out: Array = []
	for p in world.c_provinces[c_b]:
		for q in world.p_neighbors[p]:
			if world.p_owner[q] == c_a:
				out.append(p)
				break
	return out


func _fit() -> void:
	var avail: float = hud.size.y - hud.PANEL_Y - 60.0
	_scroll.custom_minimum_size.y = clampf(_body.get_combined_minimum_size().y + 2.0, 40.0, avail)
	reset_size()
