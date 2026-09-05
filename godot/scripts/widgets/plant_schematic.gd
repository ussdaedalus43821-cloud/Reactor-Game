class_name PlantSchematic
extends Control

## Plant overview: primary loop, secondary loop, cooling water -- on the
## same screen as the control room above it, no view switching.
##
## Phase 1 (this file, for now): layout, component boxes and animated flow
## direction only. Only the primary loop's color reflects real plant state
## (out_temp_c/fuel_temp_c/scram, already in the bridge's state dictionary
## -- see control_room.gd's apply_state()); the secondary loop and cooling
## water are drawn with illustrative placeholder colors and a fixed "system
## running" flow. Live numeric labels at each point, and controls that feed
## real flow_frac/load_frac physics, are later phases -- this is a big
## feature built incrementally on request, one testable step at a time.

const LANE_LABELS := ["PRIMARY LOOP", "SECONDARY LOOP", "COOLING WATER"]

const BOX_SIZE := Vector2(150.0, 46.0)
const CHEVRON_SPEED_PX_S := 70.0
const CHEVRON_SPACING := 26.0
const RETURN_DROP := 34.0   # how far the return leg dips below the boxes

var out_temp_c := 270.0
var fuel_temp_c := 270.0
var pressure_mpa := 15.5
var scram := false
var flux_pct := 0.0

var _t := 0.0


func _ready() -> void:
	set_process(true)


## `state` is the bridge's reply dictionary, same as every other widget's
## apply_state() -- this works identically against Python and the in-engine
## GDScript core.
func apply_state(state: Dictionary) -> void:
	out_temp_c = float(state.get("out_temp_c", 270.0))
	fuel_temp_c = float(state.get("fuel_temp_c", 270.0))
	pressure_mpa = float(state.get("pressure_mpa", 15.5))
	scram = bool(state.get("scram", false))
	flux_pct = float(state.get("flux_pct", 0.0))


func _process(delta: float) -> void:
	# The animation clock runs regardless of whether a new physics state
	# has arrived this frame -- flow direction is always live, the way a
	# real mimic panel's flow arrows never stop just because the display
	# hasn't refreshed.
	_t += delta
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_string(font, Vector2(10.0, 17.0), "PLANT OVERVIEW",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, ReactorTheme.TEXT_DIM)

	var top := 24.0
	var lane_h := (size.y - top) / 3.0
	_draw_primary_loop(Rect2(Vector2(0.0, top), Vector2(size.x, lane_h)), font)
	_draw_secondary_loop(Rect2(Vector2(0.0, top + lane_h), Vector2(size.x, lane_h)), font)
	_draw_cooling_water(Rect2(Vector2(0.0, top + lane_h * 2.0), Vector2(size.x, lane_h)), font)


# ==========================================================================
# Primary loop -- Core -> Steam Generator -> Pumps -> back to Core.
# Flow color and speed both reflect real state: hotter outlet temp reads
# hotter along the pipe, and a SCRAM visibly slows the animated flow to a
# crawl (the primary pumps do keep running after a trip, just cooling a
# rapidly-quieting core -- this is a stand-in for that reading until pump
# speed is wired to real physics in a later phase).
# ==========================================================================

func _draw_primary_loop(rect: Rect2, font: Font) -> void:
	var boxes := _lane_boxes(rect)
	var core: Rect2 = boxes[0]
	var sg: Rect2 = boxes[1]
	var pumps: Rect2 = boxes[2]

	var flow_color := ReactorTheme.temp_color(out_temp_c)
	var speed := CHEVRON_SPEED_PX_S if not scram else CHEVRON_SPEED_PX_S * 0.15

	_draw_loop_pipes(rect, core, sg, pumps, flow_color, speed)

	ReactorTheme.draw_caption(self, font, rect.position + Vector2(0.0, -6.0), LANE_LABELS[0])
	_draw_component_box(core, "CORE", font, flow_color)
	_draw_component_box(sg, "STEAM\nGENERATOR", font)
	_draw_component_box(pumps, "PUMPS", font)


# ==========================================================================
# Secondary loop -- Steam Generator -> Turbine -> Condenser -> back to the
# Steam Generator. Steam (red-hot leg, generator to turbine) vs. water
# (blue return leg, condenser back to the generator) are drawn as distinct
# colors on the two halves of the loop, per the design brief -- both still
# a fixed illustrative temperature until the secondary side gets its own
# heat-transfer model in a later phase.
# ==========================================================================

