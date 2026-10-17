extends RefCounted
## Technology: three trees, research points from clerks x literacy x law/tech multipliers.
## Data: data/scenario/techs.json.  Modifiers returned by modifier() are additive bonuses (0.1 = +10 %).

const BASE_POINTS := 3.0          # administrative minimum every state produces per week
const CLERK_RATE := 0.00035       # points per clerk per week at literacy 0.5
const BANK_CAP := 200.0           # points that may be saved while nothing is being researched
const SPREAD_DISCOUNT := 0.35     # max cost cut when every other state already knows a tech

var s
var _techs: Array = []            # ordered tech dicts
var _index: Dictionary = {}       # id -> dict
var _unlock_bld: Dictionary = {}  # building id -> tech id (gate)
var _n := 0
var known_set: Array = []         # Array[Dictionary id->true]
var current: Array = []           # Array[String]
var acc := PackedFloat32Array()   # points accumulated on current research
var bank := PackedFloat32Array()  # saved points
var learned_total := 0
var _mod_cache: Array = []        # Array[Dictionary key->value]
var _know_count: Dictionary = {}  # id -> number of countries knowing it


func _load_data() -> void:
	if not _techs.is_empty():
		return
	var f := FileAccess.open("res://data/scenario/techs.json", FileAccess.READ)
	if f == null:
		push_error("technology: missing techs.json")
		return
	var j = JSON.parse_string(f.get_as_text())
	_techs = j.get("techs", [])
	for t: Dictionary in _techs:
		_index[t["id"]] = t
		for b in t.get("unlocks", {}).get("buildings", []):
			_unlock_bld[b] = t["id"]


func setup(state) -> void:
	s = state
	_load_data()
	_n = s.world.country_count
	known_set = []; current = []; _mod_cache = []
	acc.resize(_n); bank.resize(_n)
	learned_total = 0
	for c in _n:
		known_set.append({})
		current.append("")
		acc[c] = 0.0
		bank[c] = 0.0
		_mod_cache.append({})
		var start: Array = []
		match String(s.world.c_rank[c]):
			"great": start = ["crop_rotation", "deep_mining", "drill_regulations", "primary_schools", "statistics"]
			"major": start = ["crop_rotation", "drill_regulations", "primary_schools", "statistics"]
			_: start = ["crop_rotation", "primary_schools", "statistics"]
		for id in start:
			_grant(c, id)
		# Whatever the starting laws need must already be known.
		if s.politics != null and s.politics.has_method("law") and s.politics.laws.size() == _n:
			for cat in s.politics.categories():
				var opt: String = s.politics.law(c, cat)
				var info: Dictionary = s.politics.option_info(opt)
				var req = info.get("requires_tech", null)
				if req != null:
					_grant(c, req)
	_recount()


func _grant(c: int, id: String) -> void:
	if not _index.has(id) or known_set[c].has(id):
		return
	for r in _index[id].get("requires", []):
		_grant(c, r)
	known_set[c][id] = true
	_mod_cache[c] = {}


func _recount() -> void:
	_know_count = {}
	for c in _n:
		for id in known_set[c]:
			_know_count[id] = int(_know_count.get(id, 0)) + 1


func to_dict() -> Dictionary:
	var cd := []
	for c in _n:
		cd.append({"k": known_set[c].keys(), "r": current[c], "a": acc[c], "b": bank[c]})
	return {"c": cd, "lt": learned_total}


func from_dict(d: Dictionary) -> void:
	_load_data()
	_n = s.world.country_count
	known_set = []; current = []; _mod_cache = []
	acc.resize(_n); bank.resize(_n)
	var cd: Array = d.get("c", [])
	for c in _n:
		var e: Dictionary = cd[c] if c < cd.size() else {}
		var ks := {}
		for id in e.get("k", []):
			ks[id] = true
		known_set.append(ks)
		current.append(String(e.get("r", "")))
		acc[c] = float(e.get("a", 0.0))
		bank[c] = float(e.get("b", 0.0))
		_mod_cache.append({})
	learned_total = int(d.get("lt", 0))
	_recount()


# --------------------------------------------------------------------------- catalogue
func tech_count() -> int:
	return _techs.size()


func tech_id(i: int) -> String:
	return _techs[i]["id"]


func all_techs() -> Array:
	## Array of tech ids in file order.
	var out := []
	for t: Dictionary in _techs:
		out.append(t["id"])
	return out


func tech_name(id: String) -> String:
	return _index[id]["name"] if _index.has(id) else id


func tech_cost(id: String) -> float:
	return float(_index[id]["cost"]) if _index.has(id) else 0.0


func tech_cost_for(c: int, id: String) -> float:
	## Cost after the "technology spread" discount (others already know it).
	var others := maxi(1, _n - 1)
	var knowing := int(_know_count.get(id, 0)) - (1 if known_set[c].has(id) else 0)
	return tech_cost(id) * (1.0 - SPREAD_DISCOUNT * clampf(float(knowing) / float(others), 0.0, 1.0))


func tech_desc(id: String) -> String:
	if not _index.has(id):
		return ""
	var t: Dictionary = _index[id]
	var parts: Array = [String(t.get("desc", ""))]
	for k in t.get("modifiers", {}):
		parts.append("%s %+d%%" % [String(k).replace("_", " "), int(round(float(t["modifiers"][k]) * 100.0))])
	for b in t.get("unlocks", {}).get("buildings", []):
		parts.append("unlocks building: " + String(b).replace("_", " "))
	for l in t.get("unlocks", {}).get("laws", []):
		parts.append("unlocks law: " + String(l).replace("_", " "))
	return " | ".join(parts)


