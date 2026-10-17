extends Sprite2D
## The world map: one textured quad drawn with map.gdshader.
## Per-province visual state is pushed into a (N x 2) lookup texture only when
## selection, hover or ownership changes — never per frame.

enum Mode { POLITICAL, TERRAIN, PROVINCES }

var world: RefCounted
var mode: int = Mode.POLITICAL
var selected_province := 0
var selected_country := -1
var hovered_province := 0
## Optional (province:int) -> controlling country. Differs from the owner while
## a province is occupied; those provinces are drawn with diagonal stripes.
var controller_fn := Callable()

var _lookup_img: Image
var _lookup_tex: ImageTexture
var _mat: ShaderMaterial
var _any_occupied := false
var _last_zoom := -1.0


func setup(w: RefCounted) -> void:
	world = w
	centered = false
	var terrain: Image = world.terrain_image.duplicate()
	terrain.generate_mipmaps()
	texture = ImageTexture.create_from_image(terrain)
	_mat = ShaderMaterial.new()
	_mat.shader = preload("res://src/map/map.gdshader")
	_mat.set_shader_parameter("terrain_tex", texture)
	_mat.set_shader_parameter("id_tex", ImageTexture.create_from_image(world.id_image))
	_mat.set_shader_parameter("map_size", Vector2(world.width, world.height))
	material = _mat
	_lookup_img = Image.create(world.province_count, 3, false, Image.FORMAT_RGBA8)
	_lookup_tex = ImageTexture.create_from_image(_lookup_img)
	_mat.set_shader_parameter("lookup_tex", _lookup_tex)
	refresh_all()


func refresh_all() -> void:
	_any_occupied = false
	for id in world.province_count:
		_write(id)
	_mat.set_shader_parameter("has_occupation", _any_occupied)
	_lookup_tex.update(_lookup_img)
	_mat.set_shader_parameter("country_selected", selected_country >= 0)
	_mat.set_shader_parameter("map_mode", mode)


func _write(id: int) -> void:
	var o: int = world.p_owner[id] if id > 0 else -1
	var c := Color(0, 0, 0, 0)
	if o >= 0:
		c = world.c_color[o]
		c.a = 1.0
	_lookup_img.set_pixel(id, 0, c)
	_lookup_img.set_pixel(id, 1, Color8(o + 1, 255 if id == selected_province and id > 0 else 0,
		255 if id == hovered_province and id > 0 else 0, 255 if o >= 0 and o == selected_country else 0))
	# Row 2: occupation. rgb = occupier colour, a = 1 when controlled by someone else.
	var occ := Color(0, 0, 0, 0)
	if controller_fn.is_valid() and o >= 0:
		var ctl: int = controller_fn.call(id)
		if ctl >= 0 and ctl != o:
			occ = world.c_color[ctl]
			occ.a = 1.0
			_any_occupied = true
	_lookup_img.set_pixel(id, 2, occ)


func _write_meta(id: int) -> void:
	var o: int = world.p_owner[id] if id > 0 else -1
	_lookup_img.set_pixel(id, 1, Color8(o + 1, 255 if id == selected_province and id > 0 else 0,
		255 if id == hovered_province and id > 0 else 0, 255 if o >= 0 and o == selected_country else 0))


func set_mode(m: int) -> void:
	mode = m
	_mat.set_shader_parameter("map_mode", mode)


func set_zoom(z: float) -> void:
	if z == _last_zoom:
		return
	_last_zoom = z
	_mat.set_shader_parameter("zoom", z)


func set_detail(on: bool) -> void:
	_mat.set_shader_parameter("detail", 1.0 if on else 0.0)


func select(province: int) -> void:
	var country: int = world.p_owner[province] if province > 0 else -1
	var old_p := selected_province
	var old_c := selected_country
	selected_province = province
	selected_country = country
	if country != old_c:
		if old_c >= 0 and old_c < world.c_provinces.size():
			for p: int in world.c_provinces[old_c]:
				_write_meta(p)
		if country >= 0 and country < world.c_provinces.size():
			for p: int in world.c_provinces[country]:
				_write_meta(p)
		_write_meta(old_p)
		_write_meta(province)
		_mat.set_shader_parameter("country_selected", selected_country >= 0)
		_lookup_tex.update(_lookup_img)
		return
	_write_meta(old_p)
	_write_meta(province)
	_lookup_tex.update(_lookup_img)


func select_country(country: int) -> void:
	var cap: int = world.c_capital[country] if country >= 0 else 0
	select(cap)


func set_hover(province: int) -> void:
	if province == hovered_province:
		return
	var old := hovered_province
	hovered_province = province
	_write_meta(old)
	_write_meta(province)
	_lookup_tex.update(_lookup_img)
