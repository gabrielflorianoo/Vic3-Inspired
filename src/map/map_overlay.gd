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
var _p_w11 := PackedFloat32Array()
var _p_w13 := PackedFloat32Array()
var _c_label_txt := PackedStringArray()
var _c_w_cache := {}
var _star_unit := PackedVector2Array()
var _cap_pts := PackedVector2Array()
var _cap_sh := PackedVector2Array()
var _roof_pts := PackedVector2Array()


func setup(w: RefCounted, camera: Camera2D, mv: Node) -> void:
	world = w
	cam = camera
	map_view = mv
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font = ThemeDB.fallback_font
	_build_clusters()
	_build_caches()
	cam.view_changed.connect(queue_redraw)


func _build_caches() -> void:
	var n: int = world.province_count
	_p_w11.resize(n)
	_p_w13.resize(n)
	for id in range(1, n):
		var nm: String = world.p_name[id]
		_p_w11[id] = _font.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		_p_w13[id] = _font.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	var cn: int = world.country_count
	_c_label_txt.resize(cn)
	for c in cn:
		_c_label_txt[c] = " ".join(world.c_short[c].to_upper().split(""))
	_star_unit.resize(10)
	for i in 10:
		var a := -PI * 0.5 + i * PI / 5.0
		var scale_r := 1.0 if i % 2 == 0 else 0.45
		_star_unit[i] = Vector2(cos(a) * scale_r, sin(a) * scale_r)
	_cap_pts.resize(11)
	_cap_sh.resize(10)
	_roof_pts.resize(4)


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
	var cam_pos: Vector2 = cam.get_screen_center_position()
	var half_size: Vector2 = size * 0.5
	var vx0 := -40.0
	var vy0 := -40.0
	var vx1 := size.x + 40.0
	var vy1 := size.y + 40.0
	var n: int = world.province_count
	var anchors: PackedVector2Array = world.p_anchor
	var ports: PackedVector2Array = world.p_port
	var caps: PackedByteArray = world.p_capital
	var tiers: PackedByteArray = world.p_tier
	var sel_p: int = map_view.selected_province
	# Pass 1: buildings (close) — drawn first so markers/labels sit on top.
	if lod == LOD_CLOSE:
		for id in range(1, n):
			var s := (anchors[id] - cam_pos) * z + half_size
			if s.x >= vx0 and s.x <= vx1 and s.y >= vy0 and s.y <= vy1:
				_draw_cluster(id, s, z)
	# Pass 2: towns and ports.
	if lod >= LOD_REGIONAL:
		for id in range(1, n):
			var s := (anchors[id] - cam_pos) * z + half_size
			if s.x < vx0 or s.x > vx1 or s.y < vy0 or s.y > vy1:
				continue
			var pt := ports[id]
			if pt.x >= 0.0:
				_draw_port((pt - cam_pos) * z + half_size)
			if caps[id] == 0:
				_draw_town(s, int(tiers[id]), id == sel_p)
	# Pass 3: capitals at every zoom.
	var c_caps: PackedInt32Array = world.c_capital
	var cn: int = world.country_count
	var is_far := lod == LOD_FAR
	for c in cn:
		var s := (anchors[c_caps[c]] - cam_pos) * z + half_size
		if s.x >= vx0 and s.x <= vx1 and s.y >= vy0 and s.y <= vy1:
			_draw_capital(s, is_far)
	if not show_labels:
		return
	# Pass 4: province names.
	if z >= 1.7:
		var is_11 := z < CLOSE_AT
		var fs := 11 if is_11 else 13
		var pw := _p_w11 if is_11 else _p_w13
		var p_names: PackedStringArray = world.p_name
		var col := Color(0.97, 0.94, 0.86)
		var ocol := Color(0.08, 0.06, 0.05, 0.9)
		var y_off := 16.0 + fs * 0.35
		for id in range(1, n):
			var s := (anchors[id] - cam_pos) * z + half_size
			if s.x >= vx0 and s.x <= vx1 and s.y >= vy0 and s.y <= vy1:
				var pos := Vector2(s.x - pw[id] * 0.5, s.y + y_off)
				draw_string_outline(_font, pos, p_names[id], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, ocol)
				draw_string(_font, pos, p_names[id], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	# Pass 5: country names, fading out as provinces take over.
	var alpha := clampf((1.9 - z) / 0.7, 0.0, 1.0)
	if alpha > 0.0:
		var c_labels: PackedVector2Array = world.c_label
		var c_areas: PackedInt32Array = world.c_area
		var col := Color(1, 0.97, 0.88, alpha)
		var ocol := Color(0.08, 0.06, 0.05, 0.85 * alpha)
		var gvx0 := -240.0
		var gvy0 := -240.0
		var gvx1 := size.x + 240.0
		var gvy1 := size.y + 240.0
		for c in cn:
			var s := (c_labels[c] - cam_pos) * z + half_size
			if s.x < gvx0 or s.x > gvx1 or s.y < gvy0 or s.y > gvy1:
				continue
			var fs := int(clampf(sqrt(float(c_areas[c])) * z * 0.075, 11.0, 34.0))
			var txt: String = _c_label_txt[c]
			var key := (c << 8) | fs
			var w: float = _c_w_cache.get(key, -1.0)
			if w < 0.0:
				w = _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				_c_w_cache[key] = w
			var pos := Vector2(s.x - w * 0.5, s.y + fs * 0.35)
			var outline := maxi(4, fs >> 2)
			draw_string_outline(_font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, outline, ocol)
			draw_string(_font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


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
	var sh_off := s + Vector2(1.5, 2.0)
	for i in 10:
		var d := _star_unit[i] * r
		_cap_pts[i] = s + d
		_cap_sh[i] = sh_off + d
	_cap_pts[10] = _cap_pts[0]
	draw_colored_polygon(_cap_sh, Color(0, 0, 0, 0.4))
	draw_colored_polygon(_cap_pts.slice(0, 10), Color(0.98, 0.84, 0.36))
	draw_polyline(_cap_pts, Color(0.2, 0.12, 0.05), 1.2)


## Pseudo-3D boxes: shadow, side wall, front wall and roof — cheap 2.5D depth.
func _draw_cluster(id: int, s: Vector2, z: float) -> void:
	var k := z * 1.25
	var base := Color(0.80, 0.74, 0.64)
	var side_col := base.darkened(0.3)
	var sh_col := Color(0, 0, 0, 0.28)
	var roof := Color(0.62, 0.30, 0.24) if world.p_tier[id] < 5 else Color(0.36, 0.42, 0.55)
	for b in _bld[id]:
		var p := s + Vector2(b.x, b.y) * k
		var w := 2.0 * b.z * k
		var hgt := 1.7 * b.z * k
		draw_rect(Rect2(p + Vector2(-w * 0.5 + hgt * 0.5, -hgt * 0.2), Vector2(w, hgt * 0.6)), sh_col)
		draw_rect(Rect2(p + Vector2(-w * 0.5, -hgt), Vector2(w, hgt)), base)
		draw_rect(Rect2(p + Vector2(w * 0.5, -hgt), Vector2(w * 0.25, hgt)), side_col)
		_roof_pts[0] = p + Vector2(-w * 0.6, -hgt)
		_roof_pts[1] = p + Vector2(w * 0.1, -hgt - w * 0.55)
		_roof_pts[2] = p + Vector2(w * 0.85, -hgt - w * 0.4)
		_roof_pts[3] = p + Vector2(w * 0.75, -hgt)
		draw_colored_polygon(_roof_pts, roof)
