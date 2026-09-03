class_name Game
extends Node2D

## The world: owns the player, the ambient spawner, sector/hyperdrive
## state, score, and wires the HUD/minimap/hyperdrive-overlay to all of
## it. Every number that drives spawning (hostile counts, danger scaling,
## sector charge/travel times) comes from Daedalus -- this script decides
## *when* to act on those numbers (timers, caps, which container a node
## goes in), never what the numbers themselves are.
##
## Pause is a two-tier process_mode split, set up in _ready(): this node
## runs PROCESS_MODE_ALWAYS so its own _process()/_unhandled_input() (and
## therefore the HUD, which lives under the same always-on UI layer) keep
## running while get_tree().paused is true, while $World is explicitly put
## back to PROCESS_MODE_PAUSABLE so it does not inherit "always" from this
## node -- Player, Enemy and Projectile all freeze correctly. Without that
## second line, PROCESS_MODE_ALWAYS on the root would cascade to every
## child and pausing would do nothing.

const MAX_HOSTILES := 24
const MAX_CAPITALS := 3
const MAX_WINGMEN := 4
const SPAWN_CHECK_INTERVAL := 1.0
const ADVISOR_INTERVAL := 0.1
const SNAPSHOT_INTERVAL := 4.0
const SPAWN_RING_MIN := 900.0
const SPAWN_RING_MAX := 1500.0

## Used only when a sector's own `mix` is empty.
const DEFAULT_MIX := [["fighter", 5], ["dart", 3], ["capital", 1],
	["replicator", 1], ["hive", 1], ["ori", 1]]

## SECTORS.mix carries "wcruiser" from the original engine's contact
## naming, which daedalus_ai.nova's own KIND_ALIAS does not resolve (it
## only knows "wdart"/"whive" -- "wcruiser" was always meant to be the
## Brawler, canonical name "capital"). This is a spawner-side lookup only;
## it does not touch daedalus_rules.nova or daedalus_ai.nova.
const SECTOR_MIX_ALIAS := {"wcruiser": "capital"}

const CAPITAL_KINDS := ["capital", "hive", "ori"]
const LANDMARK_KINDS := ["planet", "stargate", "black_hole", "nebula"]
const LANDMARK_COUNT := 6

var player: Player = null
var score := 0
var sector_key := 1
var gen_minutes := 0.0

var hyper_state := "idle"     # idle / charging / travel
var hyper_target_key := -1
var hyper_progress := 0.0     # 0..1 within the current charge/travel phase

var _hyper_elapsed := 0.0
var _hyper_charge_time := 0.0
var _hyper_travel_time := 0.0

var _spawn_accum := 0.0
var _advisor_accum := 0.0
var _snapshot_accum := 0.0
var _rng := RandomNumberGenerator.new()

var player_scene: PackedScene = preload("res://scenes/player.tscn")
var enemy_scene: PackedScene = preload("res://scenes/enemy.tscn")

@onready var _world: Node2D = $World
@onready var _combatants: Node2D = $World/Combatants
@onready var _projectiles: Node2D = $World/Projectiles
@onready var _landmarks: Node2D = $World/Landmarks
@onready var _hud = $UI/HUD
@onready var _minimap = $UI/Minimap
@onready var _hyperdrive = $UI/Hyperdrive


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_world.process_mode = Node.PROCESS_MODE_PAUSABLE
	get_tree().paused = false

	_spawn_player()
	_spawn_landmarks()
	for i in range(GameState.starting_wingmen):
		spawn_wingman()

	_hud.setup(self, player)
	_minimap.setup(self, player)
	_hyperdrive.setup(self)
	_minimap.visible = GameState.minimap_enabled


func _spawn_player() -> void:
	player = player_scene.instantiate() as Player
	player.ship_key = GameState.selected_ship
	_combatants.add_child(player)
	player.projectiles_root = _projectiles
	player.god_mode = GameState.god_mode
	player.infinite_ammo = GameState.infinite_ammo
	player.cloak_available = GameState.cloak_available
	player.died.connect(_on_player_died)
	player.wingman_requested.connect(_on_wingman_requested)

	if GameState.has_resume():
		var snap: Dictionary = GameState.resume_snapshot
		player.restore(snap.get("player", {}))
		sector_key = int(snap.get("sector_key", GameState.starting_sector))
		gen_minutes = float(snap.get("gen_minutes", 0.0))
		score = int(snap.get("score", 0))
	else:
		sector_key = GameState.starting_sector
		player.global_position = Vector2.ZERO


# ==========================================================================
# Frame loop
# ==========================================================================

