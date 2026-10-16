extends Control
## Screen-space map annotations: country names, capitals, towns, ports and,
## at close zoom, small extruded building clusters (the 2.5D layer).
##
## One Control draws everything with immediate-mode canvas calls (batched by
## the renderer) instead of hundreds of nodes. It redraws only when the camera
## or selection changes, and culls everything outside the view.

const LOD_FAR := 0
const LOD_REGIONAL := 1
const LOD_CLOSE := 2
const REGIONAL_AT := 1.0
const CLOSE_AT := 2.4

var world: RefCounted
var cam: Camera2D
var map_view: Node
var show_labels := true
var lod := LOD_FAR

var _font: Font
var _bld: Array[PackedVector3Array] = []  # per province: (dx, dy, size)


func setup(w: RefCounted, camera: Camera2D, mv: Node) -> void:
	world = w
	cam = camera
	map_view = mv
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font = ThemeDB.fallback_font
	_build_clusters()
	cam.view_changed.connect(queue_redraw)


## Deterministic building layout per town, computed once at load.
func _build_clusters() -> void:
	var rng := RandomNumberGenerator.new()
	_bld.resize(world.province_count)
	for id in world.province_count:
		var arr := PackedVector3Array()
		if id > 0:
			rng.seed = world.seed_value * 7919 + id
			var n: int = 2 + int(world.p_tier[id]) * 3
			var spread: float = 3.0 + world.p_tier[id] * 1.6
			for i in n:
				var ang := rng.randf() * TAU
				var r := sqrt(rng.randf()) * spread
				arr.append(Vector3(cos(ang) * r, sin(ang) * r * 0.7, rng.randf_range(0.7, 1.3)))
			arr.sort()  # crude back-to-front order by x keeps overlap stable
		_bld[id] = arr


func w2s(p: Vector2) -> Vector2:
	return (p - cam.get_screen_center_position()) * cam.zoom.x + size * 0.5


func _draw() -> void:
	var z: float = cam.zoom.x
	lod = LOD_FAR if z < REGIONAL_AT else (LOD_REGIONAL if z < CLOSE_AT else LOD_CLOSE)
	var view := Rect2(Vector2(-40, -40), size + Vector2(80, 80))
	var n: int = world.province_count
	# Pass 1: buildings (close) — drawn first so markers/labels sit on top.
	if lod == LOD_CLOSE:
		for id in range(1, n):
			var s := w2s(world.p_anchor[id])
			if view.has_point(s):
				_draw_cluster(id, s, z)
	# Pass 2: towns and ports.
	if lod >= LOD_REGIONAL:
		for id in range(1, n):
			var s := w2s(world.p_anchor[id])
			if not view.has_point(s):
				continue
			if world.p_port[id].x >= 0.0:
				var ps := w2s(world.p_port[id])
				_draw_port(ps)
			if world.p_capital[id] == 0:
				_draw_town(s, int(world.p_tier[id]), id == map_view.selected_province)
	# Pass 3: capitals at every zoom.
	for c in world.country_count:
		var s := w2s(world.p_anchor[world.c_capital[c]])
		if view.has_point(s):
			_draw_capital(s, lod == LOD_FAR)
	if not show_labels:
		return
	# Pass 4: province names.
	if z >= 1.7:
		var fs := 11 if z < CLOSE_AT else 13
		for id in range(1, n):
			var s := w2s(world.p_anchor[id])
			if view.has_point(s):
				_label(world.p_name[id], s + Vector2(0, 16), fs, Color(0.97, 0.94, 0.86), 3)
	# Pass 5: country names, fading out as provinces take over.
	var alpha := clampf((1.9 - z) / 0.7, 0.0, 1.0)
	if alpha > 0.0:
		for c in world.country_count:
			var s := w2s(world.c_label[c])
			if not view.grow(200).has_point(s):
				continue
			var fs := int(clampf(sqrt(float(world.c_area[c])) * z * 0.075, 11.0, 34.0))
			var txt: String = " ".join(world.c_short[c].to_upper().split(""))
			_label(txt, s, fs, Color(1, 0.97, 0.88, alpha), maxi(4, fs / 4), Color(0.08, 0.06, 0.05, 0.85 * alpha))


func _label(t: String, p: Vector2, fs: int, col: Color, outline: int, ocol := Color(0.08, 0.06, 0.05, 0.9)) -> void:
	var w := _font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var pos := p + Vector2(-w * 0.5, fs * 0.35)
	draw_string_outline(_font, pos, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, outline, ocol)
	draw_string(_font, pos, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _draw_town(s: Vector2, tier: int, selected: bool) -> void:
	var r := 2.0 + tier * 0.9
	draw_circle(s + Vector2(1.5, 2.0), r + 1.0, Color(0, 0, 0, 0.35))
	draw_circle(s, r + 1.0, Color(0.12, 0.09, 0.07))
	draw_circle(s, r, Color(0.98, 0.86, 0.45) if selected else Color(0.93, 0.89, 0.80))


func _draw_port(s: Vector2) -> void:
	draw_circle(s + Vector2(1, 1.5), 4.5, Color(0, 0, 0, 0.3))
	draw_circle(s, 4.5, Color(0.13, 0.22, 0.32))
	draw_line(s + Vector2(0, -2.5), s + Vector2(0, 2.5), Color(0.9, 0.92, 0.95), 1.4)
	draw_arc(s + Vector2(0, 0.5), 2.4, 0.3, PI - 0.3, 8, Color(0.9, 0.92, 0.95), 1.2)


func _draw_capital(s: Vector2, far: bool) -> void:
	var r := 5.5 if far else 7.0
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI * 0.5 + i * PI / 5.0
		pts.append(s + Vector2(cos(a), sin(a)) * (r if i % 2 == 0 else r * 0.45))
	var sh := PackedVector2Array()
	for p in pts:
		sh.append(p + Vector2(1.5, 2.0))
	draw_colored_polygon(sh, Color(0, 0, 0, 0.4))
	draw_colored_polygon(pts, Color(0.98, 0.84, 0.36))
	pts.append(pts[0])
	draw_polyline(pts, Color(0.2, 0.12, 0.05), 1.2)


## Pseudo-3D boxes: shadow, side wall, front wall and roof — cheap 2.5D depth.
func _draw_cluster(id: int, s: Vector2, z: float) -> void:
	var k := z * 1.25
	var base := Color(0.80, 0.74, 0.64)
	var roof := Color(0.62, 0.30, 0.24) if world.p_tier[id] < 5 else Color(0.36, 0.42, 0.55)
	for b in _bld[id]:
		var p := s + Vector2(b.x, b.y) * k
		var w := 2.0 * b.z * k
		var hgt := 1.7 * b.z * k
		draw_rect(Rect2(p + Vector2(-w * 0.5 + hgt * 0.5, -hgt * 0.2), Vector2(w, hgt * 0.6)), Color(0, 0, 0, 0.28))
		draw_rect(Rect2(p + Vector2(-w * 0.5, -hgt), Vector2(w, hgt)), base)
		draw_rect(Rect2(p + Vector2(w * 0.5, -hgt), Vector2(w * 0.25, hgt)), base.darkened(0.3))
		draw_colored_polygon(PackedVector2Array([
			p + Vector2(-w * 0.6, -hgt), p + Vector2(w * 0.1, -hgt - w * 0.55),
			p + Vector2(w * 0.85, -hgt - w * 0.4), p + Vector2(w * 0.75, -hgt)]), roof)
