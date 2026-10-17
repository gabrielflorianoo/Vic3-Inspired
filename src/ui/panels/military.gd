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

	add_child(K.section("Posture (battles, arms use, upkeep)"))
	var pbox := K.hbox(6)
	var ptips := ["Defensive: +25% strength defending, -20% attacking, 25% lighter losses, only counter-attacks to retake land, 10% cheaper.",
		"Balanced: no modifiers.",
		"Offensive: +25% strength attacking, -15% defending, 25% heavier losses, always presses the front, 20% costlier arms and upkeep."]
	for i in 3:
		pbox.add_child(K.btn(mil.POST_NAMES[i], ptips[i], func(): act(mil.set_posture(c, i), "Army posture: %s." % mil.POST_NAMES[i]), mil.get_posture(c) != i))
	add_child(pbox)

	add_child(K.section("Recruit / disband (hover for predicted impact)"))
	var rr := K.hbox(6)
	for n in [1, 5, 10]:
		var r_tip: String = mil.preview_recruit_impact(c, n) if mil.has_method("preview_recruit_impact") else ("Raise %d battalion(s)." % n)
		rr.add_child(K.btn("Recruit %d" % n, r_tip, func(): act(mil.recruit(c, n), "Recruited %d battalion(s)." % n)))
	add_child(rr)
	var dr := K.hbox(6)
	for n in [1, 5, 10]:
		var d_tip: String = mil.preview_disband_impact(c, n) if mil.has_method("preview_disband_impact") else ("Release %d battalion(s)." % n)
		dr.add_child(K.btn("Disband %d" % n, d_tip, func(): act(mil.disband(c, n), "Disbanded %d battalion(s)." % n), bn > 0))
	add_child(dr)

	add_child(K.section("Wars"))
	war_rows(self)

	add_child(K.section("Strategic Fronts & Logistics"))
	var fronts: Array = mil.fronts_of_country(c) if mil.has_method("fronts_of_country") else []
	if fronts.is_empty():
		add_child(K.lbl("No active war fronts.", 12, K.DIM))
	else:
		for f: Dictionary in fronts:
			var foe: int = int(f.get("enemy", -1))
			var st_txt: String = str(f.get("status", "Holding line"))
			var sup: float = float(f.get("supply", 1.0))
			var is_foc: bool = bool(f.get("is_focused", false))
			var f_exp: String = str(f.get("explanation", ""))
			var st_col := K.GOOD if st_txt == "Advancing" else (K.BAD if st_txt == "Losing ground" else K.WARN)
			var fhead := K.hbox(8)
			fhead.add_child(country_chip(foe, 13))
			fhead.add_child(K.lbl("Front vs %s  [%s]%s" % [world.c_name[foe], st_txt, "  ★ FOCUSED (+25% Power)" if is_foc else ""], 13, st_col, f_exp))
			fhead.add_child(K.spacer())
			var sup_col := K.GOOD if sup >= 0.80 else (K.WARN if sup >= 0.55 else K.BAD)
			fhead.add_child(K.lbl("Supply %s" % K.pct(sup), 12, sup_col, f_exp))
			add_child(fhead)

			var fstats := K.hbox(12)
			fstats.add_child(K.lbl("Relative Power: %.0f vs %.0f" % [float(f.get("my_power", 0.0)), float(f.get("enemy_power", 0.0))], 12, K.INK, f_exp))
			fstats.add_child(K.lbl("Terrain Def: +%d%%" % int(round(float(f.get("terrain_def", 0.0)) * 100.0)), 12, K.DIM, f_exp))
			fstats.add_child(K.lbl("Occupied: +%d / -%d" % [int(f.get("gained_count", 0)), int(f.get("lost_count", 0))], 12, K.INK, f_exp))
			add_child(fstats)

			var thr: Array = f.get("threatened_provinces", [])
			if not thr.is_empty():
				add_child(_wrapped("Threatened border provinces: " + _names(thr), K.WARN))
			add_child(_wrapped(f_exp, K.DIM))

			var fbtns := K.hbox(8)
			var foc_btn := K.btn("Unfocus Front" if is_foc else "Focus Front (+25% Power)",
				"Concentrate reserves and logistics on the front against %s (+25%% combat strength on this front, -15%% on secondary fronts)." % world.c_short[foe],
				func():
					var target_foe := -1 if is_foc else foe
					act(mil.set_focus_enemy(c, target_foe), ("Focused offensive on %s." % world.c_short[foe]) if target_foe >= 0 else "Front focus cleared."))
			foc_btn.toggle_mode = true
			foc_btn.button_pressed = is_foc
			fbtns.add_child(foc_btn)
			fbtns.add_child(K.btn("Retreat & Regroup",
				"Withdraw from offensive battles against %s, switch to Defensive posture, and recover +6%% morale immediately." % world.c_short[foe],
				func(): act(mil.retreat_front(c, foe), "Forces regrouping on the %s front." % world.c_short[foe])))
			add_child(fbtns)
			add_child(HSeparator.new())

	add_child(K.section("Active Battles"))
	var live_b: Array = mil.battle_report(c)
	if live_b.is_empty():
		add_child(K.lbl("No battles are being fought.", 12, K.DIM))
	for e: Dictionary in live_b:
		var mine_att: bool = int(e["attacker"]) == c
		var brow := K.hbox(8)
		brow.add_child(K.lbl("%s %s" % [world.p_name[int(e["province"])], "(attacking)" if mine_att else "(defending)"], 13, K.GOLD, str(e["text"])))
		brow.add_child(K.spacer())
		brow.add_child(K.bar(float(e["org_a"] if mine_att else e["org_d"]), K.GOOD, 70.0, 8.0, "Your organisation"))
		brow.add_child(K.bar(float(e["org_d"] if mine_att else e["org_a"]), K.BAD, 70.0, 8.0, "Enemy organisation"))
		add_child(brow)
		add_child(_wrapped(str(e["text"]), K.DIM))
	var held: Array = mil.occupied_by(c)
	if not held.is_empty():
		add_child(_wrapped("Provinces you occupy: " + _names(held), K.GOOD))
	var lost: Array = []
	for p in world.c_provinces[c]:
		if mil.controller(p) != c:
			lost.append(p)
	if not lost.is_empty():
		add_child(_wrapped("Provinces occupied by the enemy: " + _names(lost), K.BAD))


func _names(arr: Array) -> String:
	var names: PackedStringArray = []
	for p in arr:
		names.append(world.p_name[int(p)])
	return ", ".join(names)


func _wrapped(t: String, col: Color) -> Label:
	var l := K.lbl(t, 12, col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(480, 0)
	return l
