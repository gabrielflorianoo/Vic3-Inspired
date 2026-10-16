extends RefCounted
## Diplomacy: relations, pacts (alliance / trade / rivalry / claims), wars, peace.
## relation(a,b) is the sum of the factors in relation_breakdown(a,b) (clamped to -100..100) -- no hidden state.
## Deviation from spec: actions cost "diplomatic points" (dp, +1/month, max 20) instead of money because the
## economy has no spend API. dp(c) is exposed for the UI.

const SimUtil := preload("res://src/sim/sim_util.gd")
const MAX_ALLIES := 3
const MAX_TRADE := 4
const MAX_RIVALS := 2
const DP_CAP := 20.0
const DP_IMPROVE := 3.0
const DP_CLAIM := 6.0
const TRUCE_WHITE := 2 * 365
const TRUCE_CEDE := 4 * 365
const MAX_WAR_DAYS := 3 * 365
const PROPOSAL_LIFETIME := 90

var s
var _n := 0
var base_rel := PackedInt32Array()      # n*n symmetric historical baseline
var improve := PackedFloat32Array()     # n*n symmetric, from improve_relations
var improve_left := PackedInt32Array()  # n*n months of active improvement
var grudge := PackedFloat32Array()      # n*n symmetric, negative events (decays)
var alliances: Dictionary = {}          # key -> day formed
var trade: Dictionary = {}              # key -> day formed
var truces: Dictionary = {}             # key -> day until
var rival_list: Array = []              # Array[PackedInt32Array] rivals declared by c
var claims: Array = []                  # Array[PackedInt32Array] claimed province ids per country
var wars: Array = []                    # Array[Dictionary]
var exhaustion := PackedFloat32Array()
var dp_points := PackedFloat32Array()
var proposals: Array = []               # [{id, kind, from, to, war_id, terms, day}]
var _nbrs: Array = []                   # country -> PackedInt32Array neighbours (cached)
var _nbr_dirty := false
var next_war_id := 1
var next_proposal_id := 1
var wars_started := 0
var wars_ended := 0
var war_log: Array = []                 # [{id, attackers, defenders, start_day, end_day, result}] history (last 40)


func _key(a: int, b: int) -> int:
	return mini(a, b) * 1000 + maxi(a, b)


# --------------------------------------------------------------------------- setup / persistence
func setup(state) -> void:
	s = state
	_n = s.world.country_count
	var nn := _n * _n
	base_rel.resize(nn); improve.resize(nn); improve_left.resize(nn); grudge.resize(nn)
	exhaustion.resize(_n); dp_points.resize(_n)
	for i in nn:
		base_rel[i] = 0; improve[i] = 0.0; improve_left[i] = 0; grudge[i] = 0.0
	alliances = {}; trade = {}; truces = {}; wars = []; proposals = []; war_log = []
	rival_list = []; claims = []
	next_war_id = 1; next_proposal_id = 1; wars_started = 0; wars_ended = 0
	_refresh_neighbors()
	var rk := {"great": 0, "major": 1, "minor": 2}
	for a in _n:
		rival_list.append(PackedInt32Array())
		claims.append(PackedInt32Array())
		exhaustion[a] = 0.0
		dp_points[a] = 10.0
	for a in _n:
		for b in range(a + 1, _n):
			var ra: int = rk.get(String(s.world.c_rank[a]), 2)
			var rb: int = rk.get(String(s.world.c_rank[b]), 2)
			var v := 0
			if ra == 0 and rb == 0: v = -6
			elif ra == 0 or rb == 0: v = 4 if (ra + rb) >= 2 else -2
			else: v = 6 if (ra + rb) >= 3 else 2
			v += s.rng.randi_range(-14, 14)
			base_rel[a * _n + b] = v
			base_rel[b * _n + a] = v
	# Historical claims: each neighbouring pair has a chance of a border grievance.
	for a in _n:
		for b: int in _nb(a):
			var rel := base_rel[a * _n + b] - 6
			var chance := 0.55 if rel < 0 else 0.25
			if s.rng.randf() < chance:
				var border := _border_provinces_of(b, a)
				if not border.is_empty():
					var k := mini(border.size(), s.rng.randi_range(1, 2))
					for _i in k:
						var p: int = border[s.rng.randi() % border.size()]
						if not claims[a].has(p):
							claims[a].append(p)
	# A few starting friendships: strongest positive neighbour pairs ally, others trade.
	for a in _n:
		var best := -1
		var bv := 14
		for b: int in _nb(a):
			if b > a and base_rel[a * _n + b] > bv and _ally_count(a) < 1 and _ally_count(b) < 1:
				bv = base_rel[a * _n + b]; best = b
		if best >= 0:
			alliances[_key(a, best)] = 0
	for a in _n:
		for b: int in _nb(a):
			if b > a and relation(a, b) >= 0 and _trade_count(a) < 2 and _trade_count(b) < 2 and not is_allied(a, b):
				trade[_key(a, b)] = 0


