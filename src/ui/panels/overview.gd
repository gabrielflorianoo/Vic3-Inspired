extends "res://src/ui/panels/panel_base.gd"
## Overview: headline stats, budget (with tax level control & private investment pool), research, wars, recent events.

const TAX_NAMES := ["Low", "Medium", "High"]


func rebuild() -> void:
	var c := player
	var head := K.hbox(10)
	head.add_child(K.flag(world.c_color[c], Vector2(40, 28)))
	var hv := K.vbox(0)
	hv.add_child(K.lbl(world.c_name[c], 18, K.GOLD))
	var gov: String = state.politics.government_name(c)
	hv.add_child(K.lbl("%s  -  %s" % [hud.RANKS.get(world.c_rank[c], ""), gov if gov != "" else world.c_gov[c]], 12, K.DIM))
	head.add_child(hv)
	add_child(head)

	add_child(K.section("State of the nation"))
	var g := K.grid(4, 16, 4)
	var pops = state.pops
	var econ = state.econ
	var pop: float = pops.country_pop(c)
	_kv(g, "Population", K.num(pop), "Total population: %s (Literacy %s, Unemp %s)\n%s" % [K.num(pop), K.pct(pops.literacy_of(c), 1), K.pct(pops.unemployment(c), 1), pops.sol_explanation(c)])
	_kv(g, "GDP", K.money(econ.gdp(c)), econ.gdp_explanation(c))
	_kv(g, "Provinces", str(world.c_provinces[c].size()))
	var leg_val: float = state.politics.legitimacy(c)
	_kv(g, "Legitimacy", "%d" % int(leg_val), "Government legitimacy: %d / 100\nInfluenced by governing interest group clout/approval, national debt, radicalism, and war exhaustion.\nAction: Enact laws supported by powerful interest groups or pay off national debt." % int(leg_val))
	_kv(g, "Unemployment", K.pct(pops.unemployment(c), 1))
	_kv(g, "Avg. standard of living", "%.1f" % pops.avg_sol(c), pops.sol_explanation(c))
	_kv(g, "Literacy", K.pct(pops.literacy_of(c), 1))
	var rad: float = pops.radical_share(c)
	_kv(g, "Radicals", K.pct(rad, 1), "Radical citizens: %s\nMain factors: Standard of Living (%.1f), unemployment (%s), and high taxation.\nConsequence: Above 35%% for 3 months risks revolution.\nAction: Lower taxes, expand consumer goods (Grain, Clothes, Furniture), or create jobs." % [K.pct(rad, 1), pops.avg_sol(c), K.pct(pops.unemployment(c), 1)], K.BAD if rad > 0.25 else K.INK)
	var army: Dictionary = state.military.army(c)
	_kv(g, "Army", "%d bn  (power %.0f)" % [int(army.get("battalions", 0)), float(army.get("power", 0.0))], K.breakdown_text("Army power", state.military.power_breakdown(c)))
	_kv(g, "Wars", str(state.diplo.wars_of(c).size()))
	add_child(g)

	# Smart Alerts & Causal Diagnostics
	var alerts: Array = econ.smart_alerts(c) if econ.has_method("smart_alerts") else []
	if state.military != null and state.military.has_method("front_alerts"):
		for fa in state.military.front_alerts(c):
			alerts.append(fa)
	if not alerts.is_empty():
		add_child(K.section("Active Diagnostics & Alerts (%d)" % alerts.size()))
		for i in mini(alerts.size(), 4):
			var al: Dictionary = alerts[i]
			var sev: String = str(al.get("severity", "warning"))
			var col := K.BAD if sev == "critical" else (K.WARN if sev == "warning" else K.GOOD)
			var tip_txt := "[%s] %s\nCause: %s\nAction: %s" % [sev.to_upper(), str(al.get("problem", "")), str(al.get("cause", "")), str(al.get("action", ""))]
			var arow := K.hbox(8)
			var albl := K.lbl("• %s: %s" % [str(al.get("label", "Alert")), str(al.get("problem", ""))], 12, col, tip_txt)
			albl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			albl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			albl.custom_minimum_size = Vector2(360, 0)
			arow.add_child(albl)
			var tab_id: String = str(al.get("tab", "overview"))
			var prov_id: int = int(al.get("province", -1))
			if tab_id != "overview" or prov_id > 0:
				arow.add_child(K.btn("Inspect", tip_txt, func():
					if prov_id > 0 and hud.has_method("focus_province"):
						hud.focus_province(prov_id)
					if tab_id != "" and tab_id != "overview":
						hud.open_tab(tab_id)))
			add_child(arow)

	add_child(K.section("Budget (per week) — hover for cause & effect"))
	var b: Dictionary = econ.budget(c)
	var b_exp: String = econ.budget_explanation(c)
	var bg := K.grid(2, 30, 3)
	var treasury: float = K.treasury(econ, c)
	_kv(bg, "Treasury", K.money(treasury), b_exp, K.BAD if treasury < 0.0 else K.INK)
	if econ.can_see_investment_pool(c):
		var p_pool: float = econ.investment_pool(c)
		var p_net: float = econ.investment_inflow(c) - econ.investment_outflow(c)
		_kv(bg, "Private Investment Pool (Read-only)", "%s (%s/wk)" % [K.money(p_pool), K.signed_money(p_net)],
			"Private capital accumulated by capitalists and aristocrats (visible under Free Trade). Cannot be spent by the state; funds autonomous private expansion, privatizations, and allied foreign investment.",
			K.GOLD)
	else:
		_kv(bg, "Private Investment Pool", "Hidden (requires Free Trade)",
			"Enact Free Trade in the Politics tab to inspect the private sector's investment pool balance.",
			K.DIM)
	var item_tips := {
		"tax": "Income and poll taxes collected from employed pops. Modified by Tax Level and Administrative Efficiency (%s)." % K.pct(econ.admin_efficiency(c)),
		"tariffs": "Trade duties collected on market imports and exports. Modified by Trade Law.",
		"admin": "Wages and paper inputs for Government Administration, Universities, and state institutions.",
		"military": "Battalion wages, arms consumption, and posture upkeep (%s posture)." % state.military.POST_NAMES[state.military.get_posture(c)],
		"construction": "Weekly spending on active state construction projects (%d active)." % mini(econ.queue(c).size(), econ._con_slots(c)),
		"interest": "Weekly interest paid on national debt (2.5%% of negative treasury)."
	}
	for kv in [["Taxes", "tax", 1.0], ["Tariffs", "tariffs", 1.0], ["Administration", "admin", -1.0], ["Military upkeep", "military", -1.0],
			["Construction", "construction", -1.0], ["Debt interest", "interest", -1.0]]:
		var shown: float = absf(float(b.get(kv[1], 0.0))) * kv[2]
		_kv(bg, kv[0], K.signed_money(shown), str(item_tips.get(kv[1], b_exp)), K.sign_color(shown))
	var bal: float = float(b.get("balance", 0.0))
	_kv(bg, "Balance", K.signed_money(bal), b_exp, K.sign_color(bal))
	add_child(bg)
	if econ.in_debt(c):
		add_child(K.lbl("The treasury is in debt: interest accrues and legitimacy suffers.", 12, K.BAD))
	var tr := K.hbox(6)
	tr.add_child(K.lbl("Tax level", 13, K.INK, "Higher taxes raise revenue but hurt standard of living. Hover each button to preview predicted impact."))
	var cur := _tax_level(c)
	for i in 3:
		var prev_tip: String = str(econ.preview_tax_change(c, i).get("summary", "Set tax level to %s" % TAX_NAMES[i].to_lower()))
		var tb := K.btn(TAX_NAMES[i], prev_tip, func(): act(_set_tax(c, i), "Tax level set to %s." % TAX_NAMES[i].to_lower()))
		tb.toggle_mode = true
		tb.button_pressed = i == cur
		tr.add_child(tb)
	add_child(tr)

	# Historical Trends (26 weeks)
	add_child(K.section("Historical Trends (Last 26 Weeks)"))
	var hg := K.grid(3, 14, 8)
	var charts := [
		["Treasury", "treasury", K.GOLD, true, false],
		["Weekly Balance", "balance", K.GOOD if bal >= 0.0 else K.BAD, true, true],
		["Annual GDP", "gdp", K.GOLD, true, false],
		["Tax & Tariffs / wk", "tax", K.GOOD, true, false],
		["Population", "pop", K.INK, false, false],
		["Radicals %", "radicals", K.BAD if rad > 0.20 else K.WARN, false, false],
	]
	for ch in charts:
		var series: PackedFloat32Array = econ.history_series(c, ch[1])
		var cbox := K.vbox(2)
		var first_v: float = series[0] if series.size() > 0 else 0.0
		var last_v: float = series[series.size() - 1] if series.size() > 0 else 0.0
		var d_v: float = last_v - first_v
		var val_str := ""
		var delta_str := ""
		if ch[1] == "pop":
			val_str = K.num(last_v)
			delta_str = "%+d" % int(round(d_v))
		elif ch[1] == "radicals":
			val_str = K.pct(last_v, 1)
			delta_str = "%+.1f%%" % (d_v * 100.0)
		elif bool(ch[4]):
			val_str = K.signed_money(last_v)
			delta_str = K.signed_money(d_v)
		else:
			val_str = K.money(last_v)
			delta_str = K.signed_money(d_v)
		var ctip := "%s (%d-week history)\nStart: %s  ->  Current: %s  (Change: %s)" % [
			ch[0], series.size(),
			(K.num(first_v) if ch[1] == "pop" else (K.pct(first_v, 1) if ch[1] == "radicals" else K.money(first_v))),
			val_str, delta_str
		]
		cbox.add_child(K.lbl("%s: %s (%s)" % [ch[0], val_str, delta_str], 11, K.INK, ctip))
		var sp := K.spark(series, ch[2], Vector2(150, 30))
		sp.tooltip_text = ctip
		cbox.add_child(sp)
		hg.add_child(cbox)
	add_child(hg)

	add_child(K.section("Research"))
	var rid: String = state.tech.researching(c)
	if rid == "":
		add_child(K.lbl("Nothing is being researched. Open the Technology tab.", 13, K.WARN))
	else:
		var rr := K.hbox(8)
		rr.add_child(K.lbl(state.tech.tech_name(rid), 14, K.INK, state.tech.tech_desc(rid)))
		rr.add_child(K.bar(state.tech.progress(c), K.GOLD, 160.0, 10.0))
		rr.add_child(K.lbl("%.1f / wk" % state.tech.points_per_week(c), 12, K.DIM))
		add_child(rr)

	var wars: Array = state.diplo.wars_of(c)
	if not wars.is_empty():
		add_child(K.section("Wars"))
		war_rows(self)

	add_child(K.section("Recent events"))
	var shown_n := 0
	for i in range(state.events.size() - 1, -1, -1):
		var e: Dictionary = state.events[i]
		if int(e.get("country", -1)) != c and int(e.get("country", -1)) != -1:
			continue
		var l := K.lbl("%s  %s" % [_date_of(int(e.get("day", 0))), str(e.get("text", ""))], 12, hud.kind_color(str(e.get("kind", ""))))
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(480, 0)
		add_child(l)
		shown_n += 1
		if shown_n >= 6:
			break
	if shown_n == 0:
		add_child(K.lbl("Nothing of note yet.", 12, K.DIM))


func _kv(g: GridContainer, k: String, v: String, tip := "", col := K.INK) -> void:
	g.add_child(K.lbl(k, 12, K.DIM, tip))
	g.add_child(K.lbl(v, 13, col, tip))


func _set_tax(c: int, level: int) -> Variant:
	if state.politics.has_method("set_tax_level"):
		return state.politics.set_tax_level(c, level)
	return state.econ.set_tax_level(c, level)


func _tax_level(c: int) -> int:
	if state.econ.has_method("tax_level"):
		return int(state.econ.tax_level(c))
	return ["low", "medium", "high"].find(state.politics.law(c, "taxation"))


func _date_of(day: int) -> String:
	return hud.short_date(day)
