# Development Log

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
