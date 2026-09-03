class_name MainMenu
extends Control

## Title screen: Resume (only when a run is in progress), New Game, Select
## Ship, Settings, Controls, Quit. Select Ship and Settings are their own
## full screens (ship_select.tscn, settings.tscn); Controls is a panel
## layered over this same scene instead, since it is read-only and the
## brief's file list does not name a separate scene for it.

var _controls_panel: Control = null
var _resume_button: Button = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	get_tree().paused = false

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.03, 0.04, 0.07)
	add_child(bg)

	var title := Label.new()
	title.text = "DAEDALUS"
	title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title.position = Vector2(-160, 90)
	title.custom_minimum_size = Vector2(320, 48)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	add_child(title)

	var subtitle := Label.new()
	subtitle.text = "a space-combat sim written in NovaLang"
	subtitle.set_anchors_preset(Control.PRESET_CENTER_TOP)
	subtitle.position = Vector2(-160, 140)
	subtitle.custom_minimum_size = Vector2(320, 24)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(subtitle)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-110, -60)
	box.add_theme_constant_override("separation", 10)
	add_child(box)

	_resume_button = _menu_button(box, "Resume", _on_resume_pressed)
	_resume_button.visible = GameState.has_resume()
	_menu_button(box, "New Game", _on_new_game_pressed)
	_menu_button(box, "Select Ship", _on_select_ship_pressed)
	_menu_button(box, "Settings", _on_settings_pressed)
	_menu_button(box, "Controls", _on_controls_pressed)
	_menu_button(box, "Quit", _on_quit_pressed)

	_controls_panel = _build_controls_panel()


func _menu_button(parent: Control, text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(220, 42)
	b.pressed.connect(handler)
	parent.add_child(b)
	return b


# ==========================================================================
# Navigation
# ==========================================================================

func _on_resume_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _on_new_game_pressed() -> void:
	GameState.clear_snapshot()
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _on_select_ship_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/ship_select.tscn")


func _on_settings_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/settings.tscn")


func _on_controls_pressed() -> void:
	_controls_panel.visible = true


func _on_quit_pressed() -> void:
	get_tree().quit()


# ==========================================================================
# Controls panel
# ==========================================================================

const CONTROL_LINES := [
	"Mouse / A-D or Left-Right     Turn",
	"W / Up                        Thrust forward",
	"S / Down                      Thrust reverse",
	"Space                         Fire guns",
	"Shift                         Fire rockets",
	"X                             Fire homing missile",
	"F (hold)                      Fire beam",
	"Q                             Toggle cloak",
	"G                             Spawn wingman",
	"Tab                           Cycle ship",
	"M                             Toggle minimap",
	"0-9                           Hyperjump to sector",
	"Esc                           Pause / menu",
]

func _build_controls_panel() -> Control:
	var panel := _overlay_panel()

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-220, -220)
	panel.add_child(box)

	var title := Label.new()
	title.text = "CONTROLS"
	box.add_child(title)

	var body := Label.new()
	body.text = "\n".join(PackedStringArray(CONTROL_LINES))
	box.add_child(body)

	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(140, 36)
	back.pressed.connect(func(): panel.visible = false)
	box.add_child(back)

	return panel


func _overlay_panel() -> Control:
	var panel := Control.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.visible = false
	add_child(panel)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.8)
	panel.add_child(dim)

	return panel
