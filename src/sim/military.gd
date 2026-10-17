extends RefCounted
## Military: battalions, manpower, morale, upkeep, implicit fronts, battles, sieges and occupation.
## A war has no unit micromanagement: every week each side attacks up to two border provinces of the enemy
## (or tries to liberate its own occupied provinces). Outcome = power ratio x terrain x supply x noise.
## Deviation from spec: power uses eq = 0.4 + 0.6 * equipment_fill so an arms shortage hurts without zeroing the army.

const Biome := preload("res://src/world/biome.gd")
const SimUtil := preload("res://src/sim/sim_util.gd")
const PROF_SOLDIER := 6
const PROF_COUNT := 7
const UPKEEP_PER_MAN := 0.8   # money / week / man under arms
const ARMS_PER_1000 := 4.0      # arms / week / 1000 men (x1.5 at war)
const REINFORCE_RATE := 0.12    # battalions regained per week toward establishment
const POST_NAMES := ["Defensive", "Balanced", "Offensive"]
const POST_ATK := [0.8, 1.0, 1.25]     # combat power when attacking, by posture
const POST_DEF := [1.25, 1.0, 0.85]    # combat power when defending
const POST_TAKE := [0.75, 1.0, 1.25]   # org and casualties suffered
const POST_COST := [0.9, 1.0, 1.2]     # arms use and upkeep while at war
const MAX_BATTLE_WEEKS := 10

var s
var _n := 0
var batt_size := 1000.0         # men per battalion (calibrated at setup from world manpower)
var bat := PackedFloat32Array()         # battalions in the field (fractional = under strength)
var est := PackedFloat32Array()         # establishment the country tries to keep
var morale := PackedFloat32Array()
var occupier := PackedInt32Array()      # per province: country that holds it, -1 = owner holds it
var siege: Dictionary = {}              # province -> {"by": country, "prog": float}
var casualties := PackedFloat32Array()  # lifetime battalions lost
var battles := 0
var recent: Array = []                  # [{day, text}] last 30 battle reports
var _fill_cache := PackedFloat32Array()
var posture := PackedByteArray()        # per country: 0 defensive, 1 balanced, 2 offensive
var live: Dictionary = {}               # attacked province -> running battle {w, side, x, y, src, oa, od, wk, dig, ratio, f}
var _load := PackedFloat32Array()       # per country: battles it is committed to this week


func setup(state) -> void:
	s = state
	_n = s.world.country_count
	bat.resize(_n); est.resize(_n); morale.resize(_n); casualties.resize(_n)
	occupier.resize(s.world.province_count)
	occupier.fill(-1)
	siege = {}; recent = []; battles = 0
	posture.resize(_n); posture.fill(1)
	live = {}
	_load.resize(_n)
	var tot := 0.0
	for c in _n:
		tot += _manpower_raw(c)
	batt_size = clampf(tot / float(maxi(1, _n)) / 20.0, 200.0, 20000.0)
	for c in _n:
		var mb := max_battalions(c)
		var b := maxf(2.0, floorf(mb * 0.5))
		if String(s.world.c_rank[c]) == "great":
			b = maxf(b, floorf(mb * 0.6))
		bat[c] = b
		est[c] = b
		morale[c] = 1.0
		casualties[c] = 0.0


func to_dict() -> Dictionary:
	var sg := []
	for p in siege:
		sg.append([int(p), int(siege[p]["by"]), SimUtil.num_str(float(siege[p]["prog"]))])
	return {"bs": SimUtil.num_str(batt_size), "bat": SimUtil.enc_f32(bat), "est": SimUtil.enc_f32(est),
		"mor": SimUtil.enc_f32(morale), "occ": Array(occupier),
		"siege": sg, "cas": SimUtil.enc_f32(casualties), "battles": battles, "recent": recent.duplicate(true),
		"post": Array(posture), "fl": _live_to_array()}


