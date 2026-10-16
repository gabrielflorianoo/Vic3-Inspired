extends RefCounted
## Root of the simulation: calendar, RNG, module wiring, event log, ownership changes.
## No Nodes in here. Modules (pops, econ, politics, tech, diplo, military, ai) are
## RefCounted objects with `var s`, `setup(state)`, `to_dict()`, `from_dict(d)` and optional
## tick_day / tick_week / tick_month. Optional modules are loaded tolerantly.

const SimUtil := preload("res://src/sim/sim_util.gd")
const Population := preload("res://src/sim/population.gd")
const Economy := preload("res://src/sim/economy.gd")

const SELF_PATH := "res://src/sim/game_state.gd"
const START_YEAR := 1836
const DAYS_PER_YEAR := 365
const MONTH_LEN := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
const MONTH_NAMES := ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
const MAX_EVENTS := 400
const OPTIONAL_MODULES := {
	"politics": "res://src/sim/politics.gd",
	"tech": "res://src/sim/technology.gd",
	"diplo": "res://src/sim/diplomacy.gd",
	"military": "res://src/sim/military.gd",
	"ai": "res://src/sim/ai.gd",
}

var world
var day := 0
var rng := RandomNumberGenerator.new()
var seed_value := 0
var player := -1
var alive := PackedByteArray()
var month_index := 0
var ownership_dirty := false

var pops
var econ
var politics
var tech
var diplo
var military
var ai

var events: Array = []
var _event_total := 0
var _event_taken := 0

var profile := false                 ## when true, per-module tick time is accumulated in prof_us / prof_n
var prof_us: Dictionary = {}
var prof_n: Dictionary = {}
var prof_max: Dictionary = {}

var _day_calls: Array = []           ## [[name, Callable], ...]
var _week_calls: Array = []
var _month_calls: Array = []
var _month_of_doy := PackedByteArray()   # 1..12 per day of year
var _dom_of_doy := PackedByteArray()     # day of month per day of year


# --------------------------------------------------------------------------- construction
static func new_game(world_data, player_country: int, seed_val: int) -> RefCounted:
	_reset_ownership(world_data)
	var st = (load(SELF_PATH) as GDScript).new()
	st.world = world_data
	st.seed_value = seed_val
	st.player = player_country
	st.rng.seed = seed_val
	st._build_calendar()
	st._make_modules()
	st.alive.resize(world_data.country_count)
	st.alive.fill(1)
	for m in st._ordered_modules():
		m.setup(st)
	st._build_tick_lists()
	st.econ.warm_up(12)
	st.events.clear()
	st._event_total = 0
	st._event_taken = 0
	return st


static func from_dict(world_data, d: Dictionary) -> RefCounted:
	_reset_ownership(world_data)
	var st = (load(SELF_PATH) as GDScript).new()
	st.world = world_data
	st.seed_value = int(str(d.get("seed", "0")))
	st.day = int(d.get("day", 0))
	st.month_index = int(d.get("month_index", 0))
	st.player = int(d.get("player", 0))
	st._build_calendar()
	# Apply saved ownership before any module looks at the world.
	var owner := SimUtil.dec_i32(d.get("owner", ""))
	if owner.size() == world_data.p_owner.size():
		for i in owner.size():
			world_data.p_owner[i] = owner[i]
		for c in world_data.country_count:
			world_data.c_provinces[c] = PackedInt32Array()
		for i in range(1, owner.size()):
			if owner[i] >= 0:
				world_data.c_provinces[owner[i]].append(i)
	var caps := SimUtil.dec_i32(d.get("capitals", ""))
	if caps.size() == world_data.country_count:
		for c in caps.size():
			world_data.c_capital[c] = caps[c]
	st.alive = SimUtil.dec_u8(d.get("alive", ""))
	if st.alive.size() != world_data.country_count:
		st.alive.resize(world_data.country_count)
		st.alive.fill(1)
	st._make_modules()
	# setup() builds static tables / sizes arrays, then from_dict() overwrites the state.
	for m in st._ordered_modules():
		m.setup(st)
	var keys := {"pops": st.pops, "econ": st.econ, "politics": st.politics, "tech": st.tech,
		"diplo": st.diplo, "military": st.military, "ai": st.ai}
	for k: String in keys:
		var m = keys[k]
		if m != null and d.has(k) and d[k] is Dictionary:
			m.from_dict(d[k])
	st.rng.seed = st.seed_value
	st.rng.state = int(str(d.get("rng_state", "0")))
	st.events = (d.get("events", []) as Array).duplicate(true)
	for e: Dictionary in st.events:
		e["day"] = int(e["day"])
		e["country"] = int(e["country"])
	st._event_total = int(d.get("event_total", st.events.size()))
	st._event_taken = st._event_total
	st._build_tick_lists()
	return st


