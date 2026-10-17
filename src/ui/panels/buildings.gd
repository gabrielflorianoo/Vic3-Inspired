extends "res://src/ui/panels/panel_base.gd"
## Buildings: the selected province's buildings, Build buttons (can_build /
## queue_build), and the national construction queue with cancel.


func rebuild() -> void:
	var c := player
	var econ = state.econ
	var p: int = hud.selected_province

	# Victoria 3 QoL: National Auto-Expand / Best Investment bar
	var best_nat: Dictionary = econ.best_build_candidate(c, -1)
	var top_bar := K.hbox(8)
	if bool(best_nat.get("ok", false)):
		var bp: int = int(best_nat["province"])
		var bt: int = int(best_nat["type"])
		var bpf: float = float(best_nat["profit"])
		var bcost: float = float(best_nat["cost"])
		top_bar.add_child(K.btn("Auto-Invest Best: %s in %s (%s/wk)" % [econ.building_name(bt), world.p_name[bp], K.signed_money(bpf)],
			"Queue the highest-return building across all your provinces (Cost %s)" % K.money(bcost),
			func(): act(econ.queue_build(c, bp, bt), "%s queued in %s." % [econ.building_name(bt), world.p_name[bp]])))
	else:
		top_bar.add_child(K.lbl("No profitable national expansion available (queue full or inputs short).", 12, K.DIM))
	add_child(top_bar)

	if p > 0 and world.p_owner[p] == c:
		var p_head := K.hbox(10)
		p_head.add_child(K.lbl("%s%s" % [world.p_name[p], "  (capital)" if world.p_capital[p] else ""], 16, K.GOLD))
		var rail_lv: int = econ.railway_level(p)
		if rail_lv > 0:
			p_head.add_child(K.lbl("Railways lv %d (+%d%% output)" % [rail_lv, int(round(econ.rail_bonus[p] * 100.0))], 12, K.GOOD))
		add_child(p_head)
		add_child(K.section("Existing buildings"))
		var bl: Array = econ.buildings_in(p)
		var q_counts := {}
		for qe: Dictionary in econ.queues[c]:
			if int(qe["province"]) == p:
				var qt: int = int(qe["type"])
				q_counts[qt] = int(q_counts.get(qt, 0)) + 1
		if bl.is_empty():
			add_child(K.lbl("None yet.", 12, K.DIM))
		else:
			var g := K.grid(5, 12, 3)
			for h in ["Building", "Level", "Workers", "Profit / wk", ""]:
				g.add_child(K.lbl(h, 12, K.GOLD))
			for b: Dictionary in bl:
				var bt_id: int = int(b.get("type", 0))
				var cap_lv: int = int(econ.cap[p * econ.B + bt_id])
				var q_add: int = int(q_counts.get(bt_id, 0))
				var q_str := (" (+%d)" % q_add) if q_add > 0 else ""
				g.add_child(K.lbl(str(b.get("name", "?")), 13))
				g.add_child(K.lbl("%d%s / %d" % [int(b.get("level", 1)), q_str, cap_lv], 13))
				var need: int = int(b.get("workers_needed", 0))
				var emp: int = int(b.get("employed", 0))
				g.add_child(K.lbl("%s / %s" % [K.num(emp), K.num(need)], 13, K.WARN if emp < need else K.INK,
					"Employed workers versus positions. Unfilled jobs reduce output."))
				var pf: float = float(b.get("profit", 0.0))
				g.add_child(K.lbl(K.signed_money(pf), 13, K.sign_color(pf)))
				var can_exp: bool = econ.can_build_fast(c, p, bt_id)
				g.add_child(K.btn("+ Expand", "Queue another level in %s" % world.p_name[p],
					func(): act(econ.queue_build(c, p, bt_id), "%s queued in %s." % [econ.building_name(bt_id), world.p_name[p]]), can_exp))
			add_child(g)
		add_child(K.section("Construct (sorted by expected profit)"))
		var rows: Array = []
		for t in econ.building_count_types():
			var res: Dictionary = econ.can_build(c, p, t)
			var ok: bool = bool(res.get("ok", false))
			var is_state: bool = econ.b_state[t] == 1
			var eff: float = econ.tp[p * econ.B + t] if econ.b_primary[t] == 1 else (1.0 + econ.rail_bonus[p])
			var est_pf: float = 0.0 if is_state else float(econ.level_profit(c, t)) * eff
			rows.append([ok, est_pf, t, str(res.get("reason", ""))])
		rows.sort_custom(func(a, b):
			if a[0] != b[0]:
				return a[0] and not b[0]
			return a[1] > b[1])
		var cg := K.grid(4, 10, 4)
		for h in ["Building (Cost)", "Est. Profit", "Status / Notes", ""]:
			cg.add_child(K.lbl(h, 11, K.GOLD))
		for r in rows:
			var ok: bool = r[0]
			var est_pf: float = r[1]
			var t: int = r[2]
			var reason: String = r[3]
			var cost_val: float = econ.building_cost_at(p, t)
			cg.add_child(K.lbl("%s (%s)" % [econ.building_name(t), K.money(cost_val)], 13, K.INK if ok else K.DIM))
			if econ.b_state[t] == 1:
				cg.add_child(K.lbl("State service", 12, K.DIM))
			else:
				cg.add_child(K.lbl("%s/wk" % K.signed_money(est_pf), 12, K.sign_color(est_pf) if ok else K.DIM))
			var sh_g: int = econ.has_input_shortage(c, t)
			var status_txt := reason
			var status_col := K.DIM
			if ok:
				if sh_g >= 0:
					status_txt = "! %s shortage" % econ.good_name(sh_g)
					status_col = K.WARN
				else:
					var out_g: int = econ.b_out_g[t]
					status_txt = ("Produces %s" % econ.good_name(out_g)) if out_g >= 0 else "Infrastructure / Admin"
			var why := K.lbl(status_txt, 11, status_col)
			why.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			why.custom_minimum_size = Vector2(145, 0)
			cg.add_child(why)
			cg.add_child(K.btn("Build", "Queue construction in %s" % world.p_name[p] if ok else reason,
				func(): act(econ.queue_build(c, p, t), "%s queued in %s." % [econ.building_name(t), world.p_name[p]]), ok))
		add_child(cg)
	else:
		var msg := "Select one of your provinces on the map to see and construct buildings, or use Auto-Invest Best above." if p <= 0 or world.p_owner[p] < 0 else \
			"%s belongs to %s. You can only build in your own provinces." % [world.p_name[p], world.c_short[world.p_owner[p]]]
		var l := K.lbl(msg, 13, K.DIM)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(480, 0)
		add_child(l)

	var slots: int = econ._con_slots(c)
	var q: Array = econ.queue(c)
	add_child(K.section("Construction queue (%d / %d, %d parallel slots)" % [q.size(), econ.QUEUE_MAX, slots]))
	if q.is_empty():
		add_child(K.lbl("Nothing under construction.", 12, K.DIM))
	for i in q.size():
		var e: Dictionary = q[i]
		var row := K.hbox(6)
		var cost: float = float(e.get("cost", 1.0))
		var frac: float = float(e.get("progress", 0.0)) / maxf(cost, 0.0001)
		var prov: int = int(e.get("province", 0))
		var active_tag := " [Active]" if i < slots else ""
		row.add_child(K.lbl("%d. %s - %s%s" % [i + 1, econ.building_name(int(e.get("type", 0))), world.p_name[prov], active_tag], 13, K.INK if i < slots else K.DIM))
		row.add_child(K.spacer())
		row.add_child(K.bar(frac, K.GOLD, 95.0, 10.0, "%d%% complete" % int(frac * 100.0)))
		if i > 0:
			row.add_child(K.btn("Top", "Move project to the top of the construction queue", func(): act(econ.prioritize_build(c, i), "Moved to top of queue.")))
		row.add_child(K.btn("Cancel", "Cancel this project (50% refund of spent progress)", func(): act(econ.cancel_build(c, i), "Construction cancelled.")))
		add_child(row)