func from_dict(d: Dictionary) -> void:
	_n = s.world.country_count
	batt_size = SimUtil.parse_num(d.get("bs", 1000.0), 1000.0)
	bat = SimUtil.dec_f32(d.get("bat", ""))
	est = SimUtil.dec_f32(d.get("est", ""))
	morale = SimUtil.dec_f32(d.get("mor", ""))
	casualties = SimUtil.dec_f32(d.get("cas", ""))
	for arr in [bat, est, morale, casualties]:
		if arr.size() != _n:
			arr.resize(_n)
	var oc := []
	for v in d.get("occ", []):
		oc.append(int(v))
	occupier = PackedInt32Array(oc)
	if occupier.size() != s.world.province_count:
		occupier.resize(s.world.province_count)
		occupier.fill(-1)
	siege = {}
	for e in d.get("siege", []):
		siege[int(e[0])] = {"by": int(e[1]), "prog": SimUtil.parse_num(e[2])}
	battles = int(d.get("battles", 0))
	recent = []
	for e: Dictionary in d.get("recent", []):
		recent.append({"day": int(e["day"]), "text": String(e["text"])})
	posture = PackedByteArray()
	posture.resize(_n)
	posture.fill(1)
	var pa_arr: Array = d.get("post", [])
	if pa_arr.size() == _n:
		for i in _n:
			posture[i] = clampi(int(pa_arr[i]), 0, 2)
	live = {}
	for e in d.get("fl", []):
		live[int(e[0])] = {"w": int(e[1]), "side": int(e[2]), "x": int(e[3]), "y": int(e[4]), "src": int(e[5]),
			"oa": SimUtil.parse_num(e[6]), "od": SimUtil.parse_num(e[7]), "wk": int(e[8]), "dig": SimUtil.parse_num(e[9]),
			"ratio": SimUtil.parse_num(e[10]), "f": [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]}
	_load.resize(_n)


func _live_to_array() -> Array:
	var out := []
	for q: int in live.keys():
		var b: Dictionary = live[q]
		out.append([q, int(b["w"]), int(b["side"]), int(b["x"]), int(b["y"]), int(b["src"]), SimUtil.num_str(float(b["oa"])),
			SimUtil.num_str(float(b["od"])), int(b["wk"]), SimUtil.num_str(float(b["dig"])), SimUtil.num_str(float(b["ratio"]))])
	return out


# --------------------------------------------------------------------------- helpers
func _mod(c: int, key: String) -> float:
	if s.has_method("modifier"):
		return float(s.modifier(c, key))
	var t := 0.0
	if s.politics != null and s.politics.has_method("modifier"):
		t += float(s.politics.modifier(c, key))
	if s.tech != null and s.tech.has_method("modifier"):
		t += float(s.tech.modifier(c, key))
	return t


func _tech_mod(c: int, key: String) -> float:
	if s.tech != null and s.tech.has_method("modifier"):
		return float(s.tech.modifier(c, key))
	return 0.0


func _soldiers(c: int) -> float:
	if s.pops != null and s.pops.has_method("country_prof"):
		return float(s.pops.country_prof(c, PROF_SOLDIER))
	return 0.015 * 20000.0 * s.world.c_provinces[c].size()


func _country_pop(c: int) -> float:
	if s.pops != null and s.pops.has_method("country_pop"):
		return float(s.pops.country_pop(c))
	return 20000.0 * s.world.c_provinces[c].size()


func _manpower_raw(c: int) -> float:
	return _soldiers(c) + _country_pop(c) * 0.01


func manpower(c: int) -> int:
	## Men available for service: serving soldiers plus the conscription pool.
	return int(_soldiers(c) + _country_pop(c) * clampf(_mod(c, "conscription_rate"), 0.0, 0.2))


func max_battalions(c: int) -> int:
	return int(float(manpower(c)) / batt_size)


func battalions(c: int) -> int:
	return int(roundf(bat[c]))


func at_war(c: int) -> bool:
	return s.diplo != null and not s.diplo.wars_of(c).is_empty()


func equipment_fill(c: int) -> float:
	if s.econ != null and s.econ.has_method("equipment_fill"):
		return clampf(float(s.econ.equipment_fill(c)), 0.0, 1.0)
	return 1.0


func upkeep(c: int) -> float:
	return bat[c] * batt_size * UPKEEP_PER_MAN * (1.25 * float(POST_COST[posture[c]]) if at_war(c) else 1.0)


func arms_demand(c: int) -> float:
	return bat[c] * batt_size / 1000.0 * ARMS_PER_1000 * (1.5 * float(POST_COST[posture[c]]) if at_war(c) else 1.0)


func power_breakdown(c: int) -> Array:
	var out: Array = [{"reason": "Battalions in the field", "value": bat[c]}]
	var fill := equipment_fill(c)
	out.append({"reason": "Equipment (arms supply %d%%)" % int(fill * 100.0), "value": 0.4 + 0.6 * fill, "mult": true})
	out.append({"reason": "Morale", "value": morale[c], "mult": true})
	out.append({"reason": "Military technology", "value": 1.0 + _tech_mod(c, "army_power"), "mult": true})
	return out


