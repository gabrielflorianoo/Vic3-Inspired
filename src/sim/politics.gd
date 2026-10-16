extends RefCounted
## Politics: interest groups, laws, legitimacy, unrest, revolutions, elections.
## Everything that moves approval / legitimacy is listed in *_breakdown() so the UI can explain it.
## Data: data/scenario/laws.json, interest_groups.json.  See docs/GAMEPLAY_SPEC.md.

const PROFS := ["peasant", "laborer", "machinist", "clerk", "aristocrat", "capitalist", "soldier"]
const PROF_COUNT := 7
## Fallback population shares when no population module exists (tests / early integration).
const DEFAULT_SHARE := [0.62, 0.20, 0.02, 0.03, 0.01, 0.005, 0.015]
const WEALTH := [0.6, 0.8, 1.2, 2.0, 14.0, 18.0, 1.2]
## Keys whose value is "1 + sum of offsets" (everything else is a plain sum).
const MULT_KEYS := ["tax_mult", "research_mult", "radicalism_mult"]
const REVOLT_SHARE := 0.35
const REVOLT_MONTHS := 3

var s
var _cats: Array = []            # [{id, name, months, options:[{id,name,desc,modifiers,requires_tech,franchise?,wealth_exp?}]}]
var _cat_index: Dictionary = {}  # cat id -> index
var _opt_cat: Dictionary = {}    # option id -> cat id
var _opt: Dictionary = {}        # option id -> option dict
var _igs: Array = []             # [{id,name,color(Color),supporters{profidx:w},prefs{opt:v},debt_sensitivity,war_attitude}]
var _n := 0

# Per-country state
var laws: Array = []             # Array[Dictionary cat->option]
var leg := PackedFloat32Array()
var gov_igs: Array = []          # Array[PackedInt32Array]
var clout_cache := PackedFloat32Array()
var approval_cache := PackedFloat32Array()
var enacting: Array = []         # Array[Dictionary] {} or {cat,opt,months,start_month}
var last_change: Array = []      # Array[Dictionary] cat -> month_index of last change
var radical_months := PackedInt32Array()
var rev_cooldown := PackedInt32Array()
var next_election := PackedInt32Array()
var prev_sol := PackedFloat32Array()
var revolutions := PackedInt32Array()
var laws_enacted := PackedInt32Array()
var month_counter := 0
var total_revolutions := 0
var total_laws_enacted := 0


func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("politics: missing " + path)
		return {}
	var j = JSON.parse_string(f.get_as_text())
	return j if j is Dictionary else {}


func _load_data() -> void:
	if not _cats.is_empty():
		return
	var lj := _load_json("res://data/scenario/laws.json")
	_cats = lj.get("categories", [])
	for i in _cats.size():
		var cat: Dictionary = _cats[i]
		_cat_index[cat["id"]] = i
		for o: Dictionary in cat["options"]:
			_opt_cat[o["id"]] = cat["id"]
			_opt[o["id"]] = o
	var ij := _load_json("res://data/scenario/interest_groups.json")
	_igs = []
	for g: Dictionary in ij.get("groups", []):
		var sup := {}
		for k in g["supporters"]:
			var pi := PROFS.find(k)
			if pi >= 0:
				sup[pi] = float(g["supporters"][k])
		_igs.append({"id": g["id"], "name": g["name"], "color": Color.html(g["color"]), "supporters": sup,
			"prefs": g["prefs"], "debt_sensitivity": float(g.get("debt_sensitivity", 1.0)),
			"war_attitude": float(g.get("war_attitude", 0.0))})


func setup(state) -> void:
	s = state
	_load_data()
	_n = s.world.country_count
	var ig_n := _igs.size()
	laws = []; gov_igs = []; enacting = []; last_change = []
	leg.resize(_n); radical_months.resize(_n); rev_cooldown.resize(_n)
	next_election.resize(_n); prev_sol.resize(_n); revolutions.resize(_n); laws_enacted.resize(_n)
	clout_cache.resize(_n * ig_n); approval_cache.resize(_n * ig_n)
	month_counter = 0
	for c in _n:
		laws.append(_initial_laws(c))
		gov_igs.append(PackedInt32Array())
		enacting.append({})
		last_change.append({})
		leg[c] = 55.0
		radical_months[c] = 0
		rev_cooldown[c] = 0
		next_election[c] = 0
		prev_sol[c] = _avg_sol(c)
		revolutions[c] = 0
		laws_enacted[c] = 0
	for c in _n:
		_refresh_clout(c)
		_recompute_government(c, true)
		_schedule_election(c, c * 61)
	for c in _n:
		_refresh_approval(c)
		leg[c] = clampf(_legitimacy_target(c), 20.0, 80.0)


