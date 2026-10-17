extends RefCounted
## Economy: one national market per country, goods flowing through buildings and households.
##
## Everything is flat packed arrays:
##   per country x good  (c * G + g)        price, supply, demand, fill, sold, ...
##   per province x type (p * B + b)        lvl, cap, emp, staff, profit, ...
## Weekly order: hire+produce -> household demand -> state demand -> trade -> clear & settle
## (revenue, wages, dividends, consumption, standard of living, prices) -> construction -> budget.
## Production uses LAST week's fill ratios as input availability, so the supply chain is a
## feed-forward pipeline with one week of delay (no oscillation); prices follow supply/demand
## with 30 % smoothing.

const Biome := preload("res://src/world/biome.gd")
const SimUtil := preload("res://src/sim/sim_util.gd")

const PC := 7                       ## professions (see population.gd)
const P_PEASANT := 0
const P_LABORER := 1
const P_MACHINIST := 2
const P_CLERK := 3
const P_ARISTOCRAT := 4
const P_CAPITALIST := 5
const P_SOLDIER := 6
const LABOR_PROFS := 4              ## peasant..clerk take jobs in buildings

const WAGE_SHARE := 0.55            ## share of value added offered to workers above the floor
const MAX_WAGE_K := 2.5
const PRICE_SMOOTH := 0.30
const PRICE_EXP := 0.7
const TRADE_CAP := 0.20             ## max share of an exporter's output moved to one partner per week
const TAX_BASE := 0.07
const SPEND_SHARE := 0.97
const BUILD_WEEKS := 8.0
const QUEUE_MAX := 12
const SOL_SMOOTH := 0.12
const REF_PERIOD := 4
const EMPLOY_TARGET := 0.93
const OCCUPIED_OUTPUT := 0.15
const ADMIN_POP := 45000.0
const DEBT_RATE := 0.08
const LEVEL_COST_STEP := 0.03
const ARMS_PC := {"great": 0.00003, "major": 0.00002, "minor": 0.00001}   ## floor so a spare arms level always exists
const COVERAGE := {"great": 1.0, "major": 0.9, "minor": 0.78}
const DEP_COAL := [0.0, 0.25, 0.30, 0.80, 1.00, 0.15, 0.15, 0.30]
const DEP_IRON := [0.0, 0.20, 0.25, 0.90, 1.00, 0.10, 0.10, 0.30]
const PROF_KEYS := ["peasant", "laborer", "machinist", "clerk", "aristocrat", "capitalist", "soldier"]

var s
var world
var pops

var week := 0
var _seeded := false                ## buildings are seeded in warm_up(), once every module (tech, military...) exists
var C := 0
var G := 0
var B := 0
var NN := 0
var T := 0                          ## flow tags: B building types + pops, construction, military, trade, other
var TAG_POPS := 0
var TAG_CON := 0
var TAG_MIL := 0
var TAG_TRADE := 0
var TAG_OTHER := 0

# --- static definitions
var good_ids := PackedStringArray()
var good_names := PackedStringArray()
var good_cat := PackedStringArray()
var good_base := PackedFloat64Array()
var n_good := PackedInt32Array()
var n_qty := PackedFloat64Array()
var n_weight := PackedFloat64Array()
var n_mult := PackedFloat64Array()      # NN * PC
var n_group := PackedInt32Array()
var grp_b := PackedInt32Array()         # start index of each need group, plus NN at the end
var floor_w := PackedFloat64Array()     # PC
var sub_w := PackedFloat64Array()       # PC

var b_ids := PackedStringArray()
var b_names := PackedStringArray()
var b_cat := PackedStringArray()
var b_cost := PackedFloat64Array()
var b_work := PackedFloat64Array()      # B * PC workers per level
var b_work_total := PackedFloat64Array()
var b_in_g: Array = []                  # per b: PackedInt32Array
var b_in_q: Array = []                  # per b: PackedFloat64Array
var b_out_g := PackedInt32Array()
var b_out_q := PackedFloat64Array()
var b_bg_g: Array = []                  # build goods
var b_bg_q: Array = []
var b_mod := PackedInt32Array()         # 0 farm, 1 mine, 2 factory, -1 none
var b_state := PackedByteArray()
var b_owner := PackedInt32Array()       # 0 land, 1 capital, 2 state
var b_coastal := PackedByteArray()
var b_terrain: Array = []
var b_tech := PackedStringArray()
var b_deposit := PackedInt32Array()     # 0 none, 1 coal, 2 iron
var b_tprod: Array = []                 # per b: PackedFloat64Array(8)
var b_maxlvl := PackedInt32Array()
var b_primary := PackedByteArray()
var b_mineff := PackedFloat64Array()    ## output floor when inputs are short (tools make primary work faster, they do not gate it)
var i_farm := 0
var i_railway := 0
var i_admin := 0
var i_fishing := 0
var i_ranch := 0
var i_logging := 0
var i_coal := 0
var i_iron := 0
var i_merchant := 0
var g_grain := 0
var g_arms := 0

# --- market state (country x good)
var mp := PackedFloat64Array()
var ms := PackedFloat64Array()
var md := PackedFloat64Array()
var fill := PackedFloat64Array()
var sold := PackedFloat64Array()
var src_flow := PackedFloat64Array()    # (c*G+g)*T + tag
var snk_flow := PackedFloat64Array()
var ref_price := PackedFloat64Array()   # window start for explanations (4-8 weeks old)
var ref_supply := PackedFloat64Array()
var ref_demand := PackedFloat64Array()
var ref_src := PackedFloat64Array()
var ref_snk := PackedFloat64Array()
var new_price := PackedFloat64Array()   # newer snapshot, becomes ref at the next period
var new_supply := PackedFloat64Array()
var new_demand := PackedFloat64Array()
var new_src := PackedFloat64Array()
var new_snk := PackedFloat64Array()
var extra_demand := PackedFloat64Array()  # c*G+g  additional weekly demand (events, tests)
var need_scale := PackedFloat64Array()    # c*NN
var need_w := PackedFloat64Array()        # c*NN effective sol weights
var need_fill := PackedFloat64Array()     # c*NN share of standard basket delivered

# --- country state
var tre := PackedFloat64Array()
var gdp_w := PackedFloat64Array()
var tax_base := PackedFloat64Array()
var bud_tax := PackedFloat64Array()
var bud_tariff := PackedFloat64Array()
var bud_admin := PackedFloat64Array()
var bud_mil := PackedFloat64Array()
var bud_con := PackedFloat64Array()
var bud_int := PackedFloat64Array()
var mil_arms := PackedFloat64Array()
var trade_vol := PackedFloat64Array()
var tax_level_local := PackedInt32Array()
var admin_staff := PackedFloat64Array()
var short_lost := PackedFloat64Array()  # c*B
var short_lvl := PackedFloat64Array()
var short_good := PackedInt32Array()
var queues: Array = []                  # per country: Array of {province,type,progress,cost}

# --- province state
var lvl := PackedInt32Array()           # p*B
var cap := PackedInt32Array()
var emp := PackedFloat64Array()
var staff := PackedFloat64Array()
var wpw := PackedFloat64Array()
var profit := PackedFloat64Array()
var bout := PackedFloat64Array()
var bio := PackedFloat64Array()
var bscale := PackedFloat64Array()
var tp := PackedFloat64Array()
var rail_bonus := PackedFloat64Array()  # p
var dep := PackedFloat64Array()         # p*2 : coal, iron richness
var vacant := PackedFloat64Array()      # p*PC

# --- per-week scratch (not saved)
var _m_out := PackedFloat64Array()      # c*3 : farm, mine, factory output multipliers
var _m_wage := PackedFloat64Array()
var _m_tax := PackedFloat64Array()
var _m_tariff := PackedFloat64Array()
var _m_trade := PackedFloat64Array()
var _ctl := PackedInt32Array()
var _own := PackedInt32Array()          # world.p_owner (same array, cached for the hot loops)
var _inc := PackedFloat64Array()
var _emp := PackedFloat64Array()
var _partners: Array = []
var _tariff_rev := PackedFloat64Array()
var _act := PackedInt32Array()
var _con_money := PackedFloat64Array()
var _con_ok := PackedByteArray()
var _tmp_want := PackedFloat64Array()
var qpc := PackedFloat64Array()         # (c*PC+prof)*NN + j  per-capita wants (derived from need_scale)
var _gcost := PackedFloat64Array()
var _gsc := PackedFloat64Array()        # per cohort and need group: share of the basket bought
var _hh_want := PackedFloat64Array()
var _p_act := PackedInt32Array()        # p*B active building indices
var _p_nact := PackedInt32Array()       # p count of active buildings
var _cp_ns := PackedFloat64Array()
var _nf_num := PackedFloat64Array()
var _c_pop := PackedFloat64Array()
var _mf_fill := PackedFloat64Array()

const PERSIST_F64 := ["mp", "ms", "md", "fill", "sold", "src_flow", "snk_flow", "ref_price", "ref_supply",
	"ref_demand", "ref_src", "ref_snk", "new_price", "new_supply", "new_demand", "new_src", "new_snk", "extra_demand",
	"need_scale", "need_w", "need_fill", "tre", "gdp_w", "tax_base", "bud_tax", "bud_tariff", "bud_admin", "bud_mil",
	"bud_con", "bud_int", "mil_arms", "trade_vol", "admin_staff", "short_lost", "short_lvl", "emp", "staff", "wpw",
	"profit", "bout", "bio", "bscale", "tp", "rail_bonus", "dep", "vacant"]
const PERSIST_I32 := ["tax_level_local", "short_good", "lvl", "cap"]


# =========================================================================== setup
func setup(state) -> void:
	s = state
	world = s.world
	pops = s.pops
	C = world.country_count
	_load_defs()
	_alloc()
	_seeded = false


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Missing " + path)
		return {}
	var j = JSON.parse_string(f.get_as_text())
	return j if j is Dictionary else {}


