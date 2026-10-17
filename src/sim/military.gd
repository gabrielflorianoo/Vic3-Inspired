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
var focus_enemy := PackedInt32Array()   # per country: enemy country ID where troops are concentrated (-1 = spread evenly)
var live: Dictionary = {}               # attacked province -> running battle {w, side, x, y, src, oa, od, wk, dig, ratio, f}
var _load := PackedFloat32Array()       # per country: battles it is committed to this week
var war_hist: Dictionary = {}           # war_id -> PackedFloat32Array of attacker warscore history (up to 26 weeks)


func setup(state) -> void:
	s = state
	_n = s.world.country_count
	bat.resize(_n); est.resize(_n); morale.resize(_n); casualties.resize(_n)
	occupier.resize(s.world.province_count)
	occupier.fill(-1)
	siege = {}; recent = []; battles = 0
	posture.resize(_n); posture.fill(1)
	focus_enemy.resize(_n); focus_enemy.fill(-1)
	live = {}
	war_hist = {}
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
	var wh := {}
	for wid in war_hist:
		wh[str(wid)] = SimUtil.enc_f32(war_hist[wid])
	return {"bs": SimUtil.num_str(batt_size), "bat": SimUtil.enc_f32(bat), "est": SimUtil.enc_f32(est),
		"mor": SimUtil.enc_f32(morale), "occ": Array(occupier),
		"siege": sg, "cas": SimUtil.enc_f32(casualties), "battles": battles, "recent": recent.duplicate(true),
		"post": Array(posture), "foc": Array(focus_enemy), "wh": wh, "fl": _live_to_array()}


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
	focus_enemy = PackedInt32Array()
	focus_enemy.resize(_n)
	focus_enemy.fill(-1)
	var fe_arr: Array = d.get("foc", [])
	if fe_arr.size() == _n:
		for i in _n:
			focus_enemy[i] = int(fe_arr[i])
	war_hist = {}
	var wh_d: Dictionary = d.get("wh", {})
	for k in wh_d:
		war_hist[int(k)] = SimUtil.dec_f32(str(wh_d[k]))
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


func preview_recruit_impact(c: int, n: int) -> String:
	var room := max_battalions(c) - int(ceil(est[c]))
	var k := maxi(0, mini(n, room))
	var mult := 1.25 * float(POST_COST[posture[c]]) if at_war(c) else 1.0
	var amult := 1.5 * float(POST_COST[posture[c]]) if at_war(c) else 1.0
	var d_upk := float(n) * batt_size * UPKEEP_PER_MAN * mult
	var d_arms := float(n) * batt_size / 1000.0 * ARMS_PER_1000 * amult
	var mor_drop := int(round(0.03 * float(k) * 100.0))
	return "Raise %d battalion(s) (%d men).\nImpact: -£%.0f/wk upkeep, +%.1f Arms/wk demand, -%d%% initial morale (raw recruits)." % [
		n, int(float(n) * batt_size), d_upk, d_arms, mor_drop]


func preview_disband_impact(c: int, n: int) -> String:
	var k := minf(float(n), bat[c])
	var mult := 1.25 * float(POST_COST[posture[c]]) if at_war(c) else 1.0
	var amult := 1.5 * float(POST_COST[posture[c]]) if at_war(c) else 1.0
	var d_upk := k * batt_size * UPKEEP_PER_MAN * mult
	var d_arms := k * batt_size / 1000.0 * ARMS_PER_1000 * amult
	return "Release %d battalion(s).\nImpact: saves +£%.0f/wk upkeep and reduces Arms demand by -%.1f/wk." % [int(k), d_upk, d_arms]


func power_breakdown(c: int) -> Array:
	var out: Array = [{"reason": "Battalions in the field", "value": bat[c]}]
	var fill := equipment_fill(c)
	out.append({"reason": "Equipment (arms supply %d%%)" % int(fill * 100.0), "value": 0.4 + 0.6 * fill, "mult": true})
	out.append({"reason": "Morale / Organisation", "value": morale[c], "mult": true})
	out.append({"reason": "Military technology", "value": 1.0 + _tech_mod(c, "army_power"), "mult": true})
	out.append({"reason": "Posture (%s)" % POST_NAMES[posture[c]], "value": POST_ATK[posture[c]], "mult": true})
	return out


