extends RefCounted
## Shared UI toolkit: palette, the project-wide Theme (dark parchment panels,
## gold borders) and small static widget factories. Everything is built in code.

const GOLD := Color(0.86, 0.72, 0.42)
const INK := Color(0.93, 0.90, 0.82)
const DIM := Color(0.68, 0.64, 0.56)
const GOOD := Color(0.55, 0.85, 0.50)
const BAD := Color(0.95, 0.45, 0.40)
const WARN := Color(0.95, 0.78, 0.35)
const BG := Color(0.11, 0.10, 0.085, 0.96)
const BORDER := Color(0.50, 0.41, 0.24)

const SparkScript := preload("res://src/ui/spark.gd")

static var _theme: Theme
static var _style_cache: Dictionary = {}
static var _bar_fill_cache: Dictionary = {}


## The Session autoload, fetched by path so scripts also parse standalone.
static func session() -> Node:
	return (Engine.get_main_loop() as SceneTree).root.get_node("Session")


## Treasury accessor tolerant of the economy module naming (treasury_of / treasury).
static func treasury(econ: RefCounted, c: int) -> float:
	return econ.treasury_of(c) if econ.has_method("treasury_of") else econ.treasury(c)


static func style(bg: Color, border: Color, bw := 1, radius := 3, pad := 8) -> StyleBoxFlat:
	var key := "%s|%s|%d|%d|%d" % [bg.to_html(), border.to_html(), bw, radius, pad]
	if _style_cache.has(key):
		return _style_cache[key]
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(pad)
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 4
	_style_cache[key] = sb
	return sb


static func panel_style(pad := 12) -> StyleBoxFlat:
	return style(BG, BORDER, 1, 4, pad)


