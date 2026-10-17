extends Control
## Tiny sparkline: polyline of `values` normalised to the control's rect, with subtle zero-line when values cross 0.

var values := PackedFloat32Array()
var color := Color(0.86, 0.72, 0.42)


func _draw() -> void:
	var n := values.size()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.06, 0.055, 0.045, 0.65), true)
	if n < 2:
		return
	var lo := values[0]
	var hi := values[0]
	for v in values:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var span := maxf(hi - lo, 0.0001)
	if lo < 0.0 and hi > 0.0:
		var zy := size.y - 2.0 - (0.0 - lo) / span * (size.y - 4.0)
		draw_line(Vector2(1.0, zy), Vector2(size.x - 1.0, zy), Color(0.55, 0.50, 0.42, 0.45), 1.0)
	var pts := PackedVector2Array()
	for i in n:
		pts.append(Vector2(float(i) / (n - 1) * (size.x - 4.0) + 2.0, size.y - 2.0 - (values[i] - lo) / span * (size.y - 4.0)))
	draw_polyline(pts, color, 1.6, true)
	draw_circle(pts[n - 1], 2.2, color)
