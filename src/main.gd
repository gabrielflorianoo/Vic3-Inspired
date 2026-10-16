extends Node2D
## Game scene root. Loads the world, wires map, camera, overlay, performance
## overlay and benchmark, then runs one of the Session flows:
##   "new"        nation-pick overlay -> play
##   "autostart"  new game as Session.autostart_country (testing)
##   "load"       load Session.path
##   "benchmark"  map only (`godot --path . -- --benchmark`)
##
## Dev/CI arguments after `--`:
##   --shot=path [--shot-delay=s]  save a screenshot and quit
##   --autostart=<country>         skip menu + nation pick
##   --view=x,y,zoom --select=<province> --mode=<0..2> --low
##   --tab=<overview|market|...>   open a panel   --speed=<0..5>
##   --run-days=<n>                simulate n days before the first frame

const WorldData := preload("res://src/world/world_data.gd")
const MapView := preload("res://src/map/map_view.gd")
const MapCamera := preload("res://src/map/map_camera.gd")
const MapOverlay := preload("res://src/map/map_overlay.gd")
const PerfOverlay := preload("res://src/ui/perf_overlay.gd")
const MapBenchmark := preload("res://src/benchmark/map_benchmark.gd")
const GameHud := preload("res://src/ui/game_hud.gd")
const NationPick := preload("res://src/ui/nation_pick.gd")
const PauseMenu := preload("res://src/ui/panels/pause_menu.gd")
const GameController := preload("res://src/game/game_controller.gd")
const Settings := preload("res://src/game/settings.gd")
const K := preload("res://src/ui/ui_kit.gd")

var world: RefCounted
var state: RefCounted
var map_view: Sprite2D
var cam: Camera2D
var overlay: Control
var perf: Label
var bench: Node
var ui: CanvasLayer
var ctrl: Node
var hud: Control
var pick: Control
var pause_menu: Control
var mode := "new"

var _hover_dirty := false
var _last_lod := -1
var _args: PackedStringArray
var _preview: RefCounted
var _controllers := PackedInt32Array()


func _ready() -> void:
	var t := Time.get_ticks_msec()
	_args = OS.get_cmdline_user_args()
	mode = K.session().mode
	if "--benchmark" in _args:
		mode = "benchmark"
	for a: String in _args:
		if a.begins_with("--autostart="):
			mode = "autostart"
			K.session().autostart_country = int(a.get_slice("=", 1))
	world = WorldData.load_default()
	if world == null:
		get_tree().quit(1)
		return
	map_view = MapView.new()
	add_child(map_view)
	map_view.setup(world)
	map_view.set_detail(bool(Settings.get_value("map_detail")))
	cam = MapCamera.new()
	add_child(cam)
	cam.make_current()
	cam.setup(Vector2(world.width, world.height))
	ui = CanvasLayer.new()
	add_child(ui)
	overlay = MapOverlay.new()
	ui.add_child(overlay)
	overlay.setup(world, cam, map_view)
	perf = PerfOverlay.new()
	ui.add_child(perf)
	perf.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	perf.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	perf.grow_vertical = Control.GROW_DIRECTION_BEGIN
	perf.offset_bottom = -26
	perf.offset_right = -10
	perf.extra_info = _perf_info
	bench = MapBenchmark.new()
	add_child(bench)
	bench.cam = cam
	bench.map_view = map_view
	bench.world = world
	bench.on_select = _select
	cam.view_changed.connect(_on_view_changed)
	print("World loaded: %d provinces, %d countries in %d ms (%s)" % [
		world.province_count - 1, world.country_count, Time.get_ticks_msec() - t,
		ProjectSettings.get_setting("rendering/renderer/rendering_method")])

	if "--low" in _args:
		map_view.set_detail(false)
	match mode:
		"benchmark":
			bench.finished.connect(func(_r): get_tree().quit(0))
			get_tree().create_timer(1.0).timeout.connect(bench.start)
		"autostart":
			_start_game(K.session().new_state(world, K.session().autostart_country))
		"load":
			var s: RefCounted = K.session().load_state(world, K.session().path)
			if s == null:
				_fatal("Could not load the save file.")
			else:
				_start_game(s)
		_:
			_begin_pick()
	_apply_dev_args()


