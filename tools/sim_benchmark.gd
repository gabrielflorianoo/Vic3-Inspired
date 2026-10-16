extends SceneTree
## Headless simulation benchmark:
##   timeout 600 godot --headless --path . --script res://tools/sim_benchmark.gd [-- years=5 seed=1 player=0]
## Runs a new game for N simulated years with no player input and prints
##  - avg / max milliseconds per daily step (whole advance_day) split by day type
##  - avg / max milliseconds per subsystem tick (day / week / month)
##  - a yearly sanity table: population, GDP, price range, treasuries, unemployment, standard of living

const WorldData := preload("res://src/world/world_data.gd")
const GameState := preload("res://src/sim/game_state.gd")


func _arg(name: String, default_v: int) -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(name + "="):
			return int(a.get_slice("=", 1))
	return default_v


func _init() -> void:
	var years := _arg("years", 5)
	var seed_v := _arg("seed", 1)
	var player := _arg("player", 0)
	var world: RefCounted = WorldData.load_default()
	if world == null:
		printerr("world assets missing")
		quit(1)
		return
	var t0 := Time.get_ticks_usec()
	var st: RefCounted = GameState.new_game(world, player, seed_v)
	print("new_game (build + 12 warm-up weeks): %.0f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	st.profile = true
	var sums := {"plain": 0, "week": 0, "month": 0, "all": 0}
	var cnts := {"plain": 0, "week": 0, "month": 0, "all": 0}
	var maxs := {"plain": 0, "week": 0, "month": 0, "all": 0}
	_report_year(st, 0)
	var total_days := years * 365
	for i in total_days:
		var t1 := Time.get_ticks_usec()
		st.advance_day()
		var dt := Time.get_ticks_usec() - t1
		var kind := "plain"
		if st.day_of_month() == 1:
			kind = "month"
		elif st.day % 7 == 0:
			kind = "week"
		for k in [kind, "all"]:
			sums[k] += dt
			cnts[k] += 1
			maxs[k] = maxi(maxs[k], dt)
		if (i + 1) % 365 == 0:
			_report_year(st, (i + 1) / 365)
	print("")
	print("== advance_day cost (ms) ==")
	for k in ["plain", "week", "month", "all"]:
		print("%-6s n=%5d  avg %7.3f  max %7.3f" % [k, cnts[k], sums[k] / 1000.0 / maxf(cnts[k], 1), maxs[k] / 1000.0])
	print("")
	print("== per subsystem tick (ms) ==")
	var keys: Array = st.prof_us.keys()
	keys.sort()
	for k: String in keys:
		print("%-16s n=%5d  avg %7.3f  max %7.3f" % [k, st.prof_n[k], st.prof_us[k] / 1000.0 / st.prof_n[k], st.prof_max[k] / 1000.0])
	var e = st.econ
	st.profile = false
	var tw := Time.get_ticks_usec()
	for i in 20:
		e.tick_week()
	print("")
	print("economy.tick_week alone (%d provinces, %d countries): avg %.2f ms" % [world.province_count - 1, world.country_count, (Time.get_ticks_usec() - tw) / 1000.0 / 20.0])
	var tm := Time.get_ticks_usec()
	for i in 12:
		st.pops.tick_month()
	print("population.tick_month alone: avg %.2f ms" % ((Time.get_ticks_usec() - tm) / 1000.0 / 12.0))
	var tj := Time.get_ticks_usec()
	var txt := JSON.stringify(st.to_dict())
	print("to_dict + stringify: %.1f ms, %.2f MB" % [(Time.get_ticks_usec() - tj) / 1000.0, txt.length() / 1048576.0])
	st.dispose()
	quit()


func _report_year(st: RefCounted, y: int) -> void:
	var w = st.world
	var e = st.econ
	var pp = st.pops
	var G: int = e.goods_count()
	var pop := 0.0
	var gdp := 0.0
	var tre := 0.0
	var un_lo := 1.0
	var un_hi := 0.0
	var sol_sum := 0.0
	var pmin := 99.0
	var pmax := 0.0
	var pmin_g := ""
	var pmax_g := ""
	var tre_max := -1.0e18
	var tre_min := 1.0e18
	var n := 0
	for c in w.country_count:
		if st.alive[c] == 0:
			continue
		n += 1
		var cp: float = pp.country_pop(c)
		pop += cp
		gdp += e.gdp(c)
		tre += e.treasury(c)
		tre_max = maxf(tre_max, e.treasury(c) / maxf(e.gdp(c), 1.0))
		tre_min = minf(tre_min, e.treasury(c) / maxf(e.gdp(c), 1.0))
		var u: float = pp.unemployment(c)
		un_lo = minf(un_lo, u)
		un_hi = maxf(un_hi, u)
		sol_sum += pp.avg_sol(c) * cp
		for g in G:
			var r: float = e.price(c, g) / e.good_base_price(g)
			if r < pmin:
				pmin = r
				pmin_g = "%s/%s" % [e.good_name(g), w.c_short[c]]
			if r > pmax:
				pmax = r
				pmax_g = "%s/%s" % [e.good_name(g), w.c_short[c]]
	print("year %d (%s): pop %.2fM  GDP %.2fB/yr  avg sol %.2f  unemp %.1f%%..%.1f%%  prices %.2fx (%s)..%.2fx (%s)  treasury/GDP %.2f..%.2f  countries %d" % [
		y, st.date_string(), pop / 1.0e6, gdp / 1.0e9, sol_sum / pop, un_lo * 100.0, un_hi * 100.0, pmin, pmin_g, pmax, pmax_g, tre_min, tre_max, n])
