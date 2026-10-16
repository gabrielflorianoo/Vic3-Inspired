extends "res://src/ui/panels/panel_base.gd"
## Politics: legitimacy, interest groups (clout, approval + breakdown tooltips),
## laws per category with Enact buttons, and the enactment in progress.


func rebuild() -> void:
	var c := player
	var pol = state.politics
	var leg: float = pol.legitimacy(c)
	var head := K.hbox(10)
	head.add_child(K.lbl("Government: %s" % (pol.government_name(c) if pol.government_name(c) != "" else world.c_gov[c]), 16, K.GOLD))
	head.add_child(K.spacer())
	add_child(head)
	var lr := K.hbox(8)
	lr.add_child(K.lbl("Legitimacy %d" % int(leg), 13, K.INK, "Falls with debt, unrest and war exhaustion. Low legitimacy invites revolution."))
	lr.add_child(K.bar(leg / 100.0, K.GOOD if leg >= 50.0 else (K.WARN if leg >= 25.0 else K.BAD), 200.0, 10.0))
	lr.add_child(K.lbl("Unrest %s" % K.pct(pol.unrest(c)), 12, K.BAD if pol.unrest(c) > 0.25 else K.DIM, "Share of the population that is radical."))
	add_child(lr)

	add_child(K.section("Interest groups"))
	var g := K.grid(5, 14, 5)
	for h in ["Group", "Clout", "", "Approval", ""]:
		g.add_child(K.lbl(h, 12, K.GOLD))
	for i in pol.ig_count():
		var ap: float = pol.approval(c, i)
		var tip: String = K.breakdown_text("%s approval of the government" % pol.ig_name(i), pol.approval_breakdown(c, i))
		var in_gov: bool = pol.in_government(c, i)
		var nm := HBoxContainer.new()
		nm.add_theme_constant_override("separation", 6)
		nm.add_child(K.flag(pol.ig_color(i), Vector2(10, 10)))
		nm.add_child(K.lbl(pol.ig_name(i) + ("  *" if in_gov else ""), 13, K.INK, tip + ("\n\n* In government" if in_gov else "")))
		nm.mouse_filter = Control.MOUSE_FILTER_PASS
		g.add_child(nm)
		var clout: float = pol.clout(c, i)
		g.add_child(K.lbl(K.pct(clout, 1), 13, K.INK, "Share of political strength: population x wealth x literacy x suffrage."))
		g.add_child(K.bar(clout, pol.ig_color(i), 70.0, 8.0))
		g.add_child(K.lbl("%+.1f" % ap, 13, K.sign_color(ap), tip))
		g.add_child(K.bar((ap + 10.0) / 20.0, K.GOOD if ap >= 0.0 else K.BAD, 70.0, 8.0, tip))
	add_child(g)
	add_child(K.lbl("* governing groups", 11, K.DIM))

	var st: Dictionary = pol.enact_status(c)
	var active_cat: String = str(st.get("cat", ""))
	if active_cat != "":
		add_child(K.section("Being enacted"))
		var row := K.hbox(8)
		row.add_child(K.lbl("%s: %s" % [pol.category_name(active_cat), pol.option_name(active_cat, str(st.get("opt", "")))], 13, K.WARN))
		row.add_child(K.bar(float(st.get("progress", 0.0)), K.GOLD, 120.0, 10.0))
		row.add_child(K.lbl("support %s  -  %s / month" % [K.pct(float(st.get("support", 0.0))), K.pct(float(st.get("chance", 0.0)))], 12, K.DIM,
			"Each month the reform succeeds with a chance based on the clout of groups that approve of it."))
		row.add_child(K.btn("Cancel", "Abandon this reform", func():
			pol.cancel_enact(c)
			hud.refresh_now()))
		add_child(row)

	add_child(K.section("Laws"))
	for cat: String in pol.categories():
		var cur: String = pol.law(c, cat)
		var box := K.hbox(6)
		var cl := K.lbl(pol.category_name(cat), 13, K.GOLD)
		cl.custom_minimum_size = Vector2(96, 0)
		box.add_child(cl)
		var fl := HFlowContainer.new()
		fl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		fl.add_theme_constant_override("h_separation", 5)
		fl.add_theme_constant_override("v_separation", 4)
		for o in pol.options(cat):
			var opt: String = str(o["id"]) if o is Dictionary else str(o)
			var oname: String = pol.option_name(cat, opt)
			var odesc: String = str(o.get("desc", "")) if o is Dictionary else ""
			if o is Dictionary and o.get("modifiers") is Dictionary and not o["modifiers"].is_empty():
				var parts: PackedStringArray = []
				for mk: String in o["modifiers"]:
					parts.append("%s %+.2f" % [mk.replace("_", " "), float(o["modifiers"][mk])])
				odesc += "\n" + ", ".join(parts)
			if opt == cur:
				var cb := K.btn(oname + " (current)", odesc, Callable(), false)
				cb.disabled = true
				cb.add_theme_color_override("font_disabled_color", K.GOOD)
				fl.add_child(cb)
				continue
			var res: Dictionary = pol.can_enact(c, cat, opt)
			var ok: bool = bool(res.get("ok", false))
			fl.add_child(K.btn(oname, (odesc + "\n\nBegin enacting this law.") if ok else (odesc + "\n\n" + str(res.get("reason", ""))),
				func(): act(pol.start_enact(c, cat, opt), "Began enacting %s." % oname), ok))
		box.add_child(fl)
		add_child(box)