func to_dict() -> Dictionary:
	var al := []
	for k in alliances:
		al.append([int(k), int(alliances[k])])
	var tr := []
	for k in trade:
		tr.append([int(k), int(trade[k])])
	var tc := []
	for k in truces:
		tc.append([int(k), int(truces[k])])
	var rl := []
	var cl := []
	for c in _n:
		rl.append(Array(rival_list[c]))
		cl.append(Array(claims[c]))
	var wd := []
	for w: Dictionary in wars:
		var e := w.duplicate(true)
		e["warscore"] = SimUtil.num_str(float(w["warscore"]))   # bit-exact; JSON would round doubles
		e["battle"] = SimUtil.num_str(float(w["battle"]))
		wd.append(e)
	return {"base": Array(base_rel), "improve": Array(improve), "il": Array(improve_left), "grudge": Array(grudge),
		"al": al, "tr": tr, "tc": tc, "rl": rl, "cl": cl, "wars": wd, "ex": Array(exhaustion),
		"dp": Array(dp_points), "prop": proposals.duplicate(true), "nw": next_war_id, "np": next_proposal_id,
		"ws": wars_started, "we": wars_ended, "log": war_log.duplicate(true)}


func _ints(a) -> Array:
	var out := []
	for v in a:
		out.append(int(v))
	return out


func from_dict(d: Dictionary) -> void:
	_n = s.world.country_count
	var nn := _n * _n
	base_rel = PackedInt32Array(_ints(d.get("base", [])))
	improve = PackedFloat32Array(d.get("improve", []))
	improve_left = PackedInt32Array(_ints(d.get("il", [])))
	grudge = PackedFloat32Array(d.get("grudge", []))
	exhaustion = PackedFloat32Array(d.get("ex", []))
	dp_points = PackedFloat32Array(d.get("dp", []))
	if base_rel.size() != nn: base_rel.resize(nn)
	if improve.size() != nn: improve.resize(nn)
	if improve_left.size() != nn: improve_left.resize(nn)
	if grudge.size() != nn: grudge.resize(nn)
	if exhaustion.size() != _n: exhaustion.resize(_n)
	if dp_points.size() != _n: dp_points.resize(_n)
	alliances = {}; trade = {}; truces = {}
	for e in d.get("al", []): alliances[int(e[0])] = int(e[1])
	for e in d.get("tr", []): trade[int(e[0])] = int(e[1])
	for e in d.get("tc", []): truces[int(e[0])] = int(e[1])
	rival_list = []; claims = []
	var rl: Array = d.get("rl", [])
	var cl: Array = d.get("cl", [])
	for c in _n:
		rival_list.append(PackedInt32Array(_ints(rl[c])) if c < rl.size() else PackedInt32Array())
		claims.append(PackedInt32Array(_ints(cl[c])) if c < cl.size() else PackedInt32Array())
	wars = []
	for w: Dictionary in d.get("wars", []):
		var nw := w.duplicate(true)
		nw["id"] = int(w["id"]); nw["start_day"] = int(w["start_day"])
		nw["attackers"] = _ints(w["attackers"]); nw["defenders"] = _ints(w["defenders"]); nw["goals"] = _ints(w["goals"])
		nw["warscore"] = SimUtil.parse_num(w["warscore"]); nw["battle"] = SimUtil.parse_num(w.get("battle", 0.0))
		nw["leader_a"] = int(w["leader_a"]); nw["leader_d"] = int(w["leader_d"])
		nw["cap_weeks"] = int(w.get("cap_weeks", 0))
		wars.append(nw)
	proposals = []
	for pr: Dictionary in d.get("prop", []):
		var np := pr.duplicate(true)
		for k in ["id", "from", "to", "war_id", "day"]:
			np[k] = int(pr.get(k, 0))
		proposals.append(np)
	war_log = []
	for e: Dictionary in d.get("log", []):
		var ne := e.duplicate(true)
		ne["id"] = int(e["id"]); ne["start_day"] = int(e["start_day"]); ne["end_day"] = int(e["end_day"])
		ne["attackers"] = _ints(e["attackers"]); ne["defenders"] = _ints(e["defenders"])
		war_log.append(ne)
	next_war_id = int(d.get("nw", 1)); next_proposal_id = int(d.get("np", 1))
	wars_started = int(d.get("ws", 0)); wars_ended = int(d.get("we", 0))
	_refresh_neighbors()


# --------------------------------------------------------------------------- neighbours / geography
func on_transfer(_p: int, _from: int, _to: int) -> void:
	_nbr_dirty = true


func _nb(c: int) -> PackedInt32Array:
	if _nbr_dirty:
		_refresh_neighbors()
	return _nbrs[c]


func _refresh_neighbors() -> void:
	_nbr_dirty = false
	_nbrs = []
	for c in _n:
		_nbrs.append(s.world.country_neighbors(c) if s.alive[c] else PackedInt32Array())


func neighbors_of(c: int) -> Array:
	return Array(_nb(c))


func _border_provinces_of(owner_c: int, toward: int) -> Array:
	## Provinces of owner_c adjacent to a province owned by `toward`.
	var out := []
	for p in s.world.c_provinces[owner_c]:
		for q in s.world.p_neighbors[p]:
			if s.world.p_owner[q] == toward:
				out.append(p)
				break
	return out


func border_provinces_of(owner_c: int, toward: int) -> Array:
	return _border_provinces_of(owner_c, toward)


func _province_touches(c: int, p: int) -> bool:
	## True if province p is adjacent to territory owned by c.
	for q in s.world.p_neighbors[p]:
		if s.world.p_owner[q] == c:
			return true
	return false


# --------------------------------------------------------------------------- pact queries
func is_allied(a: int, b: int) -> bool:
	return alliances.has(_key(a, b))


func has_trade_agreement(a: int, b: int) -> bool:
	return trade.has(_key(a, b))


func is_rival(a: int, b: int) -> bool:
	return rival_list[a].has(b)


func _ally_count(c: int) -> int:
	return allies(c).size()


func _trade_count(c: int) -> int:
	return trade_partners(c).size()


