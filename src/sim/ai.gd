extends RefCounted
## AI: monthly decisions for every living non-player country, in layers:
##   strategic (yearly goal) -> economic (taxes, construction, research) -> political (laws)
##   -> diplomatic (pacts, claims, war) -> military (recruitment) ; plus weekly war reactions (peace talks).
## Only neighbour lists are consulted, never the whole world per country.

const GOAL_NAMES := ["industrialize", "expand", "stabilize"]
const WAR_POWER_RATIO := 1.4
const WAR_CHANCE_MONTHLY := 0.045   # per eligible expanding country and month

var s
var _n := 0
var goals: Array = []                  # per country goal id
var months := 0
var week_counter := 0
var wars_declared := 0
var _goods: Array = []                 # goods.json entries (id, base_price...)
var _good_idx: Dictionary = {}
var _buildings: Array = []
var _econ_loaded := false
var last_actions: Array = []           # [{day, country, text}] last 40 AI decisions (for debugging / UI)


func setup(state) -> void:
	s = state
	_n = s.world.country_count
	goals = []
	for c in _n:
		goals.append("industrialize")
	months = 0
	week_counter = 0
	wars_declared = 0
	last_actions = []


func to_dict() -> Dictionary:
	return {"goals": goals.duplicate(), "months": months, "wc": week_counter, "wd": wars_declared}


func from_dict(d: Dictionary) -> void:
	_n = s.world.country_count
	goals = []
	var g: Array = d.get("goals", [])
	for c in _n:
		goals.append(String(g[c]) if c < g.size() else "industrialize")
	months = int(d.get("months", 0))
	week_counter = int(d.get("wc", 0))
	wars_declared = int(d.get("wd", 0))
	last_actions = []


func goal(c: int) -> String:
	return goals[c]


func _note(c: int, text: String) -> void:
	last_actions.append({"day": s.day, "country": c, "text": text})
	if last_actions.size() > 40:
		last_actions.pop_front()


# --------------------------------------------------------------------------- econ data (optional)
func _load_econ_data() -> void:
	if _econ_loaded:
		return
	_econ_loaded = true
	var f := FileAccess.open("res://data/scenario/goods.json", FileAccess.READ)
	if f != null:
		var j = JSON.parse_string(f.get_as_text())
		_goods = j if j is Array else (j.get("goods", []) if j is Dictionary else [])
		for i in _goods.size():
			_good_idx[String(_goods[i].get("id", ""))] = i
	f = FileAccess.open("res://data/scenario/buildings.json", FileAccess.READ)
	if f != null:
		var j = JSON.parse_string(f.get_as_text())
		_buildings = j if j is Array else (j.get("buildings", []) if j is Dictionary else [])


# --------------------------------------------------------------------------- monthly tick
func tick_month() -> void:
	months += 1
	_load_econ_data()
	for c in _n:
		if not s.alive[c] or s.is_player(c):
			continue
		if goals[c] == "" or (months + c) % 12 == 0:
			_strategic(c)
		_economic(c)
		_political(c)
		_diplomatic(c)
		_military(c)


func _legit(c: int) -> float:
	return float(s.politics.legitimacy(c)) if s.politics != null else 50.0


func _radical(c: int) -> float:
	return float(s.pops.radical_share(c)) if s.pops != null and s.pops.has_method("radical_share") else 0.0


func _debt(c: int) -> bool:
	return s.econ != null and s.econ.has_method("in_debt") and bool(s.econ.in_debt(c))


func _power(c: int) -> float:
	return float(s.military.power(c)) if s.military != null else 1.0


# --------------------------------------------------------------------------- strategic
func _strategic(c: int) -> void:
	var old: String = goals[c]
	var g := "industrialize"
	if _legit(c) < 40.0 or _radical(c) > 0.25 or _debt(c):
		g = "stabilize"
	else:
		var best := 0.0
		for n: int in s.diplo.neighbors_of(c):
			if s.diplo.is_allied(c, n) or s.diplo.claims_of(c).is_empty():
				continue
			var r := _power(c) / maxf(0.5, _power(n))
			best = maxf(best, r)
		var rank: String = s.world.c_rank[c]
		var wants_war: bool = best > WAR_POWER_RATIO or not s.diplo.rivals(c).is_empty()
		if wants_war and (rank != "minor" or best > 2.0):
			g = "expand"
	goals[c] = g
	if g != old:
		_note(c, "%s adopts the goal: %s" % [s.world.c_short[c], g])


