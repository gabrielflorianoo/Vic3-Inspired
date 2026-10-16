extends Node
## Owns the running GameState: speed control and time-sliced stepping.
##
## Speeds (days per real second): 0 pause, 1, 3, 8, 20, MAX. Simulation work
## per frame is capped at BUDGET_MS so the UI stays responsive; unspent day
## credit carries over (capped) instead of being dropped. The UI is told once
## per frame via `stepped`, never once per simulated day.

signal stepped(days: int, week: bool, month: bool)
signal speed_changed(speed: int)
signal events_arrived(events: Array)
signal player_eliminated

const Settings := preload("res://src/game/settings.gd")
const BUDGET_MS := 8.0
const DAYS_PER_SEC := [0.0, 1.0, 3.0, 8.0, 20.0, 1.0e9]
const SPEED_NAMES := ["Paused", "Speed 1 (1 day/s)", "Speed 2 (3 days/s)", "Speed 3 (8 days/s)", "Speed 4 (20 days/s)", "Speed 5 (maximum)"]
const MAX_CARRY := 12.0

var state: RefCounted
var speed := 0
var last_speed := 1
var blocked := false         # true while a modal (pause menu) is open
var sim_ms_last := 0.0       # sim time spent in the last stepping frame
var _credit := 0.0
var _eliminated := false


func setup(s: RefCounted) -> void:
	state = s
	set_process(true)


func set_speed(v: int) -> void:
	v = clampi(v, 0, DAYS_PER_SEC.size() - 1)
	if v == speed:
		return
	speed = v
	if v > 0:
		last_speed = v
	_credit = 0.0
	speed_changed.emit(speed)


func toggle_pause() -> void:
	set_speed(last_speed if speed == 0 else 0)


func _process(delta: float) -> void:
	if state == null or speed == 0 or blocked or _eliminated:
		return
	_credit = minf(_credit + DAYS_PER_SEC[speed] * delta, MAX_CARRY if speed < 5 else 1.0e9)
	var t0 := Time.get_ticks_usec()
	var days := 0
	var week := false
	var month := false
	while _credit >= 1.0:
		state.advance_day()
		_credit -= 1.0
		days += 1
		if state.day % 7 == 0:
			week = true
		if state.day_of_month() == 1:
			month = true
			_maybe_autosave()
		if (Time.get_ticks_usec() - t0) / 1000.0 >= BUDGET_MS:
			break
	if speed == 5:
		_credit = 0.0
	sim_ms_last = (Time.get_ticks_usec() - t0) / 1000.0
	if days == 0:
		return
	stepped.emit(days, week, month)
	var evs: Array = state.take_new_events()
	if not evs.is_empty():
		events_arrived.emit(evs)
	if state.alive[state.player] == 0:
		_eliminated = true
		set_speed(0)
		player_eliminated.emit()


func _maybe_autosave() -> void:
	var mode := int(Settings.get_value("autosave"))
	if mode == 0:
		return
	if mode == 2 and state.month() != 1:
		return
	_session().save_game(state, "autosave")


func _session() -> Node:
	return (Engine.get_main_loop() as SceneTree).root.get_node("Session")