func allies(c: int) -> Array:
	var out := []
	for k in alliances:
		var a: int = int(k) / 1000
		var b: int = int(k) % 1000
		if a == c: out.append(b)
		elif b == c: out.append(a)
	out.sort()
	return out


func trade_partners(c: int) -> Array:
	var out := []
	for k in trade:
		var a: int = int(k) / 1000
		var b: int = int(k) % 1000
		if a == c: out.append(b)
		elif b == c: out.append(a)
	out.sort()
	return out


func rivals(c: int) -> Array:
	return Array(rival_list[c])


func claims_of(c: int) -> Array:
	return Array(claims[c])


func has_claim(c: int, p: int) -> bool:
	return claims[c].has(p)


func diplomatic_points(c: int) -> float:
	return dp_points[c]


func truce_days_left(a: int, b: int) -> int:
	return maxi(0, int(truces.get(_key(a, b), 0)) - s.day)


# --------------------------------------------------------------------------- relations
func _gov_step(c: int) -> int:
	if s.politics != null and s.politics.has_method("law") and s.politics.laws.size() == _n:
		return ["autocracy", "oligarchy", "census_suffrage", "universal_suffrage"].find(s.politics.law(c, "governance"))
	return 1


func relation_breakdown(a: int, b: int) -> Array:
	var out: Array = []
	if a == b:
		return out
	var i := a * _n + b
	out.append({"reason": "Historical ties", "value": float(base_rel[i])})
	if _nb(a).has(b):
		out.append({"reason": "Shared border", "value": -6.0})
	if is_allied(a, b):
		out.append({"reason": "Alliance", "value": 35.0})
	if has_trade_agreement(a, b):
		out.append({"reason": "Trade agreement", "value": 12.0})
	if is_rival(a, b) or is_rival(b, a):
		out.append({"reason": "Rivalry", "value": -30.0})
	if at_war(a, b):
		out.append({"reason": "At war", "value": -40.0})
	var ca := _claims_on(a, b)
	var cb := _claims_on(b, a)
	if ca > 0 or cb > 0:
		out.append({"reason": "Territorial claims (%d on %s, %d on %s)" % [ca, s.world.c_short[b], cb, s.world.c_short[a]], "value": -8.0 - 2.0 * minf(maxi(ca, cb) - 1, 3)})
	if improve[i] > 0.5:
		out.append({"reason": "Diplomatic goodwill", "value": improve[i]})
	if grudge[i] < -0.5:
		out.append({"reason": "Recent grievances", "value": grudge[i]})
	for w: Dictionary in wars:
		var sa := side_of(w, a)
		var sb := side_of(w, b)
		if sa != 0 and sa == sb:
			out.append({"reason": "Fighting the same war", "value": 8.0})
			break
	var shared := 0
	for r in rival_list[a]:
		if rival_list[b].has(r):
			shared += 1
	if shared > 0:
		out.append({"reason": "Common rival", "value": 8.0})
	var ally_of_enemy := 0
	for x in allies(a):
		if x != b and at_war(x, b):
			ally_of_enemy += 1
	for x in allies(b):
		if x != a and at_war(x, a):
			ally_of_enemy += 1
	if ally_of_enemy > 0:
		out.append({"reason": "Allied with their enemy", "value": -10.0 * minf(ally_of_enemy, 2)})
	var ga := _gov_step(a)
	var gb := _gov_step(b)
	if ga >= 0 and gb >= 0:
		var gd := absi(ga - gb)
		var iv: float = [4.0, 0.0, -4.0, -8.0][gd]
		if iv != 0.0:
			out.append({"reason": "%s government" % ("Similar" if iv > 0.0 else "Opposed"), "value": iv})
	var sum := 0.0
	for e: Dictionary in out:
		sum += float(e["value"])
	if sum > 100.0 or sum < -100.0:
		out.append({"reason": "Capped to the -100..100 range", "value": clampf(sum, -100.0, 100.0) - sum})
	return out


func relation(a: int, b: int) -> int:
	if a == b:
		return 100
	var t := 0.0
	for e: Dictionary in relation_breakdown(a, b):
		t += float(e["value"])
	return int(round(clampf(t, -100.0, 100.0)))


func _claims_on(holder: int, owner_c: int) -> int:
	var n := 0
	for p in claims[holder]:
		if s.world.p_owner[p] == owner_c:
			n += 1
	return n


# --------------------------------------------------------------------------- proposals to the player
func proposals_for(c: int) -> Array:
	var out := []
	for p: Dictionary in proposals:
		if p["to"] == c:
			out.append(p)
	return out


func _queue_proposal(kind: String, from: int, to: int, war_id: int = 0, terms: String = "") -> void:
	for p: Dictionary in proposals:
		if p["kind"] == kind and p["from"] == from and p["to"] == to and p["war_id"] == war_id:
			return
	proposals.append({"id": next_proposal_id, "kind": kind, "from": from, "to": to, "war_id": war_id, "terms": terms, "day": s.day})
	next_proposal_id += 1
	var txt := {"alliance": "proposes an alliance", "trade": "proposes a trade agreement", "peace": "offers peace (%s)" % terms}
	s.log_event(to, "diplomacy", "%s %s." % [s.world.c_name[from], txt.get(kind, kind)])