func _initial_laws(c: int) -> Dictionary:
	var gov: String = s.world.c_gov[c]
	var rank: String = s.world.c_rank[c]
	var d := {"governance": "oligarchy", "taxation": "medium", "trade": "protectionism",
		"labor": "no_rights", "education": "none", "conscription": "volunteers"}
	match gov:
		"Constitutional Monarchy": d["governance"] = "census_suffrage"; d["education"] = "religious_schools"
		"Republic": d["governance"] = "census_suffrage"; d["trade"] = "free_trade"; d["labor"] = "basic_rights"; d["education"] = "public_schools"
		"Merchant Republic": d["governance"] = "census_suffrage"; d["trade"] = "free_trade"; d["taxation"] = "low"
		"Absolute Monarchy": d["governance"] = "autocracy"; d["education"] = "religious_schools"
		"Autocracy": d["governance"] = "autocracy"; d["conscription"] = "mass_conscription"
		"Theocratic Monarchy": d["governance"] = "autocracy"; d["education"] = "religious_schools"; d["taxation"] = "high"
		"Principality", "Duchy": d["governance"] = "oligarchy"
		"Elective Monarchy": d["governance"] = "oligarchy"; d["education"] = "religious_schools"
		"Confederation": d["governance"] = "oligarchy"; d["taxation"] = "low"; d["trade"] = "free_trade"
	if rank == "great" and gov == "Absolute Monarchy":
		d["conscription"] = "mass_conscription"
	# A little deterministic variety between otherwise similar states.
	if (c * 7 + 3) % 5 == 0 and d["trade"] == "protectionism":
		d["trade"] = "free_trade"
	return d


# --------------------------------------------------------------------------- persistence
func to_dict() -> Dictionary:
	var cd := []
	for c in _n:
		cd.append({"laws": laws[c], "leg": leg[c], "gov": Array(gov_igs[c]), "enact": enacting[c], "last": last_change[c],
			"rm": radical_months[c], "rc": rev_cooldown[c], "ne": next_election[c], "ps": prev_sol[c],
			"rev": revolutions[c], "le": laws_enacted[c]})
	return {"c": cd, "month": month_counter, "tr": total_revolutions, "tl": total_laws_enacted}


func from_dict(d: Dictionary) -> void:
	_load_data()
	_n = s.world.country_count
	var ig_n := _igs.size()
	clout_cache.resize(_n * ig_n); approval_cache.resize(_n * ig_n)
	leg.resize(_n); radical_months.resize(_n); rev_cooldown.resize(_n)
	next_election.resize(_n); prev_sol.resize(_n); revolutions.resize(_n); laws_enacted.resize(_n)
	laws = []; gov_igs = []; enacting = []; last_change = []
	month_counter = int(d.get("month", 0))
	total_revolutions = int(d.get("tr", 0))
	total_laws_enacted = int(d.get("tl", 0))
	var cd: Array = d.get("c", [])
	for c in _n:
		var e: Dictionary = cd[c] if c < cd.size() else {}
		laws.append(e.get("laws", _initial_laws(c)))
		leg[c] = float(e.get("leg", 50.0))
		var gi := PackedInt32Array()
		for v in e.get("gov", []):
			gi.append(int(v))
		gov_igs.append(gi)
		var en: Dictionary = e.get("enact", {})
		if en.has("months"):
			en["months"] = int(en["months"])
		enacting.append(en)
		var lc: Dictionary = e.get("last", {})
		for k in lc:
			lc[k] = int(lc[k])
		last_change.append(lc)
		radical_months[c] = int(e.get("rm", 0))
		rev_cooldown[c] = int(e.get("rc", 0))
		next_election[c] = int(e.get("ne", 0))
		prev_sol[c] = float(e.get("ps", 8.0))
		revolutions[c] = int(e.get("rev", 0))
		laws_enacted[c] = int(e.get("le", 0))
	for c in _n:
		_refresh_clout(c)
	for c in _n:
		_refresh_approval(c)