# --------------------------------------------------------------------------- economic
func _economic(c: int) -> void:
	_taxes(c)
	_construction(c)
	_research(c)


func _taxes(c: int) -> void:
	if s.politics == null or s.econ == null or not s.econ.has_method("budget"):
		return
	var b: Dictionary = s.econ.budget(c)
	var bal := float(b.get("balance", 0.0))
	var lvl: int = s.politics.tax_level(c)
	if (bal < 0.0 and (_debt(c) or _treasury(c) < 0.0)) and lvl < 2 and _legit(c) > 30.0:
		var r: Dictionary = s.politics.set_tax_level(c, lvl + 1)
		if r["ok"]:
			_note(c, "%s raises taxes" % s.world.c_short[c])
	elif bal > 0.0 and not _debt(c) and lvl > 0 and (_legit(c) < 40.0 or _radical(c) > 0.3) and _treasury(c) > 0.0:
		var r2: Dictionary = s.politics.set_tax_level(c, lvl - 1)
		if r2["ok"]:
			_note(c, "%s lowers taxes to calm unrest" % s.world.c_short[c])


func _treasury(c: int) -> float:
	return float(s.econ.treasury_of(c))


func _good_price(c: int, gid: String) -> float:
	var gi: int = _good_idx.get(gid, -1)
	if gi < 0:
		return 0.0
	return float(s.econ.price(c, gi))


func _building_score(c: int, t: int) -> float:
	var econ = s.econ
	var cat: String = econ.b_cat[t]
	if cat == "infrastructure" or cat == "government":
		return 6.0   # state buildings have no market profit; build them at a steady, modest priority
	var ig: PackedInt32Array = econ.b_in_g[t]
	var iq: PackedFloat64Array = econ.b_in_q[t]
	var cg: int = c * econ.G
	for j in ig.size():
		if econ.ms[cg + ig[j]] < iq[j] * 0.5:
			return -1.0
	return float(econ.level_profit(c, t)) / maxf(1.0, econ.b_cost[t]) * 100.0


func _construction(c: int) -> void:
	var econ = s.econ
	if econ == null or econ.queue_size(c) >= 2:
		return
	var provs: PackedInt32Array = s.world.c_provinces[c]
	if provs.is_empty():
		return
	var treasury := _treasury(c)
	if _debt(c) or treasury < 0.0:
		return
	# Rank building types by profit per money spent (market prices), then find a province that accepts one.
	var ranked: Array = []
	var nb: int = econ.B
	for t in nb:
		if econ.b_cost[t] * 1.2 > treasury:
			continue
		if s.tech != null and econ.b_tech[t] != "" and not s.tech.building_unlocked(c, econ.b_ids[t]):
			continue
		var sc := _building_score(c, t)
		if sc <= 0.0:
			continue
		if goals[c] == "industrialize" and econ.b_cat[t] == "secondary":
			sc *= 1.25
		ranked.append([sc, t])
	ranked.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	for k in mini(4, ranked.size()):
		var t2: int = ranked[k][1]
		for _try in mini(6, provs.size()):
			var p: int = provs[s.rng.randi() % provs.size()]
			if econ.can_build_fast(c, p, t2) and econ.queue_build(c, p, t2):
				_note(c, "%s builds %s in %s" % [s.world.c_short[c], econ.b_names[t2], s.world.p_name[p]])
				return


func _research(c: int) -> void:
	if s.tech == null or s.tech.researching(c) != "":
		return
	var av: Array = s.tech.available(c)
	if av.is_empty():
		return
	var pref := {"production": 1.0, "society": 0.6, "military": 0.4}
	match goals[c]:
		"expand": pref = {"production": 0.6, "society": 0.3, "military": 1.0}
		"stabilize": pref = {"production": 0.6, "society": 1.0, "military": 0.2}
	var best := ""
	var bv := -1e9
	for id in av:
		var v: float = float(pref.get(s.tech.tech_tree(id), 0.5)) * 1000.0 - s.tech.tech_cost(id)
		if v > bv:
			bv = v; best = id
	if best != "":
		s.tech.set_research(c, best)


