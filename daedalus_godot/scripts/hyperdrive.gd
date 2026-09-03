class_name HyperdriveOverlay
extends Control

## Charging overlay (spinning ring + progress bar) and travel overlay
## (star streaks + ETA), driven entirely by game.gd's hyper_state /
## hyper_progress / hyper_target_key -- this file owns no hyperdrive state
## of its own, only how "charging" and "travel" look. Also draws the
## always-available "press a digit to jump" destination list while idle,
## since raw number keys (0-9, matching SECTORS' own `key` field) are the
## only hyperjump input and the player has to see the menu somewhere.

const STREAK_COUNT := 40

var game: Game = null
var _ring_angle := 0.0
var _streaks: Array = []   # [angle, length, speed]

var _charge_layer: Control
var _charge_label: Label
var _charge_bar: ProgressBar
var _charge_ring: Control

var _travel_layer: Control
var _travel_label: Label
var _star_canvas: Control

var _sector_list_label: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_build_charge_layer()
	_build_travel_layer()
	_build_sector_list()

	for i in range(STREAK_COUNT):
		_streaks.append([randf_range(0.0, TAU), randf_range(0.1, 1.0), randf_range(220.0, 520.0)])


func setup(g: Game) -> void:
	game = g


func _build_charge_layer() -> void:
	_charge_layer = Control.new()
	_charge_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_charge_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_charge_layer.visible = false
	add_child(_charge_layer)

	_charge_ring = Control.new()
	_charge_ring.set_anchors_preset(Control.PRESET_CENTER)
	_charge_ring.position = Vector2(-70, -70)
	_charge_ring.custom_minimum_size = Vector2(140, 140)
	_charge_ring.size = _charge_ring.custom_minimum_size
	_charge_ring.draw.connect(_draw_ring.bind(_charge_ring))
	_charge_layer.add_child(_charge_ring)

	_charge_label = Label.new()
	_charge_label.set_anchors_preset(Control.PRESET_CENTER)
	_charge_label.position = Vector2(-200, 90)
	_charge_label.custom_minimum_size = Vector2(400, 30)
	_charge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_charge_layer.add_child(_charge_label)

	_charge_bar = ProgressBar.new()
	_charge_bar.set_anchors_preset(Control.PRESET_CENTER)
	_charge_bar.position = Vector2(-160, 120)
	_charge_bar.size = Vector2(320, 16)
	_charge_bar.show_percentage = false
	_charge_bar.min_value = 0.0
	_charge_bar.max_value = 1.0
	_charge_layer.add_child(_charge_bar)


func _draw_ring(ring: Control) -> void:
	var center := ring.size * 0.5
	var radius := minf(center.x, center.y) - 6.0
	ring.draw_arc(center, radius, 0.0, TAU, 48, Color(0.3, 0.5, 0.6, 0.35), 4.0)
	ring.draw_arc(center, radius, _ring_angle, _ring_angle + PI * 0.6, 24,
			Color(0.5, 0.95, 1.0, 0.9), 4.0)


func _build_travel_layer() -> void:
	_travel_layer = Control.new()
	_travel_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_travel_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_travel_layer.visible = false
	add_child(_travel_layer)

	_star_canvas = Control.new()
	_star_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_star_canvas.draw.connect(_draw_streaks.bind(_star_canvas))
	_travel_layer.add_child(_star_canvas)

	_travel_label = Label.new()
	_travel_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_travel_label.position = Vector2(-160, -80)
	_travel_label.custom_minimum_size = Vector2(320, 30)
	_travel_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_travel_layer.add_child(_travel_label)


func _draw_streaks(canvas: Control) -> void:
	var center := canvas.size * 0.5
	for s in _streaks:
		var angle: float = s[0]
		var len_frac: float = s[1]
		var dir := Vector2.RIGHT.rotated(angle)
		var far := minf(center.x, center.y) * 1.6
		var inner := far * (1.0 - len_frac)
		canvas.draw_line(center + dir * inner, center + dir * far,
				Color(0.8, 0.9, 1.0, 0.5), 2.0)


func _build_sector_list() -> void:
	_sector_list_label = Label.new()
	_sector_list_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_sector_list_label.position = Vector2(20, -190)
	_sector_list_label.custom_minimum_size = Vector2(420, 180)
	add_child(_sector_list_label)


func _process(delta: float) -> void:
	if game == null:
		return

	_ring_angle = wrapf(_ring_angle + 2.4 * delta, 0.0, TAU)
	for s in _streaks:
		s[1] = fmod(s[1] + delta * (s[2] / 400.0), 1.0)

	var charging := game.hyper_state == "charging"
	var traveling := game.hyper_state == "travel"
	_charge_layer.visible = charging
	_travel_layer.visible = traveling
	_sector_list_label.visible = game.hyper_state == "idle"

	if charging:
		_charge_ring.queue_redraw()
		_charge_bar.value = game.hyper_progress
		var dest := Daedalus.sector(game.hyper_target_key)
		_charge_label.text = "SPOOLING HYPERDRIVE -- %s" % String(dest.get("name", "?"))
	elif traveling:
		_star_canvas.queue_redraw()
		var dest := Daedalus.sector(game.hyper_target_key)
		var remaining := maxf(0.0, (1.0 - game.hyper_progress)) * _travel_seconds()
		_travel_label.text = "IN TRANSIT -- %s   ETA %.1fs" % [String(dest.get("name", "?")), remaining]
	elif _sector_list_label.visible:
		_sector_list_label.text = _build_sector_hint()


func _travel_seconds() -> float:
	var dest := Daedalus.sector(game.hyper_target_key)
	return float(dest.get("travel", 4.0))


func _build_sector_hint() -> String:
	var lines := ["JUMP -- press a number key:"]
	for s in Daedalus.sectors:
		var d: Dictionary = s
		lines.append("  %d  %s" % [int(d.get("key", 0)), String(d.get("name", "?"))])
	return "\n".join(PackedStringArray(lines))
