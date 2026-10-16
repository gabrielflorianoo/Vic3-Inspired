extends RefCounted
## Province IDs are stored in an RGB8 image: R = low byte, G = high byte.
## Supports 65535 provinces; the shader decodes the same way.

static func encode(id: int) -> Color:
	return Color8(id & 255, (id >> 8) & 255, 0)


static func decode(c: Color) -> int:
	return int(round(c.r * 255.0)) + int(round(c.g * 255.0)) * 256


static func encode_image(ids: PackedInt32Array, w: int, h: int) -> Image:
	var data := PackedByteArray()
	data.resize(w * h * 3)
	for i in ids.size():
		var v := ids[i]
		data[i * 3] = v & 255
		data[i * 3 + 1] = (v >> 8) & 255
	return Image.create_from_data(w, h, false, Image.FORMAT_RGB8, data)
