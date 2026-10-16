extends RefCounted
## Runtime world tables, loaded once from the baked assets.
##
## Data-oriented: provinces/countries are dense integer IDs indexing packed
## arrays. Index 0 of every province array is the sea / "no province" slot.
## Rendering and UI read from here; nothing here knows about nodes.

const IdCodec := preload("res://src/world/id_codec.gd")
const Biome := preload("res://src/world/biome.gd")
const DIR := "res://data/generated/"
const KM_PER_PX := 1.9

var width := 0
var height := 0
var seed_value := 0
var id_image: Image
var terrain_image: Image

var province_count := 0  # includes slot 0
var p_name := PackedStringArray()
var p_owner := PackedInt32Array()
var p_anchor := PackedVector2Array()
var p_port := PackedVector2Array()   # (-1,-1) when landlocked
var p_area := PackedInt32Array()
var p_terrain := PackedByteArray()
var p_elev := PackedFloat32Array()
var p_tier := PackedByteArray()
var p_capital := PackedByteArray()
var p_neighbors: Array[PackedInt32Array] = []
var p_terrain_mix: Array[PackedFloat32Array] = []

var country_count := 0
var c_name := PackedStringArray()
var c_short := PackedStringArray()
var c_tag := PackedStringArray()
var c_adjective := PackedStringArray()
var c_rank := PackedStringArray()
var c_gov := PackedStringArray()
var c_color := PackedColorArray()
var c_capital := PackedInt32Array()
var c_label := PackedVector2Array()
var c_area := PackedInt32Array()
var c_provinces: Array[PackedInt32Array] = []


static func load_default() -> RefCounted:
	var wd = load("res://src/world/world_data.gd").new()
	return wd if wd.load_from(DIR) else null


func load_from(dir: String) -> bool:
	id_image = load(dir + "province_ids.res")
	terrain_image = load(dir + "terrain.res")
	var f := FileAccess.open(dir + "world.json", FileAccess.READ)
	if id_image == null or terrain_image == null or f == null:
		push_error("World assets missing in %s — run tools/generate_world.gd" % dir)
		return false
	var j: Dictionary = JSON.parse_string(f.get_as_text())
	width = j["width"]
	height = j["height"]
	seed_value = j["seed"]
	_load_provinces(j["provinces"])
	_load_countries(j["countries"])
	return true


func _load_provinces(arr: Array) -> void:
	province_count = arr.size() + 1
	var n := province_count
	p_name.resize(n); p_owner.resize(n); p_anchor.resize(n); p_port.resize(n)
	p_area.resize(n); p_terrain.resize(n); p_elev.resize(n); p_tier.resize(n); p_capital.resize(n)
	p_neighbors.resize(n); p_terrain_mix.resize(n)
	p_name[0] = "Open Sea"
	p_owner[0] = -1
	p_neighbors[0] = PackedInt32Array()
	p_terrain_mix[0] = PackedFloat32Array()
	for p: Dictionary in arr:
		var id: int = p["id"]
		p_name[id] = p["name"]
		p_owner[id] = p["owner"]
		p_anchor[id] = Vector2(p["anchor"][0], p["anchor"][1])
		p_port[id] = Vector2(p["port"][0], p["port"][1]) if p["port"] != null else Vector2(-1, -1)
		p_area[id] = p["area"]
		p_terrain[id] = p["terrain"]
		p_elev[id] = p["elevation"]
		p_tier[id] = p["tier"]
		p_capital[id] = 1 if p["capital"] else 0
		p_neighbors[id] = PackedInt32Array(p["neighbors"])
		p_terrain_mix[id] = PackedFloat32Array(p["terrain_mix"])


func _load_countries(arr: Array) -> void:
	country_count = arr.size()
	var n := country_count
	c_name.resize(n); c_short.resize(n); c_tag.resize(n); c_adjective.resize(n); c_rank.resize(n)
	c_gov.resize(n); c_color.resize(n); c_capital.resize(n); c_label.resize(n); c_area.resize(n)
	c_provinces.resize(n)
	for c: Dictionary in arr:
		var id: int = c["id"]
		c_name[id] = c["name"]
		c_short[id] = c["short"]
		c_tag[id] = c["tag"]
		c_adjective[id] = c["adjective"]
		c_rank[id] = c["rank"]
		c_gov[id] = c["government"]
		c_color[id] = Color.html(c["color"])
		c_capital[id] = c["capital"]
		c_label[id] = Vector2(c["label"][0], c["label"][1])
		c_area[id] = int(c["area"])
		c_provinces[id] = PackedInt32Array()
	for id in range(1, province_count):
		var o := p_owner[id]
		if o >= 0:
			c_provinces[o].append(id)


## O(1) picking: read the ID image under a map position.
func province_at(pos: Vector2) -> int:
	var x := int(pos.x)
	var y := int(pos.y)
	if x < 0 or y < 0 or x >= width or y >= height:
		return 0
	return IdCodec.decode(id_image.get_pixel(x, y))


func country_neighbors(c: int) -> PackedInt32Array:
	var seen := {}
	for p in c_provinces[c]:
		for q in p_neighbors[p]:
			var o := p_owner[q]
			if o >= 0 and o != c:
				seen[o] = true
	var out := PackedInt32Array(seen.keys())
	out.sort()
	return out


func country_terrain_mix(c: int) -> PackedFloat32Array:
	var mix := PackedFloat32Array()
	mix.resize(Biome.COUNT)
	var total := 0.0
	for p in c_provinces[c]:
		var m := p_terrain_mix[p]
		for b in Biome.COUNT:
			mix[b] += m[b] * p_area[p]
		total += p_area[p]
	for b in Biome.COUNT:
		mix[b] /= maxf(total, 1.0)
	return mix


func area_km2(px: int) -> int:
	return int(px * KM_PER_PX * KM_PER_PX)
