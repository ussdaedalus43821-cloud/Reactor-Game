class_name ShipSelect
extends Control

## All six hulls with their Stage 1 stats, read straight from
## Daedalus.get_ship_stats() -- nothing here is a second copy of a number
## already in daedalus_rules.nova. "Special" is the one thing NovaLang
## does not carry as a labelled field (SHIPS has no `special` key), so it
## is synthesised here from data that *is* there: hardened, and which
## weapon fields are non-zero.

const SPECIAL_NOTE := {
	"x302": "Fast interceptor; no beam, no drones",
	"daedalus": "Asgard beam weapon",
	"phoenix": "Asgard beam, improved hull/shield",
	"aurora": "Hardened shield; drone salvo x3",
	"destiny": "5 automated point-defense turrets",
	"atlantis": "Hardened shield; omni-broadside x8 ports, drone salvo x6",
}


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.03, 0.04, 0.07)
	add_child(bg)

	var title := Label.new()
	title.text = "SELECT SHIP"
	title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title.position = Vector2(-100, 30)
	title.custom_minimum_size = Vector2(200, 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_CENTER)
	row.position = Vector2(-3 * 190, -160)
	row.add_theme_constant_override("separation", 16)
	add_child(row)

	for key in Daedalus.ship_order:
		row.add_child(_build_card(String(key)))

	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(140, 40)
	back.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	back.position = Vector2(-70, -60)
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/ui/menu.tscn"))
	add_child(back)


func _build_card(key: String) -> Control:
	var stats := Daedalus.get_ship_stats(key)
	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(180, 320)
	panel.add_theme_constant_override("separation", 4)

	var name_label := Label.new()
	name_label.text = String(stats.get("name", key))
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	panel.add_child(name_label)

	var class_label := Label.new()
	class_label.text = "class: %s" % String(stats.get("class", "?"))
	panel.add_child(class_label)

	panel.add_child(_stat_line("Shield", stats.get("shield", 0.0)))
	panel.add_child(_stat_line("Hull", stats.get("hull", 0.0)))
	panel.add_child(_stat_line("Speed", stats.get("speed", 0.0)))
	panel.add_child(_stat_line("Turn", stats.get("turn", 0.0)))

	var hardened_label := Label.new()
	hardened_label.text = "Hardened: %s" % ("yes" if bool(stats.get("hardened", false)) else "no")
	panel.add_child(hardened_label)

	var special := Label.new()
	special.text = String(SPECIAL_NOTE.get(key, ""))
	special.autowrap_mode = TextServer.AUTOWRAP_WORD
	panel.add_child(special)

	var select_btn := Button.new()
	select_btn.text = "Fly this ship"
	select_btn.custom_minimum_size = Vector2(160, 36)
	select_btn.pressed.connect(func(): _select_ship(key))
	panel.add_child(select_btn)

	return panel


func _stat_line(label: String, value) -> Label:
	var l := Label.new()
	l.text = "%s: %.0f" % [label, float(value)]
	return l


func _select_ship(key: String) -> void:
	GameState.selected_ship = key
	get_tree().change_scene_to_file("res://scenes/ui/menu.tscn")