# --------------------------------------------------------------------------- simple queries
func ig_count() -> int:
	return _igs.size()


func ig_name(i: int) -> String:
	return _igs[i]["name"]


func ig_id(i: int) -> String:
	return _igs[i]["id"]


func ig_color(i: int) -> Color:
	return _igs[i]["color"]


func ig_prefs(i: int) -> Dictionary:
	return _igs[i]["prefs"]


func ig_supporters(i: int) -> Dictionary:
	## {profession name: weight}
	var out := {}
	for pi in _igs[i]["supporters"]:
		out[PROFS[pi]] = _igs[i]["supporters"][pi]
	return out


func categories() -> Array:
	## Array of category ids (String).
	var out := []
	for c: Dictionary in _cats:
		out.append(c["id"])
	return out


func category_name(cat: String) -> String:
	return _cats[_cat_index[cat]]["name"] if _cat_index.has(cat) else cat


func options(cat: String) -> Array:
	## Array of option dictionaries {id, name, desc, modifiers, requires_tech}.
	return _cats[_cat_index[cat]]["options"] if _cat_index.has(cat) else []


func option_name(_cat: String, opt: String) -> String:
	return _opt[opt]["name"] if _opt.has(opt) else opt


func option_info(opt: String) -> Dictionary:
	return _opt.get(opt, {})


func law(c: int, cat: String) -> String:
	return laws[c].get(cat, "")


func law_name(c: int, cat: String) -> String:
	return option_name(cat, law(c, cat))


func tax_level(c: int) -> int:
	match law(c, "taxation"):
		"low": return 0
		"high": return 2
	return 1


func government_name(c: int) -> String:
	return option_name("governance", law(c, "governance"))


func legitimacy(c: int) -> float:
	return leg[c]


func unrest(c: int) -> float:
	if s.pops != null and s.pops.has_method("radical_share"):
		return float(s.pops.radical_share(c))
	return 0.0


func clout(c: int, ig: int) -> float:
	## Share of political strength, 0..1 (sums to 1 over interest groups).
	return clout_cache[c * _igs.size() + ig]


func approval(c: int, ig: int) -> float:
	## Always equals the sum of approval_breakdown (computed live; the monthly cache is only for legitimacy).
	var t := 0.0
	for e: Dictionary in approval_breakdown(c, ig, false):
		t += float(e["value"])
	return clampf(t, -10.0, 10.0)


func in_government(c: int, ig: int) -> bool:
	return gov_igs[c].has(ig)


func government_igs(c: int) -> Array:
	return Array(gov_igs[c])


func months_since_change(c: int, cat: String) -> int:
	return month_counter - int(last_change[c].get(cat, -999))


# --------------------------------------------------------------------------- modifiers
func modifier(c: int, key: String) -> float:
	var t := 0.0
	for e: Dictionary in modifier_breakdown(c, key):
		t += float(e["value"])
	return t + (1.0 if key in MULT_KEYS else 0.0)


func modifier_breakdown(c: int, key: String) -> Array:
	## Offsets that make up modifier(c,key) (for *_mult keys the base 1.0 is not listed).
	var out: Array = []
	for cat: Dictionary in _cats:
		var o: Dictionary = _opt.get(laws[c].get(cat["id"], ""), {})
		var v = o.get("modifiers", {}).get(key, null)
		if v != null and absf(float(v)) > 0.00001:
			out.append({"reason": "%s: %s" % [cat["name"], o["name"]], "value": float(v)})
	if key == "tax_mult" and leg[c] < 50.0:
		out.append({"reason": "Low legitimacy (%d) weakens tax collection" % int(leg[c]), "value": -(50.0 - leg[c]) / 50.0 * 0.4})
	if key == "radicalism_mult" and leg[c] < 30.0:
		out.append({"reason": "Illegitimate government (%d) breeds radicalism" % int(leg[c]), "value": (30.0 - leg[c]) / 30.0 * 0.25})
	return out


# --------------------------------------------------------------------------- pop helpers (tolerant)
func _prof_count(c: int, prof: int) -> float:
	if s.pops != null and s.pops.has_method("country_prof"):
		return float(s.pops.country_prof(c, prof))
	return DEFAULT_SHARE[prof] * 20000.0 * s.world.c_provinces[c].size()


func _avg_sol(c: int) -> float:
	if s.pops != null and s.pops.has_method("avg_sol"):
		return float(s.pops.avg_sol(c))
	return 8.0


