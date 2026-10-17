extends RefCounted
## Population: one cohort per province x profession, stored in packed arrays indexed
## `p * PROF_COUNT + prof`. Employment/income/standard-of-living are written by the economy;
## this module owns growth, migration, promotion, literacy, radicalism and loyalty.

const Biome := preload("res://src/world/biome.gd")
const SimUtil := preload("res://src/sim/sim_util.gd")

const PEASANT := 0
const LABORER := 1
const MACHINIST := 2
const CLERK := 3
const ARISTOCRAT := 4
const CAPITALIST := 5
const SOLDIER := 6
const PROF_COUNT := 7
const PROF_NAMES := ["Peasants", "Laborers", "Machinists", "Clerks", "Aristocrats", "Capitalists", "Soldiers"]

const TOTAL_POP := 62.0e6
const TIER_FACTOR := [0.0, 0.7, 1.0, 1.4, 2.0, 3.2]
const SOL_NEUTRAL := 7.5            ## standard of living at which births = deaths
const GROWTH_PER_SOL := 0.0018       ## annual growth per point of sol above neutral
const START_SOL := [11.5, 14.0, 17.0, 18.0, 18.0, 18.0, 13.0]
const PROF_LITERACY := [0.55, 1.0, 1.6, 2.6, 2.4, 2.6, 1.1]  ## relative to the province's base literacy

var s
var world
var size := PackedFloat64Array()
var employed := PackedFloat64Array()
var income := PackedFloat64Array()      ## money / week per cohort (written by econ)
var sol := PackedFloat64Array()
var sol_prev := PackedFloat64Array()    ## sol one month ago, for trend
var literacy := PackedFloat64Array()    ## per cohort (country average: literacy_of(c); a var and func cannot share a name)
var radicalism := PackedFloat64Array()
var loyalty := PackedFloat64Array()
var minority := PackedFloat64Array()    ## per province: share of pops not of the accepted culture


func setup(state) -> void:
	s = state
	world = s.world
	var n: int = world.province_count
	var m := n * PROF_COUNT
	size.resize(m); employed.resize(m); income.resize(m); sol.resize(m); sol_prev.resize(m)
	literacy.resize(m); radicalism.resize(m); loyalty.resize(m)
	minority.resize(n)
	size.fill(0.0); employed.fill(0.0); income.fill(0.0)
	_seed()


func _seed() -> void:
	var n: int = world.province_count
	var weights := PackedFloat64Array()
	weights.resize(n)
	var total := 0.0
	for p in range(1, n):
		var fert := 0.0
		var mix: PackedFloat32Array = world.p_terrain_mix[p]
		for b in mini(mix.size(), Biome.COUNT):
			fert += mix[b] * Biome.FERTILITY[b]
		var tf: float = TIER_FACTOR[clampi(world.p_tier[p], 0, 5)]
		weights[p] = float(world.p_area[p]) * (0.12 + fert) * tf
		total += weights[p]
	var scale := TOTAL_POP / maxf(total, 1.0)
	var rng: RandomNumberGenerator = s.rng
	for p in range(1, n):
		var o: int = world.p_owner[p]
		var rank: String = world.c_rank[o] if o >= 0 else "minor"
		var lit_rank := 1.2 if rank == "great" else (1.0 if rank == "major" else 0.85)
		var tier: int = world.p_tier[p]
		var pop := maxf(weights[p] * scale, 15000.0)
		var cap_bonus: float = 0.03 if world.p_capital[p] == 1 else 0.0
		var sh := [0.0, 0.0, 0.0, 0.03 + cap_bonus + (0.01 if tier >= 4 else 0.0), 0.010, 0.005, 0.015]
		sh[LABORER] = 0.14 + 0.03 * tier
		sh[PEASANT] = 1.0 - sh[LABORER] - sh[CLERK] - sh[ARISTOCRAT] - sh[CAPITALIST] - sh[SOLDIER]
		var base_lit := (0.06 + 0.07 * tier) * lit_rank * (0.8 + 0.4 * rng.randf())
		var rad0 := 0.05 + 0.06 * rng.randf()
		minority[p] = 0.25 + 0.35 * rng.randf() if rng.randf() < 0.14 else 0.02 + 0.04 * rng.randf()
		for prof in PROF_COUNT:
			var i := p * PROF_COUNT + prof
			size[i] = pop * sh[prof]
			sol[i] = START_SOL[prof]
			sol_prev[i] = sol[i]
			literacy[i] = clampf(base_lit * PROF_LITERACY[prof], 0.01, 0.95)
			radicalism[i] = rad0 * (1.3 if prof <= LABORER else 0.7)
			loyalty[i] = 0.62 + 0.18 * rng.randf()


