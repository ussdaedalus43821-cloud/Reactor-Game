class_name HeaderBar
extends Control

## The status strip across the top: operating state, shift clock, live
## reactivity, electrical output and cash earned, and which backend is
## actually running the reactor.
##
## The backend readout is not a debugging leftover. Whether the core is
## being integrated by NumPy in a Python process or by GDScript in-engine
## changes nothing about the physics, but the operator should be able to
## see at a glance which one answered -- especially after a failover.

var state_name := "STARTUP"
var plant_time := 0.0
var goal_time := 900.0
var reactivity_pcm := 0.0
var power_pct := 0.0
var revenue_usd := 0.0
var backend_label := "starting"
var backend_ok := true
var alarm_level := 0

var _phase := 0.0


func _ready() -> void:
	set_process(true)


func _process(delta: float) -> void:
	_phase = fmod(_phase + delta * 2.6, TAU)
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	var rect := Rect2(Vector2.ZERO, size)

	draw_rect(rect, ReactorTheme.PANEL_DEEP, true)
	draw_line(Vector2(0.0, size.y - 1.0), Vector2(size.x, size.y - 1.0),
			ReactorTheme.BEZEL, 1.0)

	# Operating state, with a lamp that pulses once the plant is unhappy.
	var col := ReactorTheme.state_color(state_name)
	var lamp_alpha := 1.0
	if alarm_level >= 2:
		lamp_alpha = 0.45 + 0.55 * (0.5 + 0.5 * sin(_phase))
	draw_circle(Vector2(20.0, size.y * 0.5), 7.0, Color(col, lamp_alpha))
	draw_arc(Vector2(20.0, size.y * 0.5), 10.0, 0.0, TAU, 24,
			Color(col, 0.35 * lamp_alpha), 1.5)
	draw_string(font, Vector2(38.0, size.y * 0.5 + 8.0), state_name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 22, col)

	# Shift clock and the 15-minute goal. Truncating to whole minutes is
	# the point of a T+MM:SS stamp, not an accident.
	@warning_ignore("integer_division")
	var mins := int(plant_time) / 60
	var secs := int(plant_time) % 60
	@warning_ignore("integer_division")
	var goal_m := int(goal_time) / 60
	draw_string(font, Vector2(300.0, size.y * 0.5 + 6.0),
			"T+%02d:%02d" % [mins, secs], HORIZONTAL_ALIGNMENT_LEFT, -1, 18,
			ReactorTheme.TEXT)
	draw_string(font, Vector2(392.0, size.y * 0.5 + 6.0),
			"/ %02d:00 SHIFT" % goal_m, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			ReactorTheme.TEXT_FAINT)

	# Progress through the shift.
	var bar := Rect2(Vector2(300.0, size.y - 9.0), Vector2(190.0, 3.0))
	draw_rect(bar, ReactorTheme.GRID_LINE, true)
	draw_rect(Rect2(bar.position, Vector2(bar.size.x
			* clampf(plant_time / maxf(goal_time, 1.0), 0.0, 1.0), bar.size.y)),
			ReactorTheme.state_color(state_name), true)

	# Live reactivity: the single most diagnostic number on the panel.
	var rho_col := ReactorTheme.TEXT_DIM
	if reactivity_pcm > 120.0:
		rho_col = ReactorTheme.RED
	elif reactivity_pcm > 20.0:
		rho_col = ReactorTheme.AMBER
	elif reactivity_pcm < -20.0:
		rho_col = ReactorTheme.BLUE
	draw_string(font, Vector2(540.0, size.y * 0.5 + 6.0),
			"REACTIVITY %+8.1f pcm" % reactivity_pcm,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, rho_col)

	# Electrical output sold to the grid -- capped at rated capacity and
	# degraded by turbine load/coolant flow, unlike the flux dial, which
	# is the core's own uncapped thermal reading. See NovaBridge.power_pct.
	draw_string(font, Vector2(790.0, size.y * 0.5 + 6.0),
			"OUTPUT %6.1f %%" % power_pct, HORIZONTAL_ALIGNMENT_LEFT, -1, 15,
			ReactorTheme.CYAN)

	# Cash earned so far this shift, at PRICE_PER_MWH for every MWh of
	# that same electrical output -- a SCRAM or a choked valve doesn't
	# just cost safety margin, it costs money too.
	draw_string(font, Vector2(960.0, size.y * 0.5 + 6.0),
			"SHIFT $%s" % _format_money(revenue_usd), HORIZONTAL_ALIGNMENT_LEFT,
			-1, 15, ReactorTheme.GREEN)

	# Backend badge, right-aligned.
	var badge := "SIM: " + backend_label
	var w := font.get_string_size(badge, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	var badge_col := ReactorTheme.GREEN if backend_ok else ReactorTheme.AMBER
	var badge_rect := Rect2(Vector2(size.x - w - 26.0, size.y * 0.5 - 11.0),
			Vector2(w + 16.0, 22.0))
	draw_rect(badge_rect, ReactorTheme.BG, true)
	draw_rect(badge_rect, Color(badge_col, 0.45), false, 1.0)
	draw_string(font, badge_rect.position + Vector2(8.0, 15.0), badge,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, badge_col)


## Whole dollars with a comma every three digits -- "%d" alone reads as a
## wall of digits once a shift has been running a few minutes.
static func _format_money(v: float) -> String:
	var n := int(round(abs(v)))
	var digits := str(n)
	var grouped := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		grouped = digits[i] + grouped
		count += 1
		if count % 3 == 0 and i != 0:
			grouped = "," + grouped
	return ("-" if v < 0.0 else "") + grouped
