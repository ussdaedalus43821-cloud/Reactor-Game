class_name Minimap
extends Control

## Player-relative radar: player, hostiles, wingmen and landmarks, drawn
## entirely with draw_* calls in one _draw() override -- no per-contact
## node, so the minimap's cost stays flat regardless of how many ships are
## on the scope (a plain sprite-per-contact minimap would add a Node2D per
## enemy just for its icon, doubling the scene-tree cost of every spawn).

const MAP_RADIUS := 110.0
const MAP_RANGE := 2600.0        # world units shown at the ring's edge
const SWEEP_SPEED := 1.4         # radians/sec
const RING_COUNT := 3

const LANDMARK_COLORS := {
	"planet": Color(0.5, 0.7, 1.0),
	"stargate": Color(0.8, 0.9, 1.0),
	"black_hole": Color(0.5, 0.5, 0.55),
	"nebula": Color(0.85, 0.55, 0.95),
}

var game: Game = null
var player: Player = null
var _sweep_angle := 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	custom_minimum_size = Vector2(MAP_RADIUS, MAP_RADIUS) * 2.0
	size = custom_minimum_size
	position = Vector2(-(MAP_RADIUS * 2.0 + 20.0), 20.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func setup(g: Game, p: Player) -> void:
	game = g
	player = p


func _process(delta: float) -> void:
	_sweep_angle = wrapf(_sweep_angle + SWEEP_SPEED * delta, 0.0, TAU)
	queue_redraw()


func _center() -> Vector2:
	return Vector2(MAP_RADIUS, MAP_RADIUS)


func _draw() -> void:
	var center := _center()
	draw_circle(center, MAP_RADIUS, Color(0.02, 0.05, 0.08, 0.75))

	for i in range(1, RING_COUNT + 1):
		var r := MAP_RADIUS * float(i) / float(RING_COUNT)
		draw_arc(center, r, 0.0, TAU, 48, Color(0.4, 0.7, 0.6, 0.25), 1.0)

	_draw_sweep(center)

	if player == null or not is_instance_valid(player):
		return

	for kind_group in ["landmarks", "hostiles", "wingmen"]:
		for node in get_tree().get_nodes_in_group(kind_group):
			if not is_instance_valid(node):
				continue
			_draw_contact(center, node, kind_group)

	_draw_player(center)

	draw_arc(center, MAP_RADIUS, 0.0, TAU, 64, Color(0.5, 0.9, 0.8, 0.6), 1.5)


func _draw_sweep(center: Vector2) -> void:
	var dir := Vector2.RIGHT.rotated(_sweep_angle)
	draw_line(center, center + dir * MAP_RADIUS, Color(0.4, 1.0, 0.7, 0.5), 2.0)
	var wedge := PackedVector2Array([center])
	var steps := 10
	for i in range(steps + 1):
		var a := _sweep_angle - (float(i) / float(steps)) * 0.5
		wedge.append(center + Vector2.RIGHT.rotated(a) * MAP_RADIUS)
	var colors := PackedColorArray()
	for i in range(wedge.size()):
		colors.append(Color(0.3, 0.9, 0.6, 0.12))
	draw_polygon(wedge, colors)


func _draw_contact(center: Vector2, node: Node, group: String) -> void:
	var rel: Vector2 = node.global_position - player.global_position
	var dist := rel.length()
	# Named px_per_unit, not `scale` -- CanvasItem already has a `scale`
	# property and shadowing it here would be legal but confusing.
	var px_per_unit := MAP_RADIUS / MAP_RANGE
	var color: Color
	var on_edge := false
	var point: Vector2

	if group == "landmarks":
		var kind := String(node.get_meta("kind", "planet"))
		color = LANDMARK_COLORS.get(kind, Color.WHITE)
	elif group == "wingmen":
		color = Color(0.4, 0.7, 1.0)
	else:
		color = Color(1.0, 0.35, 0.35)

	if dist > MAP_RANGE:
		on_edge = true
		point = center + rel.normalized() * (MAP_RADIUS - 8.0)
	else:
		point = center + rel * px_per_unit

	if on_edge:
		var tip := point + rel.normalized() * 7.0
		var left := point + rel.normalized().rotated(2.4) * 5.0
		var right := point + rel.normalized().rotated(-2.4) * 5.0
		draw_polygon(PackedVector2Array([tip, left, right]), PackedColorArray([color, color, color]))
	else:
		draw_circle(point, 3.0, color)


func _draw_player(center: Vector2) -> void:
	var dir := Vector2.RIGHT.rotated(player.rotation)
	var tip := center + dir * 8.0
	var left := center + dir.rotated(2.6) * 6.0
	var right := center + dir.rotated(-2.6) * 6.0
	draw_polygon(PackedVector2Array([tip, left, right]),
			PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE]))