func power(c: int) -> float:
	return bat[c] * (0.4 + 0.6 * equipment_fill(c)) * morale[c] * (1.0 + _tech_mod(c, "army_power"))


func army(c: int) -> Dictionary:
	return {"battalions": battalions(c), "manpower": manpower(c), "equipment": equipment_fill(c), "morale": morale[c],
		"upkeep": upkeep(c), "power": power(c), "men": int(bat[c] * batt_size), "establishment": est[c], "max": max_battalions(c),
		"casualties": casualties[c], "focus": focus_enemy[c]}


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


# --------------------------------------------------------------------------- control of provinces & supply
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


## True if province `src` has a contiguous land path of provinces controlled by `c` (or war allies) back to `c`'s capital (or any core province).
func has_supply_line(c: int, src: int, war_allies: Array = []) -> bool:
	if src <= 0:
		return false
	if s.world.p_owner[src] == c and controller(src) == c:
		return true
	var cap_p: int = s.world.c_capital[c]
	if cap_p <= 0 or controller(cap_p) != c:
		# Fallback: check if adjacent to any homeland province controlled by c
		for n in s.world.p_neighbors[src]:
			if s.world.p_owner[n] == c and controller(n) == c:
				return true
	var visited := {src: true}
	var queue: Array = [src]
	var head := 0
	while head < queue.size() and head < 48:
		var cur: int = queue[head]
		head += 1
		if s.world.p_owner[cur] == c and controller(cur) == c:
			return true
		for nb in s.world.p_neighbors[cur]:
			if nb > 0 and not visited.has(nb):
				var ctl := controller(nb)
				if ctl == c or war_allies.has(ctl):
					visited[nb] = true
					queue.append(nb)
	return false


## Calculates the logistics & supply efficiency (0.45..1.25) for country `c` operating from `src` into `target_p`.
func supply_efficiency(c: int, src: int, target_p: int, wk: int = 0, war_allies: Array = []) -> float:
	var deep: bool = s.world.p_owner[target_p] != c
	if deep:
		for n in s.world.p_neighbors[target_p]:
			if s.world.p_owner[n] == c:
				deep = false
				break
	var connected := has_supply_line(c, src, war_allies)
	var base_sup := 1.0 if not deep else (0.88 if connected else 0.62)
	var cap_p: int = s.world.c_capital[c]
	if cap_p > 0 and controller(cap_p) != c:
		base_sup -= 0.12 # Capital occupied: national logistics disrupted
	var rail_b := 0.04 * minf(3.0, float(_railway_level(src)))
	var camp_wear := 0.012 * float(wk)
	return clampf(base_sup + rail_b - camp_wear, 0.45, 1.25)


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


