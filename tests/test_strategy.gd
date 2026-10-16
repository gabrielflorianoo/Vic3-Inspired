extends SceneTree
## Strategy-layer tests (politics, technology, diplomacy, military, AI).
##   timeout 600 godot --headless --path . --script res://tests/test_strategy.gd
## Uses the real GameState when game_state.gd + economy.gd are present, otherwise tests/fake_state.gd.
## Exit code 0 = pass.

const WorldData := preload("res://src/world/world_data.gd")
const FakeState := preload("res://tests/fake_state.gd")

var _fail := 0
var _pass := 0
var _world
var _real := false
var _orig_owner := PackedInt32Array()
var _orig_caps := PackedInt32Array()
var _years := 5


func check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		printerr("  FAIL: ", msg)


func _init() -> void:
	_world = WorldData.load_default()
	if _world == null:
		printerr("world assets missing")
		quit(2)
		return
	_orig_owner = _world.p_owner.duplicate()
	_orig_caps = _world.c_capital.duplicate()
	_real = ResourceLoader.exists("res://src/sim/game_state.gd") and ResourceLoader.exists("res://src/sim/economy.gd")
	for a in OS.get_cmdline_user_args():
		if a == "--fake":
			_real = false
		if a.begins_with("--years="):
			_years = int(a.substr(8))
	print("mode: ", "REAL GameState" if _real else "fake state (no economy)")
	for t in [test_static_api, test_scripted_war, test_politics_actions, test_long_run, test_determinism_and_save]:
		var before := _fail
		var ms := Time.get_ticks_msec()
		t.call()
		print("%s %s (%d ms)" % ["PASS" if _fail == before else "FAIL", t.get_method(), Time.get_ticks_msec() - ms])
	print("%d checks passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# --------------------------------------------------------------------------- helpers
func _new(player: int, seed_val: int):
	if _real:
		var gs = load("res://src/sim/game_state.gd")
		return gs.new_game(_world, player, seed_val)
	return FakeState.create(_world, player, seed_val, _orig_owner, _orig_caps)


func _snap(st) -> Dictionary:
	return st.to_dict() if _real else st.snapshot()


func _restore(snap: Dictionary):
	if _real:
		var gs = load("res://src/sim/game_state.gd")
		return gs.from_dict(_world, snap)
	return FakeState.create(_world, int(snap["day"]) * 0, 1, _orig_owner, _orig_caps, snap)


func _hash(st) -> String:
	var d := _snap(st)
	var strat := {"politics": d["politics"], "tech": d["tech"], "diplo": d["diplo"], "military": d["military"], "ai": d["ai"], "owner": d["owner"], "day": d["day"]}
	return JSON.stringify(strat, "", true).sha256_text()


func _run_days(st, days: int) -> void:
	for _i in days:
		st.advance_day()


func _consistent(st) -> bool:
	var w = st.world
	var cnt := 0
	for c in w.country_count:
		for p in w.c_provinces[c]:
			if w.p_owner[p] != c:
				return false
			cnt += 1
	var owned := 0
	for p in range(1, w.province_count):
		if w.p_owner[p] >= 0:
			owned += 1
	return cnt == owned


# --------------------------------------------------------------------------- tests
func test_static_api() -> void:
	var st = _new(0, 1)
	var pol = st.politics
	var dip = st.diplo
	check(pol.ig_count() == 6, "six interest groups")
	check(pol.categories().size() == 6, "six law categories")
	for c in _world.country_count:
		var tot := 0.0
		for i in pol.ig_count():
			tot += pol.clout(c, i)
			var bd: Array = pol.approval_breakdown(c, i)
			var sum := 0.0
			for e: Dictionary in bd:
				check(e.has("reason") and e.has("value") and String(e["reason"]) != "", "breakdown entry has reason")
				sum += float(e["value"])
			check(is_equal_approx(clampf(sum, -10.0, 10.0), pol.approval(c, i)), "approval == breakdown sum (c%d ig%d)" % [c, i])
			check(is_finite(pol.approval(c, i)), "approval finite")
		check(absf(tot - 1.0) < 0.001, "clout sums to 1 (c%d: %f)" % [c, tot])
		check(pol.legitimacy(c) >= 0.0 and pol.legitimacy(c) <= 100.0, "legitimacy in range")
		check(not pol.government_igs(c).is_empty(), "government has interest groups")
		for cat in pol.categories():
			check(pol.law(c, cat) != "", "law set for %s" % cat)
		check(st.modifier(c, "tax_mult") > 0.3, "tax_mult positive")
		check(st.tech.points_per_week(c) > 0.0, "research points")
		for b in range(c + 1, _world.country_count):
			var r: int = dip.relation(c, b)
			check(r >= -100 and r <= 100 and r == dip.relation(b, c), "relation symmetric & in range")
			var s2 := 0.0
			for e: Dictionary in dip.relation_breakdown(c, b):
				s2 += float(e["value"])
			check(int(round(clampf(s2, -100.0, 100.0))) == r, "relation == breakdown sum")
	check(not st.tech.available(0).is_empty(), "techs available")
	check(st.tech.set_research(0, st.tech.available(0)[0]), "set_research ok")
	check(not st.tech.set_research(0, "general_staff"), "locked tech rejected")
	var a = st.military.army(0)
	check(a["battalions"] > 0 and a["power"] > 0.0, "country has an army")
	check(st.military.controller(5) == _world.p_owner[5], "controller == owner in peace")
	var claims_total := 0
	for c in _world.country_count:
		claims_total += dip.claims_of(c).size()
	check(claims_total > 5, "claims exist at start (%d)" % claims_total)
	print("   claims=%d alliances=%d trade=%d" % [claims_total, dip.alliances.size(), dip.trade.size()])


func _find_pair(st) -> Array:
	## [a, b, targets] with a bordering b
	for a in _world.country_count:
		for b: int in st.diplo.neighbors_of(a):
			if st.player == a or st.player == b:
				continue
			var tg: Array = st.diplo.border_provinces_of(b, a)
			if tg.size() >= 3 and not st.diplo.is_allied(a, b) and st.diplo.allies(a).is_empty() and st.diplo.allies(b).is_empty():
				return [a, b, tg]
	return []


func test_scripted_war() -> void:
	var st = _new(13, 5)
	var pair := _find_pair(st)
	check(not pair.is_empty(), "found a bordering pair")
	if pair.is_empty():
		return
	var a: int = pair[0]
	var b: int = pair[1]
	var targets := PackedInt32Array([pair[2][0], pair[2][1]])
	# Without claim and rivalry the declaration must fail with a reason.
	st.diplo.claims[a] = PackedInt32Array()
	var r: Dictionary = st.diplo.declare_war(a, b, targets)
	check(not r["ok"] and String(r["reason"]) != "", "war needs claim or rival: %s" % r["reason"])
	st.diplo.fabricate_claim(a, targets[0])
	st.diplo.claims[a].append(targets[0]); st.diplo.claims[a].append(targets[1])
	st.diplo.truces.clear()
	st.diplo.wars.clear()
	r = st.diplo.declare_war(a, b, targets)
	check(r["ok"], "declare_war with claims: %s" % r["reason"])
	check(st.diplo.at_war(a, b) and st.diplo.at_war(b, a), "at_war symmetric")
	check(not st.diplo.declare_war(a, b, targets)["ok"], "cannot declare twice")
	# Make the attacker overwhelming so the war resolves in its favour.
	st.military.bat[a] = 60.0; st.military.est[a] = 60.0
	st.military.bat[b] = 2.0; st.military.est[b] = 2.0
	var owners_before := {}
	for p in targets:
		owners_before[p] = _world.p_owner[p]
	var w0: Dictionary = st.diplo.wars[0]
	var occupied_seen := false
	var days := 0
	while not st.diplo.wars.is_empty() and days < 4 * 365:
		st.advance_day()
		days += 1
		if st.military.occupied_by(a).size() > 0:
			occupied_seen = true
			check(st.military.controller(st.military.occupied_by(a)[0]) == a, "occupied province controlled by occupier")
		# AI peace logic runs through react_wars (weekly) -- keep the attacker's military topped up.
		st.military.bat[a] = maxf(st.military.bat[a], 40.0)
	check(st.diplo.wars.is_empty(), "war ended within 4 years (%d days)" % days)
	check(occupied_seen, "provinces were occupied during the war")
	var moved := 0
	for p in targets:
		if _world.p_owner[p] != owners_before[p]:
			moved += 1
			check(_world.p_owner[p] == a, "goal went to the attacker")
	print("   war lasted %d days, goals moved: %d/%d, ws=%.0f" % [days, moved, targets.size(), w0["warscore"]])
	check(moved > 0, "peace transferred at least one goal province")
	check(_consistent(st), "ownership tables consistent after peace")
	check(st.military.occupied_by(a).is_empty() and st.military.occupied_by(b).is_empty(), "occupations cleared after peace")
	check(st.diplo.truce_days_left(a, b) > 0, "truce after war")
	check(not st.diplo.declare_war(a, b, targets)["ok"], "truce blocks new war")
	# white peace path
	st.diplo.truces.clear()
	var cl: Array = []
	for p in st.diplo.border_provinces_of(b, a):
		cl.append(p)
	if not cl.is_empty():
		st.diplo.claims[a].append(cl[0])
		r = st.diplo.declare_war(a, b, PackedInt32Array([cl[0]]))
		if r["ok"]:
			var wid: int = r["war_id"]
			st.military.bat[a] = 20.0; st.military.bat[b] = 20.0
			_run_days(st, 40)
			var o: Dictionary = st.diplo.offer_peace(wid, a, "white_peace")
			check(o.has("ok") and o.has("reason"), "offer_peace returns ok/reason")


func test_politics_actions() -> void:
	var st = _new(0, 3)
	var pol = st.politics
	# A law that needs a missing tech is rejected with a reason.
	var r: Dictionary = pol.can_enact(0, "governance", "universal_suffrage")
	check(not r["ok"] and String(r["reason"]) != "", "can_enact explains refusal: %s" % r["reason"])
	# Pick any legal change and run it through.
	var done := false
	for cat in pol.categories():
		if cat == "governance":
			continue
		for o: Dictionary in pol.options(cat):
			if o["id"] != pol.law(0, cat) and pol.can_enact(0, cat, o["id"])["ok"]:
				var rr: Dictionary = pol.start_enact(0, cat, o["id"])
				check(rr["ok"], "start_enact")
				var es: Dictionary = pol.enact_status(0)
				check(es.has("progress") and es.has("support") and es.has("chance"), "enact_status fields")
				check(not pol.start_enact(0, cat, o["id"])["ok"], "only one bill at a time")
				done = true
				break
		if done:
			break
	check(done, "found an enactable law")
	var guard := 0
	while not pol.enact_status(0).is_empty() and guard < 40:
		st.politics.s.rng.randf()
		_run_days(st, 30)
		guard += 1
	print("   bill resolved after ~%d months, laws enacted so far: %d" % [guard, pol.total_laws_enacted])
	check(pol.enact_status(0).is_empty(), "bill resolved")
	# taxation
	var lvl: int = pol.tax_level(5)
	var tr: Dictionary = pol.set_tax_level(5, 2 if lvl < 2 else 0)
	check(tr["ok"], "set_tax_level")
	check(not pol.set_tax_level(5, 1)["ok"], "tax cooldown")
	# friendly diplomacy answers
	var d = st.diplo
	var res: Dictionary = d.improve_relations(0, 6)
	check(res.has("ok") and res.has("reason"), "improve_relations result")
	for b in range(1, _world.country_count):
		var ra: Dictionary = d.propose_alliance(0, b)
		check(ra.has("ok") and ra.has("reason"), "alliance result has reason")
		if not ra["ok"]:
			check(String(ra["reason"]) != "", "refusal has reason")
		var rt: Dictionary = d.propose_trade_agreement(0, b)
		check(rt.has("ok") and rt.has("reason"), "trade result")
	check(d.declare_rival(0, 7)["ok"] or d.is_rival(0, 7) or d.rivals(0).size() >= 2, "declare_rival")


func test_long_run() -> void:
	var st = _new(0, 1)
	var wars_seen := 0
	var max_war_days := 0
	var transfers := 0
	var prev_owner: PackedInt32Array = _world.p_owner.duplicate()
	var total_days := _years * 365
	var bad_leg := 0
	var worst_rad := 0.0
	var gv := {"leg_min": 100.0, "leg_max": 0.0}
	for day in total_days:
		st.advance_day()
		if day % 30 == 0:
			var pol = st.politics
			for c in _world.country_count:
				if not st.alive[c]:
					continue
				var l: float = pol.legitimacy(c)
				gv["leg_min"] = minf(gv["leg_min"], l); gv["leg_max"] = maxf(gv["leg_max"], l)
				if l < 0.0 or l > 100.0 or not is_finite(l):
					bad_leg += 1
				for i in pol.ig_count():
					check(is_finite(pol.approval(c, i)) and absf(pol.approval(c, i)) <= 10.001, "approval finite/in range")
				worst_rad = maxf(worst_rad, st.pops.radical_share(c))
				var ex: float = st.diplo.war_exhaustion(c)
				check(ex >= 0.0 and ex <= 100.0, "exhaustion in range")
			for w: Dictionary in st.diplo.wars:
				max_war_days = maxi(max_war_days, st.day - int(w["start_day"]))
				check(w["warscore"] >= -100.0 and w["warscore"] <= 100.0, "warscore in range")
		if day % 91 == 0:
			check(_consistent(st), "ownership consistent (day %d)" % day)
	check(bad_leg == 0, "legitimacy always in 0..100")
	for p in range(1, _world.province_count):
		if _world.p_owner[p] != prev_owner[p]:
			transfers += 1
	check(st.diplo.wars.size() < 6, "not too many simultaneous wars")
	check(max_war_days <= 3 * 365 + 40, "no war outlives the cap (%d days)" % max_war_days)
	check(st.diplo.wars_started <= 12 * _years, "AI does not declare war constantly (%d wars in %d years)" % [st.diplo.wars_started, _years])
	print("   %d yrs: wars started %d / ended %d, revolutions %d, laws enacted %d, techs %d, provinces changed hands %d" % [
		_years, st.diplo.wars_started, st.diplo.wars_ended, st.politics.total_revolutions, st.politics.total_laws_enacted, st.tech.learned_total, transfers])
	print("   legitimacy range %.0f..%.0f, worst radical share %.2f, ai-declared %d, battles %d" % [gv["leg_min"], gv["leg_max"], worst_rad, st.ai.wars_declared, st.military.battles])
	var kinds := {}
	for e in st.events:
		kinds[e["kind"]] = int(kinds.get(e["kind"], 0)) + 1
	print("   events by kind: ", kinds)
	var shown := 0
	for e in st.events:
		if e["kind"] == "war" or (e["kind"] == "politics" and String(e["text"]).contains("REVOLUTION")):
			if shown < 14:
				print("     [%d] %s" % [e["day"], e["text"]])
				shown += 1
	# Every living country still has provinces; dead ones none.
	for c in _world.country_count:
		check((st.alive[c] == 1) == (_world.c_provinces[c].size() > 0), "alive flag matches provinces (c%d)" % c)
	st.dispose()


func test_determinism_and_save() -> void:
	# NOTE: all states share one WorldData (ownership is world state), so runs are strictly sequential.
	var a = _new(0, 7)
	_run_days(a, 400)
	var h400 := _hash(a)
	var json_text := JSON.stringify(_snap(a))      # through JSON text like a real save
	_run_days(a, 500)
	var ha := _hash(a)
	var da := _snap(a)
	a.dispose()
	var b = _new(0, 7)
	_run_days(b, 400)
	check(_hash(b) == h400, "same seed -> identical strategy state after 400 days")
	b.dispose()
	var snap: Dictionary = JSON.parse_string(json_text)
	var restored = _restore(snap)
	check(_hash(restored) == h400, "restored state equals original at save time")
	_run_days(restored, 500)
	var hr := _hash(restored)
	check(ha == hr, "original and restored stay identical after 500 more days")
	if ha != hr:
		var dr := _snap(restored)
		for k in ["politics", "tech", "diplo", "military", "ai"]:
			if JSON.stringify(da[k], "", true) != JSON.stringify(dr[k], "", true):
				printerr("   diverged module: ", k)
	restored.dispose()