func _load_defs() -> void:
	var gj := _read_json("res://data/scenario/goods.json")
	var goods: Array = gj.get("goods", [])
	G = goods.size()
	good_ids.resize(G); good_names.resize(G); good_cat.resize(G); good_base.resize(G)
	for g in G:
		good_ids[g] = goods[g]["id"]
		good_names[g] = goods[g]["name"]
		good_cat[g] = goods[g].get("category", "")
		good_base[g] = float(goods[g]["base_price"])
	g_grain = good_index("grain")
	g_arms = good_index("arms")
	var needs: Array = gj.get("needs", [])
	NN = needs.size()
	n_good.resize(NN); n_qty.resize(NN); n_weight.resize(NN); n_mult.resize(NN * PC); n_group.resize(NN)
	grp_b.clear()
	for j in NN:
		n_good[j] = good_index(needs[j]["good"])
		n_qty[j] = float(needs[j]["qty"])
		n_weight[j] = float(needs[j]["weight"])
		n_group[j] = int(needs[j].get("group", j))
		if j == 0 or n_group[j] != n_group[j - 1]:
			grp_b.append(j)
		for k in PC:
			n_mult[j * PC + k] = float(needs[j]["mult"][k])
	grp_b.append(NN)
	floor_w.resize(PC); sub_w.resize(PC)
	floor_w.fill(0.0); sub_w.fill(0.0)
	var wf: Dictionary = gj.get("wage_floor", {})
	var sb: Dictionary = gj.get("subsistence", {})
	for k in PC:
		floor_w[k] = float(wf.get(PROF_KEYS[k], 0.0))
		sub_w[k] = float(sb.get(PROF_KEYS[k], 0.0))

	var bj := _read_json("res://data/scenario/buildings.json")
	var bl: Array = bj.get("buildings", [])
	B = bl.size()
	b_ids.resize(B); b_names.resize(B); b_cat.resize(B); b_cost.resize(B)
	b_work.resize(B * PC); b_work.fill(0.0)
	b_work_total.resize(B)
	b_out_g.resize(B); b_out_q.resize(B); b_mod.resize(B); b_state.resize(B); b_owner.resize(B)
	b_coastal.resize(B); b_tech.resize(B); b_deposit.resize(B); b_maxlvl.resize(B); b_primary.resize(B); b_mineff.resize(B)
	b_in_g.clear(); b_in_q.clear(); b_bg_g.clear(); b_bg_q.clear(); b_terrain.clear(); b_tprod.clear()
	for b in B:
		var d: Dictionary = bl[b]
		b_ids[b] = d["id"]
		b_names[b] = d["name"]
		b_cat[b] = d["category"]
		b_cost[b] = float(d["cost"])
		var wt := 0.0
		for k in PC:
			var v := float(d["workers"].get(PROF_KEYS[k], 0.0))
			b_work[b * PC + k] = v
			wt += v
		b_work_total[b] = wt
		var ig := PackedInt32Array()
		var iq := PackedFloat64Array()
		for gid: String in d["inputs"]:
			ig.append(good_index(gid))
			iq.append(float(d["inputs"][gid]))
		b_in_g.append(ig); b_in_q.append(iq)
		b_out_g[b] = -1
		b_out_q[b] = 0.0
		for gid: String in d["outputs"]:
			b_out_g[b] = good_index(gid)
			b_out_q[b] = float(d["outputs"][gid])
		var bg := PackedInt32Array()
		var bq := PackedFloat64Array()
		for gid: String in d["build_goods"]:
			bg.append(good_index(gid))
			bq.append(float(d["build_goods"][gid]))
		b_bg_g.append(bg); b_bg_q.append(bq)
		var m: String = str(d.get("mod", "")) if d.get("mod", null) != null else ""
		b_mod[b] = 0 if m == "farm" else (1 if m == "mine" else (2 if m == "factory" else -1))
		b_state[b] = 1 if d.get("state_run", false) else 0
		var ow: String = d.get("owner", "capital")
		b_owner[b] = 0 if ow == "land" else (2 if ow == "state" else 1)
		b_coastal[b] = 1 if d.get("coastal_only", false) else 0
		b_tech[b] = str(d["requires_tech"]) if d.get("requires_tech", null) != null else ""
		var dp: String = str(d.get("deposit", ""))
		b_deposit[b] = 1 if dp == "coal" else (2 if dp == "iron" else 0)
		var tl := PackedInt32Array()
		for v in d.get("terrain", []):
			tl.append(int(v))
		b_terrain.append(tl)
		var tpr := PackedFloat64Array()
		for k in Biome.COUNT:
			tpr.append(1.0)
		if d.has("terrain_prod"):
			for k in Biome.COUNT:
				tpr[k] = float(d["terrain_prod"][k])
		b_tprod.append(tpr)
		b_maxlvl[b] = int(d["max_level"]) if d.get("max_level", null) != null else -1
		b_primary[b] = 1 if d["category"] == "primary" else 0
		b_mineff[b] = float(d.get("min_efficiency", 0.0))
	i_farm = building_index("farm")
	i_railway = building_index("railway")
	i_admin = building_index("government_admin")
	i_fishing = building_index("fishing_wharf")
	i_ranch = building_index("ranch")
	i_logging = building_index("logging_camp")
	i_coal = building_index("coal_mine")
	i_iron = building_index("iron_mine")
	i_merchant = building_index("merchant_quarter")
	T = B + 5
	TAG_POPS = B
	TAG_CON = B + 1
	TAG_MIL = B + 2
	TAG_TRADE = B + 3
	TAG_OTHER = B + 4


func _alloc() -> void:
	var P: int = world.province_count
	var cg := C * G
	for a in ["mp", "ms", "md", "fill", "sold", "ref_price", "ref_supply", "ref_demand", "new_price",
			"new_supply", "new_demand", "extra_demand"]:
		var arr := PackedFloat64Array()
		arr.resize(cg)
		arr.fill(0.0)
		set(a, arr)
	for a in ["src_flow", "snk_flow", "ref_src", "ref_snk", "new_src", "new_snk"]:
		var arr := PackedFloat64Array()
		arr.resize(cg * T)
		arr.fill(0.0)
		set(a, arr)
	for a in ["need_scale", "need_w", "need_fill"]:
		var arr := PackedFloat64Array()
		arr.resize(C * NN)
		arr.fill(1.0)
		set(a, arr)
	for a in ["tre", "gdp_w", "tax_base", "bud_tax", "bud_tariff", "bud_admin", "bud_mil", "bud_con", "bud_int",
			"mil_arms", "trade_vol", "admin_staff", "_m_wage", "_m_tax", "_m_tariff", "_m_trade", "_tariff_rev", "_con_money"]:
		var arr := PackedFloat64Array()
		arr.resize(C)
		arr.fill(0.0)
		set(a, arr)
	_m_out.resize(C * 3)
	_m_out.fill(1.0)
	tax_level_local.resize(C); tax_level_local.fill(1)
	_con_ok.resize(C); _con_ok.fill(1)
	short_lost.resize(C * B); short_lost.fill(0.0)
	short_lvl.resize(C * B); short_lvl.fill(0.0)
	short_good.resize(C * B); short_good.fill(-1)
	queues.clear()
	_partners.clear()
	for c in C:
		queues.append([])
		_partners.append(PackedInt32Array())
	var pb := P * B
	lvl.resize(pb); lvl.fill(0)
	cap.resize(pb); cap.fill(0)
	for a in ["emp", "staff", "wpw", "profit", "bout", "bio", "bscale", "tp"]:
		var arr := PackedFloat64Array()
		arr.resize(pb)
		arr.fill(1.0 if (a == "tp" or a == "bio") else 0.0)
		set(a, arr)
	rail_bonus.resize(P); rail_bonus.fill(0.0)
	dep.resize(P * 2); dep.fill(0.0)
	vacant.resize(P * PC); vacant.fill(0.0)
	_ctl.resize(P); _ctl.fill(-1)
	_inc.resize(P * PC)
	_emp.resize(P * PC)
	var ng_cnt := maxi(grp_b.size() - 1, 1)
	_gsc.resize(P * PC * ng_cnt)
	_gcost.resize(C * PC * ng_cnt)
	_cp_ns.resize(C * PC * ng_cnt)
	_nf_num.resize(C * NN)
	_c_pop.resize(C)
	_mf_fill.resize(C * PC * NN)
	_hh_want.resize(C * NN)
	_tmp_want.resize(NN)
	_act.resize(B)
	_p_act.resize(pb)
	_p_nact.resize(P); _p_nact.fill(0)
	for i in cg:
		mp[i] = good_base[i % G]
		fill[i] = 1.0
		sold[i] = 1.0


func good_index(id: String) -> int:
	return good_ids.find(id)


func building_index(id: String) -> int:
	return b_ids.find(id)


# --------------------------------------------------------------------------- seeding: terrain & deposits
func _seed_terrain() -> void:
	var P: int = world.province_count
	for p in range(1, P):
		var mix: PackedFloat32Array = world.p_terrain_mix[p]
		for b in B:
			var v := 0.0
			var tpr: PackedFloat64Array = b_tprod[b]
			for k in mini(mix.size(), Biome.COUNT):
				v += mix[k] * tpr[k]
			tp[p * B + b] = v
		var rc := 0.0
		var ri := 0.0
		for k in mini(mix.size(), Biome.COUNT):
			rc += mix[k] * DEP_COAL[k]
			ri += mix[k] * DEP_IRON[k]
		# every land province has at least a thin seam, so no country can lose all its coal or iron
		dep[p * 2] = maxf(rc * (0.35 + 0.65 * s.rng.randf()), 0.15)
		dep[p * 2 + 1] = maxf(ri * (0.35 + 0.65 * s.rng.randf()), 0.15)
	# every country gets at least one decent coal and iron deposit
	for c in C:
		for kind in 2:
			var best := -1
			var bv := -1.0
			for p: int in world.c_provinces[c]:
				if dep[p * 2 + kind] > bv:
					bv = dep[p * 2 + kind]
					best = p
			if best >= 0 and bv < 0.55:
				dep[best * 2 + kind] = 0.55
	for p in range(1, P):
		var area_f := sqrt(float(world.p_area[p]) / 4500.0)
		for kind in 2:
			var b := i_coal if kind == 0 else i_iron
			var r := dep[p * 2 + kind]
			if r > 0.12:
				cap[p * B + b] = maxi(1, int(round(r * 14.0 * area_f)))
				tp[p * B + b] = 0.7 + 0.6 * r
			else:
				cap[p * B + b] = 0
				tp[p * B + b] = 0.0


# --------------------------------------------------------------------------- seeding: buildings
func _rank_of(c: int) -> String:
	return world.c_rank[c]


func _est_income_pc(prof: int) -> float:
	if prof < P_ARISTOCRAT:
		return EMPLOY_TARGET * floor_w[prof] + (1.0 - EMPLOY_TARGET) * sub_w[prof]
	if prof == P_ARISTOCRAT:
		return sub_w[prof] + 2.0
	if prof == P_CAPITALIST:
		return sub_w[prof] + 8.0
	return floor_w[prof]