func _literacy(c: int) -> float:
	if s.pops != null and s.pops.has_method("literacy_of"):
		return float(s.pops.literacy_of(c))
	return 0.25


## Weighted (by supporters' numbers) average of a per-cohort array for one interest group.
func _ig_cohort_avg(c: int, ig: int, arr_name: String, fallback: float) -> float:
	if s.pops == null:
		return fallback
	var arr_v: Variant = s.pops.get(arr_name)
	var size_v: Variant = s.pops.get("size")
	if not (arr_v is PackedFloat64Array) or not (size_v is PackedFloat64Array):
		return fallback
	var arr: PackedFloat64Array = arr_v   # typed locals: Variant indexing in this hot loop is ~10x slower
	var size: PackedFloat64Array = size_v
	var num := 0.0
	var den := 0.0
	var sup: Dictionary = _igs[ig]["supporters"]
	var keys: Array = sup.keys()
	var n := size.size()
	for p: int in s.world.c_provinces[c]:
		for pi: int in keys:
			var idx: int = p * PROF_COUNT + pi
			if idx >= n:
				continue
			var w: float = size[idx] * float(sup[pi])
			num += w * arr[idx]
			den += w
	return num / den if den > 0.0 else fallback


func _in_debt(c: int) -> bool:
	return s.econ != null and s.econ.has_method("in_debt") and bool(s.econ.in_debt(c))


func _exhaustion(c: int) -> float:
	return float(s.diplo.war_exhaustion(c)) if s.diplo != null and s.diplo.has_method("war_exhaustion") else 0.0


func _war_count(c: int) -> int:
	return s.diplo.wars_of(c).size() if s.diplo != null and s.diplo.has_method("wars_of") else 0


# --------------------------------------------------------------------------- clout
func clout_breakdown(c: int, ig: int) -> Array:
	## Contribution of each profession to this group's raw strength.
	var out: Array = []
	var gov: Dictionary = _opt[laws[c]["governance"]]
	var fr: Dictionary = gov["franchise"]
	var we := float(gov.get("wealth_exp", 1.0))
	var sup: Dictionary = _igs[ig]["supporters"]
	for pi in sup:
		var n := _prof_count(c, pi)
		var v: float = n * float(sup[pi]) * pow(WEALTH[pi], we) * float(fr.get(PROFS[pi], 0.05))
		if pi == 3:  # literate clerks: literacy lifts influence
			v *= 0.5 + _literacy(c)
		out.append({"reason": "%s: %d people x weight %.2f x vote %.2f" % [PROFS[pi], int(n), sup[pi], fr.get(PROFS[pi], 0.05)], "value": v})
	return out


func _refresh_clout(c: int) -> void:
	# Same formula as clout_breakdown, without building the explanation strings (this runs monthly
	# for every country); per-profession counts and literacy are gathered once, not per group.
	var ig_n := _igs.size()
	var gov: Dictionary = _opt[laws[c]["governance"]]
	var fr: Dictionary = gov["franchise"]
	var we := float(gov.get("wealth_exp", 1.0))
	var counts := PackedFloat64Array()
	counts.resize(PROFS.size())
	for pi in PROFS.size():
		counts[pi] = _prof_count(c, pi)
	var lit_mult := 0.5 + _literacy(c)
	var raw := PackedFloat32Array()
	raw.resize(ig_n)
	var tot := 0.0
	for i in ig_n:
		var v := 0.0
		var sup: Dictionary = _igs[i]["supporters"]
		for pi in sup:
			var x: float = counts[pi] * float(sup[pi]) * pow(WEALTH[pi], we) * float(fr.get(PROFS[pi], 0.05))
			if pi == 3:
				x *= lit_mult
			v += x
		raw[i] = v
		tot += v
	for i in ig_n:
		clout_cache[c * ig_n + i] = raw[i] / tot if tot > 0.0 else 1.0 / ig_n


