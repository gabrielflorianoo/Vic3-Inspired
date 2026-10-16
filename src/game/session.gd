extends Node
## Autoload "Session": carries the requested game flow between scenes
## (menu -> game) and is the only place that touches simulation entry points
## that live outside the UI (GameState factory, SaveSystem).
##
##   mode: "new"        nation pick, then play
##         "load"       load `path`
##         "autostart"  skip menu + pick, new game as `autostart_country`
##         "benchmark"  map only, for `-- --benchmark`

const WorldData := preload("res://src/world/world_data.gd")
const Settings := preload("res://src/game/settings.gd")
const MENU_SCENE := "res://scenes/main_menu.tscn"
const GAME_SCENE := "res://scenes/game.tscn"
const GAME_STATE := "res://src/sim/game_state.gd"
const SAVE_SYSTEM := "res://src/sim/save_system.gd"

var mode := "new"
var path := ""
var autostart_country := 0
var game_seed := 1836


func _ready() -> void:
	Settings.apply_all()


# ---- scene flow ----------------------------------------------------------

func start_new() -> void:
	mode = "new"
	_go(GAME_SCENE)


func start_autostart(country: int) -> void:
	mode = "autostart"
	autostart_country = country
	_go(GAME_SCENE)


func start_load(save_path: String) -> void:
	mode = "load"
	path = save_path
	_go(GAME_SCENE)


func start_continue() -> bool:
	var p := latest_save()
	if p == "":
		return false
	start_load(p)
	return true


func start_benchmark() -> void:
	mode = "benchmark"
	_go(GAME_SCENE)


func to_menu() -> void:
	_go(MENU_SCENE)


func quit_game() -> void:
	get_tree().quit()


func _go(scene: String) -> void:
	get_tree().change_scene_to_file.call_deferred(scene)


# ---- simulation entry points (loaded lazily so the UI parses without them) -

func load_world() -> RefCounted:
	return WorldData.load_default()


func sim_available() -> bool:
	return ResourceLoader.exists(GAME_STATE)


func new_state(world: RefCounted, player_country: int) -> RefCounted:
	if not sim_available():
		return null
	var gs = load(GAME_STATE)
	return gs.new_game(world, player_country, game_seed)


func _save_script() -> Variant:
	return load(SAVE_SYSTEM) if ResourceLoader.exists(SAVE_SYSTEM) else null


func list_saves() -> Array:
	var ss = _save_script()
	return ss.list_saves() if ss != null else []


func latest_save() -> String:
	var ss = _save_script()
	return ss.latest_save() if ss != null else ""


func save_game(state: RefCounted, save_name: String) -> String:
	var ss = _save_script()
	return ss.save_game(state, save_name) if ss != null else ""


func load_state(world: RefCounted, save_path: String) -> RefCounted:
	var ss = _save_script()
	return ss.load_game(world, save_path) if ss != null else null
