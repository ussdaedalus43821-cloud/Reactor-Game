class_name ScrollingGraph
extends Control

## Strip-chart recorder for neutron flux and fuel temperature.
##
## Holds 60 s of 20 Hz samples in two ring buffers (1200 points each) and
## redraws them as polylines against independent left/right scales, so a
## 300 % flux spike and a 2800 C fuel temperature can share one chart
## without either being squashed flat. The vertical scales expand to fit
## the data and then relax back down slowly, the way a real recorder's
## range switch would be nudged up during a transient.

const CAPACITY := 1200          # 60 s at 20 Hz, matching the physics rate
const FLUX_BASE_MAX := 150.0
const TEMP_BASE_MAX := 1000.0
const SCALE_RELAX_PER_S := 0.06

var _flux := PackedFloat32Array()
var _temp := PackedFloat32Array()
var _head := 0
var _count := 0

var _flux_scale := FLUX_BASE_MAX
var _temp_scale := TEMP_BASE_MAX
var _stale := false


func _ready() -> void:
	_flux.resize(CAPACITY)
	_temp.resize(CAPACITY)
	set_process(true)


func clear_history() -> void:
	_head = 0
	_count = 0
	_flux_scale = FLUX_BASE_MAX
	_temp_scale = TEMP_BASE_MAX
	queue_redraw()


## Append one physics sample. The control room feeds every substep the
## bridge returns, so the trace is continuous even at 60 fps over a 20 Hz
## simulation.
func push_sample(flux_pct: float, fuel_temp_c: float) -> void:
	_flux[_head] = flux_pct
	_temp[_head] = fuel_temp_c
	_head = (_head + 1) % CAPACITY
	_count = mini(_count + 1, CAPACITY)

	_flux_scale = maxf(_flux_scale, flux_pct * 1.12)
	_temp_scale = maxf(_temp_scale, fuel_temp_c * 1.12)


func set_stale(stale: bool) -> void:
	_stale = stale


func _process(delta: float) -> void:
	# Let the ranges creep back toward their defaults once the excursion is
	# over, but never below them.
	var relax := 1.0 - SCALE_RELAX_PER_S * delta
	_flux_scale = maxf(FLUX_BASE_MAX, _flux_scale * relax)
	_temp_scale = maxf(TEMP_BASE_MAX, _temp_scale * relax)
	queue_redraw()


func _sample_at(buffer: PackedFloat32Array, i: int) -> float:
	# i == 0 is the oldest retained sample.
	var start := (_head - _count + CAPACITY) % CAPACITY
	return buffer[(start + i) % CAPACITY]


func _build_line(buffer: PackedFloat32Array, value_scale: float,
		plot: Rect2) -> PackedVector2Array:
	var points := PackedVector2Array()
	if _count < 2:
		return points
	# One vertex per horizontal pixel at most: 1200 samples across ~700 px
	# is more detail than the display can show, and the stride keeps the
	# draw call cheap on mobile.
	var stride := maxi(1, int(ceil(float(_count) / maxf(plot.size.x, 1.0))))
	points.resize(0)
	var i := 0
	while i < _count:
		var v := _sample_at(buffer, i)
		var x := plot.position.x + plot.size.x * (float(i) / float(_count - 1))
		var y := plot.end.y - plot.size.y * clampf(v / value_scale, 0.0, 1.0)
		points.append(Vector2(x, y))
		i += stride
	# Always pin the newest sample to the right edge.
	var last := _sample_at(buffer, _count - 1)
	points.append(Vector2(plot.end.x,
			plot.end.y - plot.size.y * clampf(last / value_scale, 0.0, 1.0)))
	return points


func _draw() -> void:
	var font := get_theme_default_font()
	var plot := Rect2(Vector2(44.0, 22.0),
			Vector2(maxf(20.0, size.x - 44.0 - 52.0), maxf(20.0, size.y - 22.0 - 20.0)))

	ReactorTheme.draw_bay(self, Rect2(Vector2.ZERO, size))
	draw_rect(plot, ReactorTheme.BG, true)

	var dim := 0.45 if _stale else 1.0

	# Horizontal graticule with both scales labelled.
	for i in range(5):
		var f := i / 4.0
		var y := plot.end.y - plot.size.y * f
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y),
				ReactorTheme.GRID_LINE, 1.0)
		draw_string(font, Vector2(4.0, y + 4.0), "%d" % roundi(_flux_scale * f),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
				Color(ReactorTheme.CYAN, 0.62 * dim))
		draw_string(font, Vector2(plot.end.x + 6.0, y + 4.0),
				"%d" % roundi(_temp_scale * f), HORIZONTAL_ALIGNMENT_LEFT, -1,
				10, Color(ReactorTheme.AMBER, 0.62 * dim))

	# Vertical graticule: one line every 10 s of the 60 s window.
	for i in range(1, 6):
		var x := plot.position.x + plot.size.x * (i / 6.0)
		draw_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y),
				ReactorTheme.GRID_LINE, 1.0)

	# 100 % reference line -- rated power.
	var ref_y := plot.end.y - plot.size.y * clampf(100.0 / _flux_scale, 0.0, 1.0)
	draw_dashed_line(Vector2(plot.position.x, ref_y), Vector2(plot.end.x, ref_y),
			Color(ReactorTheme.GREEN, 0.35 * dim), 1.0, 6.0)

	var temp_pts := _build_line(_temp, _temp_scale, plot)
	if temp_pts.size() >= 2:
		draw_polyline(temp_pts, Color(ReactorTheme.AMBER, dim), 1.8, true)
	var flux_pts := _build_line(_flux, _flux_scale, plot)
	if flux_pts.size() >= 2:
		draw_polyline(flux_pts, Color(ReactorTheme.CYAN, dim), 1.8, true)

	# Legend and window length.
	draw_string(font, Vector2(48.0, 15.0), "NEUTRON FLUX  %",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(ReactorTheme.CYAN, dim))
	draw_string(font, Vector2(180.0, 15.0), "FUEL TEMP  C",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(ReactorTheme.AMBER, dim))
	draw_string(font, Vector2(plot.end.x - 46.0, size.y - 6.0), "-60 s .. NOW",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, ReactorTheme.TEXT_FAINT)