func _seed_country(c: int) -> void:
	var provs: PackedInt32Array = world.c_provinces[c]
	var np := provs.size()
	if np == 0:
		return
	var rank := _rank_of(c)
	var cov: float = COVERAGE.get(rank, 0.8)
	var pop_c := 0.0
	var coast_pea := 0.0
	var pop_k := PackedFloat64Array()
	pop_k.resize(np)
	for k in np:
		var p := provs[k]
		pop_k[k] = pops.province_pop(p)
		pop_c += pop_k[k]
		if world.p_port[p].x >= 0.0:
			coast_pea += pops.size[p * PC + P_PEASANT]
	# --- fish vs grain
	var j_fish := -1
	var j_grain := -1
	for j in NN:
		if good_ids[n_good[j]] == "fish":
			j_fish = j
		elif n_good[j] == g_grain:
			j_grain = j
	var s_f := 1.0
	if j_fish >= 0 and j_grain >= 0:
		var fish_dem := pop_c * n_qty[j_fish]
		var fish_cap := coast_pea * 0.22 / maxf(b_work[i_fishing * PC + P_PEASANT], 1.0) * b_out_q[i_fishing] * _mf(c, i_fishing) * EMPLOY_TARGET
		s_f = clampf(fish_cap / maxf(fish_dem, 1.0), 0.0, 1.0)
		need_scale[c * NN + j_fish] = s_f
		need_scale[c * NN + j_grain] = 1.0 + (1.0 - s_f) * n_qty[j_fish] / n_qty[j_grain]
	for j in NN:
		need_w[c * NN + j] = n_weight[j]
	if j_fish >= 0:
		need_w[c * NN + j_fish] = n_weight[j_fish] * s_f
		need_w[c * NN + j_grain] = n_weight[j_grain] + n_weight[j_fish] * (1.0 - s_f)
	# --- final demand estimate (household baskets at base prices)
	var F := PackedFloat64Array()
	F.resize(G)
	F.fill(0.0)
	for k in np:
		var p := provs[k]
		for prof in PC:
			var N: float = pops.size[p * PC + prof]
			if N <= 0.0:
				continue
			_ration(c, prof, N, N * _est_income_pc(prof) * (1.0 - TAX_BASE) * SPEND_SHARE, true, _tmp_want, 0)
			for j in NN:
				F[n_good[j]] += _tmp_want[j]
	var arms_d: float = s.arms_demand(c)
	F[g_arms] += maxf(arms_d * 1.2, pop_c * float(ARMS_PC.get(rank, 0.0003)))
	for g in G:
		if good_cat[g] == "consumer" or good_cat[g] == "military" or good_cat[g] == "service":
			F[g] *= cov
	# --- required output per good (final demand + what the chain itself eats)
	var Q := F.duplicate()
	for it in 14:
		var Qn := F.duplicate()
		for b in B:
			if b_state[b] == 1:
				continue
			var go := b_out_g[b]
			if go >= 0 and Q[go] > 0.0:
				var lv: float = Q[go] / (b_out_q[b] * _mf(c, b)) * (1.3 if b_primary[b] == 1 else 1.0)
				var ig: PackedInt32Array = b_in_g[b]
				var iq: PackedFloat64Array = b_in_q[b]
				for j in ig.size():
					Qn[ig[j]] += lv * iq[j]
		Q = Qn
	# --- pools of workers that can be created per province
	var used := []
	for prof in PC:
		var arr := PackedFloat64Array()
		arr.resize(np)
		arr.fill(0.0)
		used.append(arr)
	var pool_cap := [0.0, 0.5, 0.18, 0.10]
	# non-peasant jobs first
	var order := [i_logging, i_coal, i_iron, i_merchant]
	for b in B:
		if b_primary[b] == 0 and b != i_merchant and b_state[b] == 0:
			order.append(b)
	for b in order:
		var go := b_out_g[b]
		if go < 0 or Q[go] <= 0.0:
			continue
		_place_output(c, provs, pop_k, b, Q[go], used, pool_cap)
	# government administration and railways
	var admin_lv := int(ceil(pop_c / ADMIN_POP))
	_place_levels(c, provs, pop_k, i_admin, admin_lv, used, pool_cap, true)
	var rail_lv := 0
	if rank == "great":
		rail_lv = 8
	elif rank == "major":
		rail_lv = 4
	if rail_lv > 0:
		var cap_k := provs.find(world.c_capital[c])
		if cap_k >= 0:
			var l1: int = rail_lv / 2
			lvl[provs[cap_k] * B + i_railway] = l1
			used[P_LABORER][cap_k] += l1 * b_work[i_railway * PC + P_LABORER]
			var rest := rail_lv - l1
			for k in np:
				if rest <= 0:
					break
				if k != cap_k and world.p_tier[provs[k]] >= 3 and pop_k[k] > 150000.0:
					lvl[provs[k] * B + i_railway] = 2
					used[P_LABORER][k] += 2 * b_work[i_railway * PC + P_LABORER]
					rest -= 2
	# --- cohort sizing from job needs
	for k in np:
		var p := provs[k]
		var base := p * PC
		var pop := pop_k[k]
		var need_m: float = used[P_MACHINIST][k] / EMPLOY_TARGET
		var need_l: float = used[P_LABORER][k] / EMPLOY_TARGET
		var need_c: float = used[P_CLERK][k] / EMPLOY_TARGET
		var old_l: float = pops.size[base + P_LABORER]
		var old_c: float = pops.size[base + P_CLERK]
		var new_l := maxf(need_l, 0.015 * pop)
		var new_c := maxf(need_c, 0.02 * pop)   # educated clerks stay clerks (and do the research) even without a desk
		var new_m := need_m
		var peas: float = pops.size[base + P_PEASANT] + (old_l - new_l) + (old_c - new_c) - new_m
		if peas < 0.12 * pop:
			peas = 0.12 * pop
		pops.size[base + P_LABORER] = new_l
		pops.size[base + P_CLERK] = new_c
		pops.size[base + P_MACHINIST] = new_m
		var tot_other := 0.0
		for prof in PC:
			if prof != P_PEASANT:
				tot_other += pops.size[base + prof]
		pops.size[base + P_PEASANT] = maxf(pop - tot_other, 0.0)
		if new_m > 0.0:
			pops.literacy[base + P_MACHINIST] = maxf(pops.literacy[base + P_MACHINIST], 0.25)
	# --- peasant jobs
	var pea_pool := PackedFloat64Array()
	pea_pool.resize(np)
	for k in np:
		pea_pool[k] = pops.size[provs[k] * PC + P_PEASANT] * EMPLOY_TARGET
	# Land pressure: if the peasantry is larger than the harvest needs, each worker produces less
	# (instead of leaving a quarter of the country jobless); if labour is short, a little more.
	var fish_q := minf(Q[good_index("fish")], coast_pea * 0.22 / b_work[i_fishing * PC] * b_out_q[i_fishing] * _mf(c, i_fishing) * EMPLOY_TARGET)
	var peas_jobs: Array = [[i_farm, Q[g_grain]], [i_ranch, Q[good_index("fibers")]], [i_fishing, fish_q]]
	var labor_avail := 0.0
	for k in np:
		labor_avail += pea_pool[k]
	var labor_need := 0.0
	for e: Array in peas_jobs:
		var jb: int = e[0]
		var tw := 0.0
		var pw := 0.0
		for k in np:
			var pq := provs[k]
			if b_coastal[jb] == 1 and world.p_port[pq].x < 0.0:
				continue
			tw += pea_pool[k] * tp[pq * B + jb]
			pw += pea_pool[k]
		if pw > 0.0 and tw > 0.0 and e[1] > 0.0:
			labor_need += e[1] / (b_out_q[jb] * _mf(c, jb) * (tw / pw)) * b_work[jb * PC + P_PEASANT]
	var r_p := clampf(labor_need / maxf(labor_avail, 1.0), 0.45, 1.3)
	for k in np:
		for e: Array in peas_jobs:
			tp[provs[k] * B + int(e[0])] *= r_p
	if Q[good_index("fish")] > 0.0:
		_place_peasant(c, provs, i_fishing, fish_q, pea_pool, 0.25)
	if Q[good_index("fibers")] > 0.0:
		_place_peasant(c, provs, i_ranch, Q[good_index("fibers")], pea_pool, 1.0)
	_place_peasant(c, provs, i_farm, Q[g_grain], pea_pool, 1.0)
	# --- caps, initial income
	for k in np:
		var p := provs[k]
		var base := p * PC
		for b in B:
			if b_primary[b] == 1 and b_deposit[b] == 0:
				var cur := lvl[p * B + b]
				var allowed := tp[p * B + b] >= 0.15 and _terrain_ok(b, p)
				if b_coastal[b] == 1 and world.p_port[p].x < 0.0:
					allowed = false
				if allowed:
					var prof := P_PEASANT if b_work[b * PC + P_PEASANT] > 0.0 else P_LABORER
					var pool_sz: float = pops.size[base + prof]
					var cmax: int = int(ceil(1.7 * pool_sz / b_work[b * PC + prof] * (0.5 if b == i_ranch else 1.0)))
					cap[p * B + b] = maxi(cmax, cur + int(ceil(cur * 0.5)) + 1)
				else:
					cap[p * B + b] = cur
			elif b_deposit[b] > 0:
				cap[p * B + b] = maxi(cap[p * B + b], lvl[p * B + b])
			else:
				cap[p * B + b] = maxi(b_maxlvl[b], lvl[p * B + b])
		for prof in PC:
			pops.income[base + prof] = pops.size[base + prof] * _est_income_pc(prof)
	for k in np:
		for b in B:
			var p2 := provs[k]
			wpw[p2 * B + b] = _floor_avg(b)


## Tech/law output multiplier of building type b in country c (as used by production).
func _mf(c: int, b: int) -> float:
	var mk := b_mod[b]
	return _m_out[c * 3 + mk] if mk >= 0 else 1.0


func _floor_avg(b: int) -> float:
	var t := 0.0
	var w := 0.0
	for k in LABOR_PROFS:
		t += b_work[b * PC + k] * floor_w[k]
		w += b_work[b * PC + k]
	return t / w if w > 0.0 else 1.0


func _terrain_ok(b: int, p: int) -> bool:
	var tl: PackedInt32Array = b_terrain[b]
	return tl.is_empty() or tl.has(world.p_terrain[p])


