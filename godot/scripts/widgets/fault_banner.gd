class_name FaultBanner
extends Control

## Pulsing alert banner across the top of the panel.
##
## Shows whichever fault reactor_rules.nova currently has active, together
## with a bar counting down the seconds until it clears. When no fault is
## running but the alarm tier is non-zero, it shows the alarm text instead
## -- so the banner is always answering the question "what is wrong right
## now", never sitting empty while a gauge is in the red.

@export var pulse_rate: float = 3.0

var title := ""
var subtitle := ""
var color := ReactorTheme.AMBER
var progress := -1.0        # 0..1 for a countdown bar, negative to hide it
var active := false

var _phase := 0.0
var _fade := 0.0            # eased visibility, 0 hidden .. 1 shown


func _ready() -> void:
	set_process(true)


## `remaining` and `duration` drive the countdown bar; pass 0 for both when
## the alert has no natural end.
func show_alert(new_title: String, new_subtitle: String, new_color: Color,
		remaining: float = 0.0, duration: float = 0.0) -> void:
	title = new_title
	subtitle = new_subtitle
	color = new_color
	progress = clampf(remaining / duration, 0.0, 1.0) if duration > 0.0 else -1.0
	active = true


func hide_alert() -> void:
	active = false


func _process(delta: float) -> void:
	_phase = fmod(_phase + delta * pulse_rate, TAU)
	var target := 1.0 if active else 0.0
	_fade = move_toward(_fade, target, delta * 5.0)
	visible = _fade > 0.005
	if visible:
		queue_redraw()


func _draw() -> void:
	if _fade <= 0.005:
		return
	var font := get_theme_default_font()
	var rect := Rect2(Vector2.ZERO, size)
	var pulse := 0.5 + 0.5 * sin(_phase)

	# Body: a dark wash that breathes, with a bright bar down each edge.
	draw_rect(rect, Color(color, (0.10 + 0.16 * pulse) * _fade), true)
	draw_rect(rect, Color(color, (0.45 + 0.45 * pulse) * _fade), false, 2.0)
	var edge := Vector2(5.0, rect.size.y)
	draw_rect(Rect2(rect.position, edge), Color(color, (0.55 + 0.45 * pulse) * _fade), true)
	draw_rect(Rect2(Vector2(rect.end.x - 5.0, rect.position.y), edge),
			Color(color, (0.55 + 0.45 * pulse) * _fade), true)

	# Hazard chevrons behind the text, scrolling slowly.
	var stripe_col := Color(color, 0.06 * _fade)
	var offset := fmod(_phase * 6.0, 28.0)
	var x := rect.position.x - 28.0 + offset
	while x < rect.end.x:
		draw_colored_polygon(PackedVector2Array([
			Vector2(x, rect.end.y), Vector2(x + 14.0, rect.position.y),
			Vector2(x + 22.0, rect.position.y), Vector2(x + 8.0, rect.end.y),
		]), stripe_col)
		x += 28.0

	var text_col := Color(color.lightened(0.35), (0.75 + 0.25 * pulse) * _fade)
	draw_string(font, Vector2(20.0, rect.size.y * 0.5 + 2.0), title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 19, text_col)

	if subtitle != "":
		var tw := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 19).x
		draw_string(font, Vector2(34.0 + tw, rect.size.y * 0.5 + 2.0), subtitle,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
				Color(ReactorTheme.TEXT_DIM, _fade))

	# Countdown bar along the bottom edge: how long until the fault clears.
	if progress >= 0.0:
		var bar := Rect2(Vector2(6.0, rect.size.y - 5.0),
				Vector2((rect.size.x - 12.0) * progress, 3.0))
		draw_rect(bar, Color(color, 0.8 * _fade), true)
