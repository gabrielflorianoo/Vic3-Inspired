extends Control
## Tiny sparkline: polyline of `values` normalised to the control's rect.

var values := PackedFloat32Array()
var color := Color(0.86, 0.72, 0.42)


func _draw() -> void:
	var n := values.size()
	if n < 2:
		return
	var lo := values[0]
	var hi := values[0]
	for v in values:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var span := maxf(hi - lo, 0.0001)
	var pts := PackedVector2Array()
	for i in n:
		pts.append(Vector2(float(i) / (n - 1) * (size.x - 2) + 1, size.y - 2 - (values[i] - lo) / span * (size.y - 4)))
	draw_polyline(pts, color, 1.5, true)