# --------------------------------------------------------------------------- political
func _political(c: int) -> void:
	if s.politics == null or not s.politics.enact_status(c).is_empty():
		return
	if _legit(c) < 35.0 or s.rng.randf() > 0.25:
		return
	var calming: bool = goals[c] == "stabilize"
	var best_gain := 1.0
	var best_cat := ""
	var best_opt := ""
	for cat in s.politics.categories():
		if cat == "taxation":
			continue
		var cur: String = s.politics.law(c, cat)
		for o: Dictionary in s.politics.options(cat):
			var opt: String = o["id"]
			if opt == cur:
				continue
			var gain := 0.0
			for i in s.politics.ig_count():
				var w: float = float(s.politics.clout(c, i)) * (1.0 if calming else (2.0 if s.politics.in_government(c, i) else 0.3))
				var pr: Dictionary = s.politics.ig_prefs(i)
				gain += w * (float(pr.get(opt, 0.0)) - float(pr.get(cur, 0.0)))
			gain *= 3.0
			if gain > best_gain and s.politics.can_enact(c, cat, opt)["ok"]:
				best_gain = gain; best_cat = cat; best_opt = opt
	if best_cat != "":
		var r: Dictionary = s.politics.start_enact(c, best_cat, best_opt)
		if r["ok"]:
			_note(c, "%s starts reform: %s" % [s.world.c_short[c], s.politics.option_name(best_cat, best_opt)])


# --------------------------------------------------------------------------- diplomatic
func _diplomatic(c: int) -> void:
	var d = s.diplo
	var nb: Array = d.neighbors_of(c)
	# Better ties with lukewarm neighbours.
	if d.diplomatic_points(c) >= 6.0 and not nb.is_empty() and s.rng.randf() < 0.3:
		var n: int = nb[s.rng.randi() % nb.size()]
		var rel: int = d.relation(c, n)
		if rel > -30 and rel < 25 and not d.is_rival(c, n) and not d.at_war(c, n) and not s.is_player(n):
			d.improve_relations(c, n)
	# Trade agreements
	if d.trade_partners(c).size() < 3 and s.rng.randf() < 0.25 and not nb.is_empty():
		var n2: int = nb[s.rng.randi() % nb.size()]
		if d.relation(c, n2) >= 0:
			var r: Dictionary = d.propose_trade_agreement(c, n2)
			if r["ok"] and not s.is_player(n2):
				_note(c, "%s signs trade with %s" % [s.world.c_short[c], s.world.c_short[n2]])
	# Alliances: against a common rival, or between close friends
	if d.allies(c).size() < 2 and s.rng.randf() < 0.12:
		var cand: Array = nb.duplicate()
		for r2 in d.rivals(c):
			for n3 in d.neighbors_of(r2):
				if n3 != c and not cand.has(n3):
					cand.append(n3)
		if not cand.is_empty():
			var n4: int = cand[s.rng.randi() % cand.size()]
			var common := false
			for r3 in d.rivals(c):
				if d.is_rival(n4, r3) or d.at_war(n4, r3):
					common = true
			if (common or d.relation(c, n4) >= 40) and d.relation(c, n4) >= 25:
				var res: Dictionary = d.propose_alliance(c, n4)
				if res["ok"] and not s.is_player(n4):
					_note(c, "%s allies with %s" % [s.world.c_short[c], s.world.c_short[n4]])
	# Rivals: the neighbour we like least once we have grievances
	if d.rivals(c).is_empty() and goals[c] == "expand" and s.rng.randf() < 0.15 and not nb.is_empty():
		var worst := -1
		var wv := 0
		for n5: int in nb:
			var rl: int = d.relation(c, n5)
			if rl < wv and not d.is_allied(c, n5):
				wv = rl; worst = n5
		if worst >= 0 and wv < -20:
			d.declare_rival(c, worst)
	# Claims and war (expanding states only)
	if goals[c] != "expand":
		return
	_consider_war(c)


func _alliance_power(c: int) -> float:
	var t := _power(c)
	for a in s.diplo.allies(c):
		t += 0.7 * _power(a)
	return t