func respond_proposal(id: int, accept: bool) -> Dictionary:
	for i in proposals.size():
		var p: Dictionary = proposals[i]
		if p["id"] != id:
			continue
		proposals.remove_at(i)
		if not accept:
			return {"ok": true, "reason": "Declined."}
		match p["kind"]:
			"alliance": return _make_alliance(p["from"], p["to"])
			"trade": return _make_trade(p["from"], p["to"])
			"peace":
				var w := war_by_id(p["war_id"])
				if w.is_empty():
					return {"ok": false, "reason": "That war is over."}
				_conclude(w, p["terms"], p["from"])
				return {"ok": true, "reason": "Peace concluded."}
		return {"ok": false, "reason": "Unknown proposal."}
	return {"ok": false, "reason": "Proposal expired."}


func _is_human(c: int) -> bool:
	return s.is_player(c)


# --------------------------------------------------------------------------- friendly actions
func _basic_check(a: int, b: int) -> Dictionary:
	if a == b or a < 0 or b < 0 or a >= _n or b >= _n:
		return {"ok": false, "reason": "Invalid country."}
	if not s.alive[a] or not s.alive[b]:
		return {"ok": false, "reason": "That nation no longer exists."}
	return {"ok": true, "reason": ""}


func improve_relations(a: int, b: int) -> Dictionary:
	var r := _basic_check(a, b)
	if not r["ok"]: return r
	if at_war(a, b):
		return {"ok": false, "reason": "We are at war."}
	if dp_points[a] < DP_IMPROVE:
		return {"ok": false, "reason": "Not enough diplomatic points (need %d)." % int(DP_IMPROVE)}
	if improve_left[a * _n + b] > 0:
		return {"ok": false, "reason": "Already improving relations."}
	dp_points[a] -= DP_IMPROVE
	improve_left[a * _n + b] = 8
	improve_left[b * _n + a] = 8
	return {"ok": true, "reason": "Relations will improve over the coming months."}


func _make_alliance(a: int, b: int) -> Dictionary:
	if not (s.alive[a] and s.alive[b]):
		return {"ok": false, "reason": "A nation no longer exists."}
	alliances[_key(a, b)] = s.day
	s.log_event(a, "diplomacy", "%s and %s form an alliance." % [s.world.c_short[a], s.world.c_short[b]])
	if a != b:
		s.log_event(b, "diplomacy", "%s and %s form an alliance." % [s.world.c_short[a], s.world.c_short[b]])
	return {"ok": true, "reason": "Alliance formed."}


func _make_trade(a: int, b: int) -> Dictionary:
	trade[_key(a, b)] = s.day
	s.log_event(a, "diplomacy", "%s and %s sign a trade agreement." % [s.world.c_short[a], s.world.c_short[b]])
	s.log_event(b, "diplomacy", "%s and %s sign a trade agreement." % [s.world.c_short[a], s.world.c_short[b]])
	return {"ok": true, "reason": "Trade agreement signed."}


func can_ally(a: int, b: int) -> Dictionary:
	var r := _basic_check(a, b)
	if not r["ok"]: return r
	if is_allied(a, b): return {"ok": false, "reason": "Already allied."}
	if at_war(a, b): return {"ok": false, "reason": "We are at war."}
	if is_rival(a, b) or is_rival(b, a): return {"ok": false, "reason": "Rivals do not ally."}
	if _ally_count(a) >= MAX_ALLIES: return {"ok": false, "reason": "We have too many alliances."}
	if _ally_count(b) >= MAX_ALLIES: return {"ok": false, "reason": "They have too many alliances."}
	for x in allies(a):
		if at_war(x, b) or at_war(b, x):
			return {"ok": false, "reason": "Our ally is at war with them."}
	return {"ok": true, "reason": ""}


func propose_alliance(a: int, b: int) -> Dictionary:
	var r := can_ally(a, b)
	if not r["ok"]: return r
	var rel := relation(a, b)
	# The other side's view: needs goodwill and a reason to want a partner.
	var common := false
	for x in rival_list[b]:
		if rival_list[a].has(x): common = true
	for w: Dictionary in wars:
		if side_of(w, a) != 0 and side_of(w, a) == side_of(w, b): common = true
	var need := 30 if not common else 15
	if _is_human(b):
		_queue_proposal("alliance", a, b)
		return {"ok": true, "reason": "Proposal sent."}
	if rel < need:
		return {"ok": false, "reason": "%s refuses: relations are too poor (%d, need %d)." % [s.world.c_short[b], rel, need]}
	for x in allies(b):
		if is_rival(a, x) or is_rival(x, a):
			return {"ok": false, "reason": "%s will not ally the rival of its ally." % s.world.c_short[b]}
	return _make_alliance(a, b)


func break_alliance(a: int, b: int) -> Dictionary:
	if not is_allied(a, b):
		return {"ok": false, "reason": "Not allied."}
	alliances.erase(_key(a, b))
	grudge[a * _n + b] -= 12.0
	grudge[b * _n + a] -= 12.0
	s.log_event(a, "diplomacy", "%s ends its alliance with %s." % [s.world.c_short[a], s.world.c_short[b]])
	s.log_event(b, "diplomacy", "%s ends its alliance with %s." % [s.world.c_short[a], s.world.c_short[b]])
	return {"ok": true, "reason": "Alliance ended."}


func can_trade(a: int, b: int) -> Dictionary:
	var r := _basic_check(a, b)
	if not r["ok"]: return r
	if has_trade_agreement(a, b): return {"ok": false, "reason": "Already trading."}
	if at_war(a, b): return {"ok": false, "reason": "We are at war."}
	if _trade_count(a) >= MAX_TRADE: return {"ok": false, "reason": "We have too many trade agreements."}
	if _trade_count(b) >= MAX_TRADE: return {"ok": false, "reason": "They have too many trade agreements."}
	return {"ok": true, "reason": ""}


