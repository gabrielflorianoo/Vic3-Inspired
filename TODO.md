# TODO (prioritised)

## Next (Milestone 2, after review)
1. **Measure M1 on the target PC** (Q8300 / R7 350): `IronAndSociety.exe -- --benchmark`, then record the JSON in `docs/`. If a phase misses 16.6 ms, profile the shader (reduce fetches: bake static province-edge/coast flags into the ID texture's free B channel) before touching anything else.
2. **Deterministic time + scheduler**: a fixed-step game clock (day ticks), per-subsystem frequencies, pause/speed controls, and a seeded RNG stream per subsystem. Keep it separate from rendering.
3. **Population cohorts + headless sim benchmark**: packed cohort arrays per province (profession, class, culture, ...), plus a sim-only benchmark reporting per-subsystem tick cost and memory.

## Later
- Smooth border rendering at close zoom (distance-field edges or a 2× ID map loaded only for local LOD).
- Separate lakes from sea in the generator. Allow ports on sea coasts only.
- Sea zones as provinces (for naval logistics and trade routes).
- Railway/road overlay layer (batched polylines) once infrastructure exists.
- Pool info-panel widgets instead of rebuilding them.
- Stress worlds: 500/1000/2000 provinces via `--provinces=`, then benchmark again.
- Windows icon/version resources (rcedit) and a CI export job.
