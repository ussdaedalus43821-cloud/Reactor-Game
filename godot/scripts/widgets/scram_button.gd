class_name ScramButton
extends Control

## The big red button.
##
## Always pulsing, because a scram control that looks inert is a scram
## control nobody reaches for. The pulse rate rises with the alarm tier
## coming out of reactor_rules.nova, so the button itself tells you how
## much trouble the core is in before you have read a single gauge.

signal pressed

## Pulse rate per alarm tier: calm advisory through emergency.
const PULSE_RATES := [1.5, 2.4, 3.6, 6.4]

@export var enabled: bool = true: set = set_enabled

var alarm_level: int = 0: set = set_alarm_level
var latched: bool = false: set = set_latched

var _phase := 0.0
var _press_anim := 0.0
var _hovered := false


func _ready() -> void:
	set_process(true)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)


func _on_mouse_entered() -> void:
	_hovered = true
	queue_redraw()


func _on_mouse_exited() -> void:
	_hovered = false
	queue_redraw()


func set_enabled(v: bool) -> void:
	enabled = v
	queue_redraw()


func set_alarm_level(v: int) -> void:
	alarm_level = clampi(v, 0, 3)


func set_latched(v: bool) -> void:
	latched = v
	queue_redraw()


func _radius() -> float:
	return minf(size.x, size.y) * 0.5 - 6.0


func _process(delta: float) -> void:
	var rate: float = PULSE_RATES[alarm_level]
	_phase = fmod(_phase + delta * rate, TAU)
	_press_anim = maxf(0.0, _press_anim - delta * 5.0)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var hit := false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		hit = mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT \
			and mb.position.distance_to(size * 0.5) <= _radius() + 8.0
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		hit = st.pressed and st.position.distance_to(size * 0.5) <= _radius() + 8.0
	if hit:
		accept_event()
		trigger()


## Also called by the SPACE shortcut, so the keyboard and the button share
## one code path and one animation.
func trigger() -> void:
	if not enabled:
		return
	_press_anim = 1.0
	pressed.emit()


func _draw() -> void:
	var font := get_theme_default_font()
	var centre := size * 0.5
	var radius := _radius()
	if radius <= 6.0:
		return

	var pulse := 0.5 + 0.5 * sin(_phase)
	var live := enabled and not latched

	var body := ReactorTheme.RED if live else ReactorTheme.RED.darkened(0.55)
	if _hovered and live:
		body = body.lightened(0.10)
	body = body.lightened(0.16 * pulse if live else 0.0)
	body = body.darkened(0.22 * _press_anim)

	# Guard ring and glow.
	var glow_alpha := (0.10 + 0.22 * pulse) if live else 0.05
	draw_circle(centre, radius + 16.0, Color(ReactorTheme.RED, glow_alpha * 0.5))
	draw_circle(centre, radius + 9.0, Color(ReactorTheme.RED, glow_alpha))
	draw_circle(centre, radius + 5.0, ReactorTheme.PANEL)
	draw_arc(centre, radius + 5.0, 0.0, TAU, 48,
			ReactorTheme.BEZEL_LIT if live else ReactorTheme.BEZEL, 2.0)

	# Mushroom head: bright rim, darker centre, highlight up and left.
	var press_offset := Vector2(0.0, 2.0 * _press_anim)
	draw_circle(centre + press_offset, radius, body.darkened(0.30))
	draw_circle(centre + press_offset, radius - 4.0, body)
	draw_circle(centre + press_offset - Vector2(radius * 0.28, radius * 0.30),
			radius * 0.42, Color(ReactorTheme.WHITE, 0.10 if live else 0.04))

	var label := "SCRAM"
	var label_col := ReactorTheme.WHITE if live else Color(ReactorTheme.WHITE, 0.45)
	var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
	draw_string(font, centre + press_offset + Vector2(-w * 0.5, 8.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 22, label_col)

	var sub := "TRIPPED" if latched else "SPACE"
	var sw := font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	draw_string(font, centre + Vector2(-sw * 0.5, radius + 26.0), sub,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
			ReactorTheme.YELLOW if latched else ReactorTheme.TEXT_FAINT)
