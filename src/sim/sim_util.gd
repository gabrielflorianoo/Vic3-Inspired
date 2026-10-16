extends RefCounted
## Exact, compact (de)serialisation of packed arrays for JSON saves.
## Arrays become base64 strings of their raw bytes, so float state round-trips
## bit-for-bit (JSON number text would not) and files stay small.
## Empty arrays encode as "" and never reach Marshalls (it errors on empty data).


static func _b64(b: PackedByteArray) -> String:
	if b.is_empty():
		return ""
	return Marshalls.raw_to_base64(b)


static func _unb64(s: Variant) -> PackedByteArray:
	if s is String and s != "":
		return Marshalls.base64_to_raw(s)
	return PackedByteArray()


static func enc_f64(a: PackedFloat64Array) -> String:
	return "" if a.is_empty() else _b64(a.to_byte_array())


static func dec_f64(s: Variant) -> PackedFloat64Array:
	var b := _unb64(s)
	return b.to_float64_array() if not b.is_empty() else PackedFloat64Array()


static func enc_f32(a: PackedFloat32Array) -> String:
	return "" if a.is_empty() else _b64(a.to_byte_array())


static func dec_f32(s: Variant) -> PackedFloat32Array:
	if s is Array:   # legacy plain-array saves
		return PackedFloat32Array(s)
	var b := _unb64(s)
	return b.to_float32_array() if not b.is_empty() else PackedFloat32Array()


static func enc_i32(a: PackedInt32Array) -> String:
	return "" if a.is_empty() else _b64(a.to_byte_array())


static func dec_i32(s: Variant) -> PackedInt32Array:
	var b := _unb64(s)
	return b.to_int32_array() if not b.is_empty() else PackedInt32Array()


static func enc_u8(a: PackedByteArray) -> String:
	return _b64(a)


static func dec_u8(s: Variant) -> PackedByteArray:
	return _unb64(s)


## Bit-exact text form of one double ("x" + 16 hex chars of its IEEE bytes). JSON number text and
## String.num() are not exact for every double, so scalars that must round-trip use this.
static func num_str(x: float) -> String:
	return "x" + PackedFloat64Array([x]).to_byte_array().hex_encode()


static func parse_num(v: Variant, default: float = 0.0) -> float:
	if v is String:
		var s: String = v
		if s.length() == 17 and s[0] == "x":
			var arr := s.substr(1).hex_decode().to_float64_array()
			return arr[0] if arr.size() == 1 else default
		return s.to_float() if s != "" else default   # legacy decimal text
	if v is float or v is int:
		return float(v)
	return default


static func fmt_money(v: float) -> String:
	var a := absf(v)
	if a >= 1.0e9:
		return "%.2fB" % (v / 1.0e9)
	if a >= 1.0e6:
		return "%.2fM" % (v / 1.0e6)
	if a >= 1.0e3:
		return "%.1fk" % (v / 1.0e3)
	return "%.0f" % v