func power(c: int) -> float:
	return bat[c] * (0.4 + 0.6 * equipment_fill(c)) * morale[c] * (1.0 + _tech_mod(c, "army_power"))


func army(c: int) -> Dictionary:
	return {"battalions": battalions(c), "manpower": manpower(c), "equipment": equipment_fill(c), "morale": morale[c],
		"upkeep": upkeep(c), "power": power(c), "men": int(bat[c] * batt_size), "establishment": est[c], "max": max_battalions(c)}


func recruit(c: int, n: int) -> Dictionary:
	if n <= 0 or not s.alive[c]:
		return {"ok": false, "reason": "Nothing to recruit."}
	if s.econ != null and s.econ.has_method("in_debt") and s.econ.in_debt(c):
		return {"ok": false, "reason": "The treasury is in debt."}
	var room := max_battalions(c) - int(ceil(est[c]))
	if room <= 0:
		return {"ok": false, "reason": "No manpower left; change conscription law or grow the population."}
	var k := mini(n, room)
	est[c] += k
	bat[c] += k
	morale[c] = maxf(0.5, morale[c] - 0.03 * k)   # raw recruits dilute morale
	return {"ok": true, "reason": "Recruited %d battalions." % k if k == n else "Recruited only %d battalions (manpower limit)." % k}


func disband(c: int, n: int) -> Dictionary:
	if n <= 0 or bat[c] < 1.0:
		return {"ok": false, "reason": "No battalions to disband."}
	var k := minf(float(n), bat[c])
	bat[c] -= k
	est[c] = maxf(0.0, est[c] - k)
	return {"ok": true, "reason": "Disbanded %d battalions." % int(k)}


# --------------------------------------------------------------------------- control of provinces
func controller(p: int) -> int:
	if p <= 0 or p >= occupier.size():
		return s.world.p_owner[p] if p >= 0 and p < s.world.province_count else -1
	var o := occupier[p]
	return o if o >= 0 else s.world.p_owner[p]


func occupied_by(c: int) -> Array:
	## Provinces currently held by c that belong to someone else.
	var out := []
	for p in range(1, occupier.size()):
		if occupier[p] == c:
			out.append(p)
	return out


func occupied_count(c: int) -> int:
	## Number of c's own provinces held by an enemy.
	var n := 0
	for p in s.world.c_provinces[c]:
		if occupier[p] >= 0:
			n += 1
	return n


func border_provinces(a: int, b: int) -> Array:
	## Provinces owned by b that touch a province owned by a (the front line from a's point of view).
	return s.diplo.border_provinces_of(b, a)


func fronts(war_id: int) -> Array:
	## [{attacker, defender, provinces:[...]}] per bordering attacker/defender pair.
	var out := []
	var w: Dictionary = s.diplo.war_by_id(war_id)
	if w.is_empty():
		return out
	for a in w["attackers"]:
		for d in w["defenders"]:
			var prov: Array = s.diplo.border_provinces_of(d, a)
			prov.append_array(s.diplo.border_provinces_of(a, d))
			if not prov.is_empty():
				out.append({"attacker": a, "defender": d, "provinces": prov})
	return out


func on_transfer(p: int, _from: int, _to: int) -> void:
	if p > 0 and p < occupier.size():
		occupier[p] = -1
		siege.erase(p)
		live.erase(p)


func on_war_ended(_w: Dictionary) -> void:
	## Called by diplomacy after the war was removed: release occupations that are no longer justified.
	_release_invalid()


func _release_invalid() -> void:
	for p in range(1, occupier.size()):
		var o := occupier[p]
		if o < 0:
			continue
		var ow: int = s.world.p_owner[p]
		if ow < 0 or ow == o or not s.diplo.at_war(o, ow):
			occupier[p] = -1
			siege.erase(p)
	for p in siege.keys():
		if occupier.size() > p and not s.diplo.at_war(siege[p]["by"], s.world.p_owner[p]):
			siege.erase(p)


