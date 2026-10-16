extends VBoxContainer
## Base class for tab panels. `hud` is the GameHud (provides state, world,
## toast(), selection helpers). Panels rebuild their children in `rebuild()`;
## `refresh()` is called by the HUD on the weekly tick (throttled) or after a
## user action — never every frame.

const K := preload("res://src/ui/ui_kit.gd")

var hud: Control
var state: RefCounted
var world: RefCounted
var player := 0


func setup(h: Control) -> void:
	hud = h
	state = h.state
	world = h.world
	player = state.player
	add_theme_constant_override("separation", 8)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	refresh()


func refresh() -> void:
	K.clear(self)
	rebuild()


func rebuild() -> void:
	pass


## Run an action that returns {ok, reason} (or bool) and toast the outcome.
func act(res: Variant, ok_msg: String, then_refresh := true) -> void:
	hud.toast(K.result_text(res, ok_msg), "ok" if K.result_ok(res) else "error")
	if then_refresh:
		hud.refresh_now()


## Read a constant from a sim module instance (e.g. PROF_NAMES).
func const_of(obj: Object, const_name: String, default: Variant) -> Variant:
	var scr: Script = obj.get_script()
	return scr.get_script_constant_map().get(const_name, default) if scr != null else default


func name_of(c: int) -> String:
	return world.c_name[c] if c >= 0 and c < world.country_count else "?"


func short_of(c: int) -> String:
	return world.c_short[c] if c >= 0 and c < world.country_count else "?"


func country_chip(c: int, fs := 13) -> Control:
	var h := K.hbox(6)
	h.add_child(K.flag(world.c_color[c], Vector2(18, 12)))
	h.add_child(K.lbl(short_of(c), fs))
	return h


## Wars of the player with warscore + peace buttons. Shared by Diplomacy and Military.
func war_rows(parent: Control) -> void:
	var wars: Array = state.diplo.wars_of(player)
	if wars.is_empty():
		parent.add_child(K.lbl("At peace.", 13, K.DIM))
		return
	for w: Dictionary in wars:
		var att: Array = w.get("attackers", [])
		var is_att: bool = att.has(player)
		var foes: Array = w.get("defenders", []) if is_att else att
		var score: float = state.diplo.warscore_for(w, player)
		var names: PackedStringArray = []
		for f in foes:
			names.append(short_of(int(f)))
		var box := K.vbox(3)
		var head := K.hbox(8)
		var summary: String = state.diplo.war_summary(int(w.get("id", 0)))
		head.add_child(K.lbl("%s vs %s" % [state.diplo.war_name(w), ", ".join(names)], 14, K.BAD, summary))
		head.add_child(K.spacer())
		head.add_child(K.lbl("%s  -  %d days" % ["Attacker" if is_att else "Defender", state.day - int(w.get("start_day", 0))], 11, K.DIM, summary))
		box.add_child(head)
		var row := K.hbox(8)
		row.add_child(K.lbl("Warscore %+d" % int(score), 13, K.sign_color(score),
			"Positive means you are winning. Offers are accepted more readily when the enemy's warscore against them is poor."))
		var b := K.bar((score + 100.0) / 200.0, K.GOOD if score >= 0.0 else K.BAD, 160.0, 10.0)
		row.add_child(b)
		box.add_child(row)
		var pr := K.hbox(6)
		var wid: int = int(w.get("id", 0))
		pr.add_child(K.btn("White peace", "Offer to end the war with no changes", func(): act(state.diplo.offer_peace(wid, player, "white_peace"), "Peace agreed.")))
		pr.add_child(K.btn("Peace: cede war goals", "Offer peace on the terms of the war goals", func(): act(state.diplo.offer_peace(wid, player, "cede_goals"), "Peace agreed.")))
		box.add_child(pr)
		box.add_child(HSeparator.new())
		parent.add_child(box)
