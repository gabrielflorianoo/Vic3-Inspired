extends Camera2D
## Smooth zoom-to-cursor, drag and keyboard panning, clamped to the map.
## Emits `view_changed` only when position or zoom actually changes, so
## overlays redraw on demand instead of every frame.

signal view_changed

const ZOOM_MAX := 6.0
const ZOOM_STEP := 1.18
const PAN_SPEED := 700.0

var map_size := Vector2(2048, 1024)
var zoom_min := 0.5
var target_zoom := 1.0
var smoothing := true
var _anchor_world := Vector2.ZERO
var _anchor_screen := Vector2.ZERO
var _anchored := false
var _dragging := false
var _drag_moved := 0.0
var _last_pos := Vector2.INF
var _last_zoom := -1.0


func setup(size: Vector2) -> void:
	map_size = size
	_update_zoom_min()
	target_zoom = zoom_min * 1.05
	zoom = Vector2.ONE * target_zoom
	position = map_size * 0.5
	get_viewport().size_changed.connect(_update_zoom_min)


func _update_zoom_min() -> void:
	var vs := get_viewport_rect().size
	zoom_min = maxf(vs.x / map_size.x, vs.y / map_size.y) * 0.98


func zoom_level() -> float:
	return zoom.x


func is_drag_click() -> bool:
	return _drag_moved > 6.0


func set_view(world_pos: Vector2, z: float) -> void:
	target_zoom = clampf(z, zoom_min, ZOOM_MAX)
	zoom = Vector2.ONE * target_zoom
	position = world_pos
	_anchored = false
	_clamp()


func focus(world_pos: Vector2, z: float = -1.0) -> void:
	if z > 0.0:
		target_zoom = clampf(z, zoom_min, ZOOM_MAX)
	_anchored = false
	_focus_target = world_pos


var _focus_target := Vector2.INF


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var f := ZOOM_STEP if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / ZOOM_STEP
			target_zoom = clampf(target_zoom * f, zoom_min, ZOOM_MAX)
			_anchor_screen = mb.position
			_anchor_world = get_global_mouse_position()
			_anchored = true
			_focus_target = Vector2.INF
		elif mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_dragging = mb.pressed
			if mb.pressed:
				_drag_moved = 0.0
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_drag_moved += mm.relative.length()
		if _drag_moved > 6.0 or mm.button_mask & (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE):
			position -= mm.relative / zoom.x
			_anchored = false
			_focus_target = Vector2.INF
			_clamp()


func _process(delta: float) -> void:
	var k := Vector2(
		Input.get_axis(&"ui_left", &"ui_right") + float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		Input.get_axis(&"ui_up", &"ui_down") + float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	if k != Vector2.ZERO:
		position += k.limit_length(1.0) * PAN_SPEED * delta / zoom.x
		_anchored = false
		_focus_target = Vector2.INF
	var t := 1.0 - exp(-delta * 14.0) if smoothing else 1.0
	if not is_equal_approx(zoom.x, target_zoom):
		var z := lerpf(zoom.x, target_zoom, t)
		if absf(z - target_zoom) < 0.0005:
			z = target_zoom
		zoom = Vector2.ONE * z
		if _anchored:
			var half := get_viewport_rect().size * 0.5
			position = _anchor_world - (_anchor_screen - half) / z
	if _focus_target != Vector2.INF:
		position = position.lerp(_focus_target, t)
		if position.distance_to(_focus_target) < 0.5:
			_focus_target = Vector2.INF
	_clamp()
	if position != _last_pos or zoom.x != _last_zoom:
		_last_pos = position
		_last_zoom = zoom.x
		view_changed.emit()


func _clamp() -> void:
	var half := get_viewport_rect().size * 0.5 / zoom.x
	position.x = clampf(position.x, minf(half.x, map_size.x * 0.5), maxf(map_size.x - half.x, map_size.x * 0.5))
	position.y = clampf(position.y, minf(half.y, map_size.y * 0.5), maxf(map_size.y - half.y, map_size.y * 0.5))