## Restore the world's ownership to what it was when first seen, so a new game after a
## previous one (conquests, revolutions) starts from the pristine map.
static func _reset_ownership(world_data) -> void:
	if world_data.has_meta("orig_owner"):
		var o: PackedInt32Array = world_data.get_meta("orig_owner")
		for i in o.size():
			world_data.p_owner[i] = o[i]
		var caps: PackedInt32Array = world_data.get_meta("orig_capitals")
		for c in world_data.country_count:
			world_data.c_provinces[c] = PackedInt32Array()
			world_data.c_capital[c] = caps[c]
		for i in range(1, o.size()):
			if o[i] >= 0:
				world_data.c_provinces[o[i]].append(i)
	else:
		world_data.set_meta("orig_owner", world_data.p_owner.duplicate())
		world_data.set_meta("orig_capitals", world_data.c_capital.duplicate())


func _make_modules() -> void:
	pops = Population.new()
	econ = Economy.new()
	for k: String in OPTIONAL_MODULES:
		var path: String = OPTIONAL_MODULES[k]
		var m = null
		if ResourceLoader.exists(path):
			var sc = load(path)
			if sc != null and sc is GDScript and sc.can_instantiate():
				m = sc.new()
		set(k, m)


func _ordered_modules() -> Array:
	var out: Array = [pops, econ]
	for m in [politics, tech, diplo, military, ai]:
		if m != null:
			out.append(m)
	return out


func _build_tick_lists() -> void:
	_day_calls = _calls("tick_day", [["military", military]])
	_week_calls = _calls("tick_week", [["pops", pops], ["econ", econ], ["tech", tech], ["military", military], ["diplo", diplo]])
	_month_calls = _calls("tick_month", [["pops", pops], ["politics", politics], ["diplo", diplo], ["ai", ai]])


func _calls(method: String, mods: Array) -> Array:
	var out: Array = []
	for e: Array in mods:
		var m = e[1]
		if m != null and m.has_method(method):
			out.append([e[0], Callable(m, method)])
	return out


## Break reference cycles (state <-> modules) when a game is thrown away.
func dispose() -> void:
	for m in _ordered_modules():
		m.set("s", null)
	pops = null; econ = null; politics = null; tech = null; diplo = null; military = null; ai = null
	_day_calls.clear(); _week_calls.clear(); _month_calls.clear()


# --------------------------------------------------------------------------- calendar
func _build_calendar() -> void:
	_month_of_doy.resize(DAYS_PER_YEAR)
	_dom_of_doy.resize(DAYS_PER_YEAR)
	var i := 0
	for m in 12:
		for d in MONTH_LEN[m]:
			_month_of_doy[i] = m + 1
			_dom_of_doy[i] = d + 1
			i += 1


func year() -> int:
	return START_YEAR + day / DAYS_PER_YEAR


func month() -> int:
	return _month_of_doy[day % DAYS_PER_YEAR]


func day_of_month() -> int:
	return _dom_of_doy[day % DAYS_PER_YEAR]


func date_string() -> String:
	return "%d %s %d" % [day_of_month(), MONTH_NAMES[month() - 1], year()]


func advance_day() -> void:
	day += 1
	var doy := day % DAYS_PER_YEAR
	if profile:
		_run_profiled(_day_calls, "day")
		if day % 7 == 0:
			_run_profiled(_week_calls, "week")
		if _dom_of_doy[doy] == 1:
			_run_profiled(_month_calls, "month")
			month_index += 1
		pops.sanitize()
		return
	for e: Array in _day_calls:
		(e[1] as Callable).call()
	if day % 7 == 0:
		for e: Array in _week_calls:
			(e[1] as Callable).call()
	if _dom_of_doy[doy] == 1:
		for e: Array in _month_calls:
			(e[1] as Callable).call()
		month_index += 1
	pops.sanitize()


