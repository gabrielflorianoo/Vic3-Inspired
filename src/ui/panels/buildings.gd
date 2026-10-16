extends "res://src/ui/panels/panel_base.gd"
## Buildings: the selected province's buildings, Build buttons (can_build /
## queue_build), and the national construction queue with cancel.


func rebuild() -> void:
	var c := player
	var econ = state.econ
	var p: int = hud.selected_province
	if p > 0 and world.p_owner[p] == c:
		add_child(K.lbl("%s%s" % [world.p_name[p], "  (capital)" if world.p_capital[p] else ""], 16, K.GOLD))
		add_child(K.section("Existing buildings"))
		var bl: Array = econ.buildings_in(p)
		if bl.is_empty():
			add_child(K.lbl("None yet.", 12, K.DIM))
		else:
			var g := K.grid(4, 14, 3)
			for h in ["Building", "Level", "Workers", "Profit / wk"]:
				g.add_child(K.lbl(h, 12, K.GOLD))
			for b: Dictionary in bl:
				g.add_child(K.lbl(str(b.get("name", "?")), 13))
				g.add_child(K.lbl(str(b.get("level", 1)), 13))
				var need: int = int(b.get("workers_needed", 0))
				var emp: int = int(b.get("employed", 0))
				g.add_child(K.lbl("%s / %s" % [K.num(emp), K.num(need)], 13, K.WARN if emp < need else K.INK,
					"Employed workers versus positions. Unfilled jobs reduce output."))
				var pf: float = float(b.get("profit", 0.0))
				g.add_child(K.lbl(K.signed_money(pf), 13, K.sign_color(pf)))
			add_child(g)
		add_child(K.section("Construct"))
		var rows: Array = []
		for t in econ.building_count_types():
			var res: Dictionary = econ.can_build(c, p, t)
			rows.append([bool(res.get("ok", false)), t, str(res.get("reason", ""))])
		rows.sort_custom(func(a, b): return a[0] and not b[0])
		var cg := K.grid(3, 12, 4)
		for r in rows:
			var t: int = r[1]
			var ok: bool = r[0]
			var cost_txt := ""
			if econ.has_method("building_cost"):
				cost_txt = "  (%s)" % K.money(econ.building_cost(t))
			cg.add_child(K.lbl(econ.building_name(t) + cost_txt, 13, K.INK if ok else K.DIM))
			var why := Label.new()
			why.text = "" if ok else r[2]
			why.add_theme_font_size_override("font_size", 11)
			why.add_theme_color_override("font_color", K.DIM)
			why.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			why.custom_minimum_size = Vector2(190, 0)
			cg.add_child(why)
			cg.add_child(K.btn("Build", "Queue construction in %s" % world.p_name[p] if ok else r[2],
				func(): act(econ.queue_build(c, p, t), "%s queued in %s." % [econ.building_name(t), world.p_name[p]]), ok))
		add_child(cg)
	else:
		var msg := "Select one of your provinces on the map to see and construct buildings." if p <= 0 or world.p_owner[p] < 0 else \
			"%s belongs to %s. You can only build in your own provinces." % [world.p_name[p], world.c_short[world.p_owner[p]]]
		var l := K.lbl(msg, 13, K.DIM)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(480, 0)
		add_child(l)

	add_child(K.section("Construction queue"))
	var q: Array = econ.queue(c)
	if q.is_empty():
		add_child(K.lbl("Nothing under construction.", 12, K.DIM))
	for i in q.size():
		var e: Dictionary = q[i]
		var row := K.hbox(8)
		var cost: float = float(e.get("cost", 1.0))
		var frac: float = float(e.get("progress", 0.0)) / maxf(cost, 0.0001)
		var prov: int = int(e.get("province", 0))
		row.add_child(K.lbl("%s - %s" % [econ.building_name(int(e.get("type", 0))), world.p_name[prov]], 13))
		row.add_child(K.spacer())
		row.add_child(K.bar(frac, K.GOLD, 110.0, 10.0, "%d%% complete" % int(frac * 100.0)))
		row.add_child(K.btn("Cancel", "Cancel this project", func(): act(econ.cancel_build(c, i), "Construction cancelled.")))
		add_child(row)