func propose_trade_agreement(a: int, b: int) -> Dictionary:
	var r := can_trade(a, b)
	if not r["ok"]: return r
	if _is_human(b):
		_queue_proposal("trade", a, b)
		return {"ok": true, "reason": "Proposal sent."}
	var rel := relation(a, b)
	if rel < -5:
		return {"ok": false, "reason": "%s refuses: relations are too poor (%d, need -5)." % [s.world.c_short[b], rel]}
	if is_rival(b, a) or is_rival(a, b):
		return {"ok": false, "reason": "Rivals do not trade."}
	return _make_trade(a, b)


func cancel_trade_agreement(a: int, b: int) -> Dictionary:
	if not has_trade_agreement(a, b):
		return {"ok": false, "reason": "No agreement."}
	trade.erase(_key(a, b))
	grudge[a * _n + b] -= 4.0
	grudge[b * _n + a] -= 4.0
	s.log_event(a, "diplomacy", "The trade agreement between %s and %s is cancelled." % [s.world.c_short[a], s.world.c_short[b]])
	return {"ok": true, "reason": "Agreement cancelled."}


func declare_rival(a: int, b: int) -> Dictionary:
	var r := _basic_check(a, b)
	if not r["ok"]: return r
	if is_rival(a, b): return {"ok": false, "reason": "Already a rival."}
	if is_allied(a, b): return {"ok": false, "reason": "Break the alliance first."}
	if rival_list[a].size() >= MAX_RIVALS: return {"ok": false, "reason": "Too many rivals."}
	rival_list[a].append(b)
	if has_trade_agreement(a, b):
		trade.erase(_key(a, b))
	grudge[a * _n + b] -= 6.0
	grudge[b * _n + a] -= 6.0
	s.log_event(a, "diplomacy", "%s declares %s a rival." % [s.world.c_short[a], s.world.c_short[b]])
	s.log_event(b, "diplomacy", "%s declares %s a rival." % [s.world.c_short[a], s.world.c_short[b]])
	return {"ok": true, "reason": "Rival declared."}


func drop_rival(a: int, b: int) -> Dictionary:
	var i: int = rival_list[a].find(b)
	if i < 0: return {"ok": false, "reason": "Not a rival."}
	rival_list[a].remove_at(i)
	return {"ok": true, "reason": "Rivalry ended."}


func fabricate_claim(a: int, p: int) -> Dictionary:
	if p <= 0 or p >= s.world.province_count:
		return {"ok": false, "reason": "Invalid province."}
	var b: int = s.world.p_owner[p]
	var r := _basic_check(a, b)
	if not r["ok"]: return r
	if claims[a].has(p): return {"ok": false, "reason": "We already claim it."}
	if is_allied(a, b): return {"ok": false, "reason": "Allies' land cannot be claimed."}
	if not _province_touches(a, p): return {"ok": false, "reason": "The province must border our territory."}
	if dp_points[a] < DP_CLAIM: return {"ok": false, "reason": "Not enough diplomatic points (need %d)." % int(DP_CLAIM)}
	dp_points[a] -= DP_CLAIM
	claims[a].append(p)
	grudge[a * _n + b] -= 8.0
	grudge[b * _n + a] -= 8.0
	s.log_event(a, "diplomacy", "%s fabricates a claim on %s (%s)." % [s.world.c_short[a], s.world.p_name[p], s.world.c_short[b]])
	s.log_event(b, "diplomacy", "%s claims %s." % [s.world.c_short[a], s.world.p_name[p]])
	return {"ok": true, "reason": "Claim fabricated."}


# --------------------------------------------------------------------------- wars: queries
func at_war(a: int, b: int) -> bool:
	for w: Dictionary in wars:
		var sa := side_of(w, a)
		var sb := side_of(w, b)
		if sa != 0 and sb != 0 and sa != sb:
			return true
	return false


func side_of(w: Dictionary, c: int) -> int:
	## +1 attackers, -1 defenders, 0 not involved.
	if w["attackers"].has(c): return 1
	if w["defenders"].has(c): return -1
	return 0


func wars_of(c: int) -> Array:
	var out := []
	for w: Dictionary in wars:
		if side_of(w, c) != 0:
			out.append(w)
	return out


func war_by_id(id: int) -> Dictionary:
	for w: Dictionary in wars:
		if w["id"] == id:
			return w
	return {}


func war_exhaustion(c: int) -> float:
	return exhaustion[c] if c < exhaustion.size() else 0.0


func enemies_of(c: int) -> Array:
	var out := []
	for w: Dictionary in wars:
		var sc := side_of(w, c)
		if sc == 0: continue
		for x in (w["defenders"] if sc == 1 else w["attackers"]):
			if not out.has(x): out.append(x)
	return out


func war_name(w: Dictionary) -> String:
	return "%s-%s War" % [s.world.c_adjective[w["leader_a"]], s.world.c_adjective[w["leader_d"]]]


func war_summary(war_id: int) -> String:
	var w := war_by_id(war_id)
	if w.is_empty():
		return ""
	var an := []
	for x in w["attackers"]: an.append(s.world.c_short[x])
	var dn := []
	for x in w["defenders"]: dn.append(s.world.c_short[x])
	var occ := 0
	for p in w["goals"]:
		if s.military != null and s.military.controller(p) != s.world.p_owner[p]:
			occ += 1
	return "%s: %s vs %s. Warscore %+d for the attackers; %d/%d goals occupied; %d days." % [
		war_name(w), ", ".join(an), ", ".join(dn), int(w["warscore"]), occ, w["goals"].size(), s.day - w["start_day"]]


