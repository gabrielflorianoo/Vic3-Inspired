extends "res://src/ui/panels/panel_base.gd"
## Buildings: the selected province's buildings, Build buttons (can_build /
## queue_build), Private Initiative / Privatization / Allied Foreign Investment,
## and the national state & private construction queues.


func rebuild() -> void:
	var c := player
	var econ = state.econ
	var p: int = hud.selected_province

	# Victoria 3 QoL: National Auto-Expand & Private Initiative bar
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
	top_bar.add_child(K.spacer())
	var ap_on: bool = econ.is_auto_privatize(c)
	var ap_btn := K.btn("Auto-Privatize: %s" % ("ON" if ap_on else "OFF"),
		"When ON, domestic and allied capitalists automatically buy state-owned building levels and deposit the proceeds into your Treasury.",
		func():
			econ.set_auto_privatize(c, not ap_on)
			hud.toast("Auto-Privatization %s." % ("enabled" if not ap_on else "disabled"), "ok")
			hud.refresh_now())
	ap_btn.toggle_mode = true
	ap_btn.button_pressed = ap_on
	top_bar.add_child(ap_btn)
	add_child(top_bar)

	# Private Investment Pool (visible only under Free Trade, read-only)
	var priv_row := K.hbox(10)
	if econ.can_see_investment_pool(c):
		var pool_val: float = econ.investment_pool(c)
		var inf_val: float = econ.investment_inflow(c)
		var out_val: float = econ.investment_outflow(c)
		priv_row.add_child(K.lbl("Private Investment Pool: %s   (Inflow +%s/wk  |  Spent -%s/wk)   [Read-Only]" % [K.money(pool_val), K.money(inf_val), K.money(out_val)],
			12, K.GOLD,
			"Capitalists and aristocrats reinvest their dividends here and autonomously expand profitable sectors or invest in allied nations. You can inspect this balance under Free Trade, but cannot spend it directly."))
	else:
		priv_row.add_child(K.lbl("Private Investment Pool: Hidden (enact Free Trade in Politics to inspect private capital balance)",
			12, K.DIM,
			"Private capitalists still accumulate dividends and build autonomously, but their exact pool balance is only visible under Free Trade."))
	add_child(priv_row)

	var is_ally_prov: bool = p > 0 and world.p_owner[p] >= 0 and world.p_owner[p] != c and state.diplo != null and state.diplo.is_allied(c, world.p_owner[p])

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
		for pqe: Dictionary in econ.private_queue(c):
			if int(pqe["province"]) == p:
				var pqt: int = int(pqe["type"])
				q_counts[pqt] = int(q_counts.get(pqt, 0)) + 1
		if bl.is_empty():
			add_child(K.lbl("None yet.", 12, K.DIM))
		else:
			var g := K.grid(6, 10, 3)
			for h in ["Building", "Level (Ownership)", "Workers", "Profit / wk", "", ""]:
				g.add_child(K.lbl(h, 12, K.GOLD))
			for b: Dictionary in bl:
				var bt_id: int = int(b.get("type", 0))
				var cap_lv: int = int(econ.cap[p * econ.B + bt_id])
				var q_add: int = int(q_counts.get(bt_id, 0))
				var q_str := (" (+%d)" % q_add) if q_add > 0 else ""
				var plv: int = int(b.get("private_level", 0))
				var flv: int = int(b.get("foreign_level", 0))
				var fown: int = int(b.get("foreign_owner", -1))
				var own_tag := ""
				if econ.b_state[bt_id] == 1:
					own_tag = " [State]"
				elif plv > 0:
					own_tag = " (%dP%s)" % [plv, (", %d %s" % [flv, world.c_short[fown]]) if (flv > 0 and fown >= 0) else ""]
				g.add_child(K.lbl(str(b.get("name", "?")), 13))
				g.add_child(K.lbl("%d%s / %d%s" % [int(b.get("level", 1)), q_str, cap_lv, own_tag], 12, K.INK,
					"Total levels / Max capacity. P = Privately owned levels (by domestic or allied capitalists)."))
				var need: int = int(b.get("workers_needed", 0))
				var emp: int = int(b.get("employed", 0))
				g.add_child(K.lbl("%s / %s" % [K.num(emp), K.num(need)], 12, K.WARN if emp < need else K.INK,
					"Employed workers versus positions. Unfilled jobs reduce output."))
				var pf: float = float(b.get("profit", 0.0))
				g.add_child(K.lbl(K.signed_money(pf), 12, K.sign_color(pf), econ.building_diagnosis(p, bt_id)))
				var can_exp: bool = econ.can_build_fast(c, p, bt_id)
				g.add_child(K.btn("+ Expand", "Queue another state level in %s" % world.p_name[p],
					func(): act(econ.queue_build(c, p, bt_id), "%s queued in %s." % [econ.building_name(bt_id), world.p_name[p]]), can_exp))
				var pv_chk: Dictionary = econ.can_privatize(c, p, bt_id)
				var pv_ok: bool = bool(pv_chk.get("ok", false))
				var pv_price: float = econ.privatize_price(p, bt_id)
				g.add_child(K.btn("Privatize (+%s)" % K.money(pv_price),
					("Sell 1 state level to private capitalists for %s" % K.money(pv_price)) if pv_ok else str(pv_chk.get("reason", "")),
					func(): act(econ.privatize_building(c, p, bt_id), "Sold 1 level of %s to private investors." % econ.building_name(bt_id)),
					pv_ok))
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
	elif is_ally_prov:
		var ally_c: int = world.p_owner[p]
		add_child(K.section("Foreign Investment in %s (%s - Ally)" % [world.p_name[p], world.c_short[ally_c]]))
		add_child(K.lbl("Because you are allied with %s, your private sector can finance buildings here and remit dividends back to your Investment Pool." % world.c_name[ally_c], 12, K.DIM))
		var fg := K.grid(4, 10, 4)
		for h in ["Building (Cost)", "Est. Profit in Ally", "Status", ""]:
			fg.add_child(K.lbl(h, 11, K.GOLD))
		for t in econ.building_count_types():
			if econ.b_state[t] == 1:
				continue
			var fchk: Dictionary = econ.can_invest_foreign(c, p, t)
			var fok: bool = bool(fchk.get("ok", false))
			var feff: float = econ.tp[p * econ.B + t] if econ.b_primary[t] == 1 else (1.0 + econ.rail_bonus[p])
			var fpf: float = float(econ.level_profit(ally_c, t)) * feff
			var fcost: float = econ.building_cost_at(p, t)
			fg.add_child(K.lbl("%s (%s)" % [econ.building_name(t), K.money(fcost)], 12, K.INK if fok else K.DIM))
			fg.add_child(K.lbl("%s/wk" % K.signed_money(fpf), 12, K.sign_color(fpf) if fok else K.DIM))
			fg.add_child(K.lbl("Ready for private capital" if fok else str(fchk.get("reason", "")), 11, K.GOOD if fok else K.DIM))
			fg.add_child(K.btn("Foreign Invest", "Fund this building in %s from your Private Investment Pool" % world.p_name[p] if fok else str(fchk.get("reason", "")),
				func(): act(econ.invest_in_ally(c, p, t), "Private foreign investment queued in %s (%s)." % [world.p_name[p], world.c_short[ally_c]]), fok))
		add_child(fg)
	else:
		var msg := "Select one of your provinces (or an Allied province for Foreign Investment) on the map, or use Auto-Invest Best above." if p <= 0 or world.p_owner[p] < 0 else \
			"%s belongs to %s. Form an Alliance with %s to unlock Foreign Investment here." % [world.p_name[p], world.c_short[world.p_owner[p]], world.c_short[world.p_owner[p]]]
		var l := K.lbl(msg, 13, K.DIM)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(480, 0)
		add_child(l)

	var slots: int = econ._con_slots(c)
	var q: Array = econ.queue(c)
	add_child(K.section("State construction queue (%d / %d, %d parallel slots)" % [q.size(), econ.QUEUE_MAX, slots]))
	if q.is_empty():
		add_child(K.lbl("Nothing under state construction.", 12, K.DIM))
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

	var pq: Array = econ.private_queue(c)
	add_child(K.section("Private sector queue (%d autonomous projects)" % pq.size()))
	if pq.is_empty():
		add_child(K.lbl("Capitalists are accumulating funds for their next private expansion.", 12, K.DIM))
	for i in pq.size():
		var pe: Dictionary = pq[i]
		var prow := K.hbox(6)
		var pcost: float = float(pe.get("cost", 1.0))
		var pfrac: float = float(pe.get("progress", 0.0)) / maxf(pcost, 0.0001)
		var pprov: int = int(pe.get("province", 0))
		var pinv: int = int(pe.get("investor", c))
		var who_tag := "[Private]" if pinv == c else ("[Foreign: %s]" % world.c_short[pinv])
		prow.add_child(K.lbl("%d. %s %s - %s" % [i + 1, who_tag, econ.building_name(int(pe.get("type", 0))), world.p_name[pprov]], 13, K.GOLD if i == 0 else K.DIM))
		prow.add_child(K.spacer())
		prow.add_child(K.bar(pfrac, K.GOOD, 95.0, 10.0, "%d%% complete (Funded by Private Pool)" % int(pfrac * 100.0)))
		prow.add_child(K.lbl("Autonomous", 11, K.DIM))
		add_child(prow)
