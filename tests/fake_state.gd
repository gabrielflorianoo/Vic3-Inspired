extends RefCounted
## Minimal GameState stand-in used by tests/test_strategy.gd when the real economy is unavailable.
## Real Population + the strategy modules; econ is null (all modules guard for that).

const SimUtil := preload("res://src/sim/sim_util.gd")
const MONTH_LEN := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

var world
var day := 0
var rng := RandomNumberGenerator.new()
var seed_value := 0
var player := -1
var alive := PackedByteArray()
var month_index := 0
var ownership_dirty := false
var pops
var econ = null
var politics
var tech
var diplo
var military
var ai
var events: Array = []
var _dom := PackedByteArray()
var orig_owner := PackedInt32Array()
var orig_caps := PackedInt32Array()
var _week_calls: Array = []
var _month_calls: Array = []


static func create(world_data, player_country: int, seed_val: int, orig_owner_arr: PackedInt32Array, orig_caps_arr: PackedInt32Array, from_save: Dictionary = {}):
	var st = load("res://tests/fake_state.gd").new()
	st.world = world_data
	st.orig_owner = orig_owner_arr
	st.orig_caps = orig_caps_arr
	st._reset_world()
	st.seed_value = seed_val
	st.player = player_country
	st.rng.seed = seed_val
	var i := 0
	st._dom.resize(365)
	for m in 12:
		for d in MONTH_LEN[m]:
			st._dom[i] = d + 1
			i += 1
	st.alive.resize(world_data.country_count)
	st.alive.fill(1)
	var pscript = load("res://src/sim/population.gd")
	if pscript != null and pscript is GDScript and pscript.can_instantiate() and not OS.get_cmdline_user_args().has("--fakepops"):
		st.pops = pscript.new()
	else:
		st.pops = load("res://tests/fake_pops.gd").new()
	st.politics = load("res://src/sim/politics.gd").new()
	st.tech = load("res://src/sim/technology.gd").new()
	st.diplo = load("res://src/sim/diplomacy.gd").new()
	st.military = load("res://src/sim/military.gd").new()
	st.ai = load("res://src/sim/ai.gd").new()
	if not from_save.is_empty():
		st.player = int(from_save["player"])
		st.seed_value = int(from_save["seed"])
		st.day = int(from_save["day"])
		st.month_index = int(from_save["month_index"])
		var ow := SimUtil.dec_i32(from_save["owner"])
		for p in ow.size():
			world_data.p_owner[p] = ow[p]
		for c in world_data.country_count:
			world_data.c_provinces[c] = PackedInt32Array()
		for p in range(1, ow.size()):
			if ow[p] >= 0:
				world_data.c_provinces[ow[p]].append(p)
		st.alive = SimUtil.dec_u8(from_save["alive"])
		var caps := SimUtil.dec_i32(from_save["caps"])
		for c in caps.size():
			world_data.c_capital[c] = caps[c]
	for m in [st.pops, st.politics, st.tech, st.diplo, st.military, st.ai]:
		m.setup(st)
	if not from_save.is_empty():
		for k in ["pops", "politics", "tech", "diplo", "military", "ai"]:
			st.get(k).from_dict(from_save[k])
		st.rng.state = int(str(from_save["rng_state"]))
	st._week_calls = [st.pops, st.tech, st.military, st.diplo]
	st._month_calls = [st.pops, st.politics, st.diplo, st.ai]
	return st


func snapshot() -> Dictionary:
	return {"day": day, "month_index": month_index, "player": player, "seed": seed_value, "owner": SimUtil.enc_i32(world.p_owner), "alive": SimUtil.enc_u8(alive),
		"caps": SimUtil.enc_i32(world.c_capital), "rng_state": str(rng.state),
		"pops": pops.to_dict(), "politics": politics.to_dict(), "tech": tech.to_dict(), "diplo": diplo.to_dict(),
		"military": military.to_dict(), "ai": ai.to_dict()}


func _reset_world() -> void:
	for i in orig_owner.size():
		world.p_owner[i] = orig_owner[i]
	for c in world.country_count:
		world.c_provinces[c] = PackedInt32Array()
		world.c_capital[c] = orig_caps[c]
	for i in range(1, orig_owner.size()):
		if orig_owner[i] >= 0:
			world.c_provinces[orig_owner[i]].append(i)


func advance_day() -> void:
	day += 1
	if day % 7 == 0:
		for m in _week_calls:
			if m.has_method("tick_week"):
				m.tick_week()
	if _dom[day % 365] == 1:
		for m in _month_calls:
			if m.has_method("tick_month"):
				m.tick_month()
		month_index += 1


func log_event(country: int, kind: String, text: String) -> void:
	events.append({"day": day, "country": country, "kind": kind, "text": text})


func is_player(c: int) -> bool:
	return c == player


func modifier(c: int, key: String) -> float:
	var v := 0.0
	v += float(politics.modifier(c, key))
	v += float(tech.modifier(c, key))
	return v


func transfer_province(p: int, to: int) -> void:
	var from: int = world.p_owner[p]
	if from == to or p <= 0:
		return
	world.p_owner[p] = to
	var lst: PackedInt32Array = world.c_provinces[from]
	lst.remove_at(lst.find(p))
	world.c_provinces[from] = lst
	var lt: PackedInt32Array = world.c_provinces[to]
	lt.append(p)
	lt.sort()
	world.c_provinces[to] = lt
	ownership_dirty = true
	for m in [pops, military, diplo]:
		if m.has_method("on_transfer"):
			m.on_transfer(p, from, to)
	if lst.is_empty():
		alive[from] = 0
	elif world.c_capital[from] == p:
		world.c_capital[from] = lst[0]


func dispose() -> void:
	for m in [pops, politics, tech, diplo, military, ai]:
		m.set("s", null)
	pops = null; politics = null; tech = null; diplo = null; military = null; ai = null
