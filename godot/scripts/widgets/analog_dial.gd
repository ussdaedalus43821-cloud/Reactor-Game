class_name AnalogDial
extends Control

## A 270-degree analog gauge: sweep from 225 deg (min) clockwise to -45 deg
## (max), coloured band arcs, minor and major ticks, a needle that settles
## with a little inertia, and a digital repeater under the pivot.
##
## The needle is deliberately not snapped to the value. A real panel meter
## has mass; letting it lag and overshoot slightly is what makes a flux
## excursion *look* like one.

@export var label_text: String = "FLUX": set = _set_label
@export var unit_text: String = "%": set = _set_unit
@export var min_value: float = 0.0: set = _set_min
@export var max_value: float = 200.0: set = _set_max
@export var value: float = 0.0: set = set_value
@export var decimals: int = 1
@export var major_ticks: int = 5
@export var minor_per_major: int = 4
@export var dial_color: Color = Color("46d3dc"): set = _set_dial_color

## Coloured bands around the rim: [from_value, to_value, Color].
var zones: Array = []

var _needle := 0.0          # smoothed display value
var _needle_vel := 0.0
var _stale := false         # dim everything when the bridge stops answering

const START_DEG := 225.0
const SWEEP_DEG := 270.0
const NEEDLE_STIFFNESS := 62.0
const NEEDLE_DAMPING := 11.0


func _ready() -> void:
	_needle = value
	set_process(true)


func _set_label(v: String) -> void:
	label_text = v
	queue_redraw()

func _set_unit(v: String) -> void:
	unit_text = v
	queue_redraw()

func _set_min(v: float) -> void:
	min_value = v
	queue_redraw()

func _set_max(v: float) -> void:
	max_value = v
	queue_redraw()

func _set_dial_color(v: Color) -> void:
	dial_color = v
	queue_redraw()


func set_value(v: float) -> void:
	value = v
	if not is_inside_tree():
		_needle = v
	queue_redraw()


func set_stale(stale: bool) -> void:
	if _stale != stale:
		_stale = stale
		queue_redraw()


func set_zones(new_zones: Array) -> void:
	zones = new_zones
	queue_redraw()


func _process(delta: float) -> void:
	# Critically-ish damped spring toward the true reading.
	var error := value - _needle
	_needle_vel += (error * NEEDLE_STIFFNESS - _needle_vel * NEEDLE_DAMPING) * delta
	_needle += _needle_vel * delta
	if absf(error) < 0.0005 and absf(_needle_vel) < 0.0005:
		_needle = value
		_needle_vel = 0.0
	queue_redraw()


func _fraction(v: float) -> float:
	if is_equal_approx(max_value, min_value):
		return 0.0
	return clampf((v - min_value) / (max_value - min_value), 0.0, 1.0)


func _angle_for(v: float) -> float:
	return deg_to_rad(START_DEG - _fraction(v) * SWEEP_DEG)


func _polar(centre: Vector2, radius: float, angle_rad: float) -> Vector2:
	return centre + Vector2(cos(angle_rad), -sin(angle_rad)) * radius


func _draw() -> void:
	var font := get_theme_default_font()
	var centre := size * 0.5
	var radius := minf(size.x, size.y) * 0.5 - 8.0
	if radius <= 4.0:
		return

	var dim := 0.45 if _stale else 1.0

	# Case and glass.
	draw_circle(centre, radius + 7.0, ReactorTheme.PANEL)
	draw_arc(centre, radius + 7.0, 0.0, TAU, 64, ReactorTheme.BEZEL, 2.0)
	draw_circle(centre, radius, ReactorTheme.PANEL_DEEP)

	# Coloured band arcs just inside the rim.
	for zone in zones:
		var from_a := _angle_for(float(zone[0]))
		var to_a := _angle_for(float(zone[1]))
		var col: Color = zone[2]
		col.a *= dim
		draw_arc(centre, radius - 5.0, -from_a, -to_a, 48, col, 5.0)

	# Ticks and their numbers.
	var total_minor := major_ticks * minor_per_major
	for i in range(total_minor + 1):
		var f := float(i) / float(total_minor)
		var v := min_value + (max_value - min_value) * f
		var a := _angle_for(v)
		var is_major := i % minor_per_major == 0
		var inner := radius - (13.0 if is_major else 7.0)
		var col := ReactorTheme.TEXT_DIM if is_major else ReactorTheme.TEXT_FAINT
		col.a *= dim
		draw_line(_polar(centre, inner, a), _polar(centre, radius - 2.0, a),
				col, 2.0 if is_major else 1.0)
		if is_major:
			var text := "%d" % roundi(v)
			var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT,
					-1, 10).x
			var at := _polar(centre, radius - 25.0, a) - Vector2(width * 0.5, -4.0)
			draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
					Color(ReactorTheme.TEXT_FAINT, dim))

	# Needle: a tapered triangle plus a short counterweight.
	var needle_angle := _angle_for(_needle)
	var tip := _polar(centre, radius - 12.0, needle_angle)
	var left := _polar(centre, 5.0, needle_angle + PI * 0.5)
	var right := _polar(centre, 5.0, needle_angle - PI * 0.5)
	var tail := _polar(centre, 14.0, needle_angle + PI)
	var needle_col := Color(dial_color, dim)
	draw_colored_polygon(PackedVector2Array([tip, left, tail, right]), needle_col)
	draw_circle(centre, 6.0, ReactorTheme.BEZEL_LIT)
	draw_circle(centre, 3.0, needle_col)

	# Caption and digital repeater.
	var cap_w := font.get_string_size(label_text, HORIZONTAL_ALIGNMENT_LEFT,
			-1, 12).x
	draw_string(font, centre + Vector2(-cap_w * 0.5, -radius * 0.42),
			label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			Color(ReactorTheme.TEXT_DIM, dim))

	var read := "%s %s" % [String.num(value, decimals), unit_text]
	var read_w := font.get_string_size(read, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
	var read_pos := centre + Vector2(-read_w * 0.5 - 6.0, radius * 0.46 - 13.0)
	draw_rect(Rect2(read_pos, Vector2(read_w + 12.0, 19.0)),
			ReactorTheme.BG, true)
	draw_rect(Rect2(read_pos, Vector2(read_w + 12.0, 19.0)),
			ReactorTheme.BEZEL, false, 1.0)
	draw_string(font, read_pos + Vector2(6.0, 14.0), read,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(dial_color, dim))
