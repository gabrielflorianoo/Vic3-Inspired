extends SceneTree
## Bakes the map assets. Run:
##   godot --headless --path . --script res://tools/generate_world.gd [-- --seed=1836]

const WorldGenerator := preload("res://src/world/world_generator.gd")
const OUT := "res://data/generated/"


func _init() -> void:
	var gen := WorldGenerator.new()
	gen.verbose = true
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			gen.seed_value = int(a.split("=")[1])
		elif a.begins_with("--size="):
			gen.width = int(a.split("=")[1])
			gen.height = gen.width / 2
		elif a.begins_with("--provinces="):
			gen.target_provinces = int(a.split("=")[1])
	var f := FileAccess.open("res://data/scenario/countries.json", FileAccess.READ)
	gen.scenario_countries = JSON.parse_string(f.get_as_text())["countries"]
	var t := Time.get_ticks_msec()
	gen.generate()
	print("Generated %d provinces, %d countries in %d ms" % [gen.provinces.size() - 1, gen.countries.size(), Time.get_ticks_msec() - t])
	DirAccess.make_dir_recursive_absolute(OUT)
	ResourceSaver.save(gen.terrain_image, OUT + "terrain.res", ResourceSaver.FLAG_COMPRESS)
	ResourceSaver.save(gen.id_image, OUT + "province_ids.res", ResourceSaver.FLAG_COMPRESS)
	var out := FileAccess.open(OUT + "world.json", FileAccess.WRITE)
	out.store_string(JSON.stringify(gen.to_json(), "", false))
	out.close()
	gen.terrain_image.save_png("user://terrain_preview.png")
	print("Checksum: %d" % gen.checksum())
	quit(0)