## Detailed strategic fronts for country `c` across all active wars, with relative power, supply, terrain, threatened provinces, and status reason.
func fronts_of_country(c: int) -> Array:
	var out: Array = []
	if s.diplo == null:
		return out
	for w: Dictionary in s.diplo.wars_of(c):
		var wid: int = int(w["id"])
		var is_att: bool = (w["attackers"] as Array).has(c)
		var allies: Array = w["attackers"] if is_att else w["defenders"]
		var foes: Array = w["defenders"] if is_att else w["attackers"]
		for foe_v in foes:
			var foe: int = int(foe_v)
			if not s.alive[foe]:
				continue
			var border_theirs: Array = []
			var border_ours: Array = []
			for p in s.world.c_provinces[foe]:
				for nb in s.world.p_neighbors[p]:
					if nb > 0 and allies.has(controller(nb)):
						border_theirs.append(p)
						break
			for p in s.world.c_provinces[c]:
				for nb in s.world.p_neighbors[p]:
					if nb > 0 and foes.has(controller(nb)):
						border_ours.append(p)
						break
			var active_bt: Array = []
			for q: int in live.keys():
				var bt: Dictionary = live[q]
				if int(bt["w"]) == wid and ((int(bt["x"]) == c and int(bt["y"]) == foe) or (int(bt["x"]) == foe and int(bt["y"]) == c)):
					active_bt.append(q)
			if border_theirs.is_empty() and border_ours.is_empty() and active_bt.is_empty():
				continue
			var my_pwr := power(c) * (1.20 if focus_enemy[c] == foe else 1.0)
			var foe_pwr := power(foe) * (1.20 if focus_enemy[foe] == c else 1.0)
			var ratio := my_pwr / maxf(foe_pwr, 0.1)
			var sample_p: int = int(border_ours[0]) if not border_ours.is_empty() else (int(border_theirs[0]) if not border_theirs.is_empty() else s.world.c_capital[c])
			var sup := supply_efficiency(c, sample_p, sample_p, 0, allies)
			var avg_terr := 1.0
			var t_cnt := 0
			for tp_id in border_theirs:
				avg_terr += _terrain_def(int(tp_id)) - 1.0
				t_cnt += 1
			if t_cnt > 0:
				avg_terr = 1.0 + (avg_terr - 1.0) / float(t_cnt)
			var status := "Stagnant"
			var why := ""
			if ratio > 1.22 and posture[c] > 0:
				status = "Advancing"
				why = "Superior force (%.0f vs %.0f pwr) and %s posture allow offensive pushes." % [my_pwr, foe_pwr, POST_NAMES[posture[c]]]
			elif ratio < 0.82:
				status = "Losing ground"
				why = "Outmatched on this front (%.0f vs %.0f pwr); %d home province(s) threatened." % [my_pwr, foe_pwr, border_ours.size()]
			else:
				status = "Holding line" if posture[c] == 0 else "Contested"
				why = "Forces evenly matched (%.0f vs %.0f pwr) across %s terrain (x%.2f defense)." % [my_pwr, foe_pwr, "rugged" if avg_terr > 1.15 else "open", avg_terr]
			if equipment_fill(c) < 0.75:
				why += " Arms shortage (%d%%) weakens our troops." % int(round(equipment_fill(c) * 100.0))
			if sup < 0.85:
				why += " Extended/disrupted supply lines (%d%%)." % int(round(sup * 100.0))
			out.append({
				"war_id": wid, "enemy": foe, "enemy_name": s.world.c_short[foe],
				"my_power": my_pwr, "enemy_power": foe_pwr, "ratio": ratio,
				"supply": sup, "terrain_def": avg_terr,
				"threatened": border_ours, "targets": border_theirs, "battles": active_bt,
				"focused": focus_enemy[c] == foe,
				"status": status, "explanation": why
			})
	return out


func front_alerts(c: int) -> Array:
	var alerts: Array = []
	for f: Dictionary in fronts_of_country(c):
		var ratio: float = float(f["ratio"])
		var thr: Array = f["threatened"]
		var sup: float = float(f["supply"])
		if ratio < 0.78 and not thr.is_empty():
			var p0: int = int(thr[0])
			alerts.append({
				"id": "front_risk_%d" % int(f["enemy"]), "severity": "critical", "tab": "military", "province": p0,
				"label": "! Front Risk vs %s" % str(f["enemy_name"]),
				"problem": "Front against %s is outnumbered (%.0f vs %.0f power); %s is threatened." % [
					str(f["enemy_name"]), float(f["my_power"]), float(f["enemy_power"]), s.world.p_name[p0]],
				"cause": str(f["explanation"]),
				"action": "Switch to Defensive posture, Focus Front against %s, or recruit battalions in Military." % str(f["enemy_name"])
			})
		elif sup < 0.78:
			alerts.append({
				"id": "supply_risk_%d" % int(f["enemy"]), "severity": "warning", "tab": "military",
				"label": "! Low Supply vs %s (%d%%)" % [str(f["enemy_name"]), int(round(sup * 100.0))],
				"problem": "Troops fighting %s have poor supply efficiency (%d%%)." % [str(f["enemy_name"]), int(round(sup * 100.0))],
				"cause": "Deep advance into hostile territory or disrupted connection to capital; low railway level.",
				"action": "Build Railways in border provinces or consolidate forces."
			})
	return alerts


