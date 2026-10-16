extends "res://src/ui/panels/panel_base.gd"
## Overview: headline stats, budget (with tax level control), research, wars, recent events.

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
	_kv(g, "Population", K.num(pop))
	_kv(g, "GDP", K.money(econ.gdp(c)), "Gross domestic product (annual value added)")
	_kv(g, "Provinces", str(world.c_provinces[c].size()))
	_kv(g, "Legitimacy", "%d" % int(state.politics.legitimacy(c)), "Government legitimacy 0-100. Falls with debt, unrest and war exhaustion.")
	_kv(g, "Unemployment", K.pct(pops.unemployment(c), 1))
	_kv(g, "Avg. standard of living", "%.1f" % pops.avg_sol(c), pops.sol_explanation(c))
	_kv(g, "Literacy", K.pct(pops.literacy_of(c), 1))
	var rad: float = pops.radical_share(c)
	_kv(g, "Radicals", K.pct(rad, 1), "Share of the population that is radicalised. Above 35% for three months risks revolution.", K.BAD if rad > 0.25 else K.INK)
	var army: Dictionary = state.military.army(c)
	_kv(g, "Army", "%d bn  (power %.0f)" % [int(army.get("battalions", 0)), float(army.get("power", 0.0))])
	_kv(g, "Wars", str(state.diplo.wars_of(c).size()))
	add_child(g)

	add_child(K.section("Budget (per week)"))
	var b: Dictionary = econ.budget(c)
	var bg := K.grid(2, 30, 3)
	var treasury: float = K.treasury(econ, c)
	_kv(bg, "Treasury", K.money(treasury), "", K.BAD if treasury < 0.0 else K.INK)
	for kv in [["Taxes", "tax", 1.0], ["Tariffs", "tariffs", 1.0], ["Administration", "admin", -1.0], ["Military upkeep", "military", -1.0],
			["Construction", "construction", -1.0], ["Debt interest", "interest", -1.0]]:
		var shown: float = absf(float(b.get(kv[1], 0.0))) * kv[2]
		_kv(bg, kv[0], K.signed_money(shown), "", K.sign_color(shown))
	var bal: float = float(b.get("balance", 0.0))
	_kv(bg, "Balance", K.signed_money(bal), "", K.sign_color(bal))
	add_child(bg)
	if econ.in_debt(c):
		add_child(K.lbl("The treasury is in debt: interest accrues and legitimacy suffers.", 12, K.BAD))
	var tr := K.hbox(6)
	tr.add_child(K.lbl("Tax level", 13, K.INK, "Higher taxes raise revenue but hurt standard of living. Allowed levels depend on your laws."))
	var cur := _tax_level(c)
	for i in 3:
		var tb := K.btn(TAX_NAMES[i], "Set tax level to %s" % TAX_NAMES[i].to_lower(), func(): act(_set_tax(c, i), "Tax level set to %s." % TAX_NAMES[i].to_lower()))
		tb.toggle_mode = true
		tb.button_pressed = i == cur
		tr.add_child(tb)
	add_child(tr)

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