func _process(delta: float) -> void:
	if get_tree().paused:
		return

	match hyper_state:
		"idle":
			gen_minutes += delta / 60.0
			_spawn_accum += delta
			if _spawn_accum >= SPAWN_CHECK_INTERVAL:
				_spawn_accum = 0.0
				_maybe_spawn_hostile()
		"charging":
			_hyper_elapsed += delta
			hyper_progress = clampf(_hyper_elapsed / maxf(_hyper_charge_time, 0.01), 0.0, 1.0)
			if _hyper_elapsed >= _hyper_charge_time:
				_begin_travel()
		"travel":
			_hyper_elapsed += delta
			hyper_progress = clampf(_hyper_elapsed / maxf(_hyper_travel_time, 0.01), 0.0, 1.0)
			if _hyper_elapsed >= _hyper_travel_time:
				_arrive()

	_advisor_accum += delta
	if _advisor_accum >= ADVISOR_INTERVAL:
		_run_advisor(_advisor_accum)
		_advisor_accum = 0.0

	_snapshot_accum += delta
	if _snapshot_accum >= SNAPSHOT_INTERVAL:
		_snapshot_accum = 0.0
		_save_snapshot()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause_menu"):
		_toggle_pause()
		return
	if get_tree().paused:
		return
	if event.is_action_pressed("toggle_minimap"):
		_minimap.visible = not _minimap.visible
	elif event.is_action_pressed("cycle_ship"):
		_cycle_ship()


func _unhandled_key_input(event: InputEvent) -> void:
	if get_tree().paused or hyper_state != "idle":
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var digit := _digit_from_keycode(event.keycode)
	if digit >= 0:
		start_hyperjump(digit)


static func _digit_from_keycode(keycode: int) -> int:
	if keycode >= KEY_0 and keycode <= KEY_9:
		return keycode - KEY_0
	return -1


func _toggle_pause() -> void:
	if _hud.has_method("is_game_over") and _hud.is_game_over():
		get_tree().paused = false
		get_tree().change_scene_to_file("res://scenes/ui/menu.tscn")
		return
	get_tree().paused = not get_tree().paused
	if _hud.has_method("set_paused"):
		_hud.set_paused(get_tree().paused)


## Public wrapper so the pause overlay's "Quit to Title" button (hud.gd)
## can force an up-to-date snapshot before leaving, without reaching past
## a leading underscore into a method named as this file's own internals.
func save_now() -> void:
	_save_snapshot()


func _cycle_ship() -> void:
	var order: Array = Daedalus.ship_order
	if order.is_empty() or player == null:
		return
	var idx := order.find(player.ship_key)
	var next_key := String(order[(idx + 1) % order.size()])
	player.load_ship(next_key)


# ==========================================================================
# Ambient spawner
# ==========================================================================

func _count_group(group: String) -> int:
	var n := 0
	for node in get_tree().get_nodes_in_group(group):
		if is_instance_valid(node):
			n += 1
	return n


func _count_capitals() -> int:
	var n := 0
	for node in get_tree().get_nodes_in_group("hostiles"):
		if is_instance_valid(node) and node.has_method("get_ship_class") \
				and node.get_ship_class() == "capital":
			n += 1
	return n


func _maybe_spawn_hostile() -> void:
	if player == null or not player.alive:
		return
	var sector := Daedalus.sector(sector_key)
	if sector.is_empty() or not bool(sector.get("spawns", false)):
		return

	var desired := int(float(Daedalus.sector_hostiles(sector_key, gen_minutes)) \
			* GameState.spawn_density_multiplier())
	desired = mini(desired, MAX_HOSTILES)
	if _count_group("hostiles") >= desired:
		return

	var kind := _pick_spawn_kind(sector)
	if kind in CAPITAL_KINDS and _count_capitals() >= MAX_CAPITALS:
		kind = "fighter"
	_spawn_hostile(kind)


func _pick_spawn_kind(sector: Dictionary) -> String:
	var raw_mix: Array = sector.get("mix", [])
	var pool: Array = []
	if raw_mix.is_empty():
		pool = DEFAULT_MIX
	else:
		for entry in raw_mix:
			var k := String((entry as Dictionary).get("kind", "fighter"))
			k = String(SECTOR_MIX_ALIAS.get(k, k))
			pool.append([k, int((entry as Dictionary).get("weight", 1))])

	var unique := String(sector.get("unique", ""))
	if unique != "" and _rng.randf() < 0.25:
		return unique
	return _weighted_pick(pool)


func _weighted_pick(pool: Array) -> String:
	var total := 0.0
	for entry in pool:
		total += float(entry[1])
	if total <= 0.0:
		return "fighter"
	var r := _rng.randf_range(0.0, total)
	var acc := 0.0
	for entry in pool:
		acc += float(entry[1])
		if r <= acc:
			return String(entry[0])
	return String(pool[-1][0])


func _spawn_hostile(kind: String) -> void:
	var angle := _rng.randf_range(0.0, TAU)
	var dist := _rng.randf_range(SPAWN_RING_MIN, SPAWN_RING_MAX)
	var pos: Vector2 = player.global_position + Vector2.RIGHT.rotated(angle) * dist
	var e := enemy_scene.instantiate() as Enemy
	_combatants.add_child(e)
	e.projectiles_root = _projectiles
	e.combatants_root = _combatants
	e.died.connect(_on_enemy_died)
	e.setup({"kind": kind, "faction": "hostile", "player_key": player.ship_key, "position": pos})


func _on_wingman_requested() -> void:
	spawn_wingman()


