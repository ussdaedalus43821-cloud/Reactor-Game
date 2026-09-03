extends Node

## Builds the entire input map in code, using GDScript's named KEY_*
## constants, instead of hand-encoding InputEventKey resources with raw
## numeric keycodes directly in project.godot. A wrong keycode typed into
## that text format would bind silently to the wrong key with no error
## anywhere -- there is no way to catch that without opening the editor,
## which this environment cannot do. Named constants carry no such risk:
## KEY_ESCAPE is whatever the engine says KEY_ESCAPE is.
##
## An autoload (name "InputMapSetup"), so this runs once before any scene
## reads Input.is_action_pressed() for the first time.

const BINDINGS := {
	"thrust_forward": [KEY_W, KEY_UP],
	"thrust_reverse": [KEY_S, KEY_DOWN],
	"turn_left": [KEY_A, KEY_LEFT],
	"turn_right": [KEY_D, KEY_RIGHT],
	"fire_guns": [KEY_SPACE],
	"fire_rockets": [KEY_SHIFT],
	"fire_homing": [KEY_X],
	"fire_beam": [KEY_F],
	"toggle_cloak": [KEY_Q],
	"spawn_wingman": [KEY_G],
	"cycle_ship": [KEY_TAB],
	"toggle_minimap": [KEY_M],
	"pause_menu": [KEY_ESCAPE],
}


func _init() -> void:
	for action in BINDINGS:
		if not InputMap.has_action(action):
			InputMap.add_action(String(action))
		for keycode in BINDINGS[action]:
			var ev := InputEventKey.new()
			ev.keycode = keycode
			InputMap.action_add_event(String(action), ev)
