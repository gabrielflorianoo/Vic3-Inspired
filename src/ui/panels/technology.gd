extends "res://src/ui/panels/panel_base.gd"
## Technology: current research + progress, available techs with Research
## buttons, and the list of known techs.


func rebuild() -> void:
	var c := player
	var tech = state.tech
	add_child(K.lbl("Technology", 16, K.GOLD))
	var rid: String = tech.researching(c)
	var pts: float = tech.points_per_week(c)
	var ptip: String = K.breakdown_text("Research points per week", tech.points_breakdown(c))
	var cur := K.hbox(10)
	if rid == "":
		cur.add_child(K.lbl("Not researching anything - pick a technology below.", 13, K.WARN))
	else:
		cur.add_child(K.lbl("Researching: %s" % tech.tech_name(rid), 14, K.INK, tech.tech_desc(rid)))
		cur.add_child(K.bar(tech.progress(c), K.GOLD, 150.0, 12.0, "%d%%" % int(tech.progress(c) * 100.0)))
		var left: float = tech.tech_cost(rid) * (1.0 - tech.progress(c))
		if pts > 0.0:
			cur.add_child(K.lbl("~%d wk left" % int(ceil(left / pts)), 12, K.DIM))
	add_child(cur)
	add_child(K.lbl("%.1f research points / week" % pts, 12, K.DIM, ptip))

	add_child(K.section("Available"))
	var av: Array = tech.available(c)
	if av.is_empty():
		add_child(K.lbl("No further technologies are available.", 12, K.DIM))
	for id: String in av:
		var box := K.vbox(1)
		var row := K.hbox(8)
		var nm := K.lbl(tech.tech_name(id), 14, K.GOLD if id != rid else K.GOOD, tech.tech_desc(id))
		row.add_child(nm)
		row.add_child(K.lbl("[%s]" % tech.tech_tree(id), 11, K.DIM))
		row.add_child(K.spacer())
		row.add_child(K.lbl("cost %s" % K.num(tech.tech_cost(id)), 12, K.DIM))
		var rb := K.btn("Researching" if id == rid else "Research", "Make this the active research", func(): act(tech.set_research(c, id), "Now researching %s." % tech.tech_name(id)), id != rid)
		row.add_child(rb)
		box.add_child(row)
		var d := K.lbl(tech.tech_desc(id), 11, K.DIM)
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.custom_minimum_size = Vector2(480, 0)
		box.add_child(d)
		add_child(box)

	add_child(K.section("Known"))
	var kn: Array = tech.known(c)
	if kn.is_empty():
		add_child(K.lbl("None yet.", 12, K.DIM))
	var fl := HFlowContainer.new()
	fl.add_theme_constant_override("h_separation", 6)
	fl.add_theme_constant_override("v_separation", 4)
	for id: String in kn:
		var l := K.lbl(tech.tech_name(id), 12, K.GOOD, tech.tech_desc(id))
		fl.add_child(l)
	add_child(fl)
