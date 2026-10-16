# TODO (prioritised)

## Next (gameplay polish, Milestone 3)
1. **Measure on the target PC** (Q8300 / R7 350): `IronAndSociety.exe -- --benchmark` and `tools/sim_benchmark.gd`. The weekly economy tick is ~20 ms in the container; if it is slower there, spread it over several frames (per-region slices) or move the hot loops to packed-array-only code.
2. **Split the heavy ticks**: week + month on the same day (~45 ms) should be staggered (e.g. run month work on the following day) without breaking determinism/saves; add a regression test.
3. **Player quality of life**: research queue / "research finished" toast with auto-open of Technology, building-queue visibility in the top bar, confirmation for declaring war, tooltips explaining every number.
4. **Balance pass with the AI**: the 5-year test run shows 6 wars and 0 revolutions; tune AI aggression, tax/debt handling and law changes so that 20+ year games stay interesting. Add a long-run (50 year) soak test with invariants.
5. **Toast/side-panel layout at UI scale 150%** (toasts overlap the province card on small windows) and a responsive layout pass at 1280x720 and 1920x1080.
6. **Event log**: de-duplicate war events logged per participant; filter by kind/country.

## Later
- Trade/transport: tariffs UI, trade routes between markets, naval logistics (sea zones as provinces).
- Migration and culture/religion layers in population; population detail per province.
- Wars: army movement on the map, battle reports, peace conference with multiple demands.
- Smooth border rendering at close zoom (distance-field edges or a 2x ID map loaded only for local LOD).
- Separate lakes from sea in the generator. Allow ports on sea coasts only.
- Railway/road overlay layer (batched polylines) once infrastructure matters visually.
- Pool info-panel widgets instead of rebuilding them.
- Stress worlds: 500/1000/2000 provinces via `--provinces=`, then benchmark the sim and the map again.
- Windows icon/version resources (rcedit), CI job for tests + export, launch-test the Windows build.
- Sound, tutorial, scenario selection, more countries and a second start date.
