extends Node2D
## Composition root: loads world data, wires map, camera, overlay, HUD,
## performance overlay and benchmark. Owns input that spans systems.

const WorldData := preload("res://src/world/world_data.gd")
const MapView := preload("res://src/map/map_view.gd")
const MapCamera := preload("res://src/map/map_camera.gd")
const MapOverlay := preload("res://src/map/map_overlay.gd")
const Hud := preload("res://src/ui/hud.gd")
const PerfOverlay := preload("res://src/ui/perf_overlay.gd")
const MapBenchmark := preload("res://src/benchmark/map_benchmark.gd")

var world: RefCounted
var map_view: Sprite2D
var cam: Camera2D
var overlay: Control
var hud: Control
var perf: Label
var bench: Node
var _hover_dirty := false
var _last_lod := -1


func _ready() -> void:
	var t := Time.get_ticks_msec()
	world = WorldData.load_default()
	if world == null:
		get_tree().quit(1)
		return
	map_view = MapView.new()
	add_child(map_view)
	map_view.setup(world)
	cam = MapCamera.new()
	add_child(cam)
	cam.make_current()
	cam.setup(Vector2(world.width, world.height))
	var ui := CanvasLayer.new()
	add_child(ui)
	overlay = MapOverlay.new()
	ui.add_child(overlay)
	overlay.setup(world, cam, map_view)
	hud = Hud.new()
	ui.add_child(hud)
	hud.setup(world)
	perf = PerfOverlay.new()
	ui.add_child(perf)
	perf.extra_info = func(): return "provinces %d · countries %d · LOD %d" % [world.province_count - 1, world.country_count, overlay.lod]
	bench = MapBenchmark.new()
	add_child(bench)
	bench.cam = cam
	bench.map_view = map_view
	bench.world = world
	bench.on_select = _select

	cam.view_changed.connect(_on_view_changed)
	hud.map_mode_requested.connect(_set_mode)
	hud.country_clicked.connect(func(c): _select(world.c_capital[c]); cam.focus(world.p_anchor[world.c_capital[c]]))
	hud.focus_requested.connect(func(p): cam.focus(p, maxf(cam.target_zoom, 1.4)))
	hud.perf_toggle_requested.connect(perf.cycle)
	hud.benchmark_requested.connect(bench.start)
	hud.deselect_requested.connect(_select.bind(0))
	print("World loaded: %d provinces, %d countries in %d ms (%s)" % [
		world.province_count - 1, world.country_count, Time.get_ticks_msec() - t,
		ProjectSettings.get_setting("rendering/renderer/rendering_method")])

	var args := OS.get_cmdline_user_args()
	if "--benchmark" in args:
		bench.finished.connect(func(_r): get_tree().quit(0))
		get_tree().create_timer(1.0).timeout.connect(bench.start)
	if "--low" in args:
		map_view.set_detail(false)
	# Docs/CI helper: -- --shot=user://shot.png [--view=x,y,zoom] [--select=id] [--mode=n]
	for a: String in args:
		var v := a.get_slice("=", 1)
		if a.begins_with("--view="):
			var p := v.split_floats(",")
			cam.set_view(Vector2(p[0], p[1]), p[2])
		elif a.begins_with("--select="):
			_select(int(v))
		elif a.begins_with("--mode="):
			_set_mode(int(v))
		elif a.begins_with("--shot="):
			get_tree().create_timer(1.5).timeout.connect(func():
				get_viewport().get_texture().get_image().save_png(v)
				get_tree().quit(0))


func _on_view_changed() -> void:
	map_view.set_zoom(cam.zoom.x)
	if overlay.lod != _last_lod or Engine.get_process_frames() % 10 == 0:
		_last_lod = overlay.lod
		hud.set_status(cam.zoom.x, overlay.lod)
	_hover_dirty = true


func _set_mode(m: int) -> void:
	map_view.set_mode(m)
	hud.set_mode_button(m)


func _select(province: int) -> void:
	map_view.select(province)
	hud.show_selection(province)
	overlay.queue_redraw()


func _process(_delta: float) -> void:
	# Picking is one image read; throttle to once per frame and only when needed.
	if _hover_dirty and not bench.running:
		_hover_dirty = false
		var p: int = world.province_at(get_global_mouse_position())
		if p != map_view.hovered_province:
			map_view.set_hover(p)
			hud.show_tooltip(p, get_viewport().get_mouse_position())


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover_dirty = true
		hud.move_tooltip(event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		if not cam.is_drag_click():
			_select(world.province_at(get_global_mouse_position()))
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_1: _set_mode(0)
			KEY_2: _set_mode(1)
			KEY_3: _set_mode(2)
			KEY_F3: perf.cycle()
			KEY_F9: bench.start()
			KEY_L:
				overlay.show_labels = not overlay.show_labels
				overlay.queue_redraw()
			KEY_ESCAPE: _select(0)