## Level capacity of province k for building b given the worker pools already promised.
func _room(k: int, b: int, used: Array, pool_cap: Array, pop: float) -> float:
	var room := 1.0e9
	for prof in range(1, LABOR_PROFS):
		var wk := b_work[b * PC + prof]
		if wk > 0.0:
			room = minf(room, (pool_cap[prof] * pop - used[prof][k]) / wk)
	return maxf(room, 0.0)


func _place_output(c: int, provs: PackedInt32Array, pop_k: PackedFloat64Array, b: int, q_req: float, used: Array, pool_cap: Array) -> void:
	var np := provs.size()
	var eff_out := b_out_q[b] * _mf(c, b)
	var w := PackedFloat64Array()
	w.resize(np)
	var capk := PackedFloat64Array()
	capk.resize(np)
	var secondary := b_primary[b] == 0
	for k in np:
		var p := provs[k]
		var room := _room(k, b, used, pool_cap, pop_k[k])
		var cp: float = minf(room, float(maxi(b_maxlvl[b], 0)) if b_maxlvl[b] > 0 else 1.0e9)
		var weight := 0.0
		if secondary:
			weight = pop_k[k] * pow(1.0 + world.p_tier[p], 1.5)
		else:
			if not _terrain_ok(b, p) and b_deposit[b] == 0:
				weight = 0.0
			elif b_deposit[b] > 0:
				weight = pop_k[k] * dep[p * 2 + b_deposit[b] - 1]
				cp = minf(cp, float(cap[p * B + b]))
			else:
				weight = pop_k[k] * tp[p * B + b]
				if tp[p * B + b] < 0.2:
					weight = 0.0
		w[k] = weight
		capk[k] = cp
	if b_deposit[b] > 0:
		# make sure a country can mine as much as its own industry needs (a rich vein in its best province)
		var tot_cap := 0.0
		var best_k := 0
		for k in np:
			tot_cap += capk[k]
			if w[k] > w[best_k]:
				best_k = k
		var need_lv := q_req / maxf(eff_out, 1.0)
		if tot_cap < need_lv:
			var extra := int(ceil(need_lv - tot_cap))
			cap[provs[best_k] * B + b] += extra
			capk[best_k] += extra
	if secondary or b_deposit[b] > 0:
		# concentrate industry and mining in the strongest provinces
		var est_lv := q_req / eff_out
		var keep := maxi(1, int(ceil(est_lv / (12.0 if b == i_merchant else (2.0 if b_deposit[b] > 0 else 8.0)))))
		if b_deposit[b] > 0:
			keep = maxi(keep, mini(3, np))   # never a single point of failure
		var idx: Array = range(np)
		idx.sort_custom(func(a, bb): return w[a] > w[bb] or (w[a] == w[bb] and a < bb))
		for r in np:
			if r >= keep:
				w[idx[r]] = 0.0
	var alloc := PackedFloat64Array()
	alloc.resize(np)
	alloc.fill(0.0)
	var remaining := q_req
	for rnd in 5:
		var sum_we := 0.0
		for k in np:
			if w[k] > 0.0 and alloc[k] < capk[k] - 1e-9:
				var e := eff_out * (tp[provs[k] * B + b] if b_primary[b] == 1 else 1.0)
				sum_we += w[k] * e
		if sum_we <= 0.0 or remaining <= 1e-6:
			break
		var got := 0.0
		for k in np:
			if w[k] > 0.0 and alloc[k] < capk[k] - 1e-9:
				var e2 := eff_out * (tp[provs[k] * B + b] if b_primary[b] == 1 else 1.0)
				var add := remaining * w[k] / sum_we
				var take := minf(add, capk[k] - alloc[k])
				alloc[k] += take
				got += take * e2
		remaining = maxf(remaining - got, 0.0)
	_commit(provs, b, alloc, capk, used)


func _place_levels(c: int, provs: PackedInt32Array, pop_k: PackedFloat64Array, b: int, total: int, used: Array, pool_cap: Array, favour_cap: bool) -> void:
	var np := provs.size()
	if total <= 0:
		return
	var w := PackedFloat64Array()
	w.resize(np)
	var capk := PackedFloat64Array()
	capk.resize(np)
	for k in np:
		var p := provs[k]
		capk[k] = minf(_room(k, b, used, pool_cap, pop_k[k]), float(b_maxlvl[b]))
		w[k] = pop_k[k] * pow(1.0 + world.p_tier[p], 1.5) * (3.0 if (favour_cap and p == world.c_capital[c]) else 1.0)
	var keep := maxi(1, int(ceil(total / 5.0)))
	var idx: Array = range(np)
	idx.sort_custom(func(a, bb): return w[a] > w[bb] or (w[a] == w[bb] and a < bb))
	for r in np:
		if r >= keep:
			w[idx[r]] = 0.0
	var alloc := PackedFloat64Array()
	alloc.resize(np)
	alloc.fill(0.0)
	var remaining := float(total)
	for rnd in 4:
		var sw := 0.0
		for k in np:
			if w[k] > 0.0 and alloc[k] < capk[k] - 1e-9:
				sw += w[k]
		if sw <= 0.0 or remaining <= 1e-6:
			break
		var got := 0.0
		for k in np:
			if w[k] > 0.0 and alloc[k] < capk[k] - 1e-9:
				var take := minf(remaining * w[k] / sw, capk[k] - alloc[k])
				alloc[k] += take
				got += take
		remaining = maxf(remaining - got, 0.0)
	_commit(provs, b, alloc, capk, used)


## Round fractional allocations to integer levels with error diffusion and record worker use.
func _commit(provs: PackedInt32Array, b: int, alloc: PackedFloat64Array, capk: PackedFloat64Array, used: Array) -> void:
	var tot := 0.0
	var best := 0
	for k in provs.size():
		tot += alloc[k]
		if alloc[k] > alloc[best]:
			best = k
	if tot > 0.12 and tot < 0.5 and capk[best] >= 0.5:
		alloc[best] = 1.0   # a real need is never rounded down to nothing
	var acc := 0.0
	var placed := 0
	for k in provs.size():
		acc += alloc[k]
		var lv := int(round(acc)) - placed
		lv = mini(lv, int(floor(capk[k] + 0.5)))
		if b_maxlvl[b] > 0:
			lv = mini(lv, b_maxlvl[b])
		lv = maxi(lv, 0)
		placed += lv
		if lv > 0:
			lvl[provs[k] * B + b] = lv
			for prof in PC:
				if b_work[b * PC + prof] > 0.0:
					used[prof][k] += lv * b_work[b * PC + prof]


func _place_peasant(c: int, provs: PackedInt32Array, b: int, q_req: float, pool: PackedFloat64Array, max_share: float) -> void:
	var np := provs.size()
	var wk := b_work[b * PC + P_PEASANT]
	var eff_out := b_out_q[b] * _mf(c, b)
	var w := PackedFloat64Array()
	w.resize(np)
	var capk := PackedFloat64Array()
	capk.resize(np)
	var pop_sz := PackedFloat64Array()
	pop_sz.resize(np)
	for k in np:
		var p := provs[k]
		var ok := _terrain_ok(b, p) and tp[p * B + b] >= 0.15
		if b_coastal[b] == 1 and world.p_port[p].x < 0.0:
			ok = false
		pop_sz[k] = pops.size[p * PC + P_PEASANT]
		w[k] = pop_sz[k] * tp[p * B + b] if ok else 0.0
		capk[k] = (pool[k] * max_share) / wk if ok else 0.0
		if b == i_ranch:
			capk[k] = minf(capk[k], 0.25 * pop_sz[k] / wk)
	var alloc := PackedFloat64Array()
	alloc.resize(np)
	alloc.fill(0.0)
	var remaining := q_req
	for rnd in 6:
		var den := 0.0
		for k in np:
			if w[k] > 0.0 and alloc[k] < capk[k] - 1e-9:
				den += w[k] * tp[provs[k] * B + b]
		if den <= 0.0 or remaining <= 1e-6:
			break
		var lam := remaining / (eff_out * den)
		var got := 0.0
		for k in np:
			if w[k] > 0.0 and alloc[k] < capk[k] - 1e-9:
				var take := minf(lam * w[k], capk[k] - alloc[k])
				alloc[k] += take
				got += take * eff_out * tp[provs[k] * B + b]
		remaining = maxf(remaining - got, 0.0)
	var acc := 0.0
	var placed := 0
	for k in np:
		acc += alloc[k]
		var lv := maxi(0, int(round(acc)) - placed)
		lv = mini(lv, int(floor(capk[k] + 0.5)))
		placed += lv
		if lv > 0:
			lvl[provs[k] * B + b] = lv
			pool[k] -= lv * wk


func _finish_seed() -> void:
	for c in C:
		queues[c] = []
	# prices, flows start at base; refs equal current
	new_price = mp.duplicate()
	ref_price = mp.duplicate()


## Run the economy for some weeks before the game starts, so prices, fills, wages and standard
## of living are at their natural values when the player takes control.
func warm_up(weeks: int) -> void:
	if not _seeded:
		_refresh_country_mods(s.alive)
		_seed_terrain()
		for c in C:
			_seed_country(c)
		_finish_seed()
		_seeded = true
	_build_qpc()
	for i in weeks:
		pops.tick_week()
		tick_week()
	for c in C:
		tre[c] = 16.0 * maxf(bud_tax[c] + bud_tariff[c], 0.0)
		queues[c] = []
	_snapshot_refs()
	_snapshot_refs()
	week = 0
	s.events.clear()


# =========================================================================== weekly tick
func tick_week() -> void:
	week += 1
	var alive: PackedByteArray = s.alive
	_own = world.p_owner
	_refresh_country_mods(alive)
	var P: int = world.province_count
	if s.military != null:
		var occ_arr: PackedInt32Array = s.military.occupier
		for p in range(1, P):
			var oc := occ_arr[p]
			_ctl[p] = oc if oc >= 0 else _own[p]
	else:
		for p in range(1, P):
			_ctl[p] = _own[p]
	ms.fill(0.0)
	md.fill(0.0)
	src_flow.fill(0.0)
	snk_flow.fill(0.0)
	_inc.fill(0.0)
	_emp.fill(0.0)
	vacant.fill(0.0)
	_tariff_rev.fill(0.0)
	_con_money.fill(0.0)
	trade_vol.fill(0.0)
	gdp_w.fill(0.0)
	bud_admin.fill(0.0)
	admin_staff.fill(0.0)
	short_lost.fill(0.0)
	short_lvl.fill(0.0)
	short_good.fill(-1)
	_phase_production(alive)
	_phase_household_demand(alive)
	_phase_state_demand(alive)
	_phase_trade(alive)
	_phase_settle(alive)
	_phase_construction(alive)
	_phase_budget(alive)
	if week % REF_PERIOD == 0:
		_snapshot_refs()
		_organic_growth(alive)