func _apply_dev_args() -> void:
	var delay := 1.5
	var shot := ""
	for a: String in _args:
		var v := a.get_slice("=", 1)
		if a.begins_with("--view="):
			var p := v.split_floats(",")
			cam.set_view(Vector2(p[0], p[1]), p[2])
		elif a.begins_with("--select="):
			_select(int(v))
		elif a.begins_with("--mode="):
			_set_mode(int(v))
		elif a.begins_with("--tab=") and hud != null:
			hud.open_tab(v)
		elif a.begins_with("--diplo=") and hud != null:
			hud.open_diplomacy(int(v))
		elif a.begins_with("--speed=") and ctrl != null:
			ctrl.set_speed(int(v))
		elif a.begins_with("--run-days=") and state != null:
			for i in int(v):
				state.advance_day()
			hud.refresh_now()
		elif a.begins_with("--shot-delay="):
			delay = float(v)
		elif a.begins_with("--shot="):
			shot = v
		elif a == "--pause-menu" and pause_menu != null:
			_toggle_pause_menu()
	if shot != "":
		get_tree().create_timer(delay).timeout.connect(func():
			get_viewport().get_texture().get_image().save_png(shot)
			get_tree().quit(0))


func _exit_tree() -> void:
	# Break state <-> module reference cycles so a discarded game is freed.
	for st in [state, _preview]:
		if st != null and st.has_method("dispose"):
			st.dispose()


func _perf_info() -> String:
	var s := "provinces %d - countries %d - LOD %d" % [world.province_count - 1, world.country_count, overlay.lod]
	if state != null:
		s += "\nday %d - sim %.1f ms/frame" % [state.day, ctrl.sim_ms_last]
	return s


# ------------------------------------------------------------- flow control

func _fatal(msg: String) -> void:
	var l := K.lbl(msg + "  Returning to the main menu...", 18, K.BAD)
	l.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	ui.add_child(l)
	get_tree().create_timer(2.5).timeout.connect(K.session().to_menu)


func _begin_pick() -> void:
	if not K.session().sim_available():
		_fatal("Simulation modules are not available.")
		return
	var loading := K.lbl("Preparing the world...", 20, K.GOLD)
	loading.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	ui.add_child(loading)
	await get_tree().process_frame
	await get_tree().process_frame
	_preview = K.session().new_state(world, 0)
	loading.queue_free()
	var preview := _preview
	pick = NationPick.new()
	ui.add_child(pick)
	pick.setup(world, preview)
	pick.confirmed.connect(_on_nation_confirmed)
	pick.menu_requested.connect(K.session().to_menu)
	# A few "--select=" style dev args may have fired before pick existed.
	for a: String in _args:
		if a.begins_with("--select="):
			_select(int(a.get_slice("=", 1)))


func _on_nation_confirmed(country: int) -> void:
	if _preview != null and _preview.has_method("dispose"):
		_preview.dispose()
	_preview = null
	var s: RefCounted = K.session().new_state(world, country)
	if s == null:
		_fatal("Could not start a new game.")
		return
	pick.queue_free()
	pick = null
	_start_game(s)


func _start_game(s: RefCounted) -> void:
	if s == null:
		_fatal("Could not start the game.")
		return
	state = s
	ctrl = GameController.new()
	add_child(ctrl)
	ctrl.setup(state)
	map_view.controller_fn = state.military.controller
	_controllers = _snapshot_controllers()
	map_view.refresh_all()
	hud = GameHud.new()
	ui.add_child(hud)
	hud.setup(world, state, ctrl)
	ui.move_child(hud, 1)  # above the map overlay, below perf overlay
	hud.map_mode_requested.connect(_set_mode)
	hud.focus_requested.connect(func(p): cam.focus(p, maxf(cam.target_zoom, 1.4)))
	hud.select_requested.connect(_select)
	hud.deselect_requested.connect(_select.bind(0))
	hud.menu_requested.connect(_toggle_pause_menu)
	hud.perf_toggle_requested.connect(perf.cycle)
	pause_menu = PauseMenu.new()
	ui.add_child(pause_menu)
	pause_menu.setup(state)
	pause_menu.resume_requested.connect(_toggle_pause_menu)
	pause_menu.setting_changed.connect(_on_setting_changed)
	pause_menu.toast_requested.connect(hud.toast)
	ctrl.player_eliminated.connect(_on_player_eliminated)
	ctrl.stepped.connect(_on_stepped)
	var cap: int = world.c_capital[state.player]
	cam.set_view(world.p_anchor[cap], 1.2)
	_select(cap)
	ctrl.set_speed(0)
	hud.toast("%s awaits your command. Press Space to begin." % world.c_name[state.player], "system")
	print("Game started as %s (seed %d)" % [world.c_name[state.player], K.session().game_seed])


