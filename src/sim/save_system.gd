extends RefCounted
## Save/load of whole games as JSON under user://saves/. Static functions only.
##   save_game(state, name) -> path        list_saves() -> [{path,name,date,country,saved_at}] newest first
##   latest_save() -> path or ""           load_game(world, path) -> state or null

const GameState := preload("res://src/sim/game_state.gd")

const DIR := "user://saves/"
const VERSION := 1
const AUTOSAVE := "autosave"


static func _safe_name(name: String) -> String:
	var out := ""
	for ch in name.strip_edges():
		if ch.is_valid_identifier() or ch in [" ", "-", "."] or (ch >= "0" and ch <= "9"):
			out += ch
		else:
			out += "_"
	return out if out != "" else "save"


static func path_for(name: String) -> String:
	return DIR + _safe_name(name) + ".json"


static func save_game(state, name: String) -> String:
	DirAccess.make_dir_recursive_absolute(DIR)
	var path := path_for(name)
	var w = state.world
	var data := {
		"version": VERSION,
		"world_seed": w.seed_value,
		"saved_at": Time.get_unix_time_from_system(),
		"date": state.date_string(),
		"player_country_name": w.c_name[state.player],
		"state": state.to_dict(),
	}
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("Cannot write save %s (error %d)" % [tmp, FileAccess.get_open_error()])
		return ""
	f.store_string(JSON.stringify(data))
	f.close()
	# write-then-rename so a crash never leaves a half-written save
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	DirAccess.rename_absolute(tmp, path)
	return path


static func _read_header(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var j = JSON.parse_string(f.get_as_text())
	f.close()
	if not (j is Dictionary):
		return {}
	return j


static func list_saves() -> Array:
	var out: Array = []
	var d := DirAccess.open(DIR)
	if d == null:
		return out
	for fn in d.get_files():
		if not fn.ends_with(".json"):
			continue
		var path := DIR + fn
		var j := _read_header(path)
		if j.is_empty() or not j.has("state"):
			continue
		out.append({"path": path, "name": fn.get_basename(), "date": str(j.get("date", "")),
			"country": str(j.get("player_country_name", "")), "saved_at": float(j.get("saved_at", 0.0))})
	out.sort_custom(func(a, b): return a["saved_at"] > b["saved_at"])
	return out


static func latest_save() -> String:
	var l := list_saves()
	return l[0]["path"] if not l.is_empty() else ""


static func load_game(world, path: String):
	var j := _read_header(path)
	if j.is_empty() or not j.has("state"):
		push_error("Unreadable save: " + path)
		return null
	if int(j.get("version", 0)) != VERSION:
		push_error("Unsupported save version in " + path)
		return null
	return GameState.from_dict(world, j["state"])