func set_focus_enemy(c: int, enemy: int) -> Dictionary:
	if c < 0 or c >= _n:
		return {"ok": false, "reason": "Invalid country."}
	if focus_enemy[c] == enemy:
		focus_enemy[c] = -1
		return {"ok": true, "reason": "Troops distributed evenly across all fronts."}
	focus_enemy[c] = enemy
	return {"ok": true, "reason": "Concentrated main army effort on the %s front (+20%% combat commitment there)." % (s.world.c_short[enemy] if enemy >= 0 else "all")}


func get_focus_enemy(c: int) -> int:
	return focus_enemy[c] if c >= 0 and c < focus_enemy.size() else -1


## Order an immediate tactical withdrawal from unfavourable offensive battles against `enemy` (or all enemies if -1) to preserve manpower & organisation.
func retreat_front(c: int, enemy: int = -1) -> Dictionary:
	var withdrawn := 0
	for q: int in live.keys():
		var b: Dictionary = live[q]
		if int(b["x"]) == c and (enemy < 0 or int(b["y"]) == enemy):
			live.erase(q)
			withdrawn += 1
	posture[c] = 0 # Switch to Defensive to hold home ground and recover organisation
	morale[c] = clampf(morale[c] + 0.04, 0.2, 1.0)
	if withdrawn > 0:
		return {"ok": true, "reason": "Withdrew from %d offensive battle(s) and adopted Defensive posture to regroup." % withdrawn}
	return {"ok": true, "reason": "Adopted Defensive posture to hold the line and recover organisation."}


func war_score_history(war_id: int, for_country: int) -> PackedFloat32Array:
	var raw: PackedFloat32Array = war_hist.get(war_id, PackedFloat32Array())
	if raw.is_empty() or s.diplo == null:
		return raw
	var w: Dictionary = s.diplo.war_by_id(war_id)
	if w.is_empty() or (w["attackers"] as Array).has(for_country):
		return raw
	var inv := PackedFloat32Array()
	inv.resize(raw.size())
	for i in raw.size():
		inv[i] = -raw[i]
	return inv


func on_transfer(p: int, _from: int, _to: int) -> void:
	if p > 0 and p < occupier.size():
		occupier[p] = -1
		siege.erase(p)
		live.erase(p)


