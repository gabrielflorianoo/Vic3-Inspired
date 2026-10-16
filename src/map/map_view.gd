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

var _lookup_img: Image
var _lookup_tex: ImageTexture
var _mat: ShaderMaterial


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
	_lookup_img = Image.create(world.province_count, 2, false, Image.FORMAT_RGBA8)
	_lookup_tex = ImageTexture.create_from_image(_lookup_img)
	_mat.set_shader_parameter("lookup_tex", _lookup_tex)
	refresh_all()


func refresh_all() -> void:
	for id in world.province_count:
		_write(id)
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


func set_mode(m: int) -> void:
	mode = m
	_mat.set_shader_parameter("map_mode", mode)


func set_zoom(z: float) -> void:
	_mat.set_shader_parameter("zoom", z)


func set_detail(on: bool) -> void:
	_mat.set_shader_parameter("detail", 1.0 if on else 0.0)


func select(province: int) -> void:
	var country: int = world.p_owner[province] if province > 0 else -1
	if country != selected_country:
		selected_province = province
		selected_country = country
		refresh_all()  # whole-country highlight flag changes: rewrite N texels (~200)
		return
	var old := selected_province
	selected_province = province
	_write(old)
	_write(province)
	_lookup_tex.update(_lookup_img)


func select_country(country: int) -> void:
	selected_country = country
	selected_province = world.c_capital[country] if country >= 0 else 0
	refresh_all()


func set_hover(province: int) -> void:
	if province == hovered_province:
		return
	var old := hovered_province
	hovered_province = province
	_write(old)
	_write(province)
	_lookup_tex.update(_lookup_img)
