extends RefCounted
## Tiny population stand-in (same query API as src/sim/population.gd) used only when the real one cannot load.
const PROF_COUNT := 7
var s
var size := PackedFloat64Array()
var sol := PackedFloat64Array()
var radicalism := PackedFloat64Array()
var bias := PackedFloat64Array()


func setup(state) -> void:
	s = state
	var n: int = s.world.province_count * PROF_COUNT
	size.resize(n); sol.resize(n); radicalism.resize(n)
	bias.resize(s.world.country_count)
	var shares := [0.62, 0.20, 0.02, 0.03, 0.01, 0.005, 0.015]
	for p in range(1, s.world.province_count):
		for pr in PROF_COUNT:
			size[p * PROF_COUNT + pr] = 300000.0 * shares[pr] * (1 + s.world.p_tier[p])
			sol[p * PROF_COUNT + pr] = 9.0 + s.rng.randf() * 3.0
			radicalism[p * PROF_COUNT + pr] = 0.08 + s.rng.randf() * 0.05
	for c in s.world.country_count:
		bias[c] = s.rng.randf() * 0.25
	bias[11] = 0.6


func tick_month() -> void:
	for c in s.world.country_count:
		for p in s.world.c_provinces[c]:
			for pr in PROF_COUNT:
				var i: int = p * PROF_COUNT + pr
				radicalism[i] += (bias[c] + 0.05 - radicalism[i]) * 0.05


func on_transfer(_p: int, _f: int, _t: int) -> void:
	pass


func country_prof(c: int, prof: int) -> float:
	var t := 0.0
	for p in s.world.c_provinces[c]:
		t += size[p * PROF_COUNT + prof]
	return t


func country_pop(c: int) -> float:
	var t := 0.0
	for pr in PROF_COUNT:
		t += country_prof(c, pr)
	return t


func _w(c: int, arr: PackedFloat64Array) -> float:
	var num := 0.0
	var den := 0.0
	for p in s.world.c_provinces[c]:
		for pr in PROF_COUNT:
			var i: int = p * PROF_COUNT + pr
			num += arr[i] * size[i]
			den += size[i]
	return num / den if den > 0.0 else 0.0


func avg_sol(c: int) -> float:
	return _w(c, sol)


func radical_share(c: int) -> float:
	return _w(c, radicalism)


func literacy_of(_c: int) -> float:
	return 0.3


func to_dict() -> Dictionary:
	return {"size": Array(size), "sol": Array(sol), "rad": Array(radicalism), "bias": Array(bias)}


func from_dict(d: Dictionary) -> void:
	size = PackedFloat64Array(d["size"]); sol = PackedFloat64Array(d["sol"])
	radicalism = PackedFloat64Array(d["rad"]); bias = PackedFloat64Array(d["bias"])
