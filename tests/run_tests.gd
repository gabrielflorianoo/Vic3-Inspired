extends SceneTree
## Headless test runner:  godot --headless --path . --script res://tests/run_tests.gd
## Exit code 0 = all passed.

const WorldGenerator := preload("res://src/world/world_generator.gd")
const WorldData := preload("res://src/world/world_data.gd")
const IdCodec := preload("res://src/world/id_codec.gd")

var _fail := 0
var _pass := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		printerr("  FAIL: ", msg)


func _init() -> void:
	for t in [test_id_codec, test_generator_determinism, test_generator_invariants, test_shipped_data, test_picking]:
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