# --------------------------------------------------------------------------- approval
func approval_breakdown(c: int, ig: int, text := true) -> Array:
	## Every factor behind approval(c, ig): [{reason, value}], summing to approval (clamped to -10..10).
	## text=false skips building the reason strings (monthly refresh only needs the numbers).
	var out: Array = []
	var g: Dictionary = _igs[ig]
	var prefs: Dictionary = g["prefs"]
	for cat: Dictionary in _cats:
		var oid: String = laws[c][cat["id"]]
		var pv := float(prefs.get(oid, 0.0))
		if pv != 0.0:
			out.append({"reason": ("%s %s (%s)" % ["Likes" if pv > 0.0 else "Dislikes", _opt[oid]["name"], cat["name"]]) if text else "", "value": pv})
	# Standard of living of the group's own supporters
	var asol := _avg_sol(c)
	var gsol := _ig_cohort_avg(c, ig, "sol", asol)
	var sol_term := clampf((gsol - 8.0) * 0.3, -2.5, 2.5)
	if absf(sol_term) > 0.01:
		out.append({"reason": ("Supporters' standard of living is %.1f (%s 8.0 baseline)" % [gsol, "above" if gsol >= 8.0 else "below"]) if text else "", "value": sol_term})
	var dsol := asol - prev_sol[c]
	var trend := clampf(dsol * 2.0, -2.0, 2.0)
	if absf(trend) > 0.01:
		out.append({"reason": ("Standard of living %s over the last month (%+.2f)" % ["rising" if dsol > 0.0 else "falling", dsol]) if text else "", "value": trend})
	var rad := _ig_cohort_avg(c, ig, "radicalism", 0.0)
	if rad > 0.05:
		out.append({"reason": ("Radical supporters (%d%% radicalism)" % int(rad * 100.0)) if text else "", "value": -rad * 4.0})
	if in_government(c, ig):
		out.append({"reason": "Part of the ruling coalition", "value": 2.0})
	elif clout(c, ig) > 0.15:
		out.append({"reason": "Powerful but excluded from government", "value": -1.0})
	if _in_debt(c):
		out.append({"reason": "State is in debt", "value": -1.0 * float(g["debt_sensitivity"])})
	var ex := _exhaustion(c)
	if ex > 5.0:
		out.append({"reason": ("War exhaustion (%d)" % int(ex)) if text else "", "value": -ex / 25.0 * (1.5 if g["war_attitude"] < 0.0 else 0.7)})
	var wc := _war_count(c)
	if wc > 0 and float(g["war_attitude"]) != 0.0:
		out.append({"reason": ("%s the ongoing war" % ("Supports" if g["war_attitude"] > 0.0 else "Opposes")) if text else "", "value": float(g["war_attitude"]) * minf(wc, 2)})
	var sum := 0.0
	for e: Dictionary in out:
		sum += float(e["value"])
	if sum > 10.0 or sum < -10.0:
		out.append({"reason": "Capped to the -10..10 range", "value": clampf(sum, -10.0, 10.0) - sum})
	return out


func _refresh_approval(c: int) -> void:
	var ig_n := _igs.size()
	for i in ig_n:
		var t := 0.0
		for e: Dictionary in approval_breakdown(c, i, false):
			t += float(e["value"])
		approval_cache[c * ig_n + i] = clampf(t, -10.0, 10.0)


# --------------------------------------------------------------------------- legitimacy
func legitimacy_breakdown(c: int) -> Array:
	## Target legitimacy factors; legitimacy moves toward the sum by up to 2 points a month.
	var out: Array = [{"reason": "Baseline", "value": 40.0}]
	var wsum := 0.0
	var wt := 0.0
	for i in gov_igs[c]:
		wsum += approval_cache[c * _igs.size() + i] * clout(c, i)
		wt += clout(c, i)
	if wt > 0.0:
		out.append({"reason": "Ruling groups' approval (%+.1f weighted)" % (wsum / wt), "value": wsum / wt * 2.0})
	if _in_debt(c):
		out.append({"reason": "State debt", "value": -10.0})
	var ex := _exhaustion(c)
	if ex > 0.0:
		out.append({"reason": "War exhaustion (%d)" % int(ex), "value": -ex * 0.3})
	var un := unrest(c)
	if un > 0.05:
		out.append({"reason": "Unrest (%d%% radicals)" % int(un * 100.0), "value": -un * 40.0})
	var sol := _avg_sol(c)
	if absf(sol - 8.0) > 0.3:
		out.append({"reason": "National standard of living %.1f" % sol, "value": clampf((sol - 8.0) * 1.2, -8.0, 8.0)})
	return out


func _legitimacy_target(c: int) -> float:
	var t := 0.0
	for e: Dictionary in legitimacy_breakdown(c):
		t += float(e["value"])
	return clampf(t, 0.0, 100.0)


