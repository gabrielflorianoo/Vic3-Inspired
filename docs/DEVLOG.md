# Development Log

## 2026-10-16 — Milestone 2: playable game (menu, nation pick, simulation, AI, saves)

### What was built
- **Game flow**: main menu (New Game / Continue / Load / Settings / Quit) -> New Game asks for a province and you play its owning
  country -> HUD with top bar (date, pause + speeds 1-5, treasury/pop/GDP/legitimacy/radicals/research), nine tab panels
  (Overview, Market, Buildings, Population, Politics, Technology, Diplomacy, Military, Events), province card, toasts, pause menu,
  save/load dialog, settings (window mode, resolution, vsync, UI scale, map detail, perf overlay, autosave).
- **Simulation** (`src/sim/`): calendar + module wiring (`game_state.gd`), population cohorts (7 professions x province), market economy
  with construction queue and budget, politics (interest groups, laws, legitimacy, elections, revolutions), technology (3 trees),
  diplomacy (relations, alliances, trade agreements, rivals, claims, wars, peace), military (battalions, sieges, occupation),
  AI for every non-player country, JSON saves (arrays are base64 raw bytes, so state round-trips bit-exactly).
- Contract: `docs/GAMEPLAY_SPEC.md`.

### Integration fixes in this pass
- `has_method`-guarded calls: every guarded name now verified against the real definitions (all exist; `literacy_of` is the call used
  everywhere, the `pops.literacy` array is per-cohort). Scripted cross-module call check found no other mismatches.
- Saves: `military.gd`, `diplomacy.gd` scalar doubles (batt_size, warscore, battle, siege progress) are now bit-exact (`SimUtil.num_str`, hex of the IEEE
  bytes); military float arrays are base64. `String.num(x, 17)` was *not* exact (caught by the determinism test).
- `sim_util.gd` never calls `Marshalls` with empty data (no more `raw_to_base64` errors).
- `ai.gd` `_treasury` simplified to `econ.treasury_of(c)` (the old fallback indexed `econ.treasury`, which is a method).
- Failed save loads no longer use `push_error` (negative tests and "bad file" dialogs produce no engine ERROR lines).
- Top bar adapts to width/UI scale: lowest-priority stats are hidden until the row fits, so the Menu button is never clipped (checked at 1600x900, UI 150%).
- `game_controller.gd`: after any day that ran a weekly or monthly tick the frame stops stepping, so at speed 5 at most one weekly/monthly tick runs per frame
  (a weekly tick is atomic, ~20 ms). Also guarantees one price-history sample per week.
- `politics.gd`: monthly tick 12.4 -> ~8 ms (no explanation strings when only numbers are needed, typed arrays in the hot loop, one `avg_sol` per call).
- New dev tools: `--continue`, `--monkey=SECONDS` UI fuzzer (`src/game/monkey.gd`), `tests/run_all.sh`; `test_strategy.gd` now disposes every state and prints which module differs on a save/restore mismatch.

### Architecture / performance notes
- `GameController` accumulates day credit by speed (1, 3, 8, 20 days/s, or maximum), caps work to ~8 ms/frame and stops after the first weekly/monthly tick.
  The UI gets one `stepped` signal per frame, panels refresh at most every 0.5 s and only on weekly ticks or user actions.
- Modules hold flat packed arrays (`PackedFloat64Array` per cohort / per country x good), no per-pop objects; GameState <-> module references are cycles, so `dispose()` must be called
  when a state is discarded (tests and the game do).
- A week and a month tick falling on the same day still run in one frame (~45 ms worst case in the benchmark): the sim has no sub-day stepping.

### Tests ACTUALLY run (this session, Godot 4.3, headless)
- `tests/run_tests.gd`: **591 checks, 0 failed** (~15 s). World/generator/ID codec, calendar, determinism, JSON save round-trip (bit-exact state), economy invariants, price chains, population response, construction/ownership transfer.
- `tests/test_strategy.gd`: **7216 checks, 0 failed** (~25 s), mode "REAL GameState". Static API, scripted war, politics actions, a 5-year run (6 wars started/ended, 19 laws enacted, 122 techs, 154 battles, no revolutions, legitimacy 43..64) and determinism + save/restore over 900 days.
- Neither run prints SCRIPT ERROR / ERROR / Invalid lines (verified by grep).
- `--monkey` UI fuzzer under Xvfb at speed 5: 100 s run = 214 button presses over all tabs, simulated 6377 days (17 years), 0 errors; further runs on other countries (15 s and 60 s), 0 errors. The player researched 9-16 techs in those runs.
- Rendered screenshots inspected for menu, nation pick, Market/Politics/Diplomacy/Overview/Military tabs, pause menu, settings, Continue (loads the newest autosave), and UI scale 150% at 1600x900.
- `--benchmark` (map) still works. Exports: **Windows** (.exe + .pck) and **Linux** release exports succeed; the exported Linux build was run with `--autostart=3 --run-days=400 --monkey=10` (all `data/scenario/*.json` are packed; game started and ran). The Windows build was not launched.

