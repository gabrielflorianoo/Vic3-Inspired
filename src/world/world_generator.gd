extends RefCounted
## Offline, deterministic world generator.
##
## Produces the baked map assets (terrain relief image, province-ID image) and
## the province/country tables. It runs once at build time (tools/generate_world.gd),
## never during play, so its per-pixel GDScript loops cost nothing at runtime.
## Same seed + same parameters + same scenario => byte-identical output.

const Biome := preload("res://src/world/biome.gd")
const IdCodec := preload("res://src/world/id_codec.gd")

var width: int = 2048
var height: int = 1024
var seed_value: int = 1836
var target_provinces: int = 220
var land_fraction: float = 0.44
var river_count: int = 34
var scenario_countries: Array = []
var verbose := false

# Outputs.
var heights := PackedFloat32Array()   # normalised: <0 sea, 0..1 land elevation
var biomes := PackedByteArray()
var ids := PackedInt32Array()         # 0 = sea, 1..N = province
var terrain_image: Image
var id_image: Image
var provinces: Array = []
var countries: Array = []

var _rng := RandomNumberGenerator.new()
var _moist := PackedFloat32Array()


func generate() -> void:
	_rng.seed = seed_value
	for step in [_gen_height, _gen_biomes, _gen_terrain_image, _gen_rivers, _gen_provinces,
			_province_stats, _assign_countries, _finalise_provinces]:
		var t := Time.get_ticks_msec()
		step.call()
		if verbose:
			print("  %s: %d ms" % [step.get_method(), Time.get_ticks_msec() - t])
	id_image = IdCodec.encode_image(ids, width, height)


# --------------------------------------------------------------------------- height
func _noise(seed_offset: int, freq: float, octaves: int, ftype := FastNoiseLite.FRACTAL_FBM) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed_value + seed_offset
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq
	n.fractal_type = ftype
	n.fractal_octaves = octaves
	return n


func _gen_height() -> void:
	var w := width
	var h := height
	var n_cont := _noise(0, 2.2 / w, 4)
	var n_det := _noise(1, 9.0 / w, 5)
	var n_ridge := _noise(2, 5.0 / w, 4, FastNoiseLite.FRACTAL_RIDGED)
	var n_moist := _noise(3, 3.5 / w, 3)
	heights.resize(w * h)
	_moist.resize(w * h)
	var mx := w * 0.10
	var my := h * 0.12
	for y in h:
		var ey := clampf(minf(y, h - 1 - y) / my, 0.0, 1.0)
		for x in w:
			var ex := clampf(minf(x, w - 1 - x) / mx, 0.0, 1.0)
			var fall := minf(ex, ey)
			fall = fall * fall * (3.0 - 2.0 * fall)
			var v := n_cont.get_noise_2d(x, y) * 0.75 + n_det.get_noise_2d(x, y) * 0.3 + 0.08
			var r := n_ridge.get_noise_2d(x, y)
			v += maxf(0.0, r - 0.35) * 0.55 * clampf(v * 4.0, 0.0, 1.0)
			heights[y * w + x] = v * fall - (1.0 - fall) * 0.6
			_moist[y * w + x] = clampf(n_moist.get_noise_2d(x, y) * 1.4 + 0.5, 0.0, 1.0)
	# Choose the sea level from a deterministic sample so land fraction is stable.
	var sample := PackedFloat32Array()
	var step := maxi(1, heights.size() / 40000)
	for i in range(0, heights.size(), step):
		sample.append(heights[i])
	sample.sort()
	var sea := sample[int(sample.size() * (1.0 - land_fraction))]
	var top := sample[sample.size() - 1]
	var bottom := sample[0]
	for i in heights.size():
		var v := heights[i]
		if v >= sea:
			heights[i] = pow(clampf((v - sea) / (top - sea), 0.0, 1.0), 1.6)
		else:
			heights[i] = -clampf((sea - v) / (sea - bottom), 0.001, 1.0)


func _gen_biomes() -> void:
	biomes.resize(width * height)
	for y in height:
		var lat := float(y) / height   # 0 = north (cold), 1 = south (warm)
		for x in width:
			var i := y * width + x
			var e := heights[i]
			if e < 0.0:
				biomes[i] = Biome.OCEAN
				continue
			var temp := lat * 0.95 + 0.08 - e * 0.55
			var m := _moist[i]
			var b := Biome.PLAINS
			if e > 0.50:
				b = Biome.MOUNTAINS
			elif e > 0.27:
				b = Biome.HILLS
			elif temp < 0.20:
				b = Biome.TUNDRA
			elif temp > 0.72 and m < 0.48:
				b = Biome.DESERT
			elif m < 0.36:
				b = Biome.STEPPE
			elif m > 0.60:
				b = Biome.FOREST
			biomes[i] = b


