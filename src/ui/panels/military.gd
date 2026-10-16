extends "res://src/ui/panels/panel_base.gd"
## Military: army statistics, recruit / disband, and the wars the nation is in.


func rebuild() -> void:
	var c := player
	var mil = state.military
	var a: Dictionary = mil.army(c)
	add_child(K.lbl("Armed forces of %s" % world.c_short[c], 16, K.GOLD))
	var g := K.grid(4, 18, 4)
	var bn: int = int(a.get("battalions", 0))
	var maxb: int = mil.max_battalions(c)
	var ptip: String = K.breakdown_text("Army power", mil.power_breakdown(c))
	g.add_child(K.lbl("Battalions", 12, K.DIM))
	g.add_child(K.lbl("%d / %d" % [bn, maxb], 13, K.INK, "Current battalions versus the maximum your manpower and laws support."))
	g.add_child(K.lbl("Manpower", 12, K.DIM))
	g.add_child(K.lbl(K.num(float(a.get("manpower", 0))), 13, K.INK, "Available recruits from soldier cohorts. Conscription laws widen the pool."))
	g.add_child(K.lbl("Equipment", 12, K.DIM))
	var eq: float = float(a.get("equipment", 1.0))
	g.add_child(K.lbl(K.pct(eq), 13, K.GOOD if eq >= 0.8 else (K.WARN if eq >= 0.5 else K.BAD),
		"Share of battalion equipment that is supplied. Arms factories produce the goods; shortages weaken the army."))
	g.add_child(K.lbl("Morale", 12, K.DIM))
	g.add_child(K.lbl(K.pct(float(a.get("morale", 1.0))), 13))
	g.add_child(K.lbl("Upkeep", 12, K.DIM))
	g.add_child(K.lbl(K.money(float(a.get("upkeep", 0.0))) + " / wk", 13))
	g.add_child(K.lbl("Power", 12, K.DIM, ptip))
	g.add_child(K.lbl("%.0f" % float(a.get("power", 0.0)), 13, K.GOLD, ptip))
	add_child(g)
	var eqtip := "Arms supply versus military demand: %s" % K.pct(state.econ.equipment_fill(c))
	add_child(K.lbl(eqtip, 11, K.DIM))

	add_child(K.section("Recruit / disband"))
	var rr := K.hbox(6)
	for n in [1, 5, 10]:
		rr.add_child(K.btn("Recruit %d" % n, "Raise %d battalion(s). Costs money and manpower." % n, func(): act(mil.recruit(c, n), "Recruited %d battalion(s)." % n)))
	add_child(rr)
	var dr := K.hbox(6)
	for n in [1, 5, 10]:
		dr.add_child(K.btn("Disband %d" % n, "Release %d battalion(s) to save upkeep." % n, func(): act(mil.disband(c, n), "Disbanded %d battalion(s)." % n), bn > 0))
	add_child(dr)

	add_child(K.section("Wars"))
	war_rows(self)
	var occ: Array = mil.occupied_by(c)
	if not occ.is_empty():
		var names: PackedStringArray = []
		for p in occ:
			names.append(world.p_name[int(p)])
		var l := K.lbl("Provinces held by foreign forces: " + ", ".join(names), 12, K.BAD)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(480, 0)
		add_child(l)
