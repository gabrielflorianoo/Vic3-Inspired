extends Label
## Configurable performance overlay. F3 cycles: off → compact → detailed.
## Frame times go into a fixed ring buffer (no per-frame allocation); the text
## is rebuilt only every `refresh_interval` seconds. Mode persists in
## user://settings.cfg ([debug] perf_overlay, refresh_interval).

enum Mode { OFF, COMPACT, DETAILED }

const SETTINGS := "user://settings.cfg"
const WINDOW := 240

var mode: int = Mode.COMPACT
var refresh_interval := 0.25
var extra_info: Callable  # returns a String appended in detailed mode

var _times := PackedFloat32Array()
var _idx := 0
var _filled := 0
var _accum := 0.0
var _last_usec := 0


func _ready() -> void:
	_times.resize(WINDOW)
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS) == OK:
		mode = cfg.get_value("debug", "perf_overlay", mode)
		refresh_interval = cfg.get_value("debug", "refresh_interval", refresh_interval)
	add_theme_font_size_override("font_size", 12)
	add_theme_color_override("font_color", Color(0.75, 1.0, 0.75))
	add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	add_theme_constant_override("outline_size", 4)
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	offset_top = 44
	offset_right = -10
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = mode != Mode.OFF
	_last_usec = Time.get_ticks_usec()


func cycle() -> void:
	mode = (mode + 1) % 3
	visible = mode != Mode.OFF
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("debug", "perf_overlay", mode)
	cfg.set_value("debug", "refresh_interval", refresh_interval)
	cfg.save(SETTINGS)
	_accum = refresh_interval


func _process(delta: float) -> void:
	var now := Time.get_ticks_usec()
	_times[_idx] = (now - _last_usec) / 1000.0
	_last_usec = now
	_idx = (_idx + 1) % WINDOW
	_filled = mini(_filled + 1, WINDOW)
	if mode == Mode.OFF:
		return
	_accum += delta
	if _accum < refresh_interval:
		return
	_accum = 0.0
	var sum := 0.0
	var worst := 0.0
	for i in _filled:
		sum += _times[i]
		worst = maxf(worst, _times[i])
	var avg := sum / maxf(_filled, 1)
	var fps := Engine.get_frames_per_second()
	if mode == Mode.COMPACT:
		text = "%d FPS · %.1f ms" % [fps, avg]
		return
	text = "%d FPS\nframe avg %.2f ms · worst %.2f ms (last %d)\nprocess %.2f ms\ndraw calls %d · objects %d\nstatic mem %.1f MB (peak %.1f)\nvideo mem %.1f MB · tex %.1f MB\nnodes %d%s" % [
		fps, avg, worst, _filled,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		OS.get_static_memory_usage() / 1048576.0, OS.get_static_memory_peak_usage() / 1048576.0,
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		("\n" + extra_info.call()) if extra_info.is_valid() else ""]
