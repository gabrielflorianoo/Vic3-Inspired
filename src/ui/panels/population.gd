extends "res://src/ui/panels/panel_base.gd"
## Population: by profession (size, employment, SoL, literacy, radicals), country
## totals with sol_explanation tooltip, and the most radical provinces.

const FALLBACK_PROF := ["Peasants", "Laborers", "Machinists", "Clerks", "Aristocrats", "Capitalists", "Soldiers"]


func rebuild() -> void:
	var c := player
	var pops = state.pops
	var pc: int = int(const_of(pops, "PROF_COUNT", 7))
	var names: Array = const_of(pops, "PROF_NAMES", FALLBACK_PROF)
	add_child(K.lbl("Population of %s" % world.c_short[c], 16, K.GOLD))
	var tg := K.grid(4, 18, 3)
	tg.add_child(K.lbl("Total", 12, K.DIM))
	tg.add_child(K.lbl(K.num(pops.country_pop(c)), 13))
	tg.add_child(K.lbl("Unemployment", 12, K.DIM))
	tg.add_child(K.lbl(K.pct(pops.unemployment(c), 1), 13, K.WARN if pops.unemployment(c) > 0.12 else K.INK))
	tg.add_child(K.lbl("Standard of living", 12, K.DIM, pops.sol_explanation(c)))
	tg.add_child(K.lbl("%.1f / 20" % pops.avg_sol(c), 13, K.INK, pops.sol_explanation(c)))
	tg.add_child(K.lbl("Literacy", 12, K.DIM))
	tg.add_child(K.lbl(K.pct(pops.literacy_of(c), 1), 13))
	tg.add_child(K.lbl("Radicals", 12, K.DIM))
	var rs: float = pops.radical_share(c)
	tg.add_child(K.lbl(K.pct(rs, 1), 13, K.BAD if rs > 0.25 else K.INK))
	tg.add_child(K.lbl("Loyal", 12, K.DIM))
	tg.add_child(K.lbl(K.pct(pops.loyal_share(c), 1), 13))
	add_child(tg)

	# Aggregate cohorts of the player's provinces by profession (a few hundred array reads).
	var size_t := PackedFloat64Array()
	var emp_t := PackedFloat64Array()
	var sol_w := PackedFloat64Array()
	var lit_w := PackedFloat64Array()
	var rad_w := PackedFloat64Array()
	for a in [size_t, emp_t, sol_w, lit_w, rad_w]:
		a.resize(pc)
	var hot: Array = []
	for p in world.c_provinces[c]:
		var ptot := 0.0
		var prad := 0.0
		for k in pc:
			var i: int = p * pc + k
			var sz: float = pops.size[i]
			size_t[k] += sz
			emp_t[k] += pops.employed[i]
			sol_w[k] += pops.sol[i] * sz
			lit_w[k] += pops.literacy[i] * sz
			rad_w[k] += pops.radicalism[i] * sz
			ptot += sz
			prad += pops.radicalism[i] * sz
		hot.append([prad / maxf(ptot, 1.0), p, ptot])

	add_child(K.section("By profession"))
	var g := K.grid(6, 14, 4)
	for h in ["Profession", "People", "Employed", "SoL", "Literacy", "Radicals"]:
		g.add_child(K.lbl(h, 12, K.GOLD))
	for k in pc:
		var sz := size_t[k]
		g.add_child(K.lbl(str(names[k]), 13))
		g.add_child(K.lbl(K.num(sz), 13))
		g.add_child(K.lbl(K.pct(emp_t[k] / maxf(sz, 1.0)) if k <= 3 else "-", 13, K.DIM))
		g.add_child(K.lbl("%.1f" % (sol_w[k] / maxf(sz, 1.0)), 13, K.INK, pops.sol_explanation(c)))
		g.add_child(K.lbl(K.pct(lit_w[k] / maxf(sz, 1.0)), 13))
		var r := rad_w[k] / maxf(sz, 1.0)
		g.add_child(K.lbl(K.pct(r), 13, K.BAD if r > 0.3 else K.INK))
	add_child(g)

	add_child(K.section("Unrest hotspots"))
	hot.sort_custom(func(a, b): return a[0] > b[0])
	var hg := K.grid(3, 18, 3)
	for i in mini(6, hot.size()):
		var h: Array = hot[i]
		var pb := K.btn(world.p_name[h[1]], "Show on map", func(): hud.focus_province(h[1]))
		pb.flat = true
		pb.alignment = HORIZONTAL_ALIGNMENT_LEFT
		hg.add_child(pb)
		hg.add_child(K.lbl("radicals " + K.pct(h[0]), 12, K.BAD if h[0] > 0.3 else K.INK))
		hg.add_child(K.lbl("pop " + K.num(h[2]), 12, K.DIM))
	add_child(hg)
