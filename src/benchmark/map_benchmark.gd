extends Node
## Scripted, deterministic map benchmark. Drives the camera along a fixed path
## through all LOD levels and hammers selection/hover, recording real frame
## times per phase. VSync is disabled during the run to measure headroom.
## Results: printed + written to user://benchmarks/map_<unix>.json.
##
## Launch: godot --path . -- --benchmark     (quits when finished)

signal finished(report: Dictionary)

const PHASES := [
	["far_pan", 6.0], ["zoom_in", 5.0], ["regional_pan", 6.0],
	["close_pan", 6.0], ["zoom_sweep", 6.0], ["select_spam", 5.0],
]

var cam: Camera2D
var map_view: Node
var world: RefCounted
var on_select: Callable
var running := false

var _phase := -1
var _t := 0.0
var _times := PackedFloat32Array()
var _results: Array = []
var _rng := RandomNumberGenerator.new()
var _last_usec := 0
var _prev_vsync := 0


func start() -> void:
	if running:
		return
	running = true
	_rng.seed = 42
	_results.clear()
	_prev_vsync = DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	cam.smoothing = false
	_begin(0)


func _begin(i: int) -> void:
	_phase = i
	_t = 0.0
	_times.clear()
	_last_usec = Time.get_ticks_usec()


func _process(delta: float) -> void:
	if not running:
		return
	var now := Time.get_ticks_usec()
	_times.append((now - _last_usec) / 1000.0)
	_last_usec = now
	var dur: float = PHASES[_phase][1]
	_t += delta
	var u := clampf(_t / dur, 0.0, 1.0)
	_drive(PHASES[_phase][0], u)
	if _t >= dur:
		_results.append(_stats(PHASES[_phase][0], _times))
		if _phase + 1 < PHASES.size():
			_begin(_phase + 1)
		else:
			_finish()


func _drive(name: String, u: float) -> void:
	var W: float = world.width
	var H: float = world.height
	match name:
		"far_pan":
			cam.set_view(Vector2(lerpf(0.3, 0.7, u) * W, H * 0.5), cam.zoom_min * 1.15)
		"zoom_in":
			cam.set_view(Vector2(W * 0.5, H * 0.5), lerpf(cam.zoom_min, 1.6, u))
		"regional_pan":
			cam.set_view(Vector2(W * (0.25 + 0.5 * u), H * (0.4 + 0.2 * sin(u * TAU))), 1.6)
		"close_pan":
			cam.set_view(Vector2(W * (0.3 + 0.4 * u), H * (0.5 + 0.15 * cos(u * TAU))), 3.5)
		"zoom_sweep":
			cam.set_view(Vector2(W * 0.45, H * 0.5), lerpf(cam.zoom_min, 5.5, 0.5 - 0.5 * cos(u * TAU * 3.0)))
		"select_spam":
			cam.set_view(Vector2(W * 0.5, H * 0.5), 1.2)
			var p := _rng.randi_range(1, world.province_count - 1)
			map_view.set_hover(_rng.randi_range(1, world.province_count - 1))
			if Engine.get_process_frames() % 4 == 0:
				on_select.call(p)


func _stats(name: String, t: PackedFloat32Array) -> Dictionary:
	var s := t.duplicate()
	s.sort()
	var n := s.size()
	var sum := 0.0
	for v in s:
		sum += v
	var avg := sum / maxf(n, 1)
	var worst_1pct := 0.0
	var k := maxi(1, n / 100)
	for i in k:
		worst_1pct += s[n - 1 - i]
	worst_1pct /= k
	return {
		"phase": name, "frames": n, "avg_ms": snappedf(avg, 0.01), "avg_fps": snappedf(1000.0 / maxf(avg, 0.001), 0.1),
		"p50_ms": snappedf(s[n / 2], 0.01), "p95_ms": snappedf(s[int(n * 0.95)], 0.01),
		"p99_ms": snappedf(s[int(n * 0.99)], 0.01), "max_ms": snappedf(s[n - 1], 0.01),
		"low_1pct_fps": snappedf(1000.0 / maxf(worst_1pct, 0.001), 0.1),
	}


func _finish() -> void:
	running = false
	cam.smoothing = true
	DisplayServer.window_set_vsync_mode(_prev_vsync)
	var report := {
		"engine": Engine.get_version_info()["string"],
		"renderer": ProjectSettings.get_setting("rendering/renderer/rendering_method"),
		"gpu": RenderingServer.get_video_adapter_name(),
		"gpu_vendor": RenderingServer.get_video_adapter_vendor(),
		"cpu": OS.get_processor_name(), "cpu_count": OS.get_processor_count(),
		"resolution": str(get_viewport().get_visible_rect().size),
		"provinces": world.province_count - 1, "countries": world.country_count,
		"static_mem_mb": snappedf(OS.get_static_memory_usage() / 1048576.0, 0.1),
		"static_mem_peak_mb": snappedf(OS.get_static_memory_peak_usage() / 1048576.0, 0.1),
		"video_mem_mb": snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1),
		"phases": _results,
	}
	DirAccess.make_dir_recursive_absolute("user://benchmarks")
	var path := "user://benchmarks/map_%d.json" % int(Time.get_unix_time_from_system())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(report, "  "))
	print("=== MAP BENCHMARK ===")
	print("%s | %s | %s" % [report["gpu"], report["renderer"], report["resolution"]])
	for r: Dictionary in _results:
		print("%-13s avg %6.2f ms (%6.1f fps)  p95 %6.2f  p99 %6.2f  max %6.2f  1%%low %6.1f fps" % [
			r["phase"], r["avg_ms"], r["avg_fps"], r["p95_ms"], r["p99_ms"], r["max_ms"], r["low_1pct_fps"]])
	print("static mem %.1f MB (peak %.1f) · video mem %.1f MB" % [report["static_mem_mb"], report["static_mem_peak_mb"], report["video_mem_mb"]])
	print("Report: ", ProjectSettings.globalize_path(path))
	finished.emit(report)