### Sim benchmark (`tools/sim_benchmark.gd`, 5 simulated years, 14 countries, 205 provinces, container CPU, not target HW)
| tick | n | avg ms | max ms |
|---|---|---|---|
| plain day | 1514 | 0.17 | 0.46 |
| week day (econ+pops+tech+diplo+mil) | 251 | 22.0 | 27.5 |
| month day | 60 | 21.0 | 44.4 |
| all days | 1825 | 3.86 | 44.4 |
Per subsystem avg: econ.week 20.1, politics.month 8.0, ai.month 5.2, pops.month 3.4, tech.week 0.8, military.week 0.7, diplo.month 0.8. `new_game` (build + 12 warm-up weeks) 362 ms. Save: `to_dict` + stringify 27.9 ms, 0.77 MB.
Economy after 5 years: pop 62.0M -> 64.5M, GDP 2.52B -> 2.75B/yr, avg SoL 11.2 -> 12.9, unemployment 5-10%.
Map benchmark (llvmpipe, 1280x720): 28-36 fps average per phase (software rendering; regression baseline only).

### Known limitations
- Target hardware (Q8300 / R7 350) still unmeasured; weekly tick (~20 ms) alone exceeds a 16.6 ms frame, so speeds >= 3 show one slower frame per simulated week.
- Week + month ticks on the same day cost up to ~45 ms in one frame.
- The player has no automatic research queue: "Research: none!" appears when a tech completes; the player must pick the next one.
- Toast stack can overlap the province card at UI scale 150% on small windows.
- War events are logged once per participant, so the same text can appear twice in the event log / test output.
- No tutorial, no sound, no per-province detail for buildings beyond the list; AI is heuristic (builds, researches, enacts laws, declares wars) and not tuned for balance.
- Windows build not launched; no icon/version resources.

## 2026-10-16 — Milestone 1: Technical foundation

### Environment (inspected)
- The repository started out empty and no Godot was installed. I downloaded **Godot 4.3-stable (official, Linux x86_64)** and the 4.3 export templates.
- Dev container: 4 vCPU, 15 GB RAM, no GPU. Rendering was tested with Xvfb + Mesa **llvmpipe** (software OpenGL 4.5), through the Compatibility renderer.
- **I haven't tested on the target PC** (Core 2 Quad Q8300 / Radeon R7 350). None of the numbers below represent that machine.

### Architecture decisions and their performance implications
| Decision | Why / cost |
|---|---|
| **Offline map baking** (`tools/generate_world.gd`) | Per-pixel GDScript generation takes ~8.5 s, so it never runs at runtime. Runtime startup loads 2 images + 1 JSON: 120–150 ms measured. |
| **Whole map = one quad + one shader** | 1 draw call for terrain, political fill, province borders, country borders, coast, selection and hover. There are no per-province nodes or meshes. The cost is ~14 texture fetches per pixel, which scales with resolution and not with province count. |
| **Borders derived in the shader from the province-ID texture** | No border geometry to build or rebuild when ownership changes. The sample radius is scaled by zoom, so line width stays roughly constant on screen. |
| **Per-province state in an N×2 lookup texture** | Selection, hover and ownership changes rewrite a few texels (or ≤N≈205 for a country highlight). Nothing is uploaded per frame. Later ownership changes (wars) cost the same. |
| **Picking = one `Image.get_pixel` on the CPU ID image** | O(1) and independent of province count. The CPU copy of the ID image costs 6 MB. |
| **Overlay = one Control with immediate-mode drawing** | Labels, towns, ports, capitals and close-zoom building clusters. Off-screen items are culled, and it redraws only when the camera or selection changes. Building layouts are precomputed once at load. |
| **Packed arrays + dense integer IDs** (`world_data.gd`) | Cache-friendly, cheap to serialise, and keeps the future simulation independent of rendering. |
| **`preload` constants instead of `class_name`** | Runs from a fresh clone (headless, tests, export) without needing an editor import to build the global class cache. |
| **Images stored as compressed `Image` resources (`.res`)** | Lossless (PNG import would allow VRAM compression to corrupt IDs), needs no import step, and adds 4.9 MB to the PCK. |

### LOD rules
- **Strategic (zoom < 1.0):** country fills and names, capitals. Province borders fade out.
- **Regional (1.0–2.4):** province borders, towns, ports. Province names from zoom 1.7.
- **Local (≥ 2.4):** extruded building clusters sized by settlement tier, plus larger labels.