func warscore_for(w: Dictionary, c: int) -> float:
	return w["warscore"] * side_of(w, c)


# --------------------------------------------------------------------------- declaring war
func can_declare_war(a: int, b: int, targets: PackedInt32Array) -> Dictionary:
	var r := _basic_check(a, b)
	if not r["ok"]: return r
	if at_war(a, b): return {"ok": false, "reason": "Already at war with them."}
	if is_allied(a, b): return {"ok": false, "reason": "They are our ally."}
	if truce_days_left(a, b) > 0: return {"ok": false, "reason": "A truce holds for %d more days." % truce_days_left(a, b)}
	if not _nb(a).has(b):
		var ok := false
		for x in allies(a):
			if _nb(x).has(b): ok = true
		if not ok:
			return {"ok": false, "reason": "No common border to fight on."}
	if targets.is_empty():
		return {"ok": false, "reason": "Choose at least one province as a war goal."}
	if targets.size() > 4:
		return {"ok": false, "reason": "At most 4 war goals."}
	var rival := is_rival(a, b) or is_rival(b, a)
	for p in targets:
		if p <= 0 or p >= s.world.province_count or s.world.p_owner[p] != b:
			return {"ok": false, "reason": "War goals must be provinces of the target."}
		if not claims[a].has(p) and not rival:
			return {"ok": false, "reason": "%s: no claim and no rivalry." % s.world.p_name[p]}
		if not _province_touches(a, p) and not _touches_allied(a, p):
			return {"ok": false, "reason": "%s does not border our land." % s.world.p_name[p]}
	var active := 0
	for w: Dictionary in wars:
		if w["leader_a"] == a: active += 1
	if active >= 2:
		return {"ok": false, "reason": "Already fighting two wars of aggression."}
	return {"ok": true, "reason": ""}


func _touches_allied(a: int, p: int) -> bool:
	for x in allies(a):
		if _province_touches(x, p):
			return true
	return false


func declare_war(a: int, b: int, target_provinces: PackedInt32Array) -> Dictionary:
	var r := can_declare_war(a, b, target_provinces)
	if not r["ok"]: return r
	var w := {"id": next_war_id, "attackers": [a], "defenders": [b], "goals": Array(target_provinces),
		"warscore": 0.0, "battle": 0.0, "start_day": s.day, "leader_a": a, "leader_d": b, "cap_weeks": 0}
	next_war_id += 1
	wars.append(w)
	wars_started += 1
	grudge[a * _n + b] -= 30.0
	grudge[b * _n + a] -= 30.0
	# Call in allies (an ally is never drawn against another of its allies).
	var joined_a := []
	var joined_d := []
	for x in allies(b):
		if x != a and not is_allied(x, a) and not w["defenders"].has(x) and s.alive[x]:
			w["defenders"].append(x)
			joined_d.append(x)
	for x in allies(a):
		if x != b and not is_allied(x, b) and not w["attackers"].has(x) and not w["defenders"].has(x) and s.alive[x]:
			w["attackers"].append(x)
			joined_a.append(x)
	for x in joined_a:
		grudge[x * _n + b] -= 15.0; grudge[b * _n + x] -= 15.0
	for x in joined_d:
		grudge[x * _n + a] -= 15.0; grudge[a * _n + x] -= 15.0
	var gn := []
	for p in target_provinces: gn.append(s.world.p_name[p])
	var txt := "%s declares war on %s over %s." % [s.world.c_name[a], s.world.c_name[b], ", ".join(gn)]
	for x in w["attackers"] + w["defenders"]:
		s.log_event(x, "war", txt + ("" if x == a or x == b else " %s is drawn in." % s.world.c_short[x]))
	exhaustion[a] = maxf(exhaustion[a], 0.0)
	return {"ok": true, "reason": "War declared.", "war_id": w["id"]}


# --------------------------------------------------------------------------- peace
func evaluate_peace(w: Dictionary, receiver: int, terms: String, from: int) -> Dictionary:
	## Would `receiver` (an AI) accept `terms` offered by `from`?  Returns {ok, reason}.
	var rside := side_of(w, receiver)
	var v: float = w["warscore"] * rside                # +: receiver is winning
	var ex := exhaustion[receiver]
	var age_days: int = s.day - int(w["start_day"])
	if terms == "white_peace":
		var limit := 12.0 + ex * 0.35
		if age_days > 365 and absf(w["warscore"]) < 15.0:
			limit += 15.0
		if v <= limit:
			return {"ok": true, "reason": "Accepted."}
		return {"ok": false, "reason": "%s feels it is winning (warscore %+d, exhaustion %d) and refuses." % [s.world.c_short[receiver], int(v), int(ex)]}
	# cede_goals
	var sender_att: bool = side_of(w, from) == 1
	if rside == 1 and not sender_att:
		# The defenders surrender: the attackers get what they came for.
		return {"ok": true, "reason": "Accepted."}
	if rside == -1 and sender_att:
		var goals_taken := 0
		for p in w["goals"]:
			if s.military != null and s.military.controller(p) != s.world.p_owner[p]:
				goals_taken += 1
		var all_taken: bool = goals_taken == w["goals"].size()
		if v <= -40.0 or (v <= -25.0 and ex >= 50.0) or ex >= 85.0 or (all_taken and v <= -25.0):
			return {"ok": true, "reason": "Accepted."}
		return {"ok": false, "reason": "%s refuses to cede territory (warscore against them %d, exhaustion %d)." % [s.world.c_short[receiver], int(-v), int(ex)]}
	return {"ok": false, "reason": "Those terms make no sense for this side."}