func spawn_wingman() -> void:
	if player == null or _count_group("wingmen") >= MAX_WINGMEN:
		return
	var offset := Vector2(_rng.randf_range(-90.0, 90.0), _rng.randf_range(-90.0, 90.0))
	var e := enemy_scene.instantiate() as Enemy
	_combatants.add_child(e)
	e.projectiles_root = _projectiles
	e.combatants_root = _combatants
	e.died.connect(_on_enemy_died)
	e.setup({
		"kind": "fighter", "faction": "player", "player_key": player.ship_key,
		"position": player.global_position + offset,
	})


func _on_enemy_died(_kind: String, points: int, was_wingman: bool) -> void:
	if not was_wingman:
		score += points


# ==========================================================================
# Landmarks (minimap + light scenery, no gameplay effect)
# ==========================================================================

func _spawn_landmarks() -> void:
	for child in _landmarks.get_children():
		child.queue_free()
	for i in range(LANDMARK_COUNT):
		var kind: String = LANDMARK_KINDS[_rng.randi_range(0, LANDMARK_KINDS.size() - 1)]
		var angle := _rng.randf_range(0.0, TAU)
		var dist := _rng.randf_range(1200.0, 3600.0)
		_add_landmark(kind, Vector2.RIGHT.rotated(angle) * dist)


func _add_landmark(kind: String, pos: Vector2) -> void:
	var lm := Node2D.new()
	lm.position = pos
	lm.set_meta("kind", kind)
	lm.add_to_group("landmarks")

	var radius := 40.0
	var color := Color.WHITE
	match kind:
		"planet":
			radius = 60.0
			color = Color(0.4, 0.6, 0.9)
		"stargate":
			radius = 45.0
			color = Color(0.7, 0.85, 1.0)
		"black_hole":
			radius = 50.0
			color = Color(0.05, 0.05, 0.08)
		"nebula":
			radius = 90.0
			color = Color(0.7, 0.4, 0.8, 0.35)

	var poly := Polygon2D.new()
	var pts := PackedVector2Array()
	for i in range(16):
		var a := TAU * float(i) / 16.0
		pts.append(Vector2(cos(a), sin(a)) * radius)
	poly.polygon = pts
	poly.color = color
	lm.add_child(poly)
	_landmarks.add_child(lm)


# ==========================================================================
# Hyperdrive
# ==========================================================================

func start_hyperjump(target_key: int) -> void:
	if hyper_state != "idle":
		return
	var sector := Daedalus.sector(target_key)
	if sector.is_empty():
		return
	hyper_target_key = target_key
	_hyper_charge_time = float(sector.get("charge", 2.0))
	_hyper_travel_time = float(sector.get("travel", 4.0))
	_hyper_elapsed = 0.0
	hyper_progress = 0.0
	hyper_state = "charging"
	AudioBus.play_hyperdrive_charge()


func _begin_travel() -> void:
	hyper_state = "travel"
	_hyper_elapsed = 0.0
	hyper_progress = 0.0


func _arrive() -> void:
	hyper_state = "idle"
	_hyper_elapsed = 0.0
	hyper_progress = 0.0
	sector_key = hyper_target_key
	hyper_target_key = -1
	gen_minutes = 0.0

	for node in get_tree().get_nodes_in_group("hostiles"):
		if is_instance_valid(node):
			node.queue_free()
	for child in _projectiles.get_children():
		child.queue_free()

	_spawn_landmarks()
	if player != null:
		player.global_position = Vector2.ZERO
		player.infested = 0.0


# ==========================================================================
# Advisor -- daedalus_rules.nova's live rule engine
# ==========================================================================

func _run_advisor(dt: float) -> void:
	if player == null or not player.alive:
		return
	var contacts: Array = []
	for node in get_tree().get_nodes_in_group("hostiles"):
		if is_instance_valid(node) and "kind" in node:
			contacts.append(node.kind)

	var sector := Daedalus.sector(sector_key)
	var result := Daedalus.advisor_tick(dt, {
		"hull": player.hull, "hull_max": player.hull_max,
		"shield": player.shield, "shield_max": player.shield_max,
		"cloaked": player.cloaked, "cloak_energy": player.power,
		"infested": player.infested,
		"contacts": contacts,
		"ally_count": _count_group("wingmen"),
		"sector_danger": int(sector.get("danger", 0)),
		"rockets": player.rockets, "homing": player.homing,
		"hyper_state": hyper_state,
	})
	if _hud.has_method("apply_advisor"):
		_hud.apply_advisor(result)


# ==========================================================================
# Life cycle
# ==========================================================================

func _on_player_died() -> void:
	GameState.clear_snapshot()
	if _hud.has_method("show_game_over"):
		_hud.show_game_over(score)


func _save_snapshot() -> void:
	if player == null or not player.alive:
		return
	GameState.save_snapshot({
		"player": player.snapshot(),
		"sector_key": sector_key,
		"gen_minutes": gen_minutes,
		"score": score,
	})


func sector_name() -> String:
	return String(Daedalus.sector(sector_key).get("name", "Unknown Sector"))