# --------------------------------------------------------------------------- weekly simulation
func tick_week() -> void:
	_release_invalid()
	var wars: Array = s.diplo.wars if s.diplo != null else []
	var at_w := PackedByteArray()
	at_w.resize(_n)
	for w: Dictionary in wars:
		for x in w["attackers"]: at_w[x] = 1
		for x in w["defenders"]: at_w[x] = 1
	_drop_dead_battles()
	for c in _n:
		if not s.alive[c]:
			continue
		# Morale recovers (slower at war); battalions refill toward establishment from the manpower pool.
		morale[c] = minf(1.0, morale[c] + (0.006 if at_w[c] == 1 else 0.03))
		var maxb := float(max_battalions(c))
		est[c] = minf(est[c], maxb) if est[c] > maxb + 1.0 else est[c]
		if bat[c] < est[c]:
			# Replacements need rifles and artillery: an arms shortage slows reinforcement.
			bat[c] = minf(est[c], bat[c] + REINFORCE_RATE * (0.35 + 0.65 * equipment_fill(c)))
	if wars.is_empty():
		return
	for w: Dictionary in wars.duplicate():
		_start_battles(w)
	_load.resize(_n)
	_load.fill(0.0)
	for bt: Dictionary in live.values():
		_load[int(bt["x"])] += 1.0
		_load[int(bt["y"])] += 1.0
	for q: int in live.keys():
		if live.has(q):
			_round(q)


func _terrain_def(p: int) -> float:
	match int(s.world.p_terrain[p]):
		Biome.HILLS: return 1.25
		Biome.MOUNTAINS: return 1.6
		Biome.FOREST: return 1.15
	return 1.0


var _rail_t := -2


func _railway_level(p: int) -> int:
	if s.econ != null:
		if s.econ.has_method("railway_level"):
			return int(s.econ.railway_level(p))
		if s.econ.has_method("buildings_in"):
			if _rail_t == -2:
				var ids = s.econ.get("b_ids")
				_rail_t = ids.find("railway") if ids != null else -1
			if _rail_t < 0:
				return 0
			for b in s.econ.buildings_in(p):
				if int(b.get("type", -1)) == _rail_t:
					return int(b.get("level", 0))
	return 0


func _side_power(w: Dictionary, side: int) -> float:
	var members: Array = w["attackers"] if side == 1 else w["defenders"]
	var enemies: Array = w["defenders"] if side == 1 else w["attackers"]
	var tot := 0.0
	for x in members:
		var f := 0.5
		if x == w["leader_a"] or x == w["leader_d"]:
			f = 1.0
		else:
			for y in enemies:
				if s.diplo.neighbors_of(x).has(y):
					f = 1.0
					break
		tot += power(x) * f
	return tot


func _targets(w: Dictionary, side: int) -> Array:
	## Provinces `side` can attack this week: [score, province, source_province]
	var mine: Array = w["attackers"] if side == 1 else w["defenders"]
	var theirs: Array = w["defenders"] if side == 1 else w["attackers"]
	var goals: Array = w["goals"]
	var out := []
	for owner_set in [theirs, mine]:
		for x in owner_set:
			for q in s.world.c_provinces[x]:
				var ctl := controller(q)
				if mine.has(ctl):
					continue
				if not (theirs.has(ctl) or theirs.has(s.world.p_owner[q])):
					continue
				var src := -1
				for n in s.world.p_neighbors[q]:
					if n > 0 and mine.has(controller(n)):
						src = n
						break
				if src < 0:
					continue
				var score := 0.0
				if side == 1 and goals.has(q): score += 100.0
				if mine.has(s.world.p_owner[q]): score += 60.0      # liberate our own land
				if s.world.p_capital[q] == 1: score += 8.0
				score += 10.0 - _terrain_def(q) * 4.0 - float(s.world.p_tier[q])
				out.append([score, q, src])
	out.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	return out


func set_posture(c: int, p: int) -> bool:
	posture[c] = clampi(p, 0, 2)
	return true


func get_posture(c: int) -> int:
	return posture[c]


func _drop_dead_battles() -> void:
	for q: int in live.keys():
		var b: Dictionary = live[q]
		var x: int = b["x"]
		var y: int = b["y"]
		if not s.alive[x] or not s.alive[y] or not s.diplo.at_war(x, y) or controller(q) != y:
			live.erase(q)


func _max_fronts(members: Array) -> int:
	var tot := 0.0
	for x in members:
		tot += bat[x]
	return clampi(1 + int(tot / 8.0), 1, 3)


