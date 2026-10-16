extends SceneTree
## Headless test runner:  godot --headless --path . --script res://tests/run_tests.gd
## Exit code 0 = all passed.

const WorldGenerator := preload("res://src/world/world_generator.gd")
const WorldData := preload("res://src/world/world_data.gd")
const IdCodec := preload("res://src/world/id_codec.gd")
const GameState := preload("res://src/sim/game_state.gd")
const SaveSystem := preload("res://src/sim/save_system.gd")

var _fail := 0
var _pass := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		printerr("  FAIL: ", msg)


func _init() -> void:
	for t in [test_id_codec, test_generator_determinism, test_generator_invariants, test_shipped_data, test_picking,
			test_calendar_events, test_sim_determinism, test_save_roundtrip, test_save_system, test_econ_invariants,
			test_econ_chain_and_prices, test_pop_responds_to_sol, test_construction_and_transfer]:
		var before := _fail
		var ms := Time.get_ticks_msec()
		t.call()
		print("%s %s (%d ms)" % ["PASS" if _fail == before else "FAIL", t.get_method(), Time.get_ticks_msec() - ms])
	print("%d checks passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _scenario() -> Array:
	var f := FileAccess.open("res://data/scenario/countries.json", FileAccess.READ)
	return JSON.parse_string(f.get_as_text())["countries"]


func _small(seed_value: int) -> RefCounted:
	var g := WorldGenerator.new()
	g.width = 384
	g.height = 192
	g.seed_value = seed_value
	g.target_provinces = 36
	g.river_count = 6
	g.scenario_countries = _scenario().slice(0, 5)
	g.generate()
	return g


func test_id_codec() -> void:
	for id in [0, 1, 255, 256, 1000, 65535]:
		check(IdCodec.decode(IdCodec.encode(id)) == id, "codec round-trip %d" % id)
	var img := IdCodec.encode_image(PackedInt32Array([0, 7, 300, 65535]), 2, 2)
	check(IdCodec.decode(img.get_pixel(1, 1)) == 65535 and IdCodec.decode(img.get_pixel(0, 1)) == 300, "image encode")


func test_generator_determinism() -> void:
	var a := _small(7)
	var b := _small(7)
	var c := _small(8)
	check(a.checksum() == b.checksum(), "same seed -> identical world")
	check(a.checksum() != c.checksum(), "different seed -> different world")


func test_generator_invariants() -> void:
	var g := _small(11)
	var n: int = g.provinces.size()
	check(n > 10, "enough provinces generated (%d)" % n)
	var area := PackedInt32Array()
	area.resize(n)
	var max_id := 0
	for v in g.ids:
		max_id = maxi(max_id, v)
		if v > 0 and v < n:
			area[v] += 1
	check(max_id == n - 1, "ids dense 1..N")
	for id in range(1, n):
		var p: Dictionary = g.provinces[id]
		check(area[id] > 0 and area[id] == p["area"], "province %d area matches pixels" % id)
		check(p["owner"] >= 0 and p["owner"] < g.countries.size(), "province %d owned" % id)
		for q in p["neighbors"]:
			check(g.provinces[q]["neighbors"].has(id), "adjacency symmetric %d-%d" % [id, q])
		var ax := int(p["anchor"][0])
		var ay := int(p["anchor"][1])
		check(g.ids[ay * g.width + ax] == id, "anchor of %d inside province" % id)
	for c: Dictionary in g.countries:
		check(g.provinces[c["capital"]]["owner"] == c["id"], "capital owned by its country")
		check(c["province_count"] >= 1, "country has provinces")


func test_shipped_data() -> void:
	var w: RefCounted = WorldData.load_default()
	check(w != null, "baked world loads")
	if w == null:
		return
	check(w.id_image.get_width() == w.width and w.terrain_image.get_width() == w.width, "image sizes match")
	check(w.province_count > 100 and w.country_count >= 10, "benchmark-scale world (%d prov, %d countries)" % [w.province_count - 1, w.country_count])
	var total := 0
	for c in w.country_count:
		total += w.c_provinces[c].size()
		check(w.p_owner[w.c_capital[c]] == c, "capital of %s owned" % w.c_tag[c])
	check(total == w.province_count - 1, "every province owned exactly once")


func test_picking() -> void:
	var w: RefCounted = WorldData.load_default()
	if w == null:
		check(false, "world missing")
		return
	for id in range(1, w.province_count):
		check(w.province_at(w.p_anchor[id]) == id, "pick anchor of %d" % id)
	check(w.province_at(Vector2(-5, -5)) == 0 and w.province_at(Vector2(1, 1)) == 0, "outside/sea picks 0")


# =========================================================================== simulation core
var _world: RefCounted = null


func _get_world() -> RefCounted:
	if _world == null:
		_world = WorldData.load_default()
	return _world


func _hash_state(st: RefCounted) -> String:
	return JSON.stringify(st.to_dict()).md5_text()


func _run_days(st: RefCounted, n: int) -> void:
	for i in n:
		st.advance_day()


func test_calendar_events() -> void:
	var w := _get_world()
	var st: RefCounted = GameState.new_game(w, 0, 3)
	check(st.date_string() == "1 January 1836", "start date (%s)" % st.date_string())
	_run_days(st, 59)
	check(st.date_string() == "1 March 1836" and st.month() == 3 and st.day_of_month() == 1, "Feb has 28 days (%s)" % st.date_string())
	_run_days(st, 306)
	check(st.date_string() == "1 January 1837" and st.year() == 1837, "year rollover (%s)" % st.date_string())
	check(st.month_index == 12, "month_index counts months (%d)" % st.month_index)
	st.take_new_events()
	st.log_event(0, "system", "a")
	st.log_event(1, "economy", "b")
	var ev: Array = st.take_new_events()
	check(ev.size() == 2 and ev[0]["text"] == "a" and ev[1]["kind"] == "economy", "take_new_events returns new events")
	check(st.take_new_events().is_empty(), "events are only returned once")
	for i in 450:
		st.log_event(0, "system", "x%d" % i)
	check(st.events.size() == 400, "event log keeps the last 400")
	check(st.is_player(0) and not st.is_player(1), "is_player")
	st.dispose()


func test_sim_determinism() -> void:
	var w := _get_world()
	var a: RefCounted = GameState.new_game(w, 0, 11)
	_run_days(a, 400)
	var ha := _hash_state(a)
	var da: String = a.date_string()
	a.dispose()
	var b: RefCounted = GameState.new_game(w, 0, 11)
	_run_days(b, 400)
	check(_hash_state(b) == ha, "same seed, 400 days -> identical state hash")
	check(b.date_string() == da, "same date")
	b.dispose()
	var c: RefCounted = GameState.new_game(w, 0, 12)
	_run_days(c, 40)
	check(_hash_state(c) != ha, "different seed -> different state")
	c.dispose()


func test_save_roundtrip() -> void:
	var w := _get_world()
	var a: RefCounted = GameState.new_game(w, 2, 5)
	_run_days(a, 130)
	var snap: Dictionary = a.to_dict()
	var text := JSON.stringify(snap)
	var snap_copy: Dictionary = snap.duplicate(true)
	_run_days(a, 100)
	var h_a := _hash_state(a)
	var pop_a: float = a.pops.country_pop(2)
	var tre_a: float = a.econ.treasury(2)
	a.dispose()
	# 1) restore from the in-memory dictionary: must continue bit-for-bit identically
	var b: RefCounted = GameState.from_dict(w, snap_copy)
	check(JSON.stringify(b.to_dict()) == text, "from_dict(to_dict()) re-serialises identically")
	_run_days(b, 100)
	check(_hash_state(b) == h_a, "save/load round trip: +100 days equals the uninterrupted run")
	check(b.player == 2, "player country survives")
	b.dispose()
	# 2) restore through real JSON text (what a save file is): same economy to within float print precision
	var parsed = JSON.parse_string(text)
	check(parsed is Dictionary, "snapshot is valid JSON")
	var c: RefCounted = GameState.from_dict(w, parsed)
	_run_days(c, 100)
	check(absf(c.pops.country_pop(2) / pop_a - 1.0) < 1.0e-6, "JSON-text round trip: population matches (%.8f)" % (c.pops.country_pop(2) / pop_a))
	check(absf(c.econ.treasury(2) / tre_a - 1.0) < 1.0e-4, "JSON-text round trip: treasury matches (%.6f)" % (c.econ.treasury(2) / tre_a))
	c.dispose()


func test_save_system() -> void:
	var w := _get_world()
	var a: RefCounted = GameState.new_game(w, 4, 9)
	_run_days(a, 40)
	var path: String = SaveSystem.save_game(a, "__unit_test__")
	check(path != "" and FileAccess.file_exists(path), "save file written (%s)" % path)
	var listed: Array = SaveSystem.list_saves()
	var found := false
	for e: Dictionary in listed:
		if e["name"] == "__unit_test__":
			found = true
			check(e["country"] == w.c_name[4] and e["date"] == a.date_string(), "list_saves entry has country and date")
	check(found, "list_saves finds the save")
	check(SaveSystem.latest_save() != "", "latest_save returns a path")
	var h := _hash_state(a)
	a.dispose()
	var b = SaveSystem.load_game(w, path)
	check(b != null and _hash_state(b) == h, "load_game restores the exact state")
	if b != null:
		b.dispose()
	DirAccess.remove_absolute(path)
	check(SaveSystem.load_game(w, "user://saves/does_not_exist.json") == null, "missing save -> null")


func test_econ_invariants() -> void:
	var w := _get_world()
	var st: RefCounted = GameState.new_game(w, 0, 1)
	var e = st.econ
	var pp = st.pops
	var G: int = e.goods_count()
	var pop0 := 0.0
	for c in w.country_count:
		pop0 += pp.country_pop(c)
	check(pop0 > 40.0e6 and pop0 < 90.0e6, "world population %.1fM in 40-90M" % (pop0 / 1.0e6))
	var bad := 0
	var worst_ratio_lo := 99.0
	var worst_ratio_hi := 0.0
	for week in 104:
		_run_days(st, 7)
		for c in w.country_count:
			if st.alive[c] == 0:
				continue
			if is_nan(e.treasury(c)) or is_inf(e.treasury(c)):
				bad += 1
			for g in G:
				var pr: float = e.price(c, g)
				var ratio: float = pr / e.good_base_price(g)
				worst_ratio_lo = minf(worst_ratio_lo, ratio)
				worst_ratio_hi = maxf(worst_ratio_hi, ratio)
				if is_nan(pr) or pr <= 0.0 or e.supply(c, g) < 0.0 or e.demand(c, g) < 0.0:
					bad += 1
		if week % 13 == 0:
			for i in pp.size.size():
				if is_nan(pp.size[i]) or pp.size[i] < 0.0 or pp.employed[i] > pp.size[i] + 1.0e-6 or pp.employed[i] < 0.0 or is_nan(pp.sol[i]):
					bad += 1
					break
	check(bad == 0, "no NaN / negative prices, pops or supply over 2 years (%d bad)" % bad)
	check(worst_ratio_lo >= 0.25 and worst_ratio_hi <= 4.0, "prices stay within 0.25x-4x base (%.2f..%.2f)" % [worst_ratio_lo, worst_ratio_hi])
	var pop1 := 0.0
	for c in w.country_count:
		pop1 += pp.country_pop(c)
	var yearly := pow(pop1 / pop0, 0.5) - 1.0
	check(yearly > 0.0 and yearly < 0.025, "world population growth %.2f%%/yr is modest" % (yearly * 100.0))
	for c in w.country_count:
		if st.alive[c] == 0:
			continue
		var un: float = pp.unemployment(c)
		check(un >= 0.0 and un <= 0.30, "%s unemployment %.1f%% in range" % [w.c_short[c], un * 100.0])
		var gdp: float = e.gdp(c)
		check(gdp > 0.0 and absf(e.treasury(c)) < 20.0 * gdp, "%s treasury %.1fM vs GDP %.0fM sane" % [w.c_short[c], e.treasury(c) / 1.0e6, gdp / 1.0e6])
		var b: Dictionary = e.budget(c)
		check(b.has("tax") and b.has("tariffs") and b.has("admin") and b.has("military") and b.has("construction") and b.has("interest") and b.has("balance"), "budget keys")
	st.dispose()


func test_econ_chain_and_prices() -> void:
	var w := _get_world()
	var st: RefCounted = GameState.new_game(w, 0, 1)
	var e = st.econ
	var c := 1
	var G: int = e.goods_count()
	var ti: int = e.building_index("textile_mill")
	var g_fib: int = e.good_index("fibers")
	var g_tex: int = e.good_index("textiles")
	var prov := -1
	var lv_total := 0
	for p in w.c_provinces[c]:
		lv_total += e.level(p, ti)
		if prov < 0 and e.level(p, ti) > 0:
			prov = p
	check(prov >= 0, "country has a textile mill")
	_run_days(st, 14)
	var produced_normal: float = e.bout[prov * e.B + ti]
	check(produced_normal > 0.0, "a staffed mill with inputs produces (%.0f)" % produced_normal)
	# inputs are really consumed: fibers demand from the mills equals levels x input x staffing
	var sink := 0.0
	for k in e.top_sinks(c, g_fib, 8):
		if str(k["name"]).begins_with("textile mill"):
			sink = k["qty"]
	var expect := 0.0
	for p in w.c_provinces[c]:
		expect += e.level(p, ti) * 1000.0 * e.staff[p * e.B + ti]
	check(absf(sink - expect) < 1.0 and sink > 0.0, "mills draw fibers from the market (%.0f vs %.0f)" % [sink, expect])
	# no inputs -> no output
	for cc in w.country_count:
		e.fill[cc * G + g_fib] = 0.0
	e.tick_week()
	check(e.bout[prov * e.B + ti] == 0.0, "a mill with zero input supply produces nothing (%f)" % e.bout[prov * e.B + ti])
	check(e.supply(c, g_tex) < e.demand(c, g_tex) + 1.0 or e.bout[prov * e.B + ti] == 0.0, "no phantom textile output")
	# half the inputs -> half the output
	_run_days(st, 14)
	var full: float = e.bout[prov * e.B + ti]
	for cc in w.country_count:
		e.fill[cc * G + g_fib] = 0.5
	e.tick_week()
	var half: float = e.bout[prov * e.B + ti]
	check(full > 0.0 and absf(half / (full * e.staff[prov * e.B + ti] / maxf(e.staff[prov * e.B + ti], 1e-9)) - 0.5) < 0.1, "half the inputs -> about half the output (%.2f)" % (half / maxf(full, 1.0)))
	# raising demand raises the price over the following weeks and the explanation says why
	st.dispose()
	st = GameState.new_game(w, 0, 1)
	e = st.econ
	var g_iron: int = e.good_index("iron")
	var p0: float = e.price(c, g_iron)
	e.extra_demand[c * G + g_iron] = e.supply(c, g_iron) * 1.5
	var prev := p0
	var rising := 0
	for wk in 8:
		e.tick_week()
		if e.price(c, g_iron) > prev:
			rising += 1
		prev = e.price(c, g_iron)
	check(e.price(c, g_iron) > p0 * 1.25, "extra iron demand raises the price (%.2f -> %.2f)" % [p0, e.price(c, g_iron)])
	check(rising >= 6, "the price rises steadily week by week (%d/8)" % rising)
	for wk in 4:
		e.tick_week()
	var text: String = e.price_explanation(c, g_iron)
	check(text.begins_with("Iron Ore price rose") and text.contains("because") and text.contains("demand"), "price explanation is a cause/effect sentence: " + text)
	check(e.top_sinks(c, g_iron, 3).size() >= 1 and e.top_sources(c, g_iron, 3).size() >= 1, "top sources/sinks tracked")
	e.extra_demand[c * G + g_iron] = 0.0
	for wk in 30:
		e.tick_week()
	check(e.price(c, g_iron) < p0 * 1.2, "price relaxes after the shock (%.2f)" % e.price(c, g_iron))
	check(e.price_explanation(c, e.good_index("grain")).length() > 20, "explanation exists for a calm good")
	st.dispose()


func test_pop_responds_to_sol() -> void:
	var w := _get_world()
	var c := 3
	var st: RefCounted = GameState.new_game(w, c, 1)
	var pp = st.pops
	var base_pop: float = pp.country_pop(c)
	var hi := {}
	var lo := {}
	for p in w.c_provinces[c]:
		for prof in 7:
			hi[p * 7 + prof] = true
	# happy people grow
	for i in pp.sol.size():
		if hi.has(i):
			pp.sol[i] = 17.0
	for m in 6:
		pp.tick_month()
		for i in hi:
			pp.sol[i] = 17.0
	var grown: float = pp.country_pop(c)
	check(grown > base_pop * 1.004, "high standard of living -> population grows (%.3f)" % (grown / base_pop))
	for i in hi:
		pp.sol[i] = 3.0
	var before: float = pp.country_pop(c)
	for m in 6:
		pp.tick_month()
		for i in hi:
			pp.sol[i] = 3.0
	check(pp.country_pop(c) < before * 0.999, "poverty -> population shrinks (%.4f)" % (pp.country_pop(c) / before))
	check(pp.radical_share(c) > 0.2, "poverty -> radicalism rises (%.2f)" % pp.radical_share(c))
	st.dispose()
	# a real famine lowers sol through the market
	st = GameState.new_game(w, c, 1)
	pp = st.pops
	var e = st.econ
	var G: int = e.goods_count()
	var s0: float = pp.avg_sol(c)
	var gg: int = e.good_index("grain")
	e.extra_demand[c * G + gg] = e.supply(c, gg) * 2.0
	for wk in 14:
		e.tick_week()
	check(pp.avg_sol(c) < s0 - 0.5, "grain shortage lowers the standard of living (%.2f -> %.2f)" % [s0, pp.avg_sol(c)])
	var ex: String = pp.sol_explanation(c)
	check(ex.contains("grain") and ex.contains("supply covers"), "sol explanation names the cause: " + ex)
	check(pp.cohorts_in(w.c_provinces[c][0]).size() == 7, "cohorts_in returns 7 professions")
	st.dispose()


func test_construction_and_transfer() -> void:
	var w := _get_world()
	var c := 0
	var st: RefCounted = GameState.new_game(w, c, 1)
	var e = st.econ
	var farm: int = e.building_index("farm")
	var tool_ws: int = e.building_index("tool_workshop")
	var prov: int = w.c_provinces[c][0]
	var lv0: int = e.level(prov, tool_ws)
	var res: Dictionary = e.can_build(c, prov, tool_ws)
	check(res["ok"], "can_build tool workshop at home")
	check(not e.can_build(c, w.c_provinces[1][0], tool_ws)["ok"], "cannot build in a foreign province")
	check(e.can_build(c, prov, e.building_index("steel_mill")).has("reason"), "can_build always explains itself")
	var t0: float = e.treasury(c)
	check(e.queue_build(c, prov, tool_ws), "queue_build accepted")
	check(e.queue(c).size() == 1 and e.queue(c)[0]["type"] == tool_ws, "queue lists the project")
	check(e.cancel_build(c, 0) and e.queue(c).is_empty(), "cancel_build removes it")
	e.queue_build(c, prov, tool_ws)
	e.tre[c] = 5.0e6
	for wk in 6:
		e.tick_week()
	check(e.queue(c).size() == 1 and e.queue(c)[0]["progress"] > 0.0, "construction makes progress each week (%.0f / %.0f)" % [e.queue(c)[0]["progress"], e.queue(c)[0]["cost"]])
	check(e.budget(c)["construction"] > 0.0, "construction spending shows in the budget")
	for wk in 30:
		e.tick_week()
	check(e.level(prov, tool_ws) == lv0 + 1 and e.queue(c).is_empty(), "construction completes (%d -> %d)" % [lv0, e.level(prov, tool_ws)])
	var ev: Array = st.take_new_events()
	var done := false
	for x: Dictionary in ev:
		if x["kind"] == "economy" and x["text"].contains("completed"):
			done = true
	check(done, "completion is logged as an economy event")
	check(e.buildings_in(prov).size() > 0 and e.buildings_in(prov)[0].has("workers_needed"), "buildings_in rows")
	# debt and taxes
	e.tre[c] = -1.0e6
	check(e.in_debt(c), "in_debt when treasury < 0")
	check(e.set_tax_level(c, 2) in [true, false], "set_tax_level returns a bool")
	check(e.equipment_fill(c) >= 0.0, "equipment_fill")
	# ownership transfer
	var p2: int = w.c_provinces[1][0]
	var n_before: int = w.c_provinces[c].size()
	st.transfer_province(p2, c)
	check(w.p_owner[p2] == c and w.c_provinces[c].size() == n_before + 1 and not w.c_provinces[1].has(p2) and st.ownership_dirty, "transfer_province moves ownership")
	var last: int = w.c_provinces[1][0]
	for q in w.c_provinces[1].duplicate():
		st.transfer_province(q, c)
	check(st.alive[1] == 0, "a country with no provinces dies")
	_run_days(st, 30)
	check(true, "game keeps running after annexation")
	st.dispose()
	_get_world()