func _refresh_country_mods(alive: PackedByteArray) -> void:
	for c in C:
		if alive[c] == 0:
			continue
		_m_out[c * 3] = clampf(1.0 + s.modifier(c, "farm_output"), 0.5, 3.0)
		_m_out[c * 3 + 1] = clampf(1.0 + s.modifier(c, "mine_output"), 0.5, 3.0)
		_m_out[c * 3 + 2] = clampf(1.0 + s.modifier(c, "factory_output"), 0.5, 3.0)
		_m_wage[c] = clampf(1.0 + s.modifier(c, "wage_floor"), 0.5, 2.0)
		var tm: float = clampf(s.modifier(c, "tax_mult"), 0.2, 3.0)
		if s.politics == null:
			tm *= [0.65, 1.0, 1.4][clampi(tax_level_local[c], 0, 2)]
		_m_tax[c] = tm
		_m_tariff[c] = clampf(s.modifier(c, "tariff"), 0.0, 0.6)
		_m_trade[c] = clampf(s.modifier(c, "trade_bonus"), -0.5, 1.0)
		_partners[c] = s.trade_partners(c)


func _phase_production(alive: PackedByteArray) -> void:
	var P: int = world.province_count
	var psize: PackedFloat64Array = pops.size
	var act := _act
	for p in range(1, P):
		var c: int = _own[p]
		var pb := p * PC
		if c < 0 or alive[c] == 0:
			continue
		var base := p * B
		var nact := 0
		for b in B:
			if lvl[base + b] > 0:
				var w := wpw[base + b]
				var pos := nact
				while pos > 0 and wpw[base + act[pos - 1]] < w:
					act[pos] = act[pos - 1]
					pos -= 1
				act[pos] = b
				nact += 1
		_p_nact[p] = nact
		for a_i in nact:
			_p_act[base + a_i] = act[a_i]
		var rb := 1.0 + rail_bonus[p]
		var occ := 1.0 if _ctl[p] == c else OCCUPIED_OUTPUT
		var pool0 := psize[pb]
		var pool1 := psize[pb + 1]
		var pool2 := psize[pb + 2]
		var pool3 := psize[pb + 3]
		var cg := c * G
		var cb := c * B
		for a in nact:
			var b := act[a]
			var L := float(lvl[base + b])
			var wb := b * PC
			var w0 := L * b_work[wb]
			var w1 := L * b_work[wb + 1]
			var w2 := L * b_work[wb + 2]
			var w3 := L * b_work[wb + 3]
			var st := 1.0
			if w0 > 0.0:
				st = minf(st, pool0 / w0)
			if w1 > 0.0:
				st = minf(st, pool1 / w1)
			if w2 > 0.0:
				st = minf(st, pool2 / w2)
			if w3 > 0.0:
				st = minf(st, pool3 / w3)
			st = clampf(st, 0.0, 1.0)
			var h0 := w0 * st
			var h1 := w1 * st
			var h2 := w2 * st
			var h3 := w3 * st
			pool0 -= h0; pool1 -= h1; pool2 -= h2; pool3 -= h3
			_emp[pb] += h0; _emp[pb + 1] += h1; _emp[pb + 2] += h2; _emp[pb + 3] += h3
			vacant[pb] += w0 - h0; vacant[pb + 1] += w1 - h1; vacant[pb + 2] += w2 - h2; vacant[pb + 3] += w3 - h3
			emp[base + b] = h0 + h1 + h2 + h3
			staff[base + b] = st
			# inputs
			var io := 1.0
			var lim := -1
			var ig: PackedInt32Array = b_in_g[b]
			var iq: PackedFloat64Array = b_in_q[b]
			var ni := ig.size()
			for j in ni:
				var av := fill[cg + ig[j]]
				if av < io:
					io = av
					lim = ig[j]
			for j in ni:
				var want := L * iq[j] * st
				md[cg + ig[j]] += want
				snk_flow[(cg + ig[j]) * T + b] += want
			bio[base + b] = io
			bscale[base + b] = L * st
			var go := b_out_g[b]
			var out := 0.0
			if go >= 0:
				var mf := 1.0
				var mk := b_mod[b]
				if mk >= 0:
					mf = _m_out[c * 3 + mk]
				var ioe := b_mineff[b] + (1.0 - b_mineff[b]) * io
				out = L * b_out_q[b] * st * ioe * mf * rb * tp[base + b] * occ
				ms[cg + go] += out
				src_flow[(cg + go) * T + b] += out
			bout[base + b] = out
			short_lvl[cb + b] += L * st
			if io < 0.999 and st > 0.0:
				short_lost[cb + b] += L * st * (1.0 - io) * (1.0 - b_mineff[b])
				short_good[cb + b] = lim
			if b == i_admin:
				admin_staff[c] += emp[base + b]
		# railways raise output of the province next week
		var rl := lvl[base + i_railway]
		rail_bonus[p] = 0.2 * minf(1.0, float(rl) * staff[base + i_railway] / 4.0) if rl > 0 else 0.0


func _phase_household_demand(alive: PackedByteArray) -> void:
	var P: int = world.province_count
	var psize: PackedFloat64Array = pops.size
	var pinc: PackedFloat64Array = pops.income
	var NG := grp_b.size() - 1
	# per-capita cost of every need group at today's prices, per country and profession
	for c in C:
		if alive[c] == 0:
			continue
		var cg := c * G
		for prof in PC:
			var base := (c * PC + prof) * NN
			for gi in NG:
				var cost := 0.0
				for j in range(grp_b[gi], grp_b[gi + 1]):
					cost += qpc[base + j] * mp[cg + n_good[j]]
				_gcost[(c * PC + prof) * NG + gi] = cost
	_hh_want.fill(0.0)
	_cp_ns.fill(0.0)
	var cp_ns := _cp_ns
	for p in range(1, P):
		var c: int = _own[p]
		if c < 0 or alive[c] == 0:
			continue
		var net := (1.0 - minf(TAX_BASE * _m_tax[c], 0.6)) * SPEND_SHARE
		for prof in PC:
			var i := p * PC + prof
			var N := psize[i]
			if N <= 0.0:
				continue
			var cp := c * PC + prof
			var rem := pinc[i] * net / N
			var gb := i * NG
			var cpg := cp * NG
			for gi in NG:
				var cost := _gcost[cpg + gi]
				var sc := 1.0
				if cost > 0.0 and rem < cost:
					sc = rem / cost
				rem = maxf(rem - cost * sc, 0.0)
				_gsc[gb + gi] = sc
				cp_ns[cpg + gi] += N * sc
	for c in C:
		if alive[c] == 0:
			continue
		var hb := c * NN
		for prof in PC:
			var cp := c * PC + prof
			var cpg := cp * NG
			var qb := cp * NN
			for gi in NG:
				var ns_tot := cp_ns[cpg + gi]
				if ns_tot <= 0.0:
					continue
				for j in range(grp_b[gi], grp_b[gi + 1]):
					_hh_want[hb + j] += ns_tot * qpc[qb + j]
		var cg := c * G
		for j in NN:
			var want := _hh_want[hb + j]
			if want > 0.0:
				var g := n_good[j]
				md[cg + g] += want
				snk_flow[(cg + g) * T + TAG_POPS] += want


func _build_qpc() -> void:
	## Per-capita quantity wanted of each need, by country and profession (fish/grain scaling included).
	qpc.resize(C * PC * NN)
	for c in C:
		for prof in PC:
			for j in NN:
				qpc[(c * PC + prof) * NN + j] = n_qty[j] * n_mult[j * PC + prof] * need_scale[c * NN + j]


## Household shopping: spend `budget` on the needs basket, group by group; needs inside a group
## (grain+fish) are rationed together. Writes wanted quantities to out[off + j].
func _ration(c: int, prof: int, N: float, budget: float, base_prices: bool, out: PackedFloat64Array, off: int) -> void:
	var cg := c * G
	for gi in grp_b.size() - 1:
		var j0 := grp_b[gi]
		var j1 := grp_b[gi + 1]
		var cost := 0.0
		for j in range(j0, j1):
			var full := N * n_qty[j] * n_mult[j * PC + prof] * need_scale[c * NN + j]
			out[off + j] = full
			cost += full * (good_base[n_good[j]] if base_prices else mp[cg + n_good[j]])
		if cost <= 0.0:
			continue
		var sc := 1.0
		if budget < cost:
			sc = budget / cost
			for j in range(j0, j1):
				out[off + j] *= sc
		budget = maxf(budget - cost * sc, 0.0)


func _con_slots(c: int) -> int:
	return clampi(1 + int(pops.country_pop(c) / 2.5e6), 1, 6)


func _phase_state_demand(alive: PackedByteArray) -> void:
	for c in C:
		if alive[c] == 0:
			continue
		var cg := c * G
		var a: float = s.arms_demand(c)
		mil_arms[c] = a
		if a > 0.0:
			md[cg + g_arms] += a
			snk_flow[(cg + g_arms) * T + TAG_MIL] += a
		for g in G:
			var x := extra_demand[cg + g]
			if x > 0.0:
				md[cg + g] += x
				snk_flow[(cg + g) * T + TAG_OTHER] += x
		# construction demand for the projects that are being worked on
		var q: Array = queues[c]
		var ok := tre[c] > -8.0 * maxf(bud_tax[c], 1.0)
		_con_ok[c] = 1 if ok else 0
		if not ok:
			continue
		var n := mini(q.size(), _con_slots(c))
		for k in n:
			var t: int = q[k]["type"]
			var bg: PackedInt32Array = b_bg_g[t]
			var bq: PackedFloat64Array = b_bg_q[t]
			for j in bg.size():
				var d := bq[j] / BUILD_WEEKS
				md[cg + bg[j]] += d
				snk_flow[(cg + bg[j]) * T + TAG_CON] += d