# ------------------------------------------------------------------- relief image
func _gen_terrain_image() -> void:
	var w := width
	var h := height
	var data := PackedByteArray()
	data.resize(w * h * 3)
	var grain := _noise(9, 0.08, 2)
	var palette: Array = Biome.COLORS
	var deep := Biome.OCEAN_DEEP
	var shallow := Biome.OCEAN_SHALLOW
	var light := Vector3(-0.62, -0.62, 0.48).normalized()
	for y in h:
		var y0 := maxi(y - 1, 0)
		var y1 := mini(y + 1, h - 1)
		for x in w:
			var i := y * w + x
			var e := heights[i]
			var dx := heights[y * w + mini(x + 1, w - 1)] - heights[y * w + maxi(x - 1, 0)]
			var dy := heights[y1 * w + x] - heights[y0 * w + x]
			var c: Color
			if e < 0.0:
				var d := clampf(-e * 3.2, 0.0, 1.0)
				c = shallow.lerp(deep, sqrt(d))
				var nrm := Vector3(-dx * 18.0, -dy * 18.0, 1.0).normalized()
				var s := nrm.dot(light)
				c = c * (0.86 + 0.18 * s)
			else:
				var b: int = biomes[i]
				c = palette[b]
				if b == Biome.MOUNTAINS and e > 0.78:
					c = c.lerp(Biome.SNOW, clampf((e - 0.78) * 6.0, 0.0, 1.0))
				# Low land blends toward a lush green, high land toward rock.
				c = c.lerp(Biome.LOWLAND, clampf(0.08 - e, 0.0, 0.08) * 3.0)
				var relief := 45.0 + e * 150.0
				var nrm := Vector3(-dx * relief, -dy * relief, 1.0).normalized()
				var s := nrm.dot(light)
				c = c * (0.50 + 0.62 * s) + Color(0.03, 0.025, 0.02) * (1.0 - s)
			var g := grain.get_noise_2d(x, y) * 0.035
			var o := i * 3
			data[o] = int(clampf(c.r + g, 0.0, 1.0) * 255.0)
			data[o + 1] = int(clampf(c.g + g, 0.0, 1.0) * 255.0)
			data[o + 2] = int(clampf(c.b + g, 0.0, 1.0) * 255.0)
	terrain_image = Image.create_from_data(w, h, false, Image.FORMAT_RGB8, data)


func _gen_rivers() -> void:
	var w := width
	var h := height
	var river := PackedInt32Array()
	river.resize(w * h)
	var made := 0
	var attempts := 0
	var offs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]
	while made < river_count and attempts < river_count * 40:
		attempts += 1
		var sx := _rng.randi_range(8, w - 9)
		var sy := _rng.randi_range(8, h - 9)
		var e := heights[sy * w + sx]
		if e < 0.22 or e > 0.6 or _moist[sy * w + sx] < 0.35:
			continue
		var path := PackedInt32Array()
		var visited := {}
		var cx := sx
		var cy := sy
		var reached := false
		for _s in 4000:
			var ci := cy * w + cx
			path.append(ci)
			visited[ci] = true
			if heights[ci] < 0.0 or river[ci] > 0:
				reached = true
				break
			var best := -1
			var best_h := INF
			for o: Vector2i in offs:
				var nx: int = cx + o.x
				var ny: int = cy + o.y
				if nx < 1 or ny < 1 or nx >= w - 1 or ny >= h - 1:
					continue
				var ni := ny * w + nx
				if visited.has(ni):
					continue
				# Small deterministic jitter breaks up straight diagonal runs.
				var hv := heights[ni] + _rng.randf() * 0.004
				if hv < best_h:
					best_h = hv
					best = ni
			if best < 0:
				break
			cx = best % w
			cy = best / w
		if not reached or path.size() < 90:
			continue
		made += 1
		for k in path.size():
			river[path[k]] = maxi(river[path[k]], k + 1)
	# Paint rivers; width grows with downstream length.
	var rc := Biome.RIVER
	for i in river.size():
		var flow := river[i]
		if flow == 0 or heights[i] < 0.0:
			continue
		var x := i % w
		var y := i / w
		var r := 1 if flow > 180 else 0
		for oy in range(-r, r + 1):
			for ox in range(-r, r + 1):
				var px := clampi(x + ox, 0, w - 1)
				var py := clampi(y + oy, 0, h - 1)
				if heights[py * w + px] < 0.0:
					continue
				var a := 0.85 if (ox == 0 and oy == 0) else 0.45
				terrain_image.set_pixel(px, py, terrain_image.get_pixel(px, py).lerp(rc, a))


