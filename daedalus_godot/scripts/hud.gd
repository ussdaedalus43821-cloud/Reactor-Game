class_name HUD
extends Control

## Shield/hull/power/cloak bars, speed and ammo readouts, score/sector/
## contact counts, the live NovaLang advisor's alert banner, the pause
## overlay and the game-over screen. Also owns TouchControls (see that
## file) as a child, since both are "things drawn over the game" with no
## reason to be separate top-level scenes.
##
## Every visual node here is built in _ready() rather than hand-authored
## in hud.tscn -- the same choice made for ship/projectile/enemy visuals,
## and for the same reason: a hand-written .tscn's anchors and offsets
## cannot be checked by reading them the way code can, and this project
## cannot be opened in the editor to look at the result.

var game: Game = null
var player: Player = null

var _shield_bar: ProgressBar
var _hull_bar: ProgressBar
var _power_bar: ProgressBar
var _cloak_bar: ProgressBar
var _ship_label: Label
var _speed_label: Label
var _ammo_label: Label
var _score_label: Label
var _sector_label: Label
var _contacts_label: Label

var _chip_god: Label
var _chip_cloak: Label
var _chip_shields: Label
var _chip_hull: Label
var _chip_infest: Label

var _alert_label: Label

var _pause_layer: Control
var _gameover_layer: Control
var _gameover_label: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_build_stat_panel()
	_build_status_chips()
	_build_alert_banner()
	_build_pause_layer()
	_build_gameover_layer()

	var touch := Control.new()
	touch.set_script(load("res://scripts/touch_controls.gd"))
	add_child(touch)


func setup(g: Game, p: Player) -> void:
	game = g
	player = p
	_ship_label.text = Daedalus.ship_name(p.ship_key)

	p.power_changed.connect(func(v, vm): _power_bar.max_value = vm; _power_bar.value = v)
	p.shield_changed.connect(func(v, vm): _shield_bar.max_value = vm; _shield_bar.value = v)
	p.hull_changed.connect(func(v, vm): _hull_bar.max_value = vm; _hull_bar.value = v)
	p.cloak_changed.connect(func(_active): _update_chips())

	_power_bar.max_value = p.power_max
	_power_bar.value = p.power
	_shield_bar.max_value = p.shield_max
	_shield_bar.value = p.shield
	_hull_bar.max_value = p.hull_max
	_hull_bar.value = p.hull
	_cloak_bar.max_value = p.power_max


# ==========================================================================
# Building the panels
# ==========================================================================

func _label(parent: Control, text: String, pos: Vector2) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	parent.add_child(l)
	return l


func _bar(parent: Control, pos: Vector2, color: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.position = pos
	b.size = Vector2(220, 18)
	b.show_percentage = false
	var fg := StyleBoxFlat.new()
	fg.bg_color = color
	b.add_theme_stylebox_override("fill", fg)
	parent.add_child(b)
	return b


func _build_stat_panel() -> void:
	var panel := Control.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	add_child(panel)
	panel.position = Vector2(20, 16)

	_ship_label = _label(panel, "", Vector2(0, 0))
	_shield_bar = _bar(panel, Vector2(0, 26), Color(0.35, 0.7, 1.0))
	_label(panel, "SHIELD", Vector2(228, 26))
	_hull_bar = _bar(panel, Vector2(0, 48), Color(0.9, 0.35, 0.3))
	_label(panel, "HULL", Vector2(228, 48))
	_power_bar = _bar(panel, Vector2(0, 70), Color(0.95, 0.8, 0.3))
	_label(panel, "POWER", Vector2(228, 70))
	_cloak_bar = _bar(panel, Vector2(0, 92), Color(0.5, 0.9, 0.9))
	_label(panel, "CLOAK", Vector2(228, 92))

	_speed_label = _label(panel, "SPEED 0", Vector2(0, 120))
	_ammo_label = _label(panel, "ROCKETS 0   HOMING 0", Vector2(0, 140))
	_score_label = _label(panel, "SCORE 0", Vector2(0, 168))
	_sector_label = _label(panel, "", Vector2(0, 188))
	_contacts_label = _label(panel, "", Vector2(0, 208))


func _chip(parent: Control, text: String, pos: Vector2, color: Color) -> Label:
	var l := _label(parent, text, pos)
	l.add_theme_color_override("font_color", color)
	l.visible = false
	return l


func _build_status_chips() -> void:
	var panel := Control.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(20, 240)
	add_child(panel)

	_chip_god = _chip(panel, "GOD MODE", Vector2(0, 0), Color(1, 0.9, 0.3))
	_chip_cloak = _chip(panel, "CLOAK ACTIVE", Vector2(0, 18), Color(0.5, 0.9, 0.9))
	_chip_shields = _chip(panel, "SHIELDS REBUILDING", Vector2(0, 36), Color(0.6, 0.8, 1.0))
	_chip_hull = _chip(panel, "HULL CRITICAL", Vector2(0, 54), Color(1, 0.3, 0.3))
	_chip_infest = _chip(panel, "REPLICATOR INFESTATION", Vector2(0, 72), Color(0.4, 0.9, 0.5))


func _build_alert_banner() -> void:
	_alert_label = Label.new()
	_alert_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_alert_label.position = Vector2(-260, 16)
	_alert_label.custom_minimum_size = Vector2(520, 30)
	_alert_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_alert_label.visible = false
	add_child(_alert_label)


func _build_pause_layer() -> void:
	_pause_layer = Control.new()
	_pause_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_layer.visible = false
	add_child(_pause_layer)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.55)
	_pause_layer.add_child(dim)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-90, -60)
	box.add_theme_constant_override("separation", 12)
	_pause_layer.add_child(box)

	var title := Label.new()
	title.text = "PAUSED"
	box.add_child(title)

	var resume_btn := Button.new()
	resume_btn.text = "Resume"
	resume_btn.custom_minimum_size = Vector2(180, 40)
	resume_btn.pressed.connect(func(): game._toggle_pause())
	box.add_child(resume_btn)

	var quit_btn := Button.new()
	quit_btn.text = "Quit to Title"
	quit_btn.custom_minimum_size = Vector2(180, 40)
	quit_btn.pressed.connect(_on_quit_to_title_pressed)
	box.add_child(quit_btn)