func _phase_trade(alive: PackedByteArray) -> void:
	for a in C:
		if alive[a] == 0:
			continue
		var lst: PackedInt32Array = _partners[a]
		for b in lst:
			if b <= a or b >= C or alive[b] == 0:
				continue
			var capm := TRADE_CAP * maxf(0.1, 1.0 + 0.5 * (_m_trade[a] + _m_trade[b]))
			for g in G:
				var ia := a * G + g
				var ib := b * G + g
				var sa := ms[ia] - md[ia]
				var sb := ms[ib] - md[ib]
				var ex := -1
				var im := -1
				if sa > 0.0 and sb < 0.0:
					ex = ia
					im = ib
				elif sb > 0.0 and sa < 0.0:
					ex = ib
					im = ia
				else:
					continue
				if mp[ex] > mp[im] * 1.02:
					continue
				var surplus := ms[ex] - md[ex]
				var deficit := md[im] - ms[im]
				var flow := minf(minf(surplus, deficit), capm * ms[ex])
				if flow <= 0.0:
					continue
				md[ex] += flow
				snk_flow[ex * T + TAG_TRADE] += flow
				ms[im] += flow
				src_flow[im * T + TAG_TRADE] += flow
				var imc := im / G
				var value := flow * mp[ex]
				_tariff_rev[imc] += value * _m_tariff[imc]
				trade_vol[imc] += value
				trade_vol[ex / G] += value


func _phase_settle(alive: PackedByteArray) -> void:
	var P: int = world.province_count
	# ---- clearing ratios
	for i in C * G:
		var sp := ms[i]
		var dm := md[i]
		fill[i] = 1.0 if (dm <= sp or dm <= 0.0) else sp / dm
		sold[i] = 1.0 if (sp <= dm or sp <= 0.0) else dm / sp
	# ---- buildings: revenue, wages, dividends (iterate only active buildings)
	var fw0 := floor_w[0]; var fw1 := floor_w[1]; var fw2 := floor_w[2]; var fw3 := floor_w[3]
	var p_act := _p_act
	var p_nact := _p_nact
	for p in range(1, P):
		var c: int = _own[p]
		if c < 0 or alive[c] == 0:
			continue
		var nact := p_nact[p]
		if nact == 0:
			continue
		var base := p * B
		var pb := p * PC
		var cg := c * G
		var wmul := _m_wage[c]
		for a in nact:
			var b := p_act[base + a]
			var bsc := bscale[base + b]
			var io := bio[base + b]
			var go := b_out_g[b]
			var rev := 0.0
			if go >= 0:
				rev = bout[base + b] * sold[cg + go] * mp[cg + go]
			var cost_in := 0.0
			var ig: PackedInt32Array = b_in_g[b]
			var iq: PackedFloat64Array = b_in_q[b]
			for j in ig.size():
				cost_in += iq[j] * bsc * io * mp[cg + ig[j]]
			var va := rev - cost_in
			var wb := b * PC
			var bw := bsc * wmul
			var f0 := b_work[wb] * fw0 * bw
			var f1 := b_work[wb + 1] * fw1 * bw
			var f2 := b_work[wb + 2] * fw2 * bw
			var f3 := b_work[wb + 3] * fw3 * bw
			var floors_sum := f0 + f1 + f2 + f3
			if b_state[b] == 1:
				_inc[pb] += f0; _inc[pb + 1] += f1; _inc[pb + 2] += f2; _inc[pb + 3] += f3
				profit[base + b] = -(floors_sum + cost_in)
				wpw[base + b] = fw1 * wmul if b == i_railway else fw3 * wmul
				gdp_w[c] += floors_sum
				_state_cost_add(c, floors_sum + cost_in)
				continue
			var kb := 1.0
			if floors_sum > 0.0:
				kb = clampf(WAGE_SHARE * maxf(va, 0.0) / floors_sum, 1.0, MAX_WAGE_K)
			var wsum := floors_sum * kb
			_inc[pb] += f0 * kb; _inc[pb + 1] += f1 * kb; _inc[pb + 2] += f2 * kb; _inc[pb + 3] += f3 * kb
			var pr := va - wsum
			profit[base + b] = pr
			var workers := emp[base + b]
			wpw[base + b] = wsum / workers if workers > 0.0 else _floor_avg(b) * wmul
			gdp_w[c] += va
			if pr > 0.0:
				if b_owner[b] == 0:
					_inc[pb + P_ARISTOCRAT] += pr * 0.7
					_inc[pb + P_CAPITALIST] += pr * 0.3
				else:
					_inc[pb + P_CAPITALIST] += pr
	# ---- other incomes, tax base
	var psize: PackedFloat64Array = pops.size
	var sw0 := sub_w[0]; var sw1 := sub_w[1]; var sw2 := sub_w[2]; var sw3 := sub_w[3]
	var sw_ar := sub_w[P_ARISTOCRAT]; var sw_cap := sub_w[P_CAPITALIST]; var fw_sol := floor_w[P_SOLDIER]
	for c in C:
		tax_base[c] = 0.0
		bud_mil[c] = 0.0
	for p in range(1, P):
		var c: int = _own[p]
		if c < 0 or alive[c] == 0:
			continue
		var pb := p * PC
		var wmul := _m_wage[c]
		_inc[pb] += maxf(psize[pb] - _emp[pb], 0.0) * sw0
		_inc[pb + 1] += maxf(psize[pb + 1] - _emp[pb + 1], 0.0) * sw1
		_inc[pb + 2] += maxf(psize[pb + 2] - _emp[pb + 2], 0.0) * sw2
		_inc[pb + 3] += maxf(psize[pb + 3] - _emp[pb + 3], 0.0) * sw3
		var n_ar := psize[pb + P_ARISTOCRAT]
		var n_cap := psize[pb + P_CAPITALIST]
		var n_sol := psize[pb + P_SOLDIER]
		_emp[pb + P_ARISTOCRAT] = n_ar
		_emp[pb + P_CAPITALIST] = n_cap
		_emp[pb + P_SOLDIER] = n_sol
		_inc[pb + P_ARISTOCRAT] += n_ar * sw_ar
		_inc[pb + P_CAPITALIST] += n_cap * sw_cap
		var pay := n_sol * fw_sol * wmul
		_inc[pb + P_SOLDIER] += pay
		bud_mil[c] += pay
	# ---- consumption: delivered baskets -> standard of living
	var psol: PackedFloat64Array = pops.sol
	_nf_num.fill(0.0)
	_c_pop.fill(0.0)
	var nf_num := _nf_num
	var c_pop := _c_pop
	var mf_fill := _mf_fill
	var NG := grp_b.size() - 1
	for c in C:
		if alive[c] == 0:
			continue
		var cg := c * G
		for prof in PC:
			var base_m := (c * PC + prof) * NN
			for j in NN:
				mf_fill[base_m + j] = n_mult[j * PC + prof] * fill[cg + n_good[j]]
	for p in range(1, P):
		var c: int = _own[p]
		if c < 0 or alive[c] == 0:
			continue
		var cn := c * NN
		for prof in PC:
			var i := p * PC + prof
			var N := psize[i]
			if N <= 0.0:
				continue
			c_pop[c] += N
			var sol_t := 0.0
			var gb := i * NG
			var base_m := (c * PC + prof) * NN
			for gi in NG:
				var sc := _gsc[gb + gi]
				if sc <= 0.0:
					continue
				for j in range(grp_b[gi], grp_b[gi + 1]):
					var frac := minf(1.0, mf_fill[base_m + j] * sc)
					sol_t += need_w[cn + j] * frac
					nf_num[cn + j] += N * frac
			psol[i] += SOL_SMOOTH * (20.0 * sol_t - psol[i])
	for c in C:
		var den := c_pop[c]
		var cn := c * NN
		if den > 0.0:
			var inv_den := 1.0 / den
			for j in NN:
				var idx := cn + j
				need_fill[idx] = nf_num[idx] * inv_den if need_scale[idx] > 0.0 else 1.0
		else:
			for j in NN:
				need_fill[cn + j] = 1.0
	# ---- hand results to the population (swap buffers to avoid heap allocations)
	var prev_emp: PackedFloat64Array = pops.employed
	var prev_inc: PackedFloat64Array = pops.income
	pops.employed = _emp
	pops.income = _inc
	_emp = prev_emp if prev_emp.size() == _emp.size() else _emp.duplicate()
	_inc = prev_inc if prev_inc.size() == _inc.size() else _inc.duplicate()
	for c in C:
		if alive[c] == 0:
			continue
		var tb := 0.0
		var pinc_out: PackedFloat64Array = pops.income
		for p: int in world.c_provinces[c]:
			var pb := p * PC
			tb += pinc_out[pb] + pinc_out[pb + 1] + pinc_out[pb + 2] + pinc_out[pb + 3] + pinc_out[pb + 4] + pinc_out[pb + 5] + pinc_out[pb + 6]
		tax_base[c] = tb
	# ---- prices follow the market balance
	for i in C * G:
		var ratio := clampf((md[i] + 1.0) / (ms[i] + 1.0), 0.25, 4.0)
		var target := good_base[i % G] * pow(ratio, PRICE_EXP)
		mp[i] += PRICE_SMOOTH * (target - mp[i])


func _state_cost_add(c: int, v: float) -> void:
	bud_admin[c] += v


func _phase_construction(alive: PackedByteArray) -> void:
	var pinc: PackedFloat64Array = pops.income
	for c in C:
		bud_con[c] = 0.0
		if alive[c] == 0:
			continue
		var q: Array = queues[c]
		if q.is_empty():
			continue
		var cg := c * G
		var n := mini(q.size(), _con_slots(c))
		var ok := _con_ok[c] == 1
		var k := 0
		var seen := 0
		while seen < n and k < q.size():
			var proj: Dictionary = q[k]
			var p: int = proj["province"]
			var t: int = proj["type"]
			if world.p_owner[p] != c:
				q.remove_at(k)
				continue
			seen += 1
			var f := 0.0
			var mfill := 1.0
			var bg: PackedInt32Array = b_bg_g[t]
			var bq: PackedFloat64Array = b_bg_q[t]
			for j in bg.size():
				mfill = minf(mfill, fill[cg + bg[j]])
			if ok:
				f = mfill / BUILD_WEEKS
			var money: float = proj["cost"] * f
			var goods_val := 0.0
			for j in bg.size():
				goods_val += bq[j] * f * mp[cg + bg[j]]
			bud_con[c] += money + goods_val
			proj["progress"] = float(proj["progress"]) + proj["cost"] * f
			var pb := p * PC
			pinc[pb + P_LABORER] += 0.6 * money
			pinc[pb + P_CAPITALIST] += 0.4 * money
			if float(proj["progress"]) >= float(proj["cost"]) - 1e-6:
				lvl[p * B + t] += 1
				q.remove_at(k)
				if s.is_player(c):
					s.log_event(c, "economy", "%s completed in %s." % [b_names[t], world.p_name[p]])
				continue
			k += 1


