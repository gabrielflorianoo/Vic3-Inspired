extends RefCounted
## User settings persisted in user://settings.cfg (shared file with
## perf_overlay.gd, which owns [debug] perf_overlay / refresh_interval).
## Values are read from disk on demand and written with load-modify-save, so
## other writers of the file are never clobbered. Only keys that exist in the
## file are applied at startup, so command-line --resolution still works.

const PATH := "user://settings.cfg"
const RESOLUTIONS: Array[Vector2i] = [Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080)]
const UI_SCALES: Array[float] = [0.85, 1.0, 1.25, 1.5]
const DEFS := {
	"window_mode": ["display", 0],      # 0 windowed, 1 fullscreen
	"resolution": ["display", 0],       # index into RESOLUTIONS
	"vsync": ["display", true],
	"ui_scale": ["display", 1.0],
	"map_detail": ["gameplay", true],   # ocean animation + vignette
	"autosave": ["gameplay", 1],        # 0 off, 1 monthly, 2 yearly
	"perf_overlay": ["debug", 1],       # 0 off, 1 compact, 2 detailed (perf_overlay.gd Mode)
}


static func get_value(key: String) -> Variant:
	var d: Array = DEFS[key]
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return d[1]
	return cfg.get_value(d[0], key, d[1])


static func set_value(key: String, v: Variant, apply_now := true) -> void:
	var d: Array = DEFS[key]
	var cfg := ConfigFile.new()
	cfg.load(PATH)
	cfg.set_value(d[0], key, v)
	cfg.save(PATH)
	if apply_now:
		apply_key(key)


static func has_saved(key: String) -> bool:
	var d: Array = DEFS[key]
	var cfg := ConfigFile.new()
	return cfg.load(PATH) == OK and cfg.has_section_key(d[0], key)


## Apply every setting that the user has explicitly saved.
static func apply_all() -> void:
	for key: String in ["window_mode", "resolution", "vsync", "ui_scale"]:
		if has_saved(key):
			apply_key(key)


static func apply_key(key: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	match key:
		"window_mode", "resolution":
			var fs: bool = int(get_value("window_mode")) == 1
			if fs:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			else:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
				var r: Vector2i = RESOLUTIONS[clampi(int(get_value("resolution")), 0, RESOLUTIONS.size() - 1)]
				DisplayServer.window_set_size(r)
				var scr := DisplayServer.screen_get_size()
				var origin := DisplayServer.screen_get_position()
				DisplayServer.window_set_position(origin + (scr - r) / 2)
		"vsync":
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(get_value("vsync")) else DisplayServer.VSYNC_DISABLED)
		"ui_scale":
			var tree := Engine.get_main_loop() as SceneTree
			if tree != null:
				tree.root.content_scale_factor = float(get_value("ui_scale"))