# --------------------------------------------------------------------------- ticks
func tick_week() -> void:
	## Employment is decided by the economy; here we only keep the numbers sane.
	sanitize()


## Cheap consistency pass GameState runs after every day (military/politics may have changed sizes).
func sanitize() -> void:
	var n: int = world.province_count
	for p in range(1, n):
		var b := p * PROF_COUNT
		for k in 4:
			var i := b + k
			var sz := size[i]
			if sz < 0.0 or is_nan(sz):
				size[i] = 0.0
				sz = 0.0
			if employed[i] > sz:
				employed[i] = sz
		for k in range(4, 7):
			var i := b + k
			var sz := size[i]
			if sz < 0.0 or is_nan(sz):
				size[i] = 0.0
				sz = 0.0
			employed[i] = sz


func tick_month() -> void:
	var econ = s.econ
	var vac: PackedFloat64Array = econ.vacant
	var alive: PackedByteArray = s.alive
	for c in world.country_count:
		if alive[c] == 0:
			continue
		var provs: PackedInt32Array = world.c_provinces[c]
		var lit_gain: float = clampf(0.004 + s.modifier(c, "literacy_growth"), 0.0, 0.08) / 12.0
		var rad_mult: float = clampf(s.modifier(c, "radicalism_mult"), 0.2, 3.0)
		for prof in 4:
			_migrate(c, provs, prof, vac)
		for p in provs:
			_promote(p, vac)
			var base := p * PROF_COUNT
			var mino: float = minority[p]
			for prof in PROF_COUNT:
				var i := base + prof
				var sz := size[i]
				if sz <= 0.0:
					continue
				var sl := sol[i]
				# growth
				var r_year := clampf(GROWTH_PER_SOL * (sl - SOL_NEUTRAL), -0.02, 0.03)
				size[i] = sz + sz * (r_year / 12.0)
				# literacy
				literacy[i] = minf(0.99, literacy[i] + lit_gain * (1.0 - literacy[i]))
				# radicalism: poverty, joblessness, unaccepted culture, falling living standards
				var unemp := 0.0
				if prof < ARISTOCRAT:
					unemp = maxf(0.0, 1.0 - employed[i] / sz)
				var t := 0.10 + clampf((10.0 - sl) / 10.0, -0.5, 1.0) * 0.30
				t += unemp * 0.5 + mino * 0.22
				t += clampf(sol_prev[i] - sl, 0.0, 3.0) * 0.05
				t = maxf(t, 0.0) * rad_mult
				var rd := radicalism[i]
				radicalism[i] = clampf(rd + (t - rd) * (0.10 if t > rd else 0.06), 0.0, 1.0)
				# loyalty
				var lt := clampf(0.55 + 0.03 * (sl - 8.0) - 0.6 * radicalism[i] - 0.3 * mino, 0.05, 0.98)
				loyalty[i] += (lt - loyalty[i]) * 0.08
				sol_prev[i] = sl
			# integration of minorities
			minority[p] = maxf(0.0, mino - 0.0015)


func _move(i_from: int, i_to: int, amt: float) -> void:
	if amt <= 0.0:
		return
	var dst := size[i_to]
	var w := amt / (dst + amt)
	literacy[i_to] += (literacy[i_from] - literacy[i_to]) * w
	radicalism[i_to] += (radicalism[i_from] - radicalism[i_to]) * w
	loyalty[i_to] += (loyalty[i_from] - loyalty[i_to]) * w
	sol[i_to] += (sol[i_from] - sol[i_to]) * w * 0.5
	size[i_to] = dst + amt
	size[i_from] = maxf(0.0, size[i_from] - amt)


func _migrate(_c: int, provs: PackedInt32Array, prof: int, vac: PackedFloat64Array) -> void:
	if provs.size() < 2:
		return
	var any_vac := false
	for q in provs:
		if vac[q * PROF_COUNT + prof] > 100.0:
			any_vac = true
			break
	if not any_vac:
		return
	for p in provs:
		var i := p * PROF_COUNT + prof
		var sz := size[i]
		var u := sz - employed[i]
		if sz <= 0.0 or u < 0.02 * sz + 50.0:
			continue
		var best := -1
		var bv := 100.0
		for q in provs:
			if q != p:
				var v := vac[q * PROF_COUNT + prof]
				if v > bv:
					bv = v
					best = q
		if best < 0:
			continue
		var amt := minf(minf(u, 0.02 * sz), bv)
		_move(i, best * PROF_COUNT + prof, amt)
		vac[best * PROF_COUNT + prof] -= amt