func _run_profiled(calls: Array, tag: String) -> void:
	for e: Array in calls:
		var t0 := Time.get_ticks_usec()
		(e[1] as Callable).call()
		var dt := Time.get_ticks_usec() - t0
		var k := "%s.%s" % [e[0], tag]
		prof_us[k] = prof_us.get(k, 0) + dt
		prof_n[k] = prof_n.get(k, 0) + 1
		if dt > prof_max.get(k, 0):
			prof_max[k] = dt


# --------------------------------------------------------------------------- events
func log_event(country: int, kind: String, text: String) -> void:
	events.append({"day": day, "country": country, "kind": kind, "text": text})
	_event_total += 1
	if events.size() > MAX_EVENTS:
		events.pop_front()


func take_new_events() -> Array:
	var n := mini(_event_total - _event_taken, events.size())
	_event_taken = _event_total
	if n <= 0:
		return []
	return events.slice(events.size() - n)


# --------------------------------------------------------------------------- queries shared by modules
func is_player(c: int) -> bool:
	return c == player


## politics.modifier + tech.modifier. *_mult keys are offsets from 1.0, so with no politics
## module present they still default to 1.0.
func modifier(c: int, key: String) -> float:
	var v := 0.0
	if politics != null and politics.has_method("modifier"):
		v += float(politics.modifier(c, key))
	elif key.ends_with("_mult"):
		v += 1.0
	if tech != null and tech.has_method("modifier"):
		v += float(tech.modifier(c, key))
	return v


func trade_partners(c: int) -> PackedInt32Array:
	if diplo != null and diplo.has_method("trade_partners"):
		return PackedInt32Array(diplo.trade_partners(c))
	return PackedInt32Array()


func arms_demand(c: int) -> float:
	if military != null and military.has_method("arms_demand"):
		return float(military.arms_demand(c))
	return 0.0


func controller(p: int) -> int:
	if military != null and military.has_method("controller"):
		return int(military.controller(p))
	return world.p_owner[p]


func military_upkeep(c: int) -> float:
	if military != null and military.has_method("upkeep"):
		return float(military.upkeep(c))
	return 0.0


# --------------------------------------------------------------------------- ownership
func transfer_province(p: int, to: int) -> void:
	var from: int = world.p_owner[p]
	if from == to or p <= 0 or p >= world.province_count:
		return
	world.p_owner[p] = to
	if from >= 0:
		var lst: PackedInt32Array = world.c_provinces[from]
		var idx := lst.find(p)
		if idx >= 0:
			lst.remove_at(idx)
			world.c_provinces[from] = lst
	if to >= 0:
		var lt: PackedInt32Array = world.c_provinces[to]
		lt.append(p)
		lt.sort()
		world.c_provinces[to] = lt
	ownership_dirty = true
	for m in _ordered_modules():
		if m.has_method("on_transfer"):
			m.on_transfer(p, from, to)
	if from >= 0:
		var rest: PackedInt32Array = world.c_provinces[from]
		if rest.is_empty():
			alive[from] = 0
			log_event(from, "politics", "%s has been wiped from the map." % world.c_name[from])
			if to >= 0:
				log_event(to, "war", "%s annexes the last lands of %s." % [world.c_short[to], world.c_short[from]])
		elif world.c_capital[from] == p:
			var best: int = rest[0]
			for q in rest:
				if world.p_tier[q] > world.p_tier[best]:
					best = q
			world.c_capital[from] = best
			log_event(from, "politics", "The capital of %s moves to %s." % [world.c_short[from], world.p_name[best]])


# --------------------------------------------------------------------------- persistence
func to_dict() -> Dictionary:
	var d := {
		"version": 1,
		"seed": str(seed_value),
		"rng_state": str(rng.state),
		"day": day,
		"month_index": month_index,
		"player": player,
		"alive": SimUtil.enc_u8(alive),
		"owner": SimUtil.enc_i32(world.p_owner),
		"capitals": SimUtil.enc_i32(world.c_capital),
		"events": events.duplicate(true),
		"event_total": _event_total,
	}
	var keys := {"pops": pops, "econ": econ, "politics": politics, "tech": tech,
		"diplo": diplo, "military": military, "ai": ai}
	for k: String in keys:
		var m = keys[k]
		if m != null:
			d[k] = m.to_dict()
	return d
