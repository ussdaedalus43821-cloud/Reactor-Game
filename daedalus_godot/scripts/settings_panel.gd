class_name SettingsPanel
extends Control

## Difficulty, starting sector, starting wingmen, god mode, infinite ammo,
## cloak availability, minimap toggle -- every field GameState (the
## autoload menu/ship-select/gameplay all share) exposes. Values here
## write straight into GameState as they change; there is no separate
## "Apply" step, matching Select Ship's own immediate-write behavior.


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.03, 0.04, 0.07)
	add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-160, -220)
	box.add_theme_constant_override("separation", 10)
	add_child(box)

	var title := Label.new()
	title.text = "SETTINGS"
	box.add_child(title)

	box.add_child(_labeled("Difficulty"))
	var difficulty_row := HBoxContainer.new()
	box.add_child(difficulty_row)
	for d in GameState.DIFFICULTIES:
		# Rebound into a fresh local before the closure captures it --
		# safer than trusting the for-loop's own iteration variable to be
		# a distinct binding per pass.
		var diff_name := String(d)
		var b := Button.new()
		b.text = diff_name
		b.toggle_mode = true
		b.button_pressed = GameState.difficulty == diff_name
		b.pressed.connect(func(): _set_difficulty(diff_name, difficulty_row))
		difficulty_row.add_child(b)

	box.add_child(_labeled("Starting sector (0-9)"))
	var sector_spin := SpinBox.new()
	sector_spin.min_value = 0
	sector_spin.max_value = 9
	sector_spin.value = GameState.starting_sector
	sector_spin.value_changed.connect(func(v): GameState.starting_sector = int(v))
	box.add_child(sector_spin)

	box.add_child(_labeled("Starting wingmen (0-4)"))
	var wingmen_spin := SpinBox.new()
	wingmen_spin.min_value = 0
	wingmen_spin.max_value = 4
	wingmen_spin.value = GameState.starting_wingmen
	wingmen_spin.value_changed.connect(func(v): GameState.starting_wingmen = int(v))
	box.add_child(wingmen_spin)

	_check(box, "God mode", GameState.god_mode, func(v): GameState.god_mode = v)
	_check(box, "Infinite ammo", GameState.infinite_ammo, func(v): GameState.infinite_ammo = v)
	_check(box, "Cloak available", GameState.cloak_available, func(v): GameState.cloak_available = v)
	_check(box, "Minimap enabled", GameState.minimap_enabled, func(v): GameState.minimap_enabled = v)

	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(140, 36)
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/ui/menu.tscn"))
	box.add_child(back)


func _set_difficulty(value: String, row: HBoxContainer) -> void:
	GameState.difficulty = value
	for child in row.get_children():
		if child is Button:
			(child as Button).button_pressed = (child as Button).text == value


func _labeled(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _check(parent: Control, text: String, initial: bool, on_toggle: Callable) -> void:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = initial
	c.toggled.connect(on_toggle)
	parent.add_child(c)