# --------------------------------------------------------------------------- government / elections
func _pick_government(c: int) -> PackedInt32Array:
	var idx: Array = range(_igs.size())
	idx.sort_custom(func(a, b): return clout(c, a) > clout(c, b) or (clout(c, a) == clout(c, b) and a < b))
	var out := PackedInt32Array()
	var cum := 0.0
	for i in idx:
		out.append(i)
		cum += clout(c, i)
		if cum >= 0.5 or out.size() >= 3:
			break
	return out


func _recompute_government(c: int, force: bool) -> void:
	var nw := _pick_government(c)
	var old: PackedInt32Array = gov_igs[c]
	if not force and not old.is_empty() and old.has(nw[0]):
		return
	gov_igs[c] = nw
	if not force and nw != old and s.has_method("log_event"):
		var names := []
		for i in nw:
			names.append(ig_name(i))
		s.log_event(c, "politics", "%s: new ruling coalition: %s." % [s.world.c_short[c], ", ".join(names)])


func _is_electoral(c: int) -> bool:
	var g: String = laws[c]["governance"]
	return g == "census_suffrage" or g == "universal_suffrage"


func _schedule_election(c: int, offset: int) -> void:
	next_election[c] = s.day + 4 * 365 + offset


func _run_election(c: int) -> void:
	_refresh_clout(c)
	var old: PackedInt32Array = gov_igs[c]
	_recompute_government(c, true)
	var names := []
	for i in gov_igs[c]:
		names.append(ig_name(i))
	if s.has_method("log_event"):
		s.log_event(c, "politics", "General election in %s: %s form the government%s." % [
			s.world.c_short[c], ", ".join(names), "" if gov_igs[c] != old else " (unchanged)"])
	_schedule_election(c, 0)


# --------------------------------------------------------------------------- enacting laws
func can_enact(c: int, cat: String, opt: String) -> Dictionary:
	if not _cat_index.has(cat):
		return {"ok": false, "reason": "Unknown law category."}
	if not _opt.has(opt) or _opt_cat[opt] != cat:
		return {"ok": false, "reason": "Unknown law option."}
	if laws[c][cat] == opt:
		return {"ok": false, "reason": "Already in force."}
	if not enacting[c].is_empty():
		return {"ok": false, "reason": "Another law is already being debated."}
	var req = _opt[opt].get("requires_tech", null)
	if req != null and s.tech != null and s.tech.has_method("is_known") and not s.tech.is_known(c, req):
		return {"ok": false, "reason": "Requires the technology %s." % (s.tech.tech_name(req) if s.tech.has_method("tech_name") else str(req))}
	if months_since_change(c, cat) < 12:
		return {"ok": false, "reason": "This law changed recently; wait %d more months." % (12 - months_since_change(c, cat))}
	if leg[c] < 15.0 and cat == "governance":
		return {"ok": false, "reason": "The government is too weak to reform the constitution."}
	# Direct jumps of more than one governance step are too much for one bill.
	if cat == "governance":
		var order := ["autocracy", "oligarchy", "census_suffrage", "universal_suffrage"]
		if absi(order.find(opt) - order.find(laws[c][cat])) > 1:
			return {"ok": false, "reason": "Constitutions change one step at a time."}
	return {"ok": true, "reason": ""}


func start_enact(c: int, cat: String, opt: String) -> Dictionary:
	var r := can_enact(c, cat, opt)
	if not r["ok"]:
		return r
	enacting[c] = {"cat": cat, "opt": opt, "months": 0}
	if s.has_method("log_event"):
		s.log_event(c, "politics", "%s begins debating: %s." % [s.world.c_short[c], option_name(cat, opt)])
	return {"ok": true, "reason": ""}


func cancel_enact(c: int) -> void:
	enacting[c] = {}


func _support_for(c: int, cat: String, opt: String) -> float:
	## Clout share of groups that prefer the new option to the current one (indifferent groups count half).
	var cur: String = laws[c][cat]
	var sup := 0.0
	for i in _igs.size():
		var pr: Dictionary = _igs[i]["prefs"]
		var d := float(pr.get(opt, 0.0)) - float(pr.get(cur, 0.0))
		var w := clout(c, i)
		if d > 0.0:
			sup += w
		elif d == 0.0:
			sup += w * 0.5
	return sup