# --------------------------------------------------------------------- provinces
var _seeds: PackedVector2Array = PackedVector2Array()
var _grid: Dictionary = {}
var _cell: float = 1.0
var _area := PackedInt32Array()
var _sum := PackedVector2Array()
var _bio := PackedInt32Array()
var _hsum := PackedFloat32Array()
var _coastal := PackedByteArray()
var _adj: Dictionary = {}
var _anchor := PackedVector2Array()
var _port := PackedVector2Array()


func _gen_provinces() -> void:
	var w := width
	var h := height
	var land := 0
	for v in heights:
		if v >= 0.0:
			land += 1
	var min_d := sqrt(float(land) / target_provinces) * 0.9
	_cell = min_d
	var tries := 0
	while _seeds.size() < target_provinces and tries < target_provinces * 80:
		tries += 1
		var x := _rng.randi_range(2, w - 3)
		var y := _rng.randi_range(2, h - 3)
		var e := heights[y * w + x]
		if e < 0.0 or e > 0.8:
			continue
		var p := Vector2(x, y)
		if _near_seed(p, min_d) >= 0:
			continue
		_grid_add(p, _seeds.size())
		_seeds.append(p)
	# Warped Voronoi: domain warping gives irregular, natural-looking borders.
	var wx := _noise(20, 1.0 / 55.0, 3)
	var wy := _noise(21, 1.0 / 55.0, 3)
	var amp := min_d * 0.38
	ids.resize(w * h)
	for y in h:
		for x in w:
			var i := y * w + x
			if heights[i] < 0.0:
				ids[i] = 0
				continue
			var p := Vector2(x + wx.get_noise_2d(x, y) * amp, y + wy.get_noise_2d(x, y) * amp)
			var s := _nearest_seed(p, 1)
			if s < 0:
				s = _nearest_seed(p, 3)
			ids[i] = s + 1
	# Drop empty seeds and renumber densely.
	var count := PackedInt32Array()
	count.resize(_seeds.size() + 1)
	for v in ids:
		count[v] += 1
	var remap := PackedInt32Array()
	remap.resize(_seeds.size() + 1)
	var kept := PackedVector2Array()
	for s in _seeds.size():
		if count[s + 1] > 0:
			kept.append(_seeds[s])
			remap[s + 1] = kept.size()
	for i in ids.size():
		ids[i] = remap[ids[i]]
	_seeds = kept


func _grid_key(p: Vector2) -> Vector2i:
	return Vector2i(int(p.x / _cell), int(p.y / _cell))


func _grid_add(p: Vector2, idx: int) -> void:
	var k := _grid_key(p)
	if not _grid.has(k):
		_grid[k] = PackedInt32Array()
	var arr: PackedInt32Array = _grid[k]
	arr.append(idx)
	_grid[k] = arr


func _near_seed(p: Vector2, d: float) -> int:
	var k := _grid_key(p)
	var d2 := d * d
	for gy in range(k.y - 1, k.y + 2):
		for gx in range(k.x - 1, k.x + 2):
			var arr = _grid.get(Vector2i(gx, gy))
			if arr == null:
				continue
			for s in arr:
				if _seeds[s].distance_squared_to(p) < d2:
					return s
	return -1


func _nearest_seed(p: Vector2, r: int) -> int:
	var k := _grid_key(p)
	var best := -1
	var best_d := INF
	for gy in range(k.y - r, k.y + r + 1):
		for gx in range(k.x - r, k.x + r + 1):
			var arr = _grid.get(Vector2i(gx, gy))
			if arr == null:
				continue
			for s in arr:
				var d := _seeds[s].distance_squared_to(p)
				if d < best_d:
					best_d = d
					best = s
	# Only trust a radius-1 result if nothing outside the window could be closer.
	if r == 1 and best_d > _cell * _cell:
		return -1
	return best