func _on_quit_to_title_pressed() -> void:
	game.save_now()
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/ui/menu.tscn")


func _build_gameover_layer() -> void:
	_gameover_layer = Control.new()
	_gameover_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_gameover_layer.visible = false
	add_child(_gameover_layer)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.7)
	_gameover_layer.add_child(dim)

	_gameover_label = Label.new()
	_gameover_label.set_anchors_preset(Control.PRESET_CENTER)
	_gameover_label.position = Vector2(-200, -60)
	_gameover_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gameover_label.custom_minimum_size = Vector2(400, 120)
	_gameover_layer.add_child(_gameover_label)


# ==========================================================================
# Per-frame readouts
# ==========================================================================

func _process(_delta: float) -> void:
	if player == null or game == null:
		return
	_speed_label.text = "SPEED %d" % int(player.velocity.length())
	_ammo_label.text = "ROCKETS %d   HOMING %d" % [player.rockets, player.homing]
	_score_label.text = "SCORE %d" % game.score
	_sector_label.text = "%s   (gen %.1fm)" % [game.sector_name(), game.gen_minutes]
	_contacts_label.text = "HOSTILES %d   WINGMEN %d" % [_count("hostiles"), _count("wingmen")]
	_cloak_bar.value = player.power if player.cloaked else 0.0
	_update_chips()


func _count(group: String) -> int:
	var n := 0
	for node in get_tree().get_nodes_in_group(group):
		if is_instance_valid(node):
			n += 1
	return n


func _update_chips() -> void:
	_chip_god.visible = player.god_mode
	_chip_cloak.visible = player.cloaked
	_chip_shields.visible = player.shield < player.shield_max
	_chip_hull.visible = (player.hull / maxf(player.hull_max, 1.0)) < 0.3
	_chip_infest.visible = player.infested > 0.0


# ==========================================================================
# Advisor -- driven by Daedalus.advisor_tick() through game.gd
# ==========================================================================

func apply_advisor(result: Dictionary) -> void:
	var level := int(result.get("alert_level", 0))
	var recommend := String(result.get("recommend", ""))
	var text := String(result.get("alarm_text", ""))

	if level >= 3:
		_alert_label.modulate = Color(1, 0.35, 0.3)
	elif level >= 2:
		_alert_label.modulate = Color(1, 0.75, 0.3)
	elif level >= 1:
		_alert_label.modulate = Color(1, 1, 0.4)
	else:
		_alert_label.modulate = Color(0.75, 0.9, 1.0)

	var line := text
	if recommend != "":
		line += ("  --  " if line != "" else "") + recommend
	_alert_label.text = line
	_alert_label.visible = line != ""


# ==========================================================================
# Pause / game over
# ==========================================================================

func set_paused(paused: bool) -> void:
	_pause_layer.visible = paused


func is_game_over() -> bool:
	return _gameover_layer.visible


func show_game_over(score: int) -> void:
	_gameover_label.text = "DESTROYED\n\nFinal score: %d\n\nPress ESC for the title screen" % score
	_gameover_layer.visible = true
	get_tree().paused = true