## Opens new battles along the real province frontier. Defensive nations only counter-attack to liberate
## their own land; offensive ones always press; balanced ones attack most weeks.
func _start_battles(w: Dictionary) -> void:
	for side in [1, -1]:
		var mine: Array = w["attackers"] if side == 1 else w["defenders"]
		var cap := _max_fronts(mine)
		var cur := 0
		for bt: Dictionary in live.values():
			if int(bt["w"]) == int(w["id"]) and int(bt["side"]) == side:
				cur += 1
		if cur >= cap:
			continue
		for t in _targets(w, side):
			if cur >= cap:
				break
			var q: int = t[1]
			var src: int = t[2]
			var x := controller(src)
			var y := controller(q)
			if live.has(q) or x < 0 or y < 0 or bat[x] < 0.5 or not mine.has(x):
				continue
			var pst: int = posture[x]
			var want: bool = float(t[0]) >= 60.0 or pst == 2 or (pst == 1 and s.rng.randf() < 0.6)
			if not want:
				continue
			live[q] = {"w": int(w["id"]), "side": side, "x": x, "y": y, "src": src, "oa": morale[x], "od": morale[y],
				"wk": 0, "dig": 0.0, "ratio": 1.0, "f": [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]}
			cur += 1
			_report("%s attacks %s (%s)." % [s.world.c_short[x], s.world.p_name[q], s.world.c_short[y]], x, y)


## One week of a running battle. Forces are the share of each army committed to this front, scaled by
## equipment, supply, organisation, terrain, entrenchment and posture; the battle ends when one side's
## organisation collapses, so a smaller well-equipped force on good ground can still win.
func _round(q: int) -> void:
	var b: Dictionary = live[q]
	var x: int = b["x"]
	var y: int = b["y"]
	var w: Dictionary = s.diplo.war_by_id(int(b["w"]))
	if w.is_empty():
		live.erase(q)
		return
	var src: int = b["src"]
	var wk: int = b["wk"]
	var ca := maxf(0.2, bat[x] * 0.8 / maxf(1.0, _load[x]))
	var cd := maxf(0.2, bat[y] * 0.8 / maxf(1.0, _load[y]))
	var ex := 0.4 + 0.6 * equipment_fill(x)
	var ey := 0.4 + 0.6 * equipment_fill(y)
	var deep: bool = s.world.p_owner[q] != x
	if deep:
		for n in s.world.p_neighbors[q]:
			if s.world.p_owner[n] == x:
				deep = false
				break
	var sup_a := clampf((0.88 if deep else 1.0) + 0.04 * minf(3.0, float(_railway_level(src))) - 0.012 * wk, 0.5, 1.2)
	var sup_d := 1.0 + 0.04 * minf(3.0, float(_railway_level(q)))
	var terr := _terrain_def(q)
	var fort := 1.15 if s.world.p_capital[q] == 1 else 1.0
	var dig: float = b["dig"]
	var oa: float = b["oa"]
	var od: float = b["od"]
	var pa := ca * ex * sup_a * oa * (1.0 + _tech_mod(x, "army_power")) * float(POST_ATK[posture[x]])
	var pd := cd * ey * sup_d * od * (1.0 + _tech_mod(y, "army_power")) * float(POST_DEF[posture[y]]) * terr * fort * (1.0 + dig)
	var ratio := pa / maxf(pd, 0.01) * lerpf(0.88, 1.15, s.rng.randf())
	var rc := clampf(ratio, 0.25, 4.0)
	var tk_x: float = POST_TAKE[posture[x]]
	var tk_y: float = POST_TAKE[posture[y]]
	oa = maxf(0.0, oa - 0.16 / rc * tk_x)
	od = maxf(0.0, od - 0.16 * rc * tk_y)
	_take_casualties(x, ca * 0.035 / rc * tk_x)
	_take_casualties(y, cd * 0.035 * rc * tk_y)
	s.diplo.add_exhaustion(x, 0.06 + 0.08 / rc)
	s.diplo.add_exhaustion(y, 0.06 + 0.08 * minf(rc, 3.0) / 3.0)
	b["oa"] = oa
	b["od"] = od
	b["wk"] = wk + 1
	b["dig"] = minf(0.3, dig + 0.04)
	b["ratio"] = ratio
	b["f"] = [ca, cd, ex, ey, sup_a, sup_d, terr]
	if od <= 0.0:
		_end_battle(q, b, w, true, ratio)
	elif oa <= 0.0:
		_end_battle(q, b, w, false, ratio)
	elif wk + 1 >= MAX_BATTLE_WEEKS:
		live.erase(q)
		_report("The fighting at %s ends in stalemate." % s.world.p_name[q], x, y)