func _province_stats() -> void:
	var w := width
	var h := height
	var n := _seeds.size() + 1
	_area.resize(n)
	_sum.resize(n)
	_bio.resize(n * Biome.COUNT)
	_hsum.resize(n)
	_coastal.resize(n)
	for y in h:
		for x in w:
			var i := y * w + x
			var id := ids[i]
			if id == 0:
				continue
			_area[id] += 1
			_sum[id] += Vector2(x, y)
			_bio[id * Biome.COUNT + biomes[i]] += 1
			_hsum[id] += heights[i]
			if x + 1 < w:
				_touch(id, ids[i + 1])
			if y + 1 < h:
				_touch(id, ids[i + w])
	# Anchor (town site): centroid if inside the province, else its seed.
	_anchor.resize(n)
	_port.resize(n)
	var port_d := PackedFloat32Array()
	port_d.resize(n)
	port_d.fill(INF)
	for id in range(1, n):
		var c := _sum[id] / _area[id]
		var ci := int(c.y) * w + int(c.x)
		_anchor[id] = c if ids[ci] == id else _seeds[id - 1]
	# Port site: the province's coastal pixel nearest to its town.
	for y in range(1, h - 1):
		for x in range(1, w - 1):
			var i := y * w + x
			var id := ids[i]
			if id == 0 or _coastal[id] == 0:
				continue
			if ids[i + 1] != 0 and ids[i - 1] != 0 and ids[i + w] != 0 and ids[i - w] != 0:
				continue
			var d := _anchor[id].distance_squared_to(Vector2(x, y))
			if d < port_d[id]:
				port_d[id] = d
				_port[id] = Vector2(x, y)


func _touch(a: int, b: int) -> void:
	if b == a:
		return
	if b == 0:
		_coastal[a] = 1
		return
	_adj[mini(a, b) * 65536 + maxi(a, b)] = true


# --------------------------------------------------------------------- countries
func _assign_countries() -> void:
	var n := _seeds.size() + 1
	var nb: Array = []
	nb.resize(n)
	for id in n:
		nb[id] = PackedInt32Array()
	for key: int in _adj.keys():
		var a := key / 65536
		var b := key % 65536
		nb[a].append(b)
		nb[b].append(a)
	for id in n:
		var arr: PackedInt32Array = nb[id]
		arr.sort()
		nb[id] = arr
	var mean_area := 0.0
	for id in range(1, n):
		mean_area += _area[id]
	mean_area /= maxf(1.0, n - 1)
	# Capitals by farthest-point sampling over decent, non-mountain provinces.
	var cands := PackedInt32Array()
	for id in range(1, n):
		if _area[id] > mean_area * 0.5 and _dominant(id) != Biome.MOUNTAINS and nb[id].size() > 0:
			cands.append(id)
	var caps := PackedInt32Array()
	var nc := mini(scenario_countries.size(), cands.size())
	if nc > 0:
		caps.append(cands[_rng.randi_range(0, cands.size() - 1)])
	while caps.size() < nc:
		var best := -1
		var best_d := -1.0
		for c in cands:
			if caps.has(c):
				continue
			var md := INF
			for k in caps:
				md = minf(md, _anchor[c].distance_to(_anchor[k]))
			if md > best_d:
				best_d = md
				best = c
		caps.append(best)
	# Multi-source Dijkstra; terrain makes borders follow mountains, rank sets reach.
	var owner := PackedInt32Array()
	owner.resize(n)
	owner.fill(-1)
	var dist := PackedFloat32Array()
	dist.resize(n)
	dist.fill(INF)
	var done := PackedByteArray()
	done.resize(n)
	for c in nc:
		dist[caps[c]] = 0.0
		owner[caps[c]] = c
	while true:
		var u := -1
		var ud := INF
		for id in range(1, n):
			if done[id] == 0 and dist[id] < ud:
				ud = dist[id]
				u = id
		if u < 0:
			break
		done[u] = 1
		var strength := _rank_strength(owner[u])
		for v in nb[u]:
			var cost: float = _anchor[u].distance_to(_anchor[v]) * Biome.MOVE_COST[_dominant(v)] / strength
			if ud + cost < dist[v]:
				dist[v] = ud + cost
				owner[v] = owner[u]
	# Unreached islands go to the nearest capital (colonial holdings).
	for id in range(1, n):
		if owner[id] < 0 and nc > 0:
			var best := 0
			var bd := INF
			for c in nc:
				var d := _anchor[id].distance_to(_anchor[caps[c]])
				if d < bd:
					bd = d
					best = c
			owner[id] = best
	# Build tables.
	provinces.clear()
	provinces.append({})  # index 0 = sea placeholder
	for id in range(1, n):
		provinces.append({"id": id, "owner": owner[id], "neighbors": Array(nb[id])})
	countries.clear()
	for c in nc:
		var def: Dictionary = scenario_countries[c].duplicate()
		def["id"] = c
		def["capital"] = caps[c]
		countries.append(def)