func _phase_budget(alive: PackedByteArray) -> void:
	for c in C:
		if alive[c] == 0:
			bud_tax[c] = 0.0
			continue
		var need: float = pops.country_pop(c) / ADMIN_POP
		var eff := 0.55 + 0.45 * minf(1.0, admin_staff[c] / maxf(need * b_work_total[i_admin], 1.0))
		var rate := TAX_BASE * _m_tax[c]
		bud_tax[c] = rate * tax_base[c] * eff
		bud_tariff[c] = _tariff_rev[c]
		bud_mil[c] += s.military_upkeep(c)
		var debt := maxf(-tre[c], 0.0)
		bud_int[c] = debt * DEBT_RATE / 52.0
		var balance := bud_tax[c] + bud_tariff[c] - bud_admin[c] - bud_mil[c] - bud_con[c] - bud_int[c]
		var before := tre[c]
		tre[c] = before + balance
		if s.is_player(c):
			if before >= 0.0 and tre[c] < 0.0:
				s.log_event(c, "economy", "The treasury of %s has run dry; the state is now in debt." % world.c_short[c])
			if week % 8 == 0 and fill[c * G + g_grain] < 0.8:
				s.log_event(c, "economy", "Grain shortages: only %d%% of demand is met." % int(round(fill[c * G + g_grain] * 100.0)))


func _snapshot_refs() -> void:
	ref_price = new_price
	ref_supply = new_supply
	ref_demand = new_demand
	ref_src = new_src
	ref_snk = new_snk
	new_price = mp.duplicate()
	new_supply = ms.duplicate()
	new_demand = md.duplicate()
	new_src = src_flow.duplicate()
	new_snk = snk_flow.duplicate()


## Peasants without work clear new fields (free, slow): keeps jobs roughly in step with the
## population when nobody is building anything.
func _organic_growth(alive: PackedByteArray) -> void:
	var P: int = world.province_count
	var wk := b_work[i_farm * PC + P_PEASANT]
	for p in range(1, P):
		var c: int = world.p_owner[p]
		if c < 0 or alive[c] == 0:
			continue
		var i := p * PC + P_PEASANT
		var sz: float = pops.size[i]
		var u: float = sz - pops.employed[i]
		if u > 0.07 * sz and u > wk:
			var b := i_farm
			if sold[c * G + g_grain] < 0.92:
				continue   # the granaries are already full
			if tp[p * B + b] >= 0.3 and lvl[p * B + b] < cap[p * B + b]:
				lvl[p * B + b] += 1
			elif tp[p * B + i_ranch] >= 0.3 and lvl[p * B + i_ranch] < cap[p * B + i_ranch]:
				lvl[p * B + i_ranch] += 1


# =========================================================================== queries
func goods_count() -> int:
	return G


func good_name(g: int) -> String:
	return good_names[g]


func good_id(g: int) -> String:
	return good_ids[g]


func good_base_price(g: int) -> float:
	return good_base[g]


func good_category(g: int) -> String:
	return good_cat[g]


func building_count_types() -> int:
	return B


func building_name(t: int) -> String:
	return b_names[t]


func building_id(t: int) -> String:
	return b_ids[t]


func building_category(t: int) -> String:
	return b_cat[t]


func building_cost(t: int) -> float:
	return b_cost[t]


func building_def(t: int) -> Dictionary:
	var inputs := {}
	var outputs := {}
	var workers := {}
	var bgoods := {}
	for j in b_in_g[t].size():
		inputs[good_ids[b_in_g[t][j]]] = b_in_q[t][j]
	if b_out_g[t] >= 0:
		outputs[good_ids[b_out_g[t]]] = b_out_q[t]
	for k in PC:
		if b_work[t * PC + k] > 0.0:
			workers[PROF_KEYS[k]] = b_work[t * PC + k]
	for j in b_bg_g[t].size():
		bgoods[good_ids[b_bg_g[t][j]]] = b_bg_q[t][j]
	return {"id": b_ids[t], "name": b_names[t], "category": b_cat[t], "workers": workers, "inputs": inputs,
		"outputs": outputs, "cost": b_cost[t], "build_goods": bgoods, "requires_tech": b_tech[t], "state_run": b_state[t] == 1}


func price(c: int, g: int) -> float:
	return mp[c * G + g]


func supply(c: int, g: int) -> float:
	return ms[c * G + g]


func demand(c: int, g: int) -> float:
	return md[c * G + g]


func level(p: int, t: int) -> int:
	return lvl[p * B + t]


func railway_level(p: int) -> int:
	return lvl[p * B + i_railway]


func need_count() -> int:
	return NN


func need_good(j: int) -> int:
	return n_good[j]


func need_fill_of(c: int, j: int) -> float:
	return need_fill[c * NN + j]


func need_weight(c: int, j: int) -> float:
	return need_w[c * NN + j]


func top_sources(c: int, g: int, n: int = 3) -> Array:
	return _top(src_flow, c, g, n, true)


func top_sinks(c: int, g: int, n: int = 3) -> Array:
	return _top(snk_flow, c, g, n, false)


func _top(arr: PackedFloat64Array, c: int, g: int, n: int, is_src: bool) -> Array:
	var base := (c * G + g) * T
	var rows: Array = []
	for t in T:
		if arr[base + t] > 0.0:
			rows.append([arr[base + t], t])
	rows.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	var out: Array = []
	for r in mini(n, rows.size()):
		out.append({"name": _tag_name(rows[r][1], is_src), "qty": rows[r][0]})
	return out


func _tag_name(t: int, is_src: bool) -> String:
	if t < B:
		return ("%s output" if is_src else "%s demand") % b_names[t].to_lower()
	if t == TAG_POPS:
		return "households"
	if t == TAG_CON:
		return "construction"
	if t == TAG_MIL:
		return "the military"
	if t == TAG_TRADE:
		return "imports" if is_src else "exports"
	return "other"


func _tag_label(t: int, is_src: bool) -> String:
	if t < B:
		return ("%s output" if is_src else "%s demand") % b_names[t].to_lower()
	if t == TAG_POPS:
		return "household demand"
	if t == TAG_CON:
		return "construction demand"
	if t == TAG_MIL:
		return "military demand"
	if t == TAG_TRADE:
		return "imports" if is_src else "export demand"
	return "stockpiling demand"


func price_explanation(c: int, g: int) -> String:
	var i := c * G + g
	var nm := good_names[g]
	var p := mp[i]
	var r := ref_price[i] if ref_price[i] > 0.0 else good_base[g]
	var ch := p / r - 1.0
	var sp := ms[i]
	var dm := md[i]
	var rel := "%.0f%% of its base price" % (100.0 * p / good_base[g])
	if absf(ch) < 0.04:
		var bal := "supply and demand are in balance"
		if dm > 0.0 and sp < dm * 0.95:
			bal = "supply covers only %d%% of demand" % int(round(sp / dm * 100.0))
		elif sp > 0.0 and sp > dm * 1.05:
			bal = "supply exceeds demand by %d%%" % int(round((sp / maxf(dm, 1.0) - 1.0) * 100.0))
		return "%s price is steady at %.1f (%s): %s." % [nm, p, rel, bal]
	var up := ch > 0.0
	var tot_d := 0.0
	var tot_s := 0.0
	var base := i * T
	for t in T:
		tot_d += ref_snk[base + t]
		tot_s += ref_src[base + t]
	var causes: Array = []
	for t in T:
		var dd := snk_flow[base + t] - ref_snk[base + t]
		if (up and dd > 0.0) or (not up and dd < 0.0):
			var sc := absf(dd) / maxf(tot_d, 1.0)
			if sc > 0.02:
				causes.append([sc, t, true, dd, ref_snk[base + t]])
		var ds := src_flow[base + t] - ref_src[base + t]
		if (up and ds < 0.0) or (not up and ds > 0.0):
			var sc2 := absf(ds) / maxf(tot_s, 1.0)
			if sc2 > 0.02:
				causes.append([sc2, t, false, ds, ref_src[base + t]])
	causes.sort_custom(func(a, b): return a[0] > b[0])
	var parts: PackedStringArray = []
	for k in mini(2, causes.size()):
		var e: Array = causes[k]
		var t: int = e[1]
		var is_demand: bool = e[2]
		var d: float = e[3]
		var was: float = e[4]
		var verb := "grew" if d > 0.0 else "fell"
		var amt := "from nothing"
		if was > 0.0:
			amt = "%d%%" % int(round(absf(d) / was * 100.0)) if absf(d) / was < 5.0 else "sharply"
		var txt := "%s %s %s" % [_tag_label(t, not is_demand), verb, amt]
		if not is_demand and t < B and d < 0.0:
			var cb := c * B + t
			if short_lvl[cb] > 0.0 and short_lost[cb] / short_lvl[cb] > 0.08 and short_good[cb] >= 0:
				txt += " (held back by %s shortages)" % good_names[short_good[cb]].to_lower()
		parts.append(txt)
	var because := ""
	if parts.is_empty():
		if dm > 0.0 and sp < dm:
			because = "supply covers only %d%% of demand" % int(round(sp / dm * 100.0))
		else:
			because = "supply now exceeds demand by %d%%" % int(round((sp / maxf(dm, 1.0) - 1.0) * 100.0))
	else:
		because = (" and ".join(parts)) if parts.size() == 2 else parts[0]
	return "%s price %s %d%% over the past month to %.1f because %s." % [nm, "rose" if up else "fell", int(round(absf(ch) * 100.0)), p, because]


func buildings_in(p: int) -> Array:
	var out: Array = []
	for b in B:
		var L := lvl[p * B + b]
		if L > 0:
			out.append({"type": b, "name": b_names[b], "level": L, "employed": emp[p * B + b],
				"workers_needed": L * b_work_total[b], "profit": profit[p * B + b]})
	return out


func _build_cost_at(p: int, t: int) -> float:
	return b_cost[t] * (1.0 + LEVEL_COST_STEP * lvl[p * B + t])


func building_cost_at(p: int, t: int) -> float:
	return _build_cost_at(p, t)