func _consider_war(c: int) -> void:
	var d = s.diplo
	if not d.wars_of(c).is_empty() or _debt(c) or _legit(c) < 35.0 or d.war_exhaustion(c) > 15.0:
		return
	var best := -1
	var best_ratio := WAR_POWER_RATIO
	for n: int in d.neighbors_of(c):
		if d.is_allied(c, n) or d.truce_days_left(c, n) > 0:
			continue
		var targets := _war_targets(c, n)
		if targets.is_empty():
			continue
		var ratio := _alliance_power(c) / maxf(0.5, _alliance_power(n))
		if ratio > best_ratio:
			best_ratio = ratio; best = n
	if best < 0:
		# No suitable claim: maybe fabricate one on the weakest neighbour.
		if d.diplomatic_points(c) >= 6.0 and s.rng.randf() < 0.25:
			var weakest := -1
			var wp := 1e9
			for n2: int in d.neighbors_of(c):
				var pw := _alliance_power(n2)
				if not d.is_allied(c, n2) and pw < wp and pw * WAR_POWER_RATIO < _alliance_power(c):
					wp = pw; weakest = n2
			if weakest >= 0:
				var bp: Array = d.border_provinces_of(weakest, c)
				if not bp.is_empty():
					d.fabricate_claim(c, bp[s.rng.randi() % bp.size()])
		return
	var chance := WAR_CHANCE_MONTHLY * (1.5 if String(s.world.c_rank[c]) == "great" else 1.0) * (2.0 if d.is_rival(c, best) else 1.0)
	if s.rng.randf() < chance:
		var res: Dictionary = d.declare_war(c, best, _war_targets(c, best))
		if res["ok"]:
			wars_declared += 1
			_note(c, "%s declares war on %s" % [s.world.c_short[c], s.world.c_short[best]])


func _war_targets(c: int, n: int) -> PackedInt32Array:
	var d = s.diplo
	var rival: bool = d.is_rival(c, n) or d.is_rival(n, c)
	var out := PackedInt32Array()
	for p: int in d.border_provinces_of(n, c):
		if d.has_claim(c, p) or rival:
			out.append(p)
			if out.size() >= 3:
				break
	return out


# --------------------------------------------------------------------------- military
func _military(c: int) -> void:
	if s.military == null:
		return
	var m = s.military
	var maxb: int = m.max_battalions(c)
	var est: float = m.est[c]
	var at_w: bool = not s.diplo.wars_of(c).is_empty()
	var want := float(maxb) * (0.8 if (at_w or goals[c] == "expand") else 0.45)
	if _debt(c) and not at_w:
		want = minf(want, est - 1.0)
	if est < want - 0.5:
		m.recruit(c, 1 if not at_w else 2)
	elif est > want + 1.5 and not at_w:
		m.disband(c, 1)


# --------------------------------------------------------------------------- war reactions (called weekly by diplomacy)
func react_wars() -> void:
	week_counter += 1
	if s.diplo == null:
		return
	for w: Dictionary in s.diplo.wars.duplicate():
		if s.day - int(w["start_day"]) < 60:
			continue
		var age: int = s.day - int(w["start_day"])
		for side in [1, -1]:
			var leader: int = w["leader_a"] if side == 1 else w["leader_d"]
			if s.is_player(leader) or not s.alive[leader]:
				continue
			if (week_counter + leader) % 4 != 0:
				continue
			var v: float = w["warscore"] * side
			var ex: float = s.diplo.war_exhaustion(leader)
			var terms := ""
			if v >= 40.0 and side == 1:
				terms = "cede_goals"
			elif v >= 60.0 and side == -1 and ex > 30.0:
				terms = "white_peace"
			elif v <= -30.0 or ex >= 60.0:
				terms = "white_peace"
				if side == -1 and (v <= -50.0 or ex >= 80.0):
					terms = "cede_goals"   # surrender
			elif age > 540 and absf(w["warscore"]) < 15.0:
				terms = "white_peace"
			if terms == "":
				continue
			var r: Dictionary = s.diplo.offer_peace(w["id"], leader, terms)
			if r["ok"]:
				_note(leader, "%s offers %s" % [s.world.c_short[leader], terms])
				break