func _enact_chance(c: int, support: float, cat: String) -> float:
	var ch := 0.05 + support * 0.8
	if laws[c]["governance"] == "autocracy":
		ch += 0.1
	if cat == "governance":
		ch *= 0.8
	return clampf(ch, 0.02, 0.95)


func enact_status(c: int) -> Dictionary:
	var e: Dictionary = enacting[c]
	if e.is_empty():
		return {}
	var base: int = int(_cats[_cat_index[e["cat"]]]["months"])
	var support := _support_for(c, e["cat"], e["opt"])
	return {"cat": e["cat"], "opt": e["opt"], "progress": clampf(float(e["months"]) / float(base), 0.0, 1.0),
		"months": e["months"], "months_needed": base, "support": support, "chance": _enact_chance(c, support, e["cat"])}


func set_tax_level(c: int, level: int) -> Dictionary:
	## Taxation is the one law that can be changed at once (cooldown 6 months).
	var opt: String = ["low", "medium", "high"][clampi(level, 0, 2)]
	if laws[c]["taxation"] == opt:
		return {"ok": true, "reason": "Unchanged."}
	if months_since_change(c, "taxation") < 6:
		return {"ok": false, "reason": "Taxes were changed recently."}
	if opt == "high" and leg[c] < 20.0:
		return {"ok": false, "reason": "A government this weak cannot raise taxes."}
	_set_law(c, "taxation", opt, false)
	return {"ok": true, "reason": ""}


func _set_law(c: int, cat: String, opt: String, announce: bool) -> void:
	laws[c][cat] = opt
	last_change[c][cat] = month_counter
	if cat == "governance":
		_refresh_clout(c)
		_recompute_government(c, true)
		if _is_electoral(c):
			_schedule_election(c, 0)
	if announce and s.has_method("log_event"):
		s.log_event(c, "politics", "%s enacts %s (%s)." % [s.world.c_short[c], option_name(cat, opt), category_name(cat)])


# --------------------------------------------------------------------------- monthly tick
func tick_month() -> void:
	month_counter += 1
	for c in _n:
		if not s.alive[c]:
			continue
		_refresh_clout(c)
		if rev_cooldown[c] > 0:
			rev_cooldown[c] -= 1
		_tick_enact(c)
		if _is_electoral(c):
			if s.day >= next_election[c]:
				_run_election(c)
		elif month_counter % 12 == (c % 12):
			_recompute_government(c, false)
		_refresh_approval(c)
		_tick_legitimacy(c)
		_tick_unrest(c)
		prev_sol[c] = _avg_sol(c)


func _tick_enact(c: int) -> void:
	var e: Dictionary = enacting[c]
	if e.is_empty():
		return
	e["months"] = int(e["months"]) + 1
	var base: int = int(_cats[_cat_index[e["cat"]]]["months"])
	if e["months"] < base:
		return
	var ch := _enact_chance(c, _support_for(c, e["cat"], e["opt"]), e["cat"])
	if s.rng.randf() < ch:
		_set_law(c, e["cat"], e["opt"], true)
		laws_enacted[c] += 1
		total_laws_enacted += 1
		enacting[c] = {}
	elif e["months"] >= base + 6:
		if s.has_method("log_event"):
			s.log_event(c, "politics", "The bill for %s fails in %s." % [option_name(e["cat"], e["opt"]), s.world.c_short[c]])
		last_change[c][e["cat"]] = month_counter - 6  # short cool-down
		enacting[c] = {}


func _tick_legitimacy(c: int) -> void:
	var tgt := _legitimacy_target(c)
	var d := clampf(tgt - leg[c], -2.0, 2.0)
	leg[c] = clampf(leg[c] + d, 0.0, 100.0)
	if leg[c] < 15.0 and d < 0.0 and month_counter % 6 == c % 6 and s.has_method("log_event"):
		s.log_event(c, "politics", "The regime of %s is collapsing; legitimacy is only %d." % [s.world.c_short[c], int(leg[c])])


func revolt_threshold(c: int) -> float:
	## Radicalism that starts a revolution countdown: 0.35, down to 0.23 for an illegitimate regime.
	return REVOLT_SHARE - clampf((50.0 - leg[c]) / 50.0, 0.0, 1.0) * 0.12