func can_build(c: int, p: int, t: int) -> Dictionary:
	if t < 0 or t >= B:
		return {"ok": false, "reason": "Unknown building."}
	if p <= 0 or p >= world.province_count or world.p_owner[p] != c:
		return {"ok": false, "reason": "You do not own this province."}
	if b_tech[t] != "":
		var unlocked := true
		if s.tech != null:
			if s.tech.has_method("building_unlocked"):
				unlocked = s.tech.building_unlocked(c, b_ids[t])
		if not unlocked:
			var tn: String = b_tech[t]
			if s.tech.has_method("tech_name"):
				tn = s.tech.tech_name(b_tech[t])
			return {"ok": false, "reason": "Requires the technology %s." % tn}
	if b_coastal[t] == 1 and world.p_port[p].x < 0.0:
		return {"ok": false, "reason": "Needs a coastal province."}
	if not _terrain_ok(t, p) or (b_primary[t] == 1 and tp[p * B + t] < 0.15):
		return {"ok": false, "reason": "Unsuitable terrain."}
	if b_deposit[t] > 0 and cap[p * B + t] <= 0:
		return {"ok": false, "reason": "No deposits here."}
	var queued := 0
	for e: Dictionary in queues[c]:
		if e["province"] == p and e["type"] == t:
			queued += 1
	if lvl[p * B + t] + queued >= cap[p * B + t]:
		return {"ok": false, "reason": "Already at the maximum level here (%d)." % cap[p * B + t]}
	if queues[c].size() >= QUEUE_MAX:
		return {"ok": false, "reason": "The construction queue is full."}
	return {"ok": true, "reason": "", "cost": _build_cost_at(p, t)}


func can_build_fast(c: int, p: int, t: int) -> bool:
	if t < 0 or t >= B or p <= 0 or p >= world.province_count or world.p_owner[p] != c:
		return false
	var q: Array = queues[c]
	if q.size() >= QUEUE_MAX:
		return false
	if b_coastal[t] == 1 and world.p_port[p].x < 0.0:
		return false
	if not _terrain_ok(t, p) or (b_primary[t] == 1 and tp[p * B + t] < 0.15):
		return false
	if b_deposit[t] > 0 and cap[p * B + t] <= 0:
		return false
	if b_tech[t] != "" and s.tech != null and not s.tech.building_unlocked(c, b_ids[t]):
		return false
	var queued := 0
	for e: Dictionary in q:
		if e["province"] == p and e["type"] == t:
			queued += 1
	return lvl[p * B + t] + queued < cap[p * B + t]


func queue_size(c: int) -> int:
	return queues[c].size()


func queue_build(c: int, p: int, t: int) -> bool:
	if not can_build_fast(c, p, t):
		return false
	queues[c].append({"province": p, "type": t, "progress": 0.0, "cost": _build_cost_at(p, t)})
	return true


func prioritize_build(c: int, i: int) -> bool:
	var q: Array = queues[c]
	if i <= 0 or i >= q.size():
		return false
	var item: Dictionary = q[i]
	q.remove_at(i)
	q.push_front(item)
	return true


func cancel_build(c: int, i: int) -> bool:
	var q: Array = queues[c]
	if i < 0 or i >= q.size():
		return false
	tre[c] += 0.5 * float(q[i]["progress"])
	q.remove_at(i)
	return true


func good_fill(c: int, g: int) -> float:
	return fill[c * G + g]


func has_input_shortage(c: int, t: int) -> int:
	var ig: PackedInt32Array = b_in_g[t]
	var cg := c * G
	for j in ig.size():
		var g := ig[j]
		if md[cg + g] > 0.5 and fill[cg + g] < 0.78:
			return g
	return -1


func shortage_goods(c: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var cg := c * G
	for g in G:
		if md[cg + g] > 1.0 and fill[cg + g] < 0.80:
			out.append(g)
	return out


func province_gdp(p: int) -> float:
	if p <= 0 or p >= world.province_count:
		return 0.0
	var c: int = world.p_owner[p]
	if c < 0:
		return 0.0
	var base := p * B
	var cg := c * G
	var tot := 0.0
	for b in B:
		var L := lvl[base + b]
		if L <= 0:
			continue
		if b_state[b] == 1:
			tot += emp[base + b] * wpw[base + b]
		else:
			var go := b_out_g[b]
			var rev := bout[base + b] * sold[cg + go] * mp[cg + go] if go >= 0 else 0.0
			var cost_in := 0.0
			var ig: PackedInt32Array = b_in_g[b]
			var iq: PackedFloat64Array = b_in_q[b]
			var bsc := bscale[base + b] * bio[base + b]
			for j in ig.size():
				cost_in += iq[j] * bsc * mp[cg + ig[j]]
			tot += maxf(0.0, rev - cost_in)
	return tot * 52.0


func best_build_candidate(c: int, filter_p: int = -1) -> Dictionary:
	var provs: PackedInt32Array = PackedInt32Array([filter_p]) if filter_p > 0 else world.c_provinces[c]
	var best_p := -1
	var best_t := -1
	var best_sc := -1e9
	var best_pf := 0.0
	for t in B:
		if b_state[t] == 1:
			continue
		if b_tech[t] != "" and s.tech != null and not s.tech.building_unlocked(c, b_ids[t]):
			continue
		if has_input_shortage(c, t) >= 0:
			continue
		var pf := level_profit(c, t)
		if pf <= 0.0:
			continue
		for p: int in provs:
			if not can_build_fast(c, p, t):
				continue
			var eff := tp[p * B + t] if b_primary[t] == 1 else (1.0 + rail_bonus[p])
			var cost := _build_cost_at(p, t)
			var sc := (pf * eff) / maxf(cost, 1.0)
			if sc > best_sc:
				best_sc = sc
				best_p = p
				best_t = t
				best_pf = pf * eff
	if best_p < 0:
		return {"ok": false}
	return {"ok": true, "province": best_p, "type": best_t, "profit": best_pf, "cost": _build_cost_at(best_p, best_t)}


func queue(c: int) -> Array:
	var out: Array = []
	for e: Dictionary in queues[c]:
		out.append({"province": e["province"], "type": e["type"], "progress": e["progress"], "cost": e["cost"],
			"name": b_names[e["type"]], "province_name": world.p_name[e["province"]]})
	return out


func treasury(c: int) -> float:
	return tre[c]


func treasury_of(c: int) -> float:
	return tre[c]


func budget(c: int) -> Dictionary:
	var bal := bud_tax[c] + bud_tariff[c] - bud_admin[c] - bud_mil[c] - bud_con[c] - bud_int[c]
	return {"tax": bud_tax[c], "tariffs": bud_tariff[c], "admin": bud_admin[c], "military": bud_mil[c],
		"construction": bud_con[c], "interest": bud_int[c], "balance": bal}


## Annualised value added.
func gdp(c: int) -> float:
	return gdp_w[c] * 52.0


func in_debt(c: int) -> bool:
	return tre[c] < 0.0


func tax_level(c: int) -> int:
	if s.politics != null and s.politics.has_method("tax_level"):
		return int(s.politics.tax_level(c))
	return tax_level_local[c]


func set_tax_level(c: int, level_idx: int) -> bool:
	level_idx = clampi(level_idx, 0, 2)
	if s.politics != null and s.politics.has_method("set_tax_level"):
		var r = s.politics.set_tax_level(c, level_idx)
		return bool(r["ok"]) if r is Dictionary else bool(r)
	tax_level_local[c] = level_idx
	return true


func equipment_fill(c: int) -> float:
	if mil_arms[c] <= 0.0:
		return 1.0
	return fill[c * G + g_arms]


## Expected weekly profit of one extra level of building t in country c at current prices
## (used by the AI and the build menu).
func level_profit(c: int, t: int) -> float:
	var rev := 0.0
	if b_out_g[t] >= 0:
		rev = b_out_q[t] * mp[c * G + b_out_g[t]]
	var cost_in := 0.0
	for j in b_in_g[t].size():
		cost_in += b_in_q[t][j] * mp[c * G + b_in_g[t][j]]
	var wages := 0.0
	for k in LABOR_PROFS:
		wages += b_work[t * PC + k] * floor_w[k]
	return rev - cost_in - wages


func trade_value(c: int) -> float:
	return trade_vol[c]


func on_transfer(p: int, from: int, _to: int) -> void:
	if from >= 0:
		var q: Array = queues[from]
		var k := 0
		while k < q.size():
			if q[k]["province"] == p:
				q.remove_at(k)
			else:
				k += 1


# =========================================================================== persistence
func to_dict() -> Dictionary:
	var d := {"week": week}
	for name: String in PERSIST_F64:
		d[name] = SimUtil.enc_f64(get(name))
	for name: String in PERSIST_I32:
		d[name] = SimUtil.enc_i32(get(name))
	var qs: Array = []
	for c in queues.size():
		var pr := PackedInt32Array()
		var ty := PackedInt32Array()
		var pg := PackedFloat64Array()
		var co := PackedFloat64Array()
		for e: Dictionary in queues[c]:
			pr.append(e["province"])
			ty.append(e["type"])
			pg.append(e["progress"])
			co.append(e["cost"])
		qs.append({"p": SimUtil.enc_i32(pr), "t": SimUtil.enc_i32(ty), "g": SimUtil.enc_f64(pg), "c": SimUtil.enc_f64(co)})
	d["queues"] = qs
	return d


func from_dict(d: Dictionary) -> void:
	if not d.has("mp"):
		return
	week = int(d.get("week", 0))
	_seeded = true
	for name: String in PERSIST_F64:
		if d.has(name):
			var arr := SimUtil.dec_f64(d[name])
			var cur: PackedFloat64Array = get(name)
			if arr.size() == cur.size():
				set(name, arr)
	for name: String in PERSIST_I32:
		if d.has(name):
			var arr := SimUtil.dec_i32(d[name])
			var cur2: PackedInt32Array = get(name)
			if arr.size() == cur2.size():
				set(name, arr)
	var qs: Array = d.get("queues", [])
	for c in mini(qs.size(), queues.size()):
		var pr := SimUtil.dec_i32(qs[c]["p"])
		var ty := SimUtil.dec_i32(qs[c]["t"])
		var pg := SimUtil.dec_f64(qs[c]["g"])
		var co := SimUtil.dec_f64(qs[c]["c"])
		var lst: Array = []
		for k in pr.size():
			lst.append({"province": pr[k], "type": ty[k], "progress": pg[k], "cost": co[k]})
		queues[c] = lst
	_build_qpc()
