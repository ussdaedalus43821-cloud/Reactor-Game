class_name GameOverlay
extends Control

## End-of-run curtain: meltdown or a survived shift.
##
## Fades in over the panel rather than replacing it, so the final state of
## every gauge stays readable underneath -- the post-mortem is the point.

var headline := ""
var detail := ""
var hint := "PRESS  R  TO START A NEW SHIFT"
var tint := ReactorTheme.RED
var showing := false

var _fade := 0.0
var _phase := 0.0


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


func show_result(new_headline: String, new_detail: String, new_tint: Color) -> void:
	headline = new_headline
	detail = new_detail
	tint = new_tint
	showing = true
	visible = true


func hide_result() -> void:
	showing = false


func _process(delta: float) -> void:
	_phase = fmod(_phase + delta * 1.8, TAU)
	_fade = move_toward(_fade, 1.0 if showing else 0.0, delta * 1.4)
	visible = _fade > 0.004
	if visible:
		queue_redraw()


func _draw() -> void:
	if _fade <= 0.004:
		return
	var font := get_theme_default_font()
	var rect := Rect2(Vector2.ZERO, size)

	draw_rect(rect, Color(0.0, 0.0, 0.0, 0.62 * _fade), true)
	draw_rect(rect, Color(tint, 0.06 * _fade), true)

	var band := Rect2(Vector2(0.0, size.y * 0.5 - 96.0), Vector2(size.x, 192.0))
	draw_rect(band, Color(ReactorTheme.BG, 0.86 * _fade), true)
	draw_line(band.position, Vector2(band.end.x, band.position.y),
			Color(tint, 0.85 * _fade), 2.0)
	draw_line(Vector2(band.position.x, band.end.y), band.end,
			Color(tint, 0.85 * _fade), 2.0)

	var pulse := 0.72 + 0.28 * (0.5 + 0.5 * sin(_phase))
	var hw := font.get_string_size(headline, HORIZONTAL_ALIGNMENT_LEFT, -1, 52).x
	draw_string(font, Vector2((size.x - hw) * 0.5, size.y * 0.5 - 16.0),
			headline, HORIZONTAL_ALIGNMENT_LEFT, -1, 52,
			Color(tint, pulse * _fade))

	var dw := font.get_string_size(detail, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x
	draw_string(font, Vector2((size.x - dw) * 0.5, size.y * 0.5 + 22.0),
			detail, HORIZONTAL_ALIGNMENT_LEFT, -1, 17,
			Color(ReactorTheme.TEXT, 0.85 * _fade))

	var kw := font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	draw_string(font, Vector2((size.x - kw) * 0.5, size.y * 0.5 + 66.0),
			hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
			Color(ReactorTheme.TEXT_DIM, 0.8 * _fade))
