extends "res://src/ui/panels/panel_base.gd"
## Market: national goods table (price, supply, demand, trend). Row tooltip =
## econ.price_explanation(c, g). Price history is recorded weekly by the HUD.


func rebuild() -> void:
	var c := player
	var econ = state.econ
	add_child(K.lbl("National market of %s" % world.c_short[c], 16, K.GOLD))
	add_child(K.lbl("Hover a row for the reason behind the price. Trade partners share their surplus.", 11, K.DIM))
	var g := K.grid(7, 12, 4)
	for h in ["Good", "Price", "Trend", "26 wk", "Supply", "Demand", "Balance"]:
		g.add_child(K.lbl(h, 12, K.GOLD))
	for gi in econ.goods_count():
		var tip: String = econ.price_explanation(c, gi)
		var price: float = econ.price(c, gi)
		var sup: float = econ.supply(c, gi)
		var dem: float = econ.demand(c, gi)
		var hist: PackedFloat32Array = hud.price_history(gi)
		var chg := 0.0
		if hist.size() >= 2:
			var ref: float = hist[maxi(0, hist.size() - 5)]
			chg = (price - ref) / maxf(ref, 0.001)
		g.add_child(K.lbl(econ.good_name(gi), 13, K.INK, tip))
		g.add_child(K.lbl("£%.2f" % price, 13, K.INK, tip))
		var tcol := K.GOOD if chg > 0.01 else (K.BAD if chg < -0.01 else K.DIM)
		g.add_child(K.lbl("%+.0f%%" % (chg * 100.0), 12, tcol, tip + "\n(change over the last 4 weeks)"))
		g.add_child(K.spark(hist, tcol))
		g.add_child(K.lbl(K.num(sup), 12, K.INK, tip))
		g.add_child(K.lbl(K.num(dem), 12, K.INK, tip))
		var bal := sup - dem
		var bt := "surplus" if bal > 0.0 else "shortage"
		g.add_child(K.lbl("%s %s" % [K.num(absf(bal)), bt if absf(bal) > 0.5 else "-"], 12, K.GOOD if bal >= 0.0 else K.BAD, tip))
	add_child(g)