func tech_tree(id: String) -> String:
	return _index[id]["tree"] if _index.has(id) else ""


func tech_requires(id: String) -> Array:
	return _index[id]["requires"] if _index.has(id) else []


func tech_info(id: String) -> Dictionary:
	return _index.get(id, {})


# --------------------------------------------------------------------------- per country
func researching(c: int) -> String:
	return current[c]


func is_known(c: int, id: String) -> bool:
	return known_set[c].has(id)


func known(c: int) -> Array:
	return known_set[c].keys()


func available(c: int) -> Array:
	## Tech ids that can be researched now (prerequisites known, not yet known).
	var out := []
	for t: Dictionary in _techs:
		var id: String = t["id"]
		if known_set[c].has(id):
			continue
		var ok := true
		for r in t["requires"]:
			if not known_set[c].has(r):
				ok = false
				break
		if ok:
			out.append(id)
	return out


func set_research(c: int, id: String) -> bool:
	if id == "":
		current[c] = ""
		return true
	if not available(c).has(id):
		return false
	if current[c] != id:
		# Switching loses half of the progress (kept in the bank).
		bank[c] = minf(BANK_CAP, bank[c] + acc[c] * 0.5)
		acc[c] = 0.0
	current[c] = id
	return true


func progress(c: int) -> float:
	var id: String = current[c]
	if id == "":
		return 0.0
	return clampf(acc[c] / maxf(1.0, tech_cost_for(c, id)), 0.0, 1.0)


func modifier(c: int, key: String) -> float:
	var cache: Dictionary = _mod_cache[c]
	if cache.has(key):
		return cache[key]
	var t := 0.0
	for id in known_set[c]:
		t += float(_index[id].get("modifiers", {}).get(key, 0.0))
	cache[key] = t
	return t


func modifier_breakdown(c: int, key: String) -> Array:
	var out := []
	for id in known_set[c]:
		var v = _index[id].get("modifiers", {}).get(key, null)
		if v != null:
			out.append({"reason": "Technology: " + tech_name(id), "value": float(v)})
	return out


func building_unlocked(c: int, type_id: String) -> bool:
	if not _unlock_bld.has(type_id):
		return true
	return known_set[c].has(_unlock_bld[type_id])


func building_tech(type_id: String) -> String:
	return _unlock_bld.get(type_id, "")


func law_unlocked(c: int, opt_id: String) -> bool:
	if s.politics != null and s.politics.has_method("option_info"):
		var req = s.politics.option_info(opt_id).get("requires_tech", null)
		return req == null or known_set[c].has(req)
	return true


# --------------------------------------------------------------------------- research points
func _research_mult(c: int) -> float:
	var m := 1.0 + modifier(c, "research_mult")
	if s.politics != null and s.politics.has_method("modifier"):
		m = s.politics.modifier(c, "research_mult") + modifier(c, "research_mult")
	return maxf(0.2, m)


func points_breakdown(c: int) -> Array:
	var out: Array = [{"reason": "Scholars and administrators", "value": BASE_POINTS}]
	var clerks := 0.0
	var lit := 0.25
	if s.pops != null and s.pops.has_method("country_prof"):
		clerks = float(s.pops.country_prof(c, 3))
		lit = float(s.pops.literacy_of(c)) if s.pops.has_method("literacy_of") else 0.25
	else:
		clerks = 0.03 * 20000.0 * s.world.c_provinces[c].size()
	var cp := clerks * CLERK_RATE * (0.3 + lit)
	out.append({"reason": "Clerks (%d) at literacy %d%%" % [int(clerks), int(lit * 100.0)], "value": cp})
	var base := BASE_POINTS + cp
	var m := _research_mult(c)
	if absf(m - 1.0) > 0.001:
		out.append({"reason": "Laws and technologies (x%.2f)" % m, "value": base * (m - 1.0)})
	return out


func points_per_week(c: int) -> float:
	var clerks := 0.0
	var lit := 0.25
	if s.pops != null:
		clerks = float(s.pops.country_prof(c, 3))
		lit = float(s.pops.literacy_of(c))
	else:
		clerks = 0.03 * 20000.0 * s.world.c_provinces[c].size()
	var base := BASE_POINTS + clerks * CLERK_RATE * (0.3 + lit)
	return base * _research_mult(c)


func tick_week() -> void:
	for c in _n:
		if not s.alive[c]:
			continue
		var pts := points_per_week(c)
		var id: String = current[c]
		if id == "":
			bank[c] = minf(BANK_CAP, bank[c] + pts)
			continue
		acc[c] += pts + bank[c]
		bank[c] = 0.0
		var cost := tech_cost_for(c, id)
		if acc[c] >= cost:
			bank[c] = minf(BANK_CAP, acc[c] - cost)
			_finish(c, id)


func _finish(c: int, id: String) -> void:
	known_set[c][id] = true
	_mod_cache[c] = {}
	_know_count[id] = int(_know_count.get(id, 0)) + 1
	learned_total += 1
	current[c] = ""
	acc[c] = 0.0
	if s.has_method("log_event"):
		s.log_event(c, "tech", "%s discovers %s." % [s.world.c_short[c], tech_name(id)])