### Tests executed (all pass)
`tests/run_tests.gd`: **487 checks, 0 failures**
- ID codec round-trip (including 65535).
- Generator determinism: same seed gives an identical checksum, a different seed gives a different one.
- Generator invariants: dense IDs, pixel areas match the tables, symmetric adjacency, every province owned, capitals owned by their country, each anchor lies inside its own province.
- Shipped data: loads, image sizes match, 205 provinces / 14 countries, every province owned exactly once.
- Picking: the anchor of each of the 205 provinces picks back the correct ID; sea and out-of-bounds positions pick 0.

Other checks I actually ran:
- Rendered the game under Xvfb/llvmpipe at 1280×720 and inspected screenshots at three zoom levels (`docs/screenshots/`).
- Exported **Windows** (`.exe` + `.pck`) and **Linux** release builds. I ran the exported Linux build and it loaded the world. The Windows `.exe` was produced but **I didn't run it** (no Windows in the container).

### Measurements (llvmpipe software rendering, NOT target hardware)
`--benchmark`, VSync off, 1280×720 (full report: `docs/benchmarks_llvmpipe_m1.json`):

| phase | avg ms | avg fps | p99 ms | 1% low fps |
|---|---|---|---|---|
| far_pan | 21.9 | 45.7 | 28.3 | 30.6 |
| zoom_in | 29.9 | 33.5 | 45.5 | 19.5 |
| regional_pan | 26.7 | 37.5 | 34.5 | 18.3 |
| close_pan | 24.4 | 41.0 | 33.6 | 28.0 |
| zoom_sweep | 24.5 | 40.9 | 36.4 | 26.0 |
| select_spam | 34.1 | 29.3 | 54.5 | 13.3 |

- Memory: Godot static memory 50 MB (peak 55 MB). Reported video memory 37 MB. Process RSS of the exported Linux build at local zoom: **~284 MB** (this includes Mesa/llvmpipe's own buffers).
- Here the frame cost is dominated by CPU-emulated fragment shading, so these numbers are a regression baseline only. `select_spam` is slower because it rebuilds the info panel (Control nodes) every 4th frame, which is deliberately harsher than real use.

### Known limitations
- Not measured on the target hardware. The 60 FPS target is **unverified**.
- At very close zoom, province borders show texel stair-steps, because the ID map is 2048×1024 with nearest sampling.
- Lakes are treated as sea (ID 0), so a lakeside province can get a "port" icon.
- Some islands are given to the nearest capital, so a few countries have exclaves.
- Province/town names are procedural syllables. Countries are fictional (the map is procedural, not real geography).
- There are no railways or roads yet. Those need the economy (M3+).
- The info panel rebuilds its Control nodes on every selection. That's fine for clicks but should be pooled if selection becomes frequent.
- `RenderingServer` video-memory figures under llvmpipe may not reflect a real driver.
- The Windows build wasn't launched, and no icon or version resources were set (`application/modify_resources=false`, rcedit not configured).


## Session: war model, explanations, lenses, performance
- **Warfare** (`src/sim/military.gd`): battles are now persistent per attacked province (`live`), fought week by week. Each side commits a share of its army to every front it holds; strength = battalions x equipment x supply x organisation x tech x posture, defenders add terrain, fort and entrenchment (+4%/wk, max 30%). A battle ends when one side's organisation hits 0 (or after 10 weeks: stalemate); casualties and exhaustion scale with the weekly ratio. Postures (defensive/balanced/offensive, saved) trade strength, losses, arms use and upkeep. Reinforcement is slowed by arms shortages. `battle_report(c)` / `explain_battle(b)` feed the Military panel. AI sets postures weekly in `ai._set_postures`.
- **Economy explanations** (`economy.gd`): `building_diagnosis`, `jobs_explanation`, `budget_explanation` use live arrays; shown in building profit tooltips, population and treasury tooltips. Also `can_build_fast`, `best_build_candidate`, `prioritize_build`, `shortage_goods`, `province_gdp`.
- **Map lenses**: SoL, Pop, GDP, Unrest, War (battles/sieges/occupation/front); colours are written to the lookup texture only when data changes (monthly, weekly for War).
- **Performance**: weekly settle iterates only active buildings, scratch buffers preallocated, pops buffers swapped not duplicated, x5 paced at 55 days/s with a 5 ms/frame budget, HUD updates throttled, overlay labels/markers batched.
- Saves: `post`/`fl` keys are optional in the military dict; older saves load with balanced posture and no running battles.
- Not yet measured on the target Q8300/R7 350; run `tools/sim_benchmark.gd` there. Ideas left: army movement visualisation, peace terms driven by occupied share, naval war.