func _promote(p: int, vac: PackedFloat64Array) -> void:
	var b := p * PROF_COUNT
	# literate laborers -> machinists / clerks where jobs are waiting
	var il := b + LABORER
	var lab := size[il]
	var v_m := vac[b + MACHINIST]
	if v_m > 20.0 and lab > 0.0:
		var amt := minf(v_m, 0.010 * lab * (0.3 + literacy[il]))
		_move(il, b + MACHINIST, amt)
		vac[b + MACHINIST] -= amt
	var v_c := vac[b + CLERK]
	if v_c > 20.0 and lab > 0.0:
		var amt := minf(v_c, 0.006 * lab * (0.2 + literacy[il]))
		_move(il, b + CLERK, amt)
		vac[b + CLERK] -= amt
	# jobless peasants -> laborer jobs
	var ip := b + PEASANT
	var v_l := vac[b + LABORER]
	if v_l > 20.0:
		var unemp := maxf(0.0, size[ip] - employed[ip])
		var amt := minf(v_l, minf(0.5 * unemp, 0.03 * size[ip]))
		_move(ip, b + LABORER, amt)
		vac[b + LABORER] -= amt
	# unemployed skilled workers drift back to the land
	for prof in [LABORER, MACHINIST]:
		var i: int = b + prof
		var u := size[i] - employed[i]
		if u > 0.0:
			_move(i, ip, u * 0.10)


## Called by GameState.transfer_province: conquered people are unhappy and of another culture.
func on_transfer(p: int, _from: int, _to: int) -> void:
	minority[p] = maxf(minority[p], 0.5)
	for prof in PROF_COUNT:
		var i := p * PROF_COUNT + prof
		loyalty[i] *= 0.6
		radicalism[i] = minf(1.0, radicalism[i] + 0.05)


# --------------------------------------------------------------------------- queries
func province_pop(p: int) -> float:
	var b := p * PROF_COUNT
	return size[b] + size[b + 1] + size[b + 2] + size[b + 3] + size[b + 4] + size[b + 5] + size[b + 6]


func province_sol(p: int) -> float:
	var b := p * PROF_COUNT
	var s0 := size[b]; var s1 := size[b + 1]; var s2 := size[b + 2]; var s3 := size[b + 3]
	var s4 := size[b + 4]; var s5 := size[b + 5]; var s6 := size[b + 6]
	var den := s0 + s1 + s2 + s3 + s4 + s5 + s6
	if den <= 0.0:
		return 0.0
	return (sol[b] * s0 + sol[b + 1] * s1 + sol[b + 2] * s2 + sol[b + 3] * s3 + sol[b + 4] * s4 + sol[b + 5] * s5 + sol[b + 6] * s6) / den


func province_radical(p: int) -> float:
	var b := p * PROF_COUNT
	var s0 := size[b]; var s1 := size[b + 1]; var s2 := size[b + 2]; var s3 := size[b + 3]
	var s4 := size[b + 4]; var s5 := size[b + 5]; var s6 := size[b + 6]
	var den := s0 + s1 + s2 + s3 + s4 + s5 + s6
	if den <= 0.0:
		return 0.0
	return (radicalism[b] * s0 + radicalism[b + 1] * s1 + radicalism[b + 2] * s2 + radicalism[b + 3] * s3 + radicalism[b + 4] * s4 + radicalism[b + 5] * s5 + radicalism[b + 6] * s6) / den


func country_pop(c: int) -> float:
	var t := 0.0
	for p: int in world.c_provinces[c]:
		var b := p * PROF_COUNT
		t += size[b] + size[b + 1] + size[b + 2] + size[b + 3] + size[b + 4] + size[b + 5] + size[b + 6]
	return t


func country_prof(c: int, prof: int) -> float:
	var t := 0.0
	for p: int in world.c_provinces[c]:
		t += size[p * PROF_COUNT + prof]
	return t


## Share of the working population (peasants..clerks) without a job.
func unemployment(c: int) -> float:
	var sz := 0.0
	var emp := 0.0
	for p: int in world.c_provinces[c]:
		var b: int = p * PROF_COUNT
		sz += size[b] + size[b + 1] + size[b + 2] + size[b + 3]
		emp += employed[b] + employed[b + 1] + employed[b + 2] + employed[b + 3]
	return maxf(0.0, 1.0 - emp / sz) if sz > 0.0 else 0.0