const STEAM_COLOR := Color(0.9, 0.35, 0.3)
const FEEDWATER_COLOR := Color(0.35, 0.55, 0.95)

func _draw_secondary_loop(rect: Rect2, font: Font) -> void:
	var boxes := _lane_boxes(rect)
	var sg: Rect2 = boxes[0]
	var turbine: Rect2 = boxes[1]
	var condenser: Rect2 = boxes[2]

	# Steam leg: generator -> turbine. Water leg: condenser -> generator
	# (the return pipe below the boxes). Drawn as two separate calls
	# rather than one loop so each half gets its own color.
	_draw_flow_pipe(_right(sg), _left(turbine), STEAM_COLOR, CHEVRON_SPEED_PX_S)
	_draw_flow_pipe(_right(turbine), _left(condenser), STEAM_COLOR, CHEVRON_SPEED_PX_S)
	_draw_return_pipe(rect, condenser, sg, FEEDWATER_COLOR, CHEVRON_SPEED_PX_S)

	ReactorTheme.draw_caption(self, font, rect.position + Vector2(0.0, -6.0), LANE_LABELS[1])
	_draw_component_box(sg, "STEAM\nGENERATOR", font)
	_draw_component_box(turbine, "TURBINE", font, STEAM_COLOR)
	_draw_component_box(condenser, "CONDENSER", font)


# ==========================================================================
# Cooling water -- Intake -> Condenser -> Discharge. A fixed temperature
# rise across the condenser (illustrative -- real condenser-side heat
# transfer is a later phase), colored cool-to-warm along the pipe so the
# rise reads at a glance even before there's a numeric label on it.
# ==========================================================================

const INTAKE_TEMP_C := 18.0
const DISCHARGE_TEMP_C := 28.0

func _draw_cooling_water(rect: Rect2, font: Font) -> void:
	var boxes := _lane_boxes(rect)
	var intake: Rect2 = boxes[0]
	var condenser: Rect2 = boxes[1]
	var discharge: Rect2 = boxes[2]

	_draw_flow_pipe(_right(intake), _left(condenser),
			_water_temp_color(INTAKE_TEMP_C), CHEVRON_SPEED_PX_S)
	_draw_flow_pipe(_right(condenser), _left(discharge),
			_water_temp_color(DISCHARGE_TEMP_C), CHEVRON_SPEED_PX_S)

	ReactorTheme.draw_caption(self, font, rect.position + Vector2(0.0, -6.0), LANE_LABELS[2])
	_draw_component_box(intake, "INTAKE", font)
	_draw_component_box(condenser, "CONDENSER", font)
	_draw_component_box(discharge, "DISCHARGE", font)


## Cooling water never gets anywhere near reactor temperatures, so it uses
## its own small cool-blue -> warm-blue range rather than
## ReactorTheme.temp_color()'s reactor-scaled one, which would read as
## "ice cold" for this entire lane.
func _water_temp_color(t: float) -> Color:
	var f := clampf((t - INTAKE_TEMP_C) / maxf(DISCHARGE_TEMP_C - INTAKE_TEMP_C, 0.01), 0.0, 1.0)
	return Color(0.1, 0.35, 0.7).lerp(Color(0.25, 0.75, 0.85), f)


# ==========================================================================
# Shared drawing helpers
# ==========================================================================

## Three evenly-spaced component boxes across a lane's rect, vertically
## centered in it.
func _lane_boxes(rect: Rect2) -> Array:
	var cy := rect.position.y + rect.size.y * 0.5
	# Explicitly typed -- an untyped array literal makes `f` below a
	# Variant, and Variant arithmetic assigned with `:=` is the one
	# "cannot infer type" trap this project has to watch for everywhere.
	var fractions: Array[float] = [0.1, 0.45, 0.8]
	var result: Array = []
	for f in fractions:
		var cx := rect.position.x + rect.size.x * f
		result.append(Rect2(Vector2(cx, cy) - BOX_SIZE * 0.5, BOX_SIZE))
	return result


func _left(box: Rect2) -> Vector2:
	return box.position + Vector2(0.0, box.size.y * 0.5)


func _right(box: Rect2) -> Vector2:
	return box.position + Vector2(box.size.x, box.size.y * 0.5)


