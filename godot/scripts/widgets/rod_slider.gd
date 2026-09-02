class_name RodSlider
extends Control

## A vertical control-rod bank slider.
##
## Up is withdrawn (100 %), down is fully inserted (0 %) -- the same sense
## as the drive gear in a real plant. Dragging sets the bank's *target*;
## the rods themselves move at a finite rate, so the widget draws the
## commanded position as a bright handle and the actual position as a
## separate filled column behind it. Watching those two disagree during a
## transient is most of the game.

signal target_changed(value: float)

@export var bank_name: String = "A"
@export var accent: Color = Color("4b96eb")

var target: float = 0.0: set = set_target
var actual: float = 0.0: set = set_actual
var stuck: bool = false: set = set_stuck
var enabled: bool = true: set = set_enabled

var _dragging := false
var _pulse := 0.0

const TRACK_WIDTH := 34.0
const HANDLE_HEIGHT := 12.0


func _ready() -> void:
	set_process(true)
	mouse_filter = Control.MOUSE_FILTER_STOP


func set_target(v: float) -> void:
	target = clampf(v, 0.0, 100.0)
	queue_redraw()

func set_actual(v: float) -> void:
	actual = clampf(v, 0.0, 100.0)
	queue_redraw()

func set_stuck(v: bool) -> void:
	stuck = v
	queue_redraw()

func set_enabled(v: bool) -> void:
	enabled = v
	if not enabled:
		_dragging = false
	queue_redraw()


func _process(delta: float) -> void:
	if stuck:
		_pulse = fmod(_pulse + delta * 3.4, TAU)
		queue_redraw()


func _track_rect() -> Rect2:
	var top := 34.0
	var bottom := 26.0
	return Rect2(Vector2((size.x - TRACK_WIDTH) * 0.5, top),
			Vector2(TRACK_WIDTH, maxf(10.0, size.y - top - bottom)))


func _value_from_position(local_y: float) -> float:
	var track := _track_rect()
	var f := 1.0 - clampf((local_y - track.position.y) / track.size.y, 0.0, 1.0)
	return f * 100.0


func _gui_input(event: InputEvent) -> void:
	if not enabled:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_commit(_value_from_position(mb.position.y))
			else:
				_dragging = false
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_commit(_value_from_position((event as InputEventMouseMotion).position.y))
		accept_event()
	elif event is InputEventScreenDrag:
		_commit(_value_from_position((event as InputEventScreenDrag).position.y))
		accept_event()
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		_dragging = st.pressed
		if st.pressed:
			_commit(_value_from_position(st.position.y))
		accept_event()


func _commit(v: float) -> void:
	var clamped := clampf(v, 0.0, 100.0)
	if not is_equal_approx(clamped, target):
		target = clamped
		target_changed.emit(target)
		queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	var track := _track_rect()

	# Caption.
	var caption := "BANK %s" % bank_name
	draw_string(font, Vector2(4.0, 15.0), caption, HORIZONTAL_ALIGNMENT_LEFT,
			-1, 13, ReactorTheme.TEXT_DIM)

	# Track well with graduations every 10 %.
	ReactorTheme.draw_bay(self, track)
	for i in range(11):
		var y := track.position.y + track.size.y * (1.0 - i / 10.0)
		var major := i % 5 == 0
		draw_line(Vector2(track.position.x - (7.0 if major else 4.0), y),
				Vector2(track.position.x, y),
				ReactorTheme.TEXT_DIM if major else ReactorTheme.TEXT_FAINT, 1.0)
		if major:
			draw_string(font, Vector2(track.end.x + 5.0, y + 4.0),
					"%d" % (i * 10), HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
					ReactorTheme.TEXT_FAINT)

	# Actual rod position: the filled column, withdrawn from the bottom up.
	var actual_h := track.size.y * (actual / 100.0)
	var fill := Rect2(track.position + Vector2(3.0, track.size.y - actual_h),
			Vector2(track.size.x - 6.0, actual_h))
	var fill_col := accent
	fill_col.a = 0.30 if enabled else 0.14
	draw_rect(fill, fill_col, true)

	# Commanded target: the handle.
	var target_y := track.position.y + track.size.y * (1.0 - target / 100.0)
	var handle := Rect2(Vector2(track.position.x - 6.0,
			target_y - HANDLE_HEIGHT * 0.5),
			Vector2(track.size.x + 12.0, HANDLE_HEIGHT))
	var handle_col := accent if enabled else ReactorTheme.TEXT_FAINT
	if stuck:
		handle_col = ReactorTheme.MAGENTA
	draw_rect(handle, handle_col.darkened(0.45), true)
	draw_rect(handle, handle_col, false, 2.0)
	draw_line(Vector2(handle.position.x + 3.0, target_y),
			Vector2(handle.end.x - 3.0, target_y), handle_col.lightened(0.35), 1.0)

	# Readout.
	var read := "%5.1f%%" % target
	draw_string(font, Vector2(2.0, size.y - 8.0), read,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
			handle_col if enabled else ReactorTheme.TEXT_FAINT)

	if stuck:
		var alpha := 0.45 + 0.55 * (0.5 + 0.5 * sin(_pulse))
		var badge := Rect2(Vector2(0.0, track.position.y - 20.0),
				Vector2(size.x, 17.0))
		draw_rect(badge, Color(ReactorTheme.MAGENTA, 0.20 * alpha), true)
		draw_string(font, badge.position + Vector2(4.0, 13.0), "SEIZED",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
				Color(ReactorTheme.MAGENTA, alpha))
