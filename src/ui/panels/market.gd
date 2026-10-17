extends "res://src/ui/panels/panel_base.gd"
## Market: national goods table (price, supply, demand, trend). Row tooltip =
## econ.price_explanation(c, g). Price history is recorded weekly by the HUD.


var _filter := "all"
var _sort := "price_rel"
var _selected_good := -1


func rebuild() -> void:
	var c := player
	var econ = state.econ
	add_child(K.lbl("National market of %s" % world.c_short[c], 16, K.GOLD))
	var sh_goods: PackedInt32Array = econ.shortage_goods(c)
	if not sh_goods.is_empty():
		var snames := PackedStringArray()
		for g_id in sh_goods:
			snames.append("%s (%d%%)" % [econ.good_name(g_id), int(round(econ.good_fill(c, g_id) * 100.0))])
		add_child(K.lbl("Input Shortages: " + ", ".join(snames), 12, K.BAD,
			"Buildings using these goods suffer output penalties until supply increases or imports arrive."))
	else:
		add_child(K.lbl("All market demands have sufficient supply (no acute shortages).", 11, K.GOOD))

	# Filter & Sort bar (Victoria 3 market style)
	var fbar := K.hbox(4)
	for f in [["all", "All"], ["short", "Shortages"], ["staple", "Staples"], ["industrial", "Industrial"], ["luxury", "Consumer/Mil"]]:
		var b := K.btn(f[1], "Filter goods", func():
			_filter = f[0]
			refresh())
		b.toggle_mode = true
		b.set_pressed_no_signal(_filter == f[0])
		b.add_theme_font_size_override("font_size", 11)
		fbar.add_child(b)
	fbar.add_child(K.spacer())
	for s_opt in [["price_rel", "Sort: % Base"], ["balance", "Sort: Deficit"], ["demand", "Sort: Volume"]]:
		var sb := K.btn(s_opt[1], "Sort market table", func():
			_sort = s_opt[0]
			refresh())
		sb.toggle_mode = true
		sb.set_pressed_no_signal(_sort == s_opt[0])
		sb.add_theme_font_size_override("font_size", 11)
		fbar.add_child(sb)
	add_child(fbar)

	var indices: Array = []
	for gi in econ.goods_count():
		var cat: String = econ.good_category(gi)
		var fl: float = econ.good_fill(c, gi)
		var dem: float = econ.demand(c, gi)
		if _filter == "short" and not (dem > 0.5 and fl < 0.85):
			continue
		elif _filter == "staple" and cat != "staple":
			continue
		elif _filter == "industrial" and cat != "industrial":
			continue
		elif _filter == "luxury" and cat in ["staple", "industrial"]:
			continue
		indices.append(gi)

	indices.sort_custom(func(a, b):
		if _sort == "price_rel":
			var ra: float = econ.price(c, a) / maxf(econ.good_base_price(a), 0.1)
			var rb: float = econ.price(c, b) / maxf(econ.good_base_price(b), 0.1)
			return ra > rb
		elif _sort == "balance":
			var ba: float = econ.supply(c, a) - econ.demand(c, a)
			var bb: float = econ.supply(c, b) - econ.demand(c, b)
			return ba < bb
		return econ.demand(c, a) > econ.demand(c, b))

	var g := K.grid(7, 10, 4)
	for h in ["Good", "Price (vs Base)", "4 wk", "26 wk", "Supply", "Demand", "Balance"]:
		g.add_child(K.lbl(h, 12, K.GOLD))
	for gi: int in indices:
		var tip: String = econ.price_explanation(c, gi)
		var price: float = econ.price(c, gi)
		var base_p: float = econ.good_base_price(gi)
		var rel_pct: float = (price / maxf(base_p, 0.01) - 1.0) * 100.0
		var sup: float = econ.supply(c, gi)
		var dem: float = econ.demand(c, gi)
		var fl: float = econ.good_fill(c, gi)
		var hist: PackedFloat32Array = hud.price_history(gi)
		var chg := 0.0
		if hist.size() >= 2:
			var ref: float = hist[maxi(0, hist.size() - 5)]
			chg = (price - ref) / maxf(ref, 0.001)
		var is_short := dem > 0.5 and fl < 0.80
		var g_btn := K.btn((("! " if is_short else "") + econ.good_name(gi)), tip + "\n(Click to inspect top producers & consumers)", func():
			_selected_good = -1 if _selected_good == gi else gi
			refresh())
		g_btn.flat = true
		g_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		g_btn.add_theme_color_override("font_color", K.BAD if is_short else (K.GOLD if _selected_good == gi else K.INK))
		g.add_child(g_btn)
		var p_col := K.WARN if rel_pct > 25.0 else (K.GOOD if rel_pct < -15.0 else K.INK)
		g.add_child(K.lbl("£%.1f (%+.0f%%)" % [price, rel_pct], 12, p_col, tip))
		var tcol := K.GOOD if chg > 0.01 else (K.BAD if chg < -0.01 else K.DIM)
		g.add_child(K.lbl("%+.0f%%" % (chg * 100.0), 12, tcol, tip + "\n(change over the last 4 weeks)"))
		g.add_child(K.spark(hist, tcol))
		g.add_child(K.lbl(K.num(sup), 12, K.INK, tip))
		g.add_child(K.lbl(K.num(dem), 12, K.INK, tip))
		var bal := sup - dem
		var bt := "surplus" if bal > 0.0 else ("SHORTAGE" if is_short else "deficit")
		g.add_child(K.lbl("%s %s" % [K.num(absf(bal)), bt if absf(bal) > 0.5 else "-"], 12, K.GOOD if bal >= 0.0 else K.BAD, tip))
	add_child(g)

	if _selected_good >= 0 and _selected_good < econ.goods_count():
		var sg := _selected_good
		add_child(K.section("%s — Market Flow Breakdown" % econ.good_name(sg)))
		add_child(K.lbl(econ.price_explanation(c, sg), 12, K.INK))
		var srcs: Array = econ.top_sources(c, sg, 4)
		var snks: Array = econ.top_sinks(c, sg, 4)
		var fg := K.grid(2, 18, 2)
		fg.add_child(K.lbl("Top Supply Sources", 12, K.GOLD))
		fg.add_child(K.lbl("Top Demand Sinks", 12, K.GOLD))
		for k in maxi(srcs.size(), snks.size()):
			var s_txt := "%s: %s" % [srcs[k]["name"], K.num(float(srcs[k]["qty"]))] if k < srcs.size() else "-"
			var d_txt := "%s: %s" % [snks[k]["name"], K.num(float(snks[k]["qty"]))] if k < snks.size() else "-"
			fg.add_child(K.lbl(s_txt, 12, K.GOOD if k < srcs.size() else K.DIM))
			fg.add_child(K.lbl(d_txt, 12, K.WARN if k < snks.size() else K.DIM))
		add_child(fg)