func _bottom(box: Rect2) -> Vector2:
	return box.position + Vector2(box.size.x * 0.5, box.size.y)


## A full loop -- box_a -> box_b -> box_c along the top, then a return leg
## back to box_a dipping below all three -- all in one color/speed. Used by
## the primary loop, which (for now) has one uniform flow temperature.
func _draw_loop_pipes(rect: Rect2, box_a: Rect2, box_b: Rect2, box_c: Rect2,
		color: Color, speed_px_s: float) -> void:
	_draw_flow_pipe(_right(box_a), _left(box_b), color, speed_px_s)
	_draw_flow_pipe(_right(box_b), _left(box_c), color, speed_px_s)
	_draw_return_pipe(rect, box_c, box_a, color, speed_px_s)


## The loop-closing leg: down from box_from's bottom, across below the
## lane's boxes, and up into box_to's bottom -- drawn as one continuous
## flow path so the chevrons travel the whole return route without a seam.
func _draw_return_pipe(rect: Rect2, box_from: Rect2, box_to: Rect2,
		color: Color, speed_px_s: float) -> void:
	var y := rect.position.y + rect.size.y - RETURN_DROP * 0.4
	var p0 := _bottom(box_from)
	var p1 := Vector2(p0.x, y)
	var p2 := Vector2(_bottom(box_to).x, y)
	var p3 := _bottom(box_to)
	_draw_flow_path([p0, p1, p2, p3], color, speed_px_s)


func _draw_component_box(rect: Rect2, label: String, font: Font,
		accent: Color = ReactorTheme.BEZEL) -> void:
	draw_rect(rect, ReactorTheme.PANEL, true)
	draw_rect(rect, accent, false, 2.0)
	var lines := label.split("\n")
	var line_h := 14.0
	var start_y := rect.get_center().y - (float(lines.size() - 1) * line_h) * 0.5 + 4.0
	for i in range(lines.size()):
		var w := font.get_string_size(lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		draw_string(font, Vector2(rect.get_center().x - w * 0.5, start_y + i * line_h),
				lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, ReactorTheme.TEXT)


## A straight pipe segment with small chevrons sliding from p0 toward p1 to
## show flow direction. Re-run every frame with the same p0/p1 and _t
## advancing -- there is no state to track between calls, the animation
## phase comes entirely from the clock.
func _draw_flow_pipe(p0: Vector2, p1: Vector2, color: Color, speed_px_s: float,
		width: float = 6.0, spacing: float = CHEVRON_SPACING) -> void:
	_draw_flow_path([p0, p1], color, speed_px_s, width, spacing)


## Same as _draw_flow_pipe(), but along a multi-segment polyline (used for
## the return leg) so chevrons travel smoothly around the corner instead of
## resetting phase at each segment.
func _draw_flow_path(points: Array, color: Color, speed_px_s: float,
		width: float = 6.0, spacing: float = CHEVRON_SPACING) -> void:
	if points.size() < 2:
		return
	for i in range(points.size() - 1):
		draw_line(points[i], points[i + 1], color, width)

	var total_length := 0.0
	for i in range(points.size() - 1):
		total_length += (points[i + 1] - points[i]).length()
	if total_length < 1.0:
		return

	var phase := fmod(_t * speed_px_s, spacing)
	var d := phase
	while d < total_length:
		var pos := _point_along_path(points, d)
		if pos.size() == 2:
			var c: Vector2 = pos[0]
			var dir: Vector2 = pos[1]
			var perp := Vector2(-dir.y, dir.x)
			var tip := c + dir * 7.0
			var left := c - dir * 5.0 + perp * 5.0
			var right := c - dir * 5.0 - perp * 5.0
			draw_colored_polygon(PackedVector2Array([tip, left, right]), ReactorTheme.WHITE)
		d += spacing


## Walks a polyline `distance` units from its start, returning [position,
## unit_direction] for whichever segment that distance falls on.
func _point_along_path(points: Array, distance: float) -> Array:
	var remaining := distance
	for i in range(points.size() - 1):
		var seg_delta: Vector2 = points[i + 1] - points[i]
		var seg_len := seg_delta.length()
		if seg_len < 0.001:
			continue
		if remaining <= seg_len:
			var dir := seg_delta / seg_len
			return [points[i] + dir * remaining, dir]
		remaining -= seg_len
	return []