func offer_peace(war_id: int, from: int, terms: String) -> Dictionary:
	var w := war_by_id(war_id)
	if w.is_empty():
		return {"ok": false, "reason": "No such war."}
	var sf := side_of(w, from)
	if sf == 0:
		return {"ok": false, "reason": "Not a participant."}
	if terms != "white_peace" and terms != "cede_goals":
		return {"ok": false, "reason": "Unknown peace terms."}
	if s.day - int(w["start_day"]) < 30:
		return {"ok": false, "reason": "The war has only just begun."}
	var receiver: int = w["leader_d"] if sf == 1 else w["leader_a"]
	if not s.alive[receiver]:
		return {"ok": false, "reason": "Their leader no longer exists."}
	if _is_human(receiver) and not _is_human(from):
		_queue_proposal("peace", from, receiver, war_id, terms)
		return {"ok": true, "reason": "Offer sent."}
	var r := evaluate_peace(w, receiver, terms, from)
	if r["ok"]:
		_conclude(w, terms, from)
		return {"ok": true, "reason": "Peace concluded."}
	return r


func _winner_side_for(w: Dictionary, terms: String, from: int) -> int:
	if terms == "cede_goals":
		return 1
	return 0


func _conclude(w: Dictionary, terms: String, _from: int) -> void:
	var atk: Array = w["attackers"].duplicate()
	var dfn: Array = w["defenders"].duplicate()
	var result := "white peace"
	var ceded: Array = []
	if terms == "cede_goals":
		result = "attackers won"
		for p in w["goals"]:
			var old: int = s.world.p_owner[p]
			if not dfn.has(old):
				continue
			var taker: int = w["leader_a"]
			if s.military != null:
				var ctl: int = s.military.controller(p)
				if atk.has(ctl):
					taker = ctl
			if not s.alive[taker]:
				continue
			ceded.append([p, old, taker])
	wars.erase(w)
	if s.military != null and s.military.has_method("on_war_ended"):
		s.military.on_war_ended(w)
	for e in ceded:
		var p: int = e[0]
		if s.world.p_owner[p] != e[1]:
			continue
		s.transfer_province(p, e[2])
		_fix_capital(e[1])
		_drop_satisfied_claims(p, e[2])
	var days := TRUCE_CEDE if terms == "cede_goals" else TRUCE_WHITE
	for x in atk:
		for y in dfn:
			truces[_key(x, y)] = s.day + days
			if terms == "cede_goals":
				grudge[y * _n + x] -= 25.0
				grudge[x * _n + y] -= 25.0
	for x in atk:
		exhaustion[x] = maxf(0.0, exhaustion[x] - (15.0 if terms == "cede_goals" else 5.0))
	_refresh_neighbors()
	wars_ended += 1
	war_log.append({"id": w["id"], "attackers": atk, "defenders": dfn, "start_day": w["start_day"], "end_day": s.day,
		"result": result, "name": war_name(w), "ceded": ceded.size()})
	if war_log.size() > 40:
		war_log.pop_front()
	var txt := "The %s ends in %s." % [war_name(w), result]
	if not ceded.is_empty():
		var names := []
		for e in ceded: names.append(s.world.p_name[e[0]])
		txt += " Ceded: %s." % ", ".join(names)
	for x in atk + dfn:
		s.log_event(x, "war", txt)
	# Drop any queued peace proposals for this war.
	var keep := []
	for pr: Dictionary in proposals:
		if not (pr["kind"] == "peace" and pr["war_id"] == w["id"]):
			keep.append(pr)
	proposals = keep


func _fix_capital(c: int) -> void:
	if not s.alive[c]:
		return
	var cap: int = s.world.c_capital[c]
	if cap > 0 and s.world.p_owner[cap] == c:
		return
	var best := -1
	var bt := -1
	for p in s.world.c_provinces[c]:
		var t: int = s.world.p_tier[p]
		if t > bt:
			bt = t; best = p
	if best > 0:
		s.world.c_capital[c] = best


func _drop_satisfied_claims(p: int, new_owner: int) -> void:
	var i: int = claims[new_owner].find(p)
	if i >= 0:
		claims[new_owner].remove_at(i)


## Called by military (battles) to feed warscore / exhaustion.
func add_exhaustion(c: int, v: float) -> void:
	exhaustion[c] = clampf(exhaustion[c] + v, 0.0, 100.0)


func add_battle_score(war_id: int, side: int, v: float) -> void:
	for w: Dictionary in wars:
		if w["id"] == war_id:
			w["battle"] = clampf(w["battle"] + v * side, -25.0, 25.0)
			return


