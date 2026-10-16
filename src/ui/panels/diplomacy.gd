extends "res://src/ui/panels/panel_base.gd"
## Diplomacy: country list (relation + status) on the left; actions against the
## selected country on the right. War targets are the other side's border provinces.

var _war_confirm := -1
var _claim_idx := 0


func rebuild() -> void:
	var c := player
	var dip = state.diplo
	var t: int = hud.diplo_target
	if t < 0 or t == c or state.alive[t] == 0:
		var nb: Array = dip.neighbors_of(c)
		t = int(nb[0]) if not nb.is_empty() else (1 if c != 1 else 0)
		hud.diplo_target = t
	var props: Array = dip.proposals_for(c)
	if not props.is_empty():
		add_child(K.section("Proposals to you"))
		for pr: Dictionary in props:
			var row := K.hbox(8)
			var what: String = {"alliance": "proposes an alliance", "trade": "proposes a trade agreement", "peace": "offers peace (%s)" % str(pr.get("terms", ""))}.get(str(pr.get("kind", "")), "makes a proposal")
			row.add_child(country_chip(int(pr["from"])))
			row.add_child(K.lbl(what, 13, K.WARN))
			row.add_child(K.spacer())
			var pid: int = int(pr["id"])
			row.add_child(K.btn("Accept", "", func(): act(dip.respond_proposal(pid, true), "Accepted.")))
			row.add_child(K.btn("Decline", "", func(): act(dip.respond_proposal(pid, false), "Declined.")))
			add_child(row)
	add_child(K.lbl("Diplomatic points %.1f / %d   (improve relations costs %d, a claim costs %d)" % [dip.diplomatic_points(c), int(dip.DP_CAP), int(dip.DP_IMPROVE), int(dip.DP_CLAIM)], 12, K.DIM,
		"Diplomatic points accumulate over time and are spent on improving relations and fabricating claims."))
	var split := K.hbox(12)
	add_child(split)

	# ---- left: country list
	var left := K.vbox(2)
	left.custom_minimum_size = Vector2(190, 0)
	split.add_child(left)
	left.add_child(K.lbl("Countries", 14, K.GOLD))
	var nbs: Array = dip.neighbors_of(c)
	var ids: Array = []
	for o in world.country_count:
		if o != c and state.alive[o] != 0:
			ids.append(o)
	ids.sort_custom(func(a, b):
		var na: bool = nbs.has(a)
		var nb2: bool = nbs.has(b)
		if na != nb2:
			return na
		return world.c_short[a] < world.c_short[b])
	for o: int in ids:
		var rel: int = dip.relation(c, o)
		var tags := ""
		if dip.at_war(c, o):
			tags += " WAR"
		if dip.is_allied(c, o):
			tags += " ALLY"
		if dip.has_trade_agreement(c, o):
			tags += " TRADE"
		if dip.is_rival(c, o):
			tags += " RIVAL"
		var row := K.hbox(5)
		row.add_child(K.flag(world.c_color[o], Vector2(14, 14)))
		var b := K.btn("%s  %+d%s" % [world.c_short[o], rel, tags], K.breakdown_text("Relations with %s" % world.c_name[o], dip.relation_breakdown(c, o)),
			func():
				hud.diplo_target = o
				_war_confirm = -1
				hud.select_country_on_map(o)
				refresh())
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.toggle_mode = true
		b.button_pressed = o == t
		b.add_theme_font_size_override("font_size", 12)
		b.add_theme_color_override("font_color", K.sign_color(float(rel)) if o != t else K.GOLD)
		row.add_child(b)
		left.add_child(row)

	# ---- right: detail + actions
	var right := K.vbox(6)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	var head := K.hbox(8)
	head.add_child(K.flag(world.c_color[t], Vector2(34, 24)))
	var hv := K.vbox(0)
	hv.add_child(K.lbl(world.c_name[t], 16, K.GOLD))
	hv.add_child(K.lbl("%s  -  %s" % [hud.RANKS.get(world.c_rank[t], ""), world.c_gov[t]], 11, K.DIM))
	head.add_child(hv)
	right.add_child(head)
	var rel_t: int = dip.relation(c, t)
	var rtip: String = K.breakdown_text("Relations with %s" % world.c_short[t], dip.relation_breakdown(c, t))
	var rr := K.hbox(8)
	rr.add_child(K.lbl("Relation %+d" % rel_t, 14, K.sign_color(float(rel_t)), rtip))
	rr.add_child(K.bar((rel_t + 100.0) / 200.0, K.GOOD if rel_t >= 0 else K.BAD, 110.0, 10.0, rtip))
	right.add_child(rr)
	for e in dip.relation_breakdown(c, t):
		if e is Dictionary:
			var v: float = float(e.get("value", 0.0))
			right.add_child(K.lbl("%+d  %s" % [int(v), str(e.get("reason", ""))], 11, K.sign_color(v)))
	var st := K.grid(2, 12, 2)
	for kv in [["Provinces", str(world.c_provinces[t].size())], ["Population", K.num(state.pops.country_pop(t))],
			["GDP", K.money(state.econ.gdp(t))], ["Army power", "%.0f" % state.military.power(t)]]:
		st.add_child(K.lbl(kv[0], 12, K.DIM))
		st.add_child(K.lbl(kv[1], 12))
	right.add_child(st)

	right.add_child(K.section("Actions"))
	var at_war: bool = dip.at_war(c, t)
	var ab := K.vbox(4)
	right.add_child(ab)
	ab.add_child(_wide(K.btn("Improve relations", "Spend %d diplomatic points to raise relations over several months" % int(dip.DP_IMPROVE), func(): act(dip.improve_relations(c, t), "Relations will improve."))))
	if dip.is_allied(c, t):
		ab.add_child(_wide(K.btn("Break alliance", "End the alliance", func(): act(dip.break_alliance(c, t), "Alliance ended."))))
	else:
		var ca: Dictionary = dip.can_ally(c, t)
		ab.add_child(_wide(K.btn("Propose alliance", "Allies are called into each other's wars" if ca["ok"] else str(ca["reason"]),
			func(): act(dip.propose_alliance(c, t), "%s accepted the alliance." % world.c_short[t]), bool(ca["ok"]))))
	if dip.has_trade_agreement(c, t):
		ab.add_child(_wide(K.btn("Cancel trade agreement", "Markets stop sharing surplus", func(): act(dip.cancel_trade_agreement(c, t), "Trade agreement cancelled."))))
	else:
		var ct: Dictionary = dip.can_trade(c, t)
		ab.add_child(_wide(K.btn("Propose trade agreement", "Partner markets share surplus goods" if ct["ok"] else str(ct["reason"]),
			func(): act(dip.propose_trade_agreement(c, t), "Trade agreement signed."), bool(ct["ok"]))))
	if dip.is_rival(c, t):
		ab.add_child(_wide(K.btn("Drop rivalry", "End the rivalry", func(): act(dip.drop_rival(c, t), "Rivalry ended."))))
	else:
		ab.add_child(_wide(K.btn("Declare rival", "Rivals may be attacked without a claim, but cannot ally or trade", func(): act(dip.declare_rival(c, t), "%s is now your rival." % world.c_short[t]))))
	var truce: int = dip.truce_days_left(c, t)
	if truce > 0:
		ab.add_child(K.lbl("Truce: %d days left" % truce, 11, K.WARN))

	# Claims: fabricate on a border province of the target.
	var border := _border_provinces(c, t)
	var cr := K.hbox(4)
	var opt := OptionButton.new()
	opt.focus_mode = Control.FOCUS_NONE
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for p: int in border:
		opt.add_item(world.p_name[p] + (" (claimed)" if dip.has_claim(c, p) else ""))
	_claim_idx = clampi(_claim_idx, 0, maxi(border.size() - 1, 0))
	if not border.is_empty():
		opt.selected = _claim_idx
	opt.item_selected.connect(func(i): _claim_idx = i)
	opt.disabled = border.is_empty()
	cr.add_child(opt)
	cr.add_child(K.btn("Fabricate claim", "Costs %d diplomatic points; gives a casus belli on the chosen province" % int(dip.DP_CLAIM), _on_claim_pressed.bind(border), not border.is_empty()))
	ab.add_child(cr)

	if not at_war:
		var goals := PackedInt32Array()
		for p: int in border:
			if dip.has_claim(c, p) and goals.size() < 4:
				goals.append(p)
		if goals.is_empty() and dip.is_rival(c, t):
			for p: int in border:
				if goals.size() < 4:
					goals.append(p)
		var names: PackedStringArray = []
		for p in goals:
			names.append(world.p_name[p])
		var cw: Dictionary = dip.can_declare_war(c, t, goals) if not goals.is_empty() else {"ok": false, "reason": "War needs a claim on a border province (or a rivalry). Fabricate a claim first."}
		var armed := _war_confirm == t
		var tip: String = ("War goals: " + ", ".join(names)) if cw["ok"] else str(cw["reason"])
		var wb := K.btn("CLICK AGAIN TO DECLARE WAR" if armed else "Declare war", tip, _on_war_pressed.bind(t, goals), bool(cw["ok"]))
		wb.add_theme_color_override("font_color", K.BAD)
		wb.add_theme_color_override("font_hover_color", Color(1, 0.6, 0.5))
		ab.add_child(_wide(wb))
	else:
		ab.add_child(K.lbl("You are at war with %s." % world.c_short[t], 12, K.BAD))

	add_child(K.section("Your wars"))
	war_rows(self)


func _on_claim_pressed(border: Array) -> void:
	if not border.is_empty():
		act(state.diplo.fabricate_claim(player, border[clampi(_claim_idx, 0, border.size() - 1)]), "Claim fabricated.")


func _on_war_pressed(t: int, goals: PackedInt32Array) -> void:
	if _war_confirm == t:
		_war_confirm = -1
		act(state.diplo.declare_war(player, t, goals), "War declared on %s!" % world.c_name[t])
	else:
		_war_confirm = t
		refresh()


func _wide(b: Button) -> Button:
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return b


## Provinces of country t that touch a province of the player.
func _border_provinces(c: int, t: int) -> Array:
	var out: Array = []
	for p in world.c_provinces[t]:
		for q in world.p_neighbors[p]:
			if world.p_owner[q] == c:
				out.append(p)
				break
	return out