func _rank_strength(c: int) -> float:
	if c < 0 or c >= scenario_countries.size():
		return 1.0
	match str(scenario_countries[c].get("rank", "minor")):
		"great": return 1.75
		"major": return 1.3
	return 1.0


func _dominant(id: int) -> int:
	var best := 1
	var bc := -1
	for b in range(1, Biome.COUNT):
		var v := _bio[id * Biome.COUNT + b]
		if v > bc:
			bc = v
			best = b
	return best


func _finalise_provinces() -> void:
	var names := {}
	for id in range(1, provinces.size()):
		var p: Dictionary = provinces[id]
		var area := _area[id]
		var mix := []
		for b in Biome.COUNT:
			mix.append(snappedf(float(_bio[id * Biome.COUNT + b]) / area, 0.001))
		var dom := _dominant(id)
		var is_cap := false
		for c: Dictionary in countries:
			if c["capital"] == id:
				is_cap = true
		var coastal := _coastal[id] == 1
		var score: float = Biome.FERTILITY[dom] + minf(area / 6000.0, 1.0) * 0.4 + (0.35 if coastal else 0.0) + _rng.randf() * 0.5
		var tier := 5 if is_cap else clampi(int(score * 2.2), 1, 4)
		var name := _make_name(dom, coastal)
		while names.has(name):
			name = _make_name(dom, coastal)
		names[name] = true
		p["name"] = name
		p["area"] = area
		p["anchor"] = [snappedf(_anchor[id].x, 0.1), snappedf(_anchor[id].y, 0.1)]
		p["port"] = [_port[id].x, _port[id].y] if coastal else null
		p["terrain"] = dom
		p["terrain_mix"] = mix
		p["elevation"] = snappedf(_hsum[id] / area, 0.001)
		p["coastal"] = coastal
		p["tier"] = tier
		p["capital"] = is_cap
	# Country label anchors: area-weighted centroid if it lands inside the country.
	for c: Dictionary in countries:
		var s := Vector2.ZERO
		var a := 0.0
		var cnt := 0
		for id in range(1, provinces.size()):
			if provinces[id]["owner"] == c["id"]:
				s += _anchor[id] * _area[id]
				a += _area[id]
				cnt += 1
		var lp: Vector2 = s / maxf(a, 1.0)
		var li := clampi(int(lp.y), 0, height - 1) * width + clampi(int(lp.x), 0, width - 1)
		var lid := ids[li]
		if lid == 0 or provinces[lid]["owner"] != c["id"]:
			lp = _anchor[c["capital"]]
		c["label"] = [snappedf(lp.x, 0.1), snappedf(lp.y, 0.1)]
		c["area"] = a
		c["province_count"] = cnt


const _SYL_A := ["al", "bre", "cor", "dar", "el", "fen", "gar", "hal", "is", "kor", "lin", "mar", "nor", "os", "pel", "quin", "ros", "sal", "tor", "ul", "ver", "wen", "zar", "bel", "ca", "dun", "est", "fal", "gol", "har"]
const _SYL_B := ["a", "e", "i", "o", "ar", "en", "or", "ul", "an", "is", "el", "om"]
const _SYL_END := ["burg", "ford", "mont", "vale", "ia", "stad", "grad", "heim", "mere", "wick", "dor", "ton", "sk", "ova", "ane", "ard"]


func _make_name(dom: int, coastal: bool) -> String:
	var s: String = _SYL_A[_rng.randi_range(0, _SYL_A.size() - 1)]
	if _rng.randf() < 0.6:
		s += _SYL_B[_rng.randi_range(0, _SYL_B.size() - 1)]
	var end: String = _SYL_END[_rng.randi_range(0, _SYL_END.size() - 1)]
	if coastal and _rng.randf() < 0.3:
		end = "haven"
	elif dom == Biome.MOUNTAINS and _rng.randf() < 0.4:
		end = "berg"
	return (s + end).capitalize().replace(" ", "")


# ----------------------------------------------------------------------- output
func to_json() -> Dictionary:
	return {
		"version": 1,
		"seed": seed_value,
		"width": width,
		"height": height,
		"provinces": provinces.slice(1),
		"countries": countries,
	}


func checksum() -> int:
	return hash([ids, terrain_image.get_data(), JSON.stringify(to_json())])
