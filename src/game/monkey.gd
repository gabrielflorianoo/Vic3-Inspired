extends Node
## Dev-only UI fuzzer (`-- --autostart=N --monkey=SECONDS`): opens random tabs and presses random
## enabled buttons (build, research, enact law, diplomacy, peace...) while the game runs at speed
## 5, to surface script errors in real UI action paths. Prints a summary and quits when done.

var hud: Control
var ctrl: Node
var duration := 60.0
var presses := 0
var failures := 0
var _t := 0.0
var _acc := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 12345


func _process(delta: float) -> void:
	_t += delta
	_acc += delta
	if _t >= duration:
		var st: RefCounted = hud.state
		var p: int = st.player
		print("MONKEY done: %d presses, day %d, techs known %d, building queue %d, wars %d, laws changed %d, treasury %.0f" % [
			presses, st.day, st.tech.known(p).size(), st.econ.queue(p).size(), st.diplo.wars_of(p).size(),
			st.politics.laws_changed(p) if st.politics.has_method("laws_changed") else -1, st.econ.treasury_of(p)])
		get_tree().quit(0)
		return
	if _acc < 0.3:
		return
	_acc = 0.0
	var tabs: Array = hud.TABS
	var tab: String = tabs[_rng.randi() % tabs.size()][0]
	if tab != hud.current_tab:
		hud.open_tab(tab)
	hud.refresh_now()
	var btns: Array = []
	_collect(hud._host, btns)
	if btns.is_empty():
		return
	for _i in _rng.randi_range(1, 3):
		var b: BaseButton = btns[_rng.randi() % btns.size()]
		if not is_instance_valid(b) or b.disabled or not b.is_visible_in_tree():
			continue
		if b is OptionButton:
			if b.item_count > 0:
				b.select(_rng.randi() % b.item_count)
				b.item_selected.emit(b.selected)
			continue
		if b.text == "Close":
			continue
		presses += 1
		b.pressed.emit()
		if is_instance_valid(b) and b.toggle_mode:
			b.button_pressed = not b.button_pressed


func _collect(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is BaseButton:
			out.append(c)
		_collect(c, out)