static func get_theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font_size = 13
	t.set_color("font_color", "Label", INK)
	t.set_color("font_outline_color", "Label", Color(0, 0, 0, 0.8))
	# Buttons (also used by OptionButton / CheckBox where relevant)
	for tn in ["Button", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", tn, style(Color(0.17, 0.15, 0.12), Color(0.42, 0.35, 0.22), 1, 2, 5))
		t.set_stylebox("hover", tn, style(Color(0.26, 0.22, 0.16), GOLD, 1, 2, 5))
		t.set_stylebox("pressed", tn, style(Color(0.36, 0.29, 0.17), GOLD, 1, 2, 5))
		t.set_stylebox("disabled", tn, style(Color(0.13, 0.12, 0.10), Color(0.28, 0.24, 0.17), 1, 2, 5))
		t.set_stylebox("focus", tn, StyleBoxEmpty.new())
		t.set_color("font_color", tn, INK)
		t.set_color("font_hover_color", tn, Color(1, 0.95, 0.8))
		t.set_color("font_pressed_color", tn, Color(1, 0.92, 0.7))
		t.set_color("font_hover_pressed_color", tn, Color(1, 0.92, 0.7))
		t.set_color("font_disabled_color", tn, Color(0.45, 0.42, 0.36))
	t.set_stylebox("hover_pressed", "Button", style(Color(0.40, 0.32, 0.18), GOLD, 1, 2, 5))
	# Check boxes
	for tn in ["CheckBox", "CheckButton"]:
		t.set_color("font_color", tn, INK)
		t.set_color("font_hover_color", tn, Color(1, 0.95, 0.8))
		t.set_color("font_pressed_color", tn, INK)
		t.set_color("font_hover_pressed_color", tn, Color(1, 0.95, 0.8))
		t.set_stylebox("focus", tn, StyleBoxEmpty.new())
		t.set_stylebox("normal", tn, StyleBoxEmpty.new())
		t.set_stylebox("pressed", tn, StyleBoxEmpty.new())
		t.set_stylebox("hover", tn, StyleBoxEmpty.new())
		t.set_stylebox("hover_pressed", tn, StyleBoxEmpty.new())
		t.set_stylebox("disabled", tn, StyleBoxEmpty.new())
	# Panels, popups, tooltips
	t.set_stylebox("panel", "PanelContainer", panel_style())
	t.set_stylebox("panel", "PopupPanel", style(Color(0.10, 0.09, 0.075, 0.98), BORDER, 1, 3, 4))
	t.set_stylebox("panel", "PopupMenu", style(Color(0.10, 0.09, 0.075, 0.98), BORDER, 1, 3, 4))
	t.set_stylebox("hover", "PopupMenu", style(Color(0.30, 0.25, 0.15), GOLD, 1, 2, 3))
	t.set_color("font_color", "PopupMenu", INK)
	t.set_color("font_hover_color", "PopupMenu", Color(1, 0.95, 0.8))
	t.set_stylebox("panel", "TooltipPanel", style(Color(0.08, 0.07, 0.06, 0.96), Color(0.55, 0.45, 0.26), 1, 3, 7))
	t.set_color("font_color", "TooltipLabel", INK)
	t.set_font_size("font_size", "TooltipLabel", 12)
	# Text input
	t.set_stylebox("normal", "LineEdit", style(Color(0.07, 0.065, 0.055), Color(0.42, 0.35, 0.22), 1, 2, 5))
	t.set_stylebox("focus", "LineEdit", style(Color(0.07, 0.065, 0.055), GOLD, 1, 2, 5))
	t.set_color("font_color", "LineEdit", INK)
	t.set_color("caret_color", "LineEdit", GOLD)
	t.set_color("selection_color", "LineEdit", Color(0.5, 0.4, 0.2, 0.6))
	t.set_color("font_placeholder_color", "LineEdit", Color(0.5, 0.46, 0.38))
	# Progress / sliders / scrollbars / separators
	t.set_stylebox("background", "ProgressBar", style(Color(0.06, 0.055, 0.045), Color(0.30, 0.25, 0.16), 1, 2, 0))
	t.set_stylebox("fill", "ProgressBar", style(Color(0.62, 0.50, 0.24), Color(0.62, 0.50, 0.24), 0, 2, 0))
	for sc in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", sc, style(Color(0.07, 0.065, 0.055), Color(0.07, 0.065, 0.055), 0, 3, 0))
		t.set_stylebox("grabber", sc, style(Color(0.35, 0.29, 0.18), Color(0.35, 0.29, 0.18), 0, 3, 0))
		t.set_stylebox("grabber_highlight", sc, style(Color(0.55, 0.45, 0.25), Color(0.55, 0.45, 0.25), 0, 3, 0))
		t.set_stylebox("grabber_pressed", sc, style(Color(0.70, 0.57, 0.30), Color(0.70, 0.57, 0.30), 0, 3, 0))
	var sl := StyleBoxLine.new()
	sl.color = Color(0.42, 0.35, 0.22, 0.8)
	sl.thickness = 1
	t.set_stylebox("separator", "HSeparator", sl)
	t.set_constant("separation", "HSeparator", 8)
	_theme = t
	return t


# ---------------------------------------------------------------- widgets

static func lbl(t: String, fs := 13, col := INK, tip := "") -> Label:
	var l := Label.new()
	l.text = t
	if fs != 13:
		l.add_theme_font_size_override("font_size", fs)
	if col != INK:
		l.add_theme_color_override("font_color", col)
	if tip != "":
		l.tooltip_text = tip
		l.mouse_filter = Control.MOUSE_FILTER_STOP
	return l


static func btn(t: String, tip: String, cb: Callable, enabled := true) -> Button:
	var b := Button.new()
	b.text = t
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.disabled = not enabled
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


static func section(t: String) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.add_child(lbl(t, 14, GOLD))
	v.add_child(HSeparator.new())
	return v


static func flag(col: Color, size := Vector2(26, 18)) -> Control:
	var c := ColorRect.new()
	c.color = col
	c.custom_minimum_size = size
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return c


static func bar(frac: float, col := Color(0.62, 0.50, 0.24), w := 120.0, h := 10.0, tip := "") -> ProgressBar:
	var p := ProgressBar.new()
	p.min_value = 0.0
	p.max_value = 1.0
	p.value = clampf(frac, 0.0, 1.0)
	p.show_percentage = false
	p.custom_minimum_size = Vector2(w, h)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var key := col.to_rgba32()
	var fill: StyleBoxFlat = _bar_fill_cache.get(key, null)
	if fill == null:
		fill = StyleBoxFlat.new()
		fill.bg_color = col
		fill.set_corner_radius_all(2)
		_bar_fill_cache[key] = fill
	p.add_theme_stylebox_override("fill", fill)
	if tip != "":
		p.tooltip_text = tip
		p.mouse_filter = Control.MOUSE_FILTER_STOP
	return p


static func spark(values: PackedFloat32Array, col := GOLD, size := Vector2(70, 18)) -> Control:
	var s: Control = SparkScript.new()
	s.values = values
	s.color = col
	s.custom_minimum_size = size
	return s


static func grid(columns: int, hsep := 14, vsep := 3) -> GridContainer:
	var g := GridContainer.new()
	g.columns = columns
	g.add_theme_constant_override("h_separation", hsep)
	g.add_theme_constant_override("v_separation", vsep)
	return g


static func hbox(sep := 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


static func vbox(sep := 4) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


static func spacer() -> Control:
	var s := Control.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s


static func clear(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()


# --------------------------------------------------------------- formatting

static func num(v: float) -> String:
	var a := absf(v)
	if a >= 1.0e9:
		return "%.2fB" % (v / 1.0e9)
	if a >= 1.0e6:
		return "%.2fM" % (v / 1.0e6)
	if a >= 1.0e4:
		return "%.1fk" % (v / 1.0e3)
	return thousands(int(round(v)))


static func money(v: float) -> String:
	return ("-" if v < 0.0 else "") + "£" + num(absf(v))


static func signed_money(v: float) -> String:
	return ("+" if v >= 0.0 else "-") + "£" + num(absf(v))


static func pct(f: float, digits := 0) -> String:
	return ("%." + str(digits) + "f%%") % (f * 100.0)


static func thousands(n: int) -> String:
	var neg := n < 0
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if neg else "") + s + out


static func sign_color(v: float) -> Color:
	return GOOD if v > 0.005 else (BAD if v < -0.005 else DIM)


## Format a breakdown (Array of {reason, value} dictionaries or plain strings) as tooltip text.
static func breakdown_text(title: String, arr: Array, unit := "") -> String:
	var out := title
	if arr.is_empty():
		return out + "\n(no details)"
	for e in arr:
		if e is Dictionary:
			var v: float = float(e.get("value", 0.0))
			var txt := ""
			if absf(v - roundf(v)) < 0.001:
				txt = "%+d" % int(v)
			else:
				txt = "%+.1f" % v
			out += "\n%s  %s%s" % [txt, str(e.get("reason", "")), unit]
		else:
			out += "\n" + str(e)
	return out


static func result_text(res: Variant, ok_msg: String) -> String:
	if res is Dictionary:
		if res.get("ok", false):
			var r := str(res.get("reason", ""))
			return r if r != "" else ok_msg
		return str(res.get("reason", "Not possible"))
	return ok_msg if res else "Not possible"


static func result_ok(res: Variant) -> bool:
	if res is Dictionary:
		return bool(res.get("ok", false))
	return bool(res)
