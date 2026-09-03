class_name TouchControls
extends Control

## On-screen joystick (movement/aim) and weapon/cloak/wingman buttons for
## iOS and Web. Only shown when DisplayServer reports an actual
## touchscreen, so a desktop or a non-touch web session never sees it.
##
## The weapon/cloak/wingman buttons need no cooperation from player.gd at
## all: touching one calls Input.action_press()/action_release() on the
## same named actions a keyboard press would set, and Input's own
## just_pressed/just_released edge tracking treats that identically to a
## real key. Movement is the one case that cannot work that way -- there
## is no InputEventKey for "aim this direction" -- so the joystick
## publishes `active` / `direction` / `magnitude` on this node directly,
## in the "touch_joystick" group, and player.gd checks that group (falling
## back to mouse-aim + WASD when no touch layer is present or engaged) --
## see Player._handle_rotation() / Player._handle_thrust().

const JOYSTICK_RADIUS := 90.0
const DEADZONE := 0.12

var active := false
var direction := Vector2.RIGHT
var magnitude := 0.0

var _joystick_base: Control = null
var _joystick_knob: Control = null
var _joystick_center := Vector2.ZERO
var _joystick_touch_index := -1

const BUTTON_ACTIONS := [
	["GUNS", "fire_guns"], ["ROCKETS", "fire_rockets"], ["HOMING", "fire_homing"],
	["BEAM", "fire_beam"], ["CLOAK", "toggle_cloak"], ["WING", "spawn_wingman"],
]


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = DisplayServer.is_touchscreen_available()
	add_to_group("touch_joystick")

	_build_joystick()
	_build_buttons()


func _build_joystick() -> void:
	# add_child() first, then anchors, then position: set_anchors_preset()
	# recomputes offsets from the control's parent-relative rect, which is
	# only meaningful once the control is actually in the tree -- setting
	# position before either of those steps would just get overwritten.
	_joystick_base = _make_circle(JOYSTICK_RADIUS, Color(1, 1, 1, 0.18))
	add_child(_joystick_base)
	_joystick_base.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_joystick_base.position = Vector2(140, -140)
	_joystick_base.mouse_filter = Control.MOUSE_FILTER_PASS
	_joystick_center = _joystick_base.position

	_joystick_knob = _make_circle(JOYSTICK_RADIUS * 0.45, Color(1, 1, 1, 0.4))
	add_child(_joystick_knob)
	_joystick_knob.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_joystick_knob.position = _joystick_center
	_joystick_knob.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _make_circle(radius: float, color: Color) -> Control:
	var c := Control.new()
	# A bare Control outside a Container does not pick up
	# custom_minimum_size as its actual `size` on its own -- .size has to
	# be set explicitly too, or global_position/size (used for the touch
	# hit-test in _on_touch()) would stay a degenerate zero-size rect.
	c.custom_minimum_size = Vector2(radius, radius) * 2.0
	c.size = c.custom_minimum_size
	var poly := Polygon2D.new()
	var pts := PackedVector2Array()
	for i in range(24):
		var a := TAU * float(i) / 24.0
		pts.append(Vector2(cos(a), sin(a)) * radius + Vector2(radius, radius))
	poly.polygon = pts
	poly.color = color
	c.add_child(poly)
	return c


func _build_buttons() -> void:
	var row := HBoxContainer.new()
	add_child(row)
	row.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	row.position = Vector2(-360, -80)
	row.add_theme_constant_override("separation", 10)

	for pair in BUTTON_ACTIONS:
		var label := String(pair[0])
		var action := String(pair[1])
		var btn := Button.new()
		btn.text = label
		btn.custom_minimum_size = Vector2(58, 58)
		btn.button_down.connect(func(): Input.action_press(action))
		btn.button_up.connect(func(): Input.action_release(action))
		row.add_child(btn)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventScreenTouch:
		_on_touch(event)
	elif event is InputEventScreenDrag:
		_on_drag(event)


func _on_touch(event: InputEventScreenTouch) -> void:
	var base_rect := Rect2(_joystick_base.global_position, _joystick_base.size)
	if event.pressed:
		if _joystick_touch_index == -1 and base_rect.grow(60.0).has_point(event.position):
			_joystick_touch_index = event.index
			_update_joystick(event.position)
	elif event.index == _joystick_touch_index:
		_reset_joystick()


func _on_drag(event: InputEventScreenDrag) -> void:
	if event.index == _joystick_touch_index:
		_update_joystick(event.position)


func _update_joystick(screen_pos: Vector2) -> void:
	var center := _joystick_base.global_position + _joystick_base.size * 0.5
	var offset := screen_pos - center
	var mag := clampf(offset.length() / JOYSTICK_RADIUS, 0.0, 1.0)
	if mag < DEADZONE:
		active = false
		magnitude = 0.0
		_joystick_knob.position = _joystick_center
		return
	active = true
	magnitude = mag
	direction = offset.normalized()
	_joystick_knob.position = _joystick_center + direction * JOYSTICK_RADIUS * 0.5 * mag


func _reset_joystick() -> void:
	_joystick_touch_index = -1
	active = false
	magnitude = 0.0
	_joystick_knob.position = _joystick_center
