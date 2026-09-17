class_name ThrottleSlider
extends Control

## A vertical 0-100 % manual override for a continuous plant parameter
## (coolant flow, turbine load) that the fault injector also drives.
##
## At 100 % the operator has let go of the valve: the handle just tracks
## whatever reactor_rules.nova's active fault (or nothing) is doing to the
## real value, via follow_auto(). Dragging, nudging, or touching it below
## 100 % seizes manual control -- from that instant the operator's own
## position is authoritative, overriding the policy entirely, until it is
## pushed back up to 100 % (release_to_auto() does this directly). Unlike
## the rod banks there is no physical drive lag here, so there is only one
## value to draw, not a target/actual pair.

const TRACK_WIDTH := 34.0
const HANDLE_HEIGHT := 12.0
const AUTO_EPSILON := 0.05

@export var label_text: String = "FLOW"
@export var accent: Color = Color("4b96eb")

var value: float = 100.0: set = set_value
var enabled: bool = true: set = set_enabled

var dragging := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


## True once the handle sits at (effectively) full open -- the automatic
## system, not the operator, owns the value.
func is_auto() -> bool:
	return value >= 100.0 - AUTO_EPSILON


## Fed the live simulated value every frame. Only takes while the operator
## isn't holding the handle and it is still in auto, so a fault visibly
## moving the value shows up here even though nobody has touched it, and a
## drag in progress is never fought.
func follow_auto(live_pct: float) -> void:
	if not dragging and is_auto():
		set_value(live_pct)


func set_value(v: float) -> void:
	value = clampf(v, 0.0, 100.0)
	queue_redraw()


func set_enabled(v: bool) -> void:
	enabled = v
	if not enabled:
		dragging = false
	queue_redraw()


## Keyboard nudge -- the same "one press, one step" convention as the rod
## sliders' Q/A/W/S keys. Always a deliberate manual action.
func nudge(step: float) -> void:
	if enabled:
		set_value(value + step)


## Hands the valve back to the automatic system.
func release_to_auto() -> void:
	if enabled:
		set_value(100.0)


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
			dragging = mb.pressed
			if mb.pressed:
				set_value(_value_from_position(mb.position.y))
			accept_event()
	elif event is InputEventMouseMotion and dragging:
		set_value(_value_from_position((event as InputEventMouseMotion).position.y))
		accept_event()
	elif event is InputEventScreenDrag:
		set_value(_value_from_position((event as InputEventScreenDrag).position.y))
		accept_event()
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		dragging = st.pressed
		if st.pressed:
			set_value(_value_from_position(st.position.y))
		accept_event()


func _draw() -> void:
	var font := get_theme_default_font()
	var track := _track_rect()
	var auto := is_auto()
	var col := ReactorTheme.TEXT_FAINT if auto else accent

	draw_string(font, Vector2(4.0, 15.0), label_text, HORIZONTAL_ALIGNMENT_LEFT,
			-1, 12, ReactorTheme.TEXT_DIM)

	ReactorTheme.draw_bay(self, track)
	for i in range(11):
		var y := track.position.y + track.size.y * (1.0 - i / 10.0)
		var major := i % 5 == 0
		draw_line(Vector2(track.position.x - (7.0 if major else 4.0), y),
				Vector2(track.position.x, y),
				ReactorTheme.TEXT_DIM if major else ReactorTheme.TEXT_FAINT, 1.0)
		if major:
			draw_string(font, Vector2(track.end.x + 5.0, y + 4.0),
					"%d" % (i * 10), HORIZONTAL_ALIGNMENT_LEFT, -1, 9,
					ReactorTheme.TEXT_FAINT)

	var fill_h := track.size.y * (value / 100.0)
	var fill := Rect2(track.position + Vector2(3.0, track.size.y - fill_h),
			Vector2(track.size.x - 6.0, fill_h))
	var fill_col := col
	fill_col.a = 0.30 if enabled else 0.14
	draw_rect(fill, fill_col, true)

	var handle_y := track.position.y + track.size.y * (1.0 - value / 100.0)
	var handle := Rect2(Vector2(track.position.x - 6.0,
			handle_y - HANDLE_HEIGHT * 0.5),
			Vector2(track.size.x + 12.0, HANDLE_HEIGHT))
	var handle_col := col if enabled else ReactorTheme.TEXT_FAINT
	draw_rect(handle, handle_col.darkened(0.45), true)
	draw_rect(handle, handle_col, false, 2.0)
	draw_line(Vector2(handle.position.x + 3.0, handle_y),
			Vector2(handle.end.x - 3.0, handle_y), handle_col.lightened(0.35), 1.0)

	var read := "AUTO" if auto else "%5.1f%%" % value
	draw_string(font, Vector2(2.0, size.y - 8.0), read,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			handle_col if enabled else ReactorTheme.TEXT_FAINT)

	if not auto:
		var badge := Rect2(Vector2(0.0, track.position.y - 20.0), Vector2(size.x, 17.0))
		draw_rect(badge, Color(accent, 0.20), true)
		draw_string(font, badge.position + Vector2(4.0, 13.0), "MANUAL",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, accent)
