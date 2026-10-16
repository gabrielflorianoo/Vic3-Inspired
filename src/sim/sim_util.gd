extends RefCounted
## Exact, compact (de)serialisation of packed arrays for JSON saves.
## Arrays become base64 strings of their raw bytes, so float state round-trips
## bit-for-bit (JSON number text would not) and files stay small.


static func enc_f64(a: PackedFloat64Array) -> String:
	return Marshalls.raw_to_base64(a.to_byte_array())


static func dec_f64(s: Variant) -> PackedFloat64Array:
	if s is String and s != "":
		return Marshalls.base64_to_raw(s).to_float64_array()
	return PackedFloat64Array()


static func enc_i32(a: PackedInt32Array) -> String:
	return Marshalls.raw_to_base64(a.to_byte_array())


static func dec_i32(s: Variant) -> PackedInt32Array:
	if s is String and s != "":
		return Marshalls.base64_to_raw(s).to_int32_array()
	return PackedInt32Array()


static func enc_u8(a: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(a)


static func dec_u8(s: Variant) -> PackedByteArray:
	if s is String and s != "":
		return Marshalls.base64_to_raw(s)
	return PackedByteArray()


static func fmt_money(v: float) -> String:
	var a := absf(v)
	if a >= 1.0e9:
		return "%.2fB" % (v / 1.0e9)
	if a >= 1.0e6:
		return "%.2fM" % (v / 1.0e6)
	if a >= 1.0e3:
		return "%.1fk" % (v / 1.0e3)
	return "%.0f" % v