# --------------------------------------------------------------------------- ticks
func tick_week() -> void:
	var finished: Array = []
	for w: Dictionary in wars.duplicate():
		_prune_dead(w)
		if w["attackers"].is_empty() or w["defenders"].is_empty():
			finished.append([w, "cede_goals" if w["defenders"].is_empty() else "white_peace"])
			continue
		_update_warscore(w)
		w["battle"] = w["battle"] * 0.97
		# Exhaustion
		for side in [1, -1]:
			for x in (w["attackers"] if side == 1 else w["defenders"]):
				var tot := maxi(1, s.world.c_provinces[x].size())
				var occ := 0
				if s.military != null:
					occ = s.military.occupied_count(x) if s.military.has_method("occupied_count") else 0
				var dx := 0.30 + 2.0 * float(occ) / float(tot)
				if w["warscore"] * side < -20.0:
					dx += 0.2
				exhaustion[x] = clampf(exhaustion[x] + dx, 0.0, 100.0)
		# Total victory / forced end
		if w["warscore"] >= 99.0:
			w["cap_weeks"] += 1
		elif w["warscore"] <= -99.0:
			w["cap_weeks"] -= 1
		else:
			w["cap_weeks"] = int(w["cap_weeks"] * 0.5)
		if w["cap_weeks"] >= 4:
			finished.append([w, "cede_goals"])
		elif w["cap_weeks"] <= -4:
			finished.append([w, "white_peace"])
		elif s.day - int(w["start_day"]) > MAX_WAR_DAYS:
			finished.append([w, "white_peace"])
	for e in finished:
		if wars.has(e[0]):
			_conclude(e[0], e[1], -1)
	# Exhaustion recovers in peace.
	for c in _n:
		if exhaustion[c] > 0.0 and wars_of(c).is_empty():
			exhaustion[c] = maxf(0.0, exhaustion[c] - 1.0)
	# Expire proposals.
	var keep := []
	for pr: Dictionary in proposals:
		if s.day - int(pr["day"]) <= PROPOSAL_LIFETIME and s.alive[pr["from"]] and s.alive[pr["to"]]:
			keep.append(pr)
	proposals = keep
	if s.ai != null and s.ai.has_method("react_wars"):
		s.ai.react_wars()


func _all_goals_taken(w: Dictionary) -> bool:
	if s.military == null or w["goals"].is_empty():
		return false
	for p in w["goals"]:
		if s.world.p_owner[p] == s.military.controller(p) or not w["attackers"].has(s.military.controller(p)):
			if w["defenders"].has(s.world.p_owner[p]):
				return false
	return true


func _prune_dead(w: Dictionary) -> void:
	for key in ["attackers", "defenders"]:
		var keep := []
		for x in w[key]:
			if s.alive[x]:
				keep.append(x)
		w[key] = keep
	if not w["attackers"].is_empty() and not w["attackers"].has(w["leader_a"]):
		w["leader_a"] = w["attackers"][0]
	if not w["defenders"].is_empty() and not w["defenders"].has(w["leader_d"]):
		w["leader_d"] = w["defenders"][0]


func _update_warscore(w: Dictionary) -> void:
	if s.military == null:
		return
	var goals: Array = w["goals"]
	var goal_taken := 0
	var goals_valid := 0
	for p in goals:
		if w["defenders"].has(s.world.p_owner[p]):
			goals_valid += 1
			if w["attackers"].has(s.military.controller(p)):
				goal_taken += 1
	var ws := 0.0
	if goals_valid > 0:
		ws += 70.0 * float(goal_taken) / float(goals_valid)
	var other_def := 0
	for x in w["defenders"]:
		for p in s.world.c_provinces[x]:
			if goals.has(p): continue
			if w["attackers"].has(s.military.controller(p)):
				other_def += 1
	var lost_att := 0
	for x in w["attackers"]:
		for p in s.world.c_provinces[x]:
			if w["defenders"].has(s.military.controller(p)):
				lost_att += 1
	ws += 3.0 * other_def - 3.5 * lost_att
	ws += w["battle"]
	w["warscore"] = clampf(ws, -100.0, 100.0)


func tick_month() -> void:
	for c in _n:
		if s.alive[c]:
			dp_points[c] = minf(DP_CAP, dp_points[c] + 1.0)
	for a in _n:
		for b in range(a + 1, _n):
			var i := a * _n + b
			var j := b * _n + a
			if improve_left[i] > 0:
				improve[i] = minf(40.0, improve[i] + 4.0)
				improve_left[i] -= 1
				improve_left[j] = improve_left[i]
			elif improve[i] > 0.0:
				improve[i] = maxf(0.0, improve[i] - 1.0)
			improve[j] = improve[i]
			if grudge[i] < 0.0:
				grudge[i] = minf(0.0, grudge[i] + 0.8)
			grudge[j] = grudge[i]
	# Dead countries lose their pacts / claims; broken pacts when relations collapse.
	for c in _n:
		if not s.alive[c]:
			for x in allies(c): alliances.erase(_key(c, x))
			for x in trade_partners(c): trade.erase(_key(c, x))
			rival_list[c] = PackedInt32Array()
			claims[c] = PackedInt32Array()
	for k in alliances.keys():
		var a: int = int(k) / 1000
		var b: int = int(k) % 1000
		if relation(a, b) < -5:
			alliances.erase(k)
			s.log_event(a, "diplomacy", "The alliance of %s and %s collapses." % [s.world.c_short[a], s.world.c_short[b]])
			s.log_event(b, "diplomacy", "The alliance of %s and %s collapses." % [s.world.c_short[a], s.world.c_short[b]])
	for k in trade.keys():
		var a: int = int(k) / 1000
		var b: int = int(k) % 1000
		if at_war(a, b) or relation(a, b) < -35:
			trade.erase(k)
	# Remove stale claims (province already owned by the claimant).
	for c in _n:
		if claims[c].is_empty():
			continue
		var keep := PackedInt32Array()
		for p in claims[c]:
			if s.world.p_owner[p] != c and s.world.p_owner[p] >= 0:
				keep.append(p)
		claims[c] = keep
	_refresh_neighbors()