func _tick_unrest(c: int) -> void:
	var rs := unrest(c)
	if rs > revolt_threshold(c):
		radical_months[c] += 1
	else:
		radical_months[c] = maxi(0, radical_months[c] - 1)
	var coup := leg[c] < 10.0 and rs > 0.20
	if (radical_months[c] >= REVOLT_MONTHS or coup) and rev_cooldown[c] == 0 and s.world.c_provinces[c].size() > 1:
		var chance := 0.15 + clampf((rs - revolt_threshold(c)) / 0.3, 0.0, 1.0) * 0.25 + (0.1 if coup else 0.0)
		if s.rng.randf() < chance:
			_revolution(c)


func _prov_radicalism(p: int) -> float:
	var arr = s.pops.get("radicalism") if s.pops != null else null
	var size = s.pops.get("size") if s.pops != null else null
	if arr == null or size == null:
		return s.rng.randf()
	var num := 0.0
	var den := 0.0
	for pi in PROF_COUNT:
		var idx := p * PROF_COUNT + pi
		if idx < size.size():
			num += float(size[idx]) * float(arr[idx])
			den += float(size[idx])
	return num / den if den > 0.0 else 0.0


func _calm_pops(c: int, factor: float) -> void:
	var arr = s.pops.get("radicalism") if s.pops != null else null
	if arr == null:
		return
	for p in s.world.c_provinces[c]:
		for pi in PROF_COUNT:
			var idx: int = p * PROF_COUNT + pi
			if idx < arr.size():
				arr[idx] = float(arr[idx]) * factor


func _revolution(c: int) -> void:
	revolutions[c] += 1
	total_revolutions += 1
	rev_cooldown[c] = 24
	radical_months[c] = 0
	var name: String = s.world.c_short[c]
	var provs: PackedInt32Array = s.world.c_provinces[c]
	var r: float = s.rng.randf()
	var done := false
	if r < 0.55 and provs.size() >= 3:
		# Rebel provinces break away to a neighbouring state.
		var cand: Array = []
		for p in provs:
			if p == s.world.c_capital[c]:
				continue
			cand.append([_prov_radicalism(p), p])
		cand.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
		var take := 1 if provs.size() < 12 else 2
		var moved: Array = []
		for k in mini(take, cand.size()):
			var p: int = cand[k][1]
			var targets: Array = []
			for q in s.world.p_neighbors[p]:
				var o: int = s.world.p_owner[q]
				if o >= 0 and o != c and not targets.has(o):
					targets.append(o)
			if targets.is_empty():
				continue
			targets.sort()
			var to: int = targets[s.rng.randi() % targets.size()]
			moved.append(s.world.p_name[p])
			s.transfer_province(p, to)
			if s.has_method("log_event"):
				s.log_event(to, "politics", "Rebels in %s (%s) declare for %s." % [s.world.p_name[p], name, s.world.c_short[to]])
		if not moved.is_empty():
			done = true
			s.log_event(c, "politics", "REVOLUTION in %s! Rebels seize %s and join neighbouring states." % [name, ", ".join(moved)])
	if not done:
		_flip_government(c)
	_calm_pops(c, 0.6)
	leg[c] = maxf(leg[c], 40.0)
	enacting[c] = {}
	for i in _igs.size():
		pass
	_refresh_clout(c)
	_refresh_approval(c)


func _flip_government(c: int) -> void:
	var order := ["autocracy", "oligarchy", "census_suffrage", "universal_suffrage"]
	var cur := order.find(laws[c]["governance"])
	var radical := 0.0
	var reactionary := 0.0
	for i in _igs.size():
		var id: String = _igs[i]["id"]
		if id == "intelligentsia" or id == "trade_unions":
			radical += clout(c, i)
		elif id == "landowners" or id == "clergy_military":
			reactionary += clout(c, i)
	var step := 1 if radical >= reactionary * 0.6 else -1
	var nw := clampi(cur + step, 0, 3)
	var name: String = s.world.c_short[c]
	if nw == cur:
		step = -step
		nw = clampi(cur + step, 0, 3)
	_set_law(c, "governance", order[nw], false)
	if radical >= reactionary * 0.6 and laws[c]["labor"] == "no_rights":
		_set_law(c, "labor", "basic_rights", false)
	s.log_event(c, "politics", "REVOLUTION in %s! The old order falls: %s replaces %s." % [name, option_name("governance", order[nw]), option_name("governance", order[cur])])