func on_war_ended(w: Dictionary) -> void:
	## Called by diplomacy after the war was removed: release occupations that are no longer justified.
	if w.has("id"):
		war_hist.erase(int(w["id"]))
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
		var wid: int = int(w["id"])
		var wh: PackedFloat32Array = war_hist.get(wid, PackedFloat32Array())
		if wh.size() >= 26:
			wh.remove_at(0)
		wh.append(float(w.get("warscore", 0.0)))
		war_hist[wid] = wh
	_drop_dead_battles()
	for c in _n:
		if not s.alive[c]:
			continue
		if at_w[c] == 0:
			focus_enemy[c] = -1
		elif focus_enemy[c] >= 0 and not s.diplo.at_war(c, focus_enemy[c]):
			focus_enemy[c] = -1
		# Morale / organisation recovers faster in Defensive posture and when well supplied with Arms.
		var eq_f := equipment_fill(c)
		var rec_base := (0.012 if posture[c] == 0 else 0.006) if at_w[c] == 1 else 0.035
		morale[c] = clampf(morale[c] + rec_base * (0.5 + 0.5 * eq_f), 0.15, 1.0)
		var maxb := float(max_battalions(c))
		est[c] = minf(est[c], maxb) if est[c] > maxb + 1.0 else est[c]
		if bat[c] < est[c]:
			# Replacements need rifles and artillery: an arms shortage slows reinforcement.
			bat[c] = minf(est[c], bat[c] + REINFORCE_RATE * (0.35 + 0.65 * eq_f))
		# Campaign attrition for armies deep in hostile territory with poor supply
		if at_w[c] == 1 and eq_f < 0.5:
			_take_casualties(c, bat[c] * 0.004 * (0.5 - eq_f))
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
				var attacker_c := controller(src)
				var defender_c := controller(q)
				var score := 0.0
				if side == 1 and goals.has(q): score += 100.0
				if mine.has(s.world.p_owner[q]): score += 60.0      # liberate our own land
				if attacker_c >= 0 and focus_enemy[attacker_c] == defender_c:
					score += 45.0                                   # strategic front concentration
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
			# Require contiguous supply line from source province to launch new offensive into enemy land
			if s.world.p_owner[q] != x and not has_supply_line(x, src, mine):
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
## equipment, supply, organisation, terrain, entrenchment, focus and posture; the battle ends when one side's
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
	var side: int = int(b["side"])
	var allies_x: Array = w["attackers"] if side == 1 else w["defenders"]
	var allies_y: Array = w["defenders"] if side == 1 else w["attackers"]
	var foc_x := 1.20 if focus_enemy[x] == y else (0.85 if focus_enemy[x] >= 0 else 1.0)
	var foc_y := 1.20 if focus_enemy[y] == x else (0.85 if focus_enemy[y] >= 0 else 1.0)
	var ca := maxf(0.2, bat[x] * 0.8 * foc_x / maxf(1.0, _load[x]))
	var cd := maxf(0.2, bat[y] * 0.8 * foc_y / maxf(1.0, _load[y]))
	var ex := 0.4 + 0.6 * equipment_fill(x)
	var ey := 0.4 + 0.6 * equipment_fill(y)
	var sup_a := supply_efficiency(x, src, q, wk, allies_x)
	var sup_d := clampf(supply_efficiency(y, q, q, 0, allies_y) + 0.04 * minf(3.0, float(_railway_level(q))), 0.6, 1.28)
	var terr := _terrain_def(q)
	var fort := 1.15 if s.world.p_capital[q] == 1 else 1.0
	var dig: float = b["dig"]
	var oa: float = b["oa"]
	var od: float = b["od"]
	var pa := ca * ex * sup_a * oa * (1.0 + _tech_mod(x, "army_power")) * float(POST_ATK[posture[x]])
	var pd := cd * ey * sup_d * od * (1.0 + _tech_mod(y, "army_power")) * float(POST_DEF[posture[y]]) * terr * fort * (1.0 + dig)
	var ratio := pa / maxf(pd, 0.01) * lerpf(0.88, 1.15, s.rng.randf())
	var rc := clampf(ratio, 0.25, 4.0)
	var tk_x: float = POST_TAKE[posture[x]] * (1.25 if sup_a < 0.75 else 1.0)
	var tk_y: float = POST_TAKE[posture[y]] * (1.25 if sup_d < 0.75 else 1.0)
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
			out.append({"province": q, "source": int(b["src"]), "attacker": int(b["x"]), "defender": int(b["y"]),
				"org_a": float(b["oa"]), "org_d": float(b["od"]), "weeks": int(b["wk"]), "ratio": float(b["ratio"]),
				"text": explain_battle(b)})
	return out


func explain_battle(b: Dictionary) -> String:
	var f: Array = b["f"]
	var x: int = b["x"]
	var y: int = b["y"]
	var r: float = b["ratio"]
	var head := "Attacker advancing" if r > 1.15 else ("Defenders holding" if r < 0.87 else "Deadlock")
	return "%s (ratio %.2f). %s (%s): %.1f bn, gear %d%%, supply %d%%. %s (%s): %.1f bn, gear %d%%, supply %d%%, terrain %s (x%.2f), entrench +%d%%." % [
		head, r, s.world.c_short[x], POST_NAMES[posture[x]], f[0], int(float(f[2]) * 100.0), int(float(f[4]) * 100.0),
		s.world.c_short[y], POST_NAMES[posture[y]], f[1], int(float(f[3]) * 100.0), int(float(f[5]) * 100.0),
		Biome.NAMES[s.world.p_terrain[int(b["src"])]] if b.has("src") else "ground", f[6], int(float(b["dig"]) * 100.0)]


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
