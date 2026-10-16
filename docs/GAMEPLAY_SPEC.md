# Gameplay Spec (Milestones 2–6, condensed) — contract between modules

Godot 4.3, GDScript, **no `class_name`** (use `const X := preload("res://...")`), typed code, packed arrays,
no Nodes inside `src/sim/`. Headless scripts hang on script errors → always run godot with `timeout`.
Godot binary: `godot` (4.3). Parse check: `timeout 60 godot --headless --path . --check-only --script res://path.gd`.
Tests: `timeout 300 godot --headless --path . --script res://tests/run_tests.gd`.

Player picks a **province** on the map at New Game; they play the **country that owns it**.

## Calendar & scheduling (src/sim/game_state.gd)
- `day: int` — days since 1 Jan 1836. Own calendar, non-leap 365 days, real month lengths.
- `advance_day()`: `day += 1`, then: every day → `military.tick_day()` if exists;
  every 7th day (`day % 7 == 0`) → `pops.tick_week()`, `econ.tick_week()`, `tech.tick_week()`, `military.tick_week()`, `diplo.tick_week()`;
  first day of each month → `pops.tick_month()`, `politics.tick_month()`, `diplo.tick_month()`, `ai.tick_month()`, then `s.month_index += 1`.
  Modules are called via a fixed ordered list; a module only implements the ticks it needs (`has_method`). Order is fixed → deterministic.
- All randomness uses `s.rng` (RandomNumberGenerator, seeded, its `state` saved). Never `randi()` global.

## GameState API (src/sim/game_state.gd, extends RefCounted)
```
static func new_game(world, player_country: int, seed: int) -> RefCounted   # builds all modules, calls setup()
static func from_dict(world, d: Dictionary) -> RefCounted                   # restore (applies saved ownership to world)
func to_dict() -> Dictionary
func advance_day() -> void
func date_string() -> String            # "14 March 1836"
func year() -> int ; func month() -> int (1..12) ; func day_of_month() -> int
var world ; var day ; var rng ; var player: int ; var alive: PackedByteArray (per country)
var pops ; var econ ; var politics ; var tech ; var diplo ; var military ; var ai
var events: Array          # {day:int, country:int, kind:String, text:String}; kind ∈ economy|politics|diplomacy|war|tech|pop|system
func log_event(country: int, kind: String, text: String) -> void   # keeps last 400
func take_new_events() -> Array      # events appended since last call (UI notifications)
func transfer_province(p: int, to: int) -> void   # updates world.p_owner + world.c_provinces, sets ownership_dirty, kills countries with 0 provinces
var ownership_dirty: bool          # UI refreshes map lookup texture then clears it
func is_player(c: int) -> bool
```
Every module: `extends RefCounted`, `var s`, `func setup(state) -> void` (new game), `func to_dict() -> Dictionary`, `func from_dict(d) -> void`.
Save JSON must round-trip: `from_dict(to_dict())` then N days == original then N days (test it).

## Population (src/sim/population.gd) — cohorts = province × profession (× is_primary_culture flag)
Professions (const indices): 0 PEASANT, 1 LABORER, 2 MACHINIST (factory worker), 3 CLERK, 4 ARISTOCRAT, 5 CAPITALIST, 6 SOLDIER. `PROF_NAMES`.
Per cohort packed arrays (index `p * PROF_COUNT + prof`): `size` (people), `employed`, `income` (money/week, written by econ), `sol` (0..20 standard of living), `literacy` (0..1), `radicalism` (0..1), `loyalty` (0..1).
Initial pop from area × terrain fertility × tier (world total ≈ 50–80 M; soldiers ≈ 1.5 %, aristocrats 1 %, capitalists 0.5 %, clerks 3 %, rest peasants/laborers).
- tick_week: employment is done by econ (it sets `employed`); pops just clamps.
- tick_month: growth (birth − death depends on sol), migration (unemployed move to provinces of the same country with vacant jobs, max 2 %/month), promotion (literate employed laborers → machinists/clerks when jobs exist; unemployed → peasants), literacy growth (laws/tech modifiers), radicalism up with low/falling sol, unemployment, unaccepted culture; down with rising sol.
Query: `province_pop(p)`, `country_pop(c)`, `country_prof(c, prof)`, `unemployment(c) -> float`, `avg_sol(c) -> float`, `literacy(c) -> float`, `radical_share(c) -> float`, `loyal_share(c)`, `cohorts_in(p) -> Array[{prof, name, size, employed, income, sol, literacy, radicalism}]`, `sol_explanation(c) -> String`.