func _end_battle(q: int, b: Dictionary, w: Dictionary, win: bool, ratio: float) -> void:
	live.erase(q)
	var x: int = b["x"]
	var y: int = b["y"]
	var side: int = b["side"]
	battles += 1
	morale[x] = clampf(morale[x] + (0.03 if win else -0.08), 0.2, 1.0)
	morale[y] = clampf(morale[y] + (-0.08 if win else 0.03), 0.2, 1.0)
	s.diplo.add_exhaustion(y if win else x, 0.4)
	s.diplo.add_battle_score(w["id"], side if win else -side, 1.5)
	var verb := "storms" if win else "is repulsed at"
	_report("%s %s %s (%s) after %d weeks." % [s.world.c_short[x], verb, s.world.p_name[q], s.world.c_short[y], int(b["wk"])], x, y)
	if not win:
		return
	# A won battle advances the siege; enough progress turns into occupation or liberation.
	var need := 1.2 + 0.25 * float(s.world.p_tier[q]) + (0.6 if s.world.p_capital[q] == 1 else 0.0)
	var st: Dictionary = siege.get(q, {"by": x, "prog": 0.0})
	if st["by"] != x:
		st = {"by": x, "prog": 0.0}
	st["prog"] = float(st["prog"]) + 1.0 + 0.5 * clampf(ratio - 1.0, 0.0, 1.0)
	if st["prog"] < need:
		siege[q] = st
		return
	siege.erase(q)
	var ow: int = s.world.p_owner[q]
	if ow == x or w["attackers" if side == 1 else "defenders"].has(ow):
		occupier[q] = -1
		_report("%s liberates %s." % [s.world.c_short[x], s.world.p_name[q]], x, ow, true)
	else:
		occupier[q] = x
		_report("%s occupies %s from %s." % [s.world.c_short[x], s.world.p_name[q], s.world.c_short[ow]], x, ow, true)


## Active battles involving country c, with a plain-language reason for the way each is going.
func battle_report(c: int) -> Array:
	var out: Array = []
	for q: int in live.keys():
		var b: Dictionary = live[q]
		if int(b["x"]) == c or int(b["y"]) == c:
			out.append({"province": q, "attacker": int(b["x"]), "defender": int(b["y"]), "org_a": float(b["oa"]),
				"org_d": float(b["od"]), "weeks": int(b["wk"]), "text": explain_battle(b)})
	return out


func explain_battle(b: Dictionary) -> String:
	var f: Array = b["f"]
	var x: int = b["x"]
	var y: int = b["y"]
	var r: float = b["ratio"]
	var head := "Attacker advancing" if r > 1.15 else ("Defenders holding" if r < 0.87 else "Deadlock")
	return "%s. %s (%s): %.1f bn, gear %d%%, supply %d%%. %s (%s): %.1f bn, gear %d%%, supply %d%%, terrain x%.2f, entrenchment +%d%%." % [
		head, s.world.c_short[x], POST_NAMES[posture[x]], f[0], int(float(f[2]) * 100.0), int(float(f[4]) * 100.0),
		s.world.c_short[y], POST_NAMES[posture[y]], f[1], int(float(f[3]) * 100.0), int(float(f[5]) * 100.0), f[6], int(float(b["dig"]) * 100.0)]


func _report(text: String, a: int, b: int, major: bool = false) -> void:
	recent.append({"day": s.day, "text": text})
	if recent.size() > 30:
		recent.pop_front()
	if major:
		s.log_event(a, "war", text)
		if b != a and b >= 0:
			s.log_event(b, "war", text)


func _take_casualties(c: int, battalions_lost: float) -> void:
	var l := minf(battalions_lost, bat[c])
	bat[c] -= l
	casualties[c] += l
	# A third of the dead are permanently gone from the soldier population.
	if s.pops == null or s.world.c_provinces[c].is_empty():
		return
	var arr = s.pops.get("size")
	if arr == null:
		return
	var men := l * batt_size * 0.33
	var provs: PackedInt32Array = s.world.c_provinces[c]
	for _t in 4:
		var p: int = provs[s.rng.randi() % provs.size()]
		var idx := p * PROF_COUNT + PROF_SOLDIER
		if idx < arr.size() and float(arr[idx]) > men:
			var new_sz: float = float(arr[idx]) - men
			if arr is PackedInt32Array:
				arr[idx] = int(new_sz)
			else:
				arr[idx] = new_sz
			var emp_arr = s.pops.get("employed")
			if emp_arr != null and idx < emp_arr.size() and float(emp_arr[idx]) > float(arr[idx]):
				emp_arr[idx] = arr[idx]
			return