## Ownership changes (conquest, revolution) and occupation changes re-upload the
## small province lookup texture; nothing else on the map is touched.
func _on_stepped(_days: int, week: bool, _month: bool) -> void:
	if state.ownership_dirty:
		state.ownership_dirty = false
		map_view.refresh_all()
		overlay.queue_redraw()
		hud.refresh_now()
		_controllers = _snapshot_controllers()
	elif week:
		var snap := _snapshot_controllers()
		if snap != _controllers:
			_controllers = snap
			map_view.refresh_all()


func _snapshot_controllers() -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(world.province_count)
	for p in range(1, world.province_count):
		out[p] = state.military.controller(p)
	return out


func _on_player_eliminated() -> void:
	var p := PanelContainer.new()
	p.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	var v := K.vbox(10)
	p.add_child(v)
	v.add_child(K.lbl("%s has fallen." % world.c_name[state.player], 22, K.BAD))
	v.add_child(K.lbl("Your nation no longer exists. The game is over.", 13, K.DIM))
	var h := K.hbox(8)
	h.add_child(K.btn("Main Menu", "", K.session().to_menu))
	h.add_child(K.btn("Keep watching", "Continue observing the world", func(): p.queue_free()))
	v.add_child(h)
	p.theme = K.get_theme()
	ui.add_child(p)


func _on_setting_changed(key: String) -> void:
	match key:
		"map_detail":
			map_view.set_detail(bool(Settings.get_value("map_detail")))
		"perf_overlay":
			perf.mode = int(Settings.get_value("perf_overlay"))
			perf.visible = perf.mode != 0


func _toggle_pause_menu() -> void:
	if pause_menu == null:
		return
	if pause_menu.visible:
		pause_menu.close()
	else:
		pause_menu.open()
		if hud != null:
			hud.hide_tooltip()
	ctrl.blocked = pause_menu.visible


# ------------------------------------------------------------------- map

func _on_view_changed() -> void:
	map_view.set_zoom(cam.zoom.x)
	_hover_dirty = true


func _set_mode(m: int) -> void:
	map_view.set_mode(m)
	if hud != null:
		hud.set_mode_button(m)


func _select(province: int) -> void:
	map_view.select(province)
	if hud != null:
		hud.show_selection(province)
	if pick != null:
		pick.show_country(world.p_owner[province] if province > 0 else -1)
	overlay.queue_redraw()


func _process(_delta: float) -> void:
	# Picking is one image read; throttle to once per frame and only when needed.
	if _hover_dirty and not bench.running:
		_hover_dirty = false
		var mouse := get_viewport().get_mouse_position()
		var blocked: bool = (hud != null and hud.mouse_over_ui(mouse)) or (pause_menu != null and pause_menu.visible)
		var p: int = 0 if blocked else world.province_at(get_global_mouse_position())
		if p != map_view.hovered_province:
			map_view.set_hover(p)
		var tip_owner: Object = hud if hud != null else pick
		if tip_owner != null:
			if p > 0:
				tip_owner.show_tooltip(p, mouse)
			else:
				tip_owner.hide_tooltip()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover_dirty = true
		if hud != null:
			hud.move_tooltip(event.position)
		elif pick != null:
			pick.move_tooltip(event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		if not cam.is_drag_click() and not bench.running:
			_select(world.province_at(get_global_mouse_position()))
	elif event is InputEventKey and event.pressed and not event.echo:
		var in_game := ctrl != null
		var menu_open := pause_menu != null and pause_menu.visible
		match event.physical_keycode:
			KEY_ESCAPE:
				if in_game:
					_toggle_pause_menu()
				elif pick != null:
					pick.hide_card()
					_select(0)
			KEY_SPACE:
				if in_game and not menu_open:
					ctrl.toggle_pause()
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
				if in_game and not menu_open:
					ctrl.set_speed(event.physical_keycode - KEY_0)
			KEY_KP_ADD, KEY_EQUAL:
				if in_game and not menu_open:
					ctrl.set_speed(mini(ctrl.speed + 1, 5))
			KEY_KP_SUBTRACT, KEY_MINUS:
				if in_game and not menu_open:
					ctrl.set_speed(maxi(ctrl.speed - 1, 0))
			KEY_F5: _set_mode(0)
			KEY_F6: _set_mode(1)
			KEY_F7: _set_mode(2)
			KEY_F3: perf.cycle()
			KEY_F9: bench.start()
			KEY_L:
				overlay.show_labels = not overlay.show_labels
				overlay.queue_redraw()