## Economy (src/sim/economy.gd) + data/scenario/goods.json, buildings.json
Goods (~14): grain, fish, wood, coal, iron, cotton? (use "fibers"), textiles, clothes, furniture, tools, steel, arms, luxuries, services. `{id, name, base_price, category}`.
Buildings (~14): farm, ranch?, fishing_wharf, logging_camp, coal_mine, iron_mine, textile_mill, clothing_factory, furniture_workshop, tool_workshop, steel_mill, arms_factory, railway (infrastructure, raises market access/supply), government_admin (needs clerks, gives tax capacity). Each: `{id, name, category, workers:{prof: n_per_level}, inputs:{good: qty/level/week}, outputs:{...}, cost (money), build_goods:{good: qty}, terrain:[biomes allowed or []], requires_tech: id|null, coastal_only}`.
One **market per country** (national market). Trade agreement partners (diplo) share surplus: weekly, each good flows from cheaper to pricier partner market, capped.
tick_week (all countries):
1. Hire: each building level employs workers from same-province cohorts of required professions (wage-ordered, most profitable first).
2. Produce: output × min(staffing, input availability from last week's market) × tech/law modifiers. Railways raise output by up to +20 % (market access).
3. Market: supply/demand per (country, good) → price = base × clamp((demand+1)/(supply+1), 0.25, 4) ^ 0.7, smoothed 30 %/week. Keep last-week supply/demand + top 3 sources/sinks per good for explanations.
4. Wages & profit: building revenue − inputs − wages → profit; wages to cohorts (`pops.income`); capitalists/aristocrats get dividends.
5. Consumption: cohorts spend income on needs basket (grain/fish, clothes, furniture, luxuries, services by wealth tier) → demand; fulfilment → `sol` (smoothed).
6. Budget: taxes (law tax level × income), tariffs on trade, minus admin wages, military upkeep (military), construction spending. `treasury` can go negative → debt, interest, legitimacy hit (politics reads `in_debt(c)`).
7. Construction: per country queue `[{province, type, progress, cost}]`; construction points/week from treasury & build_goods availability (adds demand for wood/steel/tools). Finished → level +1, event.
Query/command: `price(c,g)`, `supply(c,g)`, `demand(c,g)`, `price_explanation(c,g) -> String` (cause/effect sentence, e.g. "Steel price rose 18% because construction demand grew while iron shortages cut production."), `goods_count()`, `good_name(g)`, `building_count_types()`, `building_name(t)`, `buildings_in(p) -> Array[{type, name, level, employed, workers_needed, profit}]`, `can_build(c,p,t) -> Dictionary{ok, reason}`, `queue_build(c,p,t) -> bool`, `cancel_build(c, i)`, `queue(c) -> Array`, `treasury(c)`, `budget(c) -> Dictionary{tax, tariffs, admin, military, construction, interest, balance}`, `gdp(c)`, `in_debt(c)`, `set_tax_level(c, 0..2)` (only if politics allows), `equipment_fill(c) -> float` (arms supply / military demand).

## Politics (src/sim/politics.gd) + data/scenario/laws.json, interest_groups.json
Interest groups (6): Landowners, Industrialists, Intelligentsia, Petty Bourgeoisie, Trade Unions, Clergy/Armed Forces → `{id, name, color, supporters:{prof: weight}, prefs:{law_option_id: ±value}}`. Clout = share of political strength (pop × wealth × literacy × voting law).
Laws (categories with options): governance (autocracy, oligarchy, census_suffrage, universal_suffrage), taxation (low, medium, high), trade (protectionism, free_trade), labor (no_rights, basic_rights, workers_protection), education (none, religious_schools, public_schools), conscription (volunteers, mass_conscription). Option `{id, name, modifiers:{key: value}, requires_tech}`.
Modifier keys used by others: `tax_mult`, `tariff`, `wage_floor`, `literacy_growth`, `research_mult`, `radicalism_mult`, `conscription_rate`, `trade_bonus`.
- `approval(c, ig) -> float (-10..10)` and `approval_breakdown(c, ig) -> Array[{reason, value}]` (laws liked/disliked, sol change of supporters, in government, debt). No hidden modifiers.
- Legitimacy (0..100) from government IG approval, debt, war exhaustion. Unrest = radical_share; if radical_share > 0.35 for 3 months → revolution: chance per month, province(s) with highest radicalism break away to an existing neighbour or flip government law; big event.
- Enacting: `start_enact(c, cat, opt)` → months-long; monthly success roll based on support (clout of approving IGs) — `enact_status(c) -> {cat, opt, progress, support, chance}`; `can_enact(c,cat,opt) -> {ok, reason}`.
Query: `law(c, cat) -> String`, `modifier(c, key) -> float` (sum of active law modifiers), `legitimacy(c)`, `clout(c, ig)`, `ig_count()`, `ig_name(i)`, `categories() -> Array`, `options(cat) -> Array`.
Elections every 4 years for census/universal suffrage: governing IGs re-chosen by clout.

## Technology (src/sim/technology.gd) + data/scenario/techs.json
~18 techs in 3 trees (production, society, military) `{id, name, tree, cost, requires:[], unlocks:{buildings:[], laws:[]}, modifiers:{key: v}}` (keys like `farm_output`, `mine_output`, `factory_output`, `research_mult`, `army_power`, `literacy_growth`). Research points/week from clerks × literacy × law/tech mult. Query: `researching(c)`, `set_research(c, id) -> bool`, `progress(c) -> float 0..1`, `is_known(c,id)`, `available(c) -> Array[id]`, `modifier(c, key)`, `building_unlocked(c, type_id)`, `points_per_week(c)`, tech name/cost/desc getters.

## Diplomacy (src/sim/diplomacy.gd)
Relations matrix int −100..100 (initial from rank, neighbours slightly negative), drift monthly; `relation(a,b)`, `relation_breakdown(a,b) -> Array[{reason,value}]`.
Pacts: alliances, trade agreements, rivalries, claims (`claims[c]` province list; neighbours start with some claims on each other's border provinces).
Actions (return `{ok: bool, reason: String}`): `improve_relations(a,b)` (costs money, +relation over time), `propose_alliance(a,b)`, `propose_trade_agreement(a,b)`, `declare_rival(a,b)`, `fabricate_claim(a, p)`, `declare_war(a, b, target_provinces: PackedInt32Array)` (needs claim or rival; allies are called in), `offer_peace(war_id, from, terms: String)` terms ∈ white_peace|cede_goals; AI acceptance based on warscore, exhaustion, relations.
Wars: `wars: Array[{id, attackers, defenders, goals, warscore (attacker POV −100..100), start_day}]`, `at_war(a,b)`, `wars_of(c)`, `war_exhaustion(c)`; warscore from occupation of goals/enemy provinces and battles.

## Military (src/sim/military.gd)
Per country: `battalions`, `manpower` (from SOLDIER cohorts, conscription law), `morale`, upkeep (money + arms demand → econ). Commands: `recruit(c, n) -> {ok, reason}`, `disband(c, n)`. `army(c) -> {battalions, manpower, equipment, morale, upkeep, power}`.
Fronts are implicit: for each pair at war, border provinces between them. tick_week: per front compare power = battalions × equipment_fill × morale × tech `army_power` × terrain defense (Biome: hills 1.25, mountains 1.6, forest 1.15) × supply (railway level, own vs enemy territory); winner occupies 1 enemy border province (`controller[p]`), casualties reduce battalions/manpower & soldier pops, exhaustion rises. `controller(p) -> int` (owner when not occupied). Peace: occupations cleared; ceded goals transferred via `s.transfer_province`.

## AI (src/sim/ai.gd) — monthly per non-player alive country, deterministic
Layers: strategic goal every 12 months (industrialize / expand / stabilize, from GDP, rivals, legitimacy); economic monthly (keep budget positive via tax, queue the most profitable affordable building where inputs exist, research cheapest useful tech); political (enact laws their governing IGs like when legitimacy ok); diplomatic (alliances with friends vs common rival, trade agreements, war vs weaker neighbour with claims when army power ratio > 1.4 and not in debt); war (accept peace when warscore against them < −40 or exhaustion high). Cap work per month; no full-world scans per country (use neighbour lists).

## Save/Load (src/sim/save_system.gd, static funcs)
`save_game(state, name: String) -> String(path)` → `user://saves/<name>.json` with `{version, world_seed, saved_at, date, player_country_name, state}`; `list_saves() -> Array[{path, name, date, country, saved_at}]` newest first; `latest_save() -> String` ("" if none); `load_game(world, path) -> state or null`. Autosave name `autosave`.

## Game flow (UI)
- `scenes/main_menu.tscn` is the new main scene: animated map background, title, **New Game, Continue** (latest save; disabled if none), **Load Game**, **Settings**, **Quit**.
- New Game → `scenes/game.tscn` in *nation-pick mode*: banner "Select a province to choose your nation"; click → side card with country summary (flag colour, rank, government, provinces, population, GDP, army) + **Play as X** / Back. Then game starts paused.
- Autoload `Session` (`src/game/session.gd`, registered in project.godot `[autoload]`) carries `{mode: "new"|"load", path}` between scenes.
- In-game: top bar (country, date, speed: pause + 5 speeds, keys Space and 1–5? — map modes move to F5–F7), treasury & weekly balance, population, GDP, legitimacy, radicals, research. Tabs: Overview, Market, Buildings, Population, Politics, Technology, Diplomacy, Military. Province panel shows buildings with Build buttons (player's provinces). Notifications toast feed + event log. Esc menu: Resume, Save, Load, Settings, Main Menu, Quit. Autosave per settings.
- `src/game/game_controller.gd` (Node): owns GameState, speed (days/sec: 0, 1, 3, 8, 20, max), time-sliced stepping (≤ 8 ms sim per frame, carry over), emits `day_passed`, `week_passed`; UI refreshes open panel only on week tick or on change.
- Settings (`user://settings.cfg`): window mode (windowed/fullscreen), resolution, vsync, map detail (ocean animation/vignette), perf overlay, autosave (off/monthly/yearly), UI scale. Shared screen in main menu and pause menu.
- `-- --benchmark` must still work (goes straight to map benchmark).