func _weighted(c: int, arr: PackedFloat64Array) -> float:
	var num := 0.0
	var den := 0.0
	for p: int in world.c_provinces[c]:
		var b: int = p * PROF_COUNT
		var s0 := size[b]; var s1 := size[b + 1]; var s2 := size[b + 2]; var s3 := size[b + 3]
		var s4 := size[b + 4]; var s5 := size[b + 5]; var s6 := size[b + 6]
		num += arr[b] * s0 + arr[b + 1] * s1 + arr[b + 2] * s2 + arr[b + 3] * s3 + arr[b + 4] * s4 + arr[b + 5] * s5 + arr[b + 6] * s6
		den += s0 + s1 + s2 + s3 + s4 + s5 + s6
	return num / den if den > 0.0 else 0.0


func avg_sol(c: int) -> float:
	return _weighted(c, sol)


func literacy_of(c: int) -> float:
	return _weighted(c, literacy)


func radical_share(c: int) -> float:
	return _weighted(c, radicalism)


func loyal_share(c: int) -> float:
	return _weighted(c, loyalty)


func prof_sol(c: int, prof: int) -> float:
	var num := 0.0
	var den := 0.0
	for p: int in world.c_provinces[c]:
		var i: int = p * PROF_COUNT + prof
		num += sol[i] * size[i]
		den += size[i]
	return num / den if den > 0.0 else 0.0


func income_per_capita(p: int, prof: int) -> float:
	var i := p * PROF_COUNT + prof
	return income[i] / size[i] if size[i] > 0.0 else 0.0


func cohorts_in(p: int) -> Array:
	var out: Array = []
	for prof in PROF_COUNT:
		var i := p * PROF_COUNT + prof
		out.append({"prof": prof, "name": PROF_NAMES[prof], "size": size[i], "employed": employed[i],
			"income": income[i], "sol": sol[i], "literacy": literacy[i], "radicalism": radicalism[i],
			"loyalty": loyalty[i]})
	return out


func sol_explanation(c: int) -> String:
	var econ = s.econ
	var avg := avg_sol(c)
	var txt := "Standard of living averages %.1f out of 20" % avg
	var worst := -1
	var worst_gap := 0.0
	for j in econ.need_count():
		var gap: float = (1.0 - econ.need_fill_of(c, j)) * econ.need_weight(c, j)
		if gap > worst_gap:
			worst_gap = gap
			worst = j
	if worst >= 0 and worst_gap > 0.01:
		var g: int = econ.need_good(worst)
		var name: String = econ.good_name(g).to_lower()
		var base: float = econ.good_base_price(g)
		var pr: float = econ.price(c, g) / base
		var sup: float = econ.supply(c, g)
		var dem: float = econ.demand(c, g)
		txt += ". The weakest link is %s: households reach %d%% of a full basket" % [name, int(round(econ.need_fill_of(c, worst) * 100.0))]
		if dem > 0.0 and sup < dem * 0.95:
			txt += " because supply covers just %d%% of demand (price %d%% of base)" % [int(round(sup / dem * 100.0)), int(round(pr * 100.0))]
		elif pr > 1.15:
			txt += " because the high price (%d%% of base) eats into wages" % int(round(pr * 100.0))
		else:
			txt += " because wages leave little to spend after food and clothing"
	else:
		txt += ", as households can afford their full baskets"
	var un := unemployment(c)
	if un > 0.05:
		txt += ". Unemployment of %d%% leaves jobless workers on subsistence incomes" % int(round(un * 100.0))
	return txt + "."


# --------------------------------------------------------------------------- persistence
func to_dict() -> Dictionary:
	return {
		"size": SimUtil.enc_f64(size), "employed": SimUtil.enc_f64(employed), "income": SimUtil.enc_f64(income),
		"sol": SimUtil.enc_f64(sol), "sol_prev": SimUtil.enc_f64(sol_prev), "literacy": SimUtil.enc_f64(literacy),
		"radicalism": SimUtil.enc_f64(radicalism), "loyalty": SimUtil.enc_f64(loyalty),
		"minority": SimUtil.enc_f64(minority),
	}


func from_dict(d: Dictionary) -> void:
	var m := size.size()
	var tmp := SimUtil.dec_f64(d.get("size", ""))
	if tmp.size() != m:
		return
	size = tmp
	employed = SimUtil.dec_f64(d["employed"])
	income = SimUtil.dec_f64(d["income"])
	sol = SimUtil.dec_f64(d["sol"])
	sol_prev = SimUtil.dec_f64(d["sol_prev"])
	literacy = SimUtil.dec_f64(d["literacy"])
	radicalism = SimUtil.dec_f64(d["radicalism"])
	loyalty = SimUtil.dec_f64(d["loyalty"])
	minority = SimUtil.dec_f64(d["minority"])
