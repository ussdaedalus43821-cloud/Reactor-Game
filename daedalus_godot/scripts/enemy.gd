class_name Enemy
extends CharacterBody2D

## One instance of this script plays all six hostile archetypes AND the
## player's wingmen -- the behavior itself is entirely data from
## Daedalus.get_enemy_behavior(kind, player_key) (daedalus_ai.nova,
## composed with the player's actual class and hardened flag through
## daedalus_rules.nova), resolved once at spawn, never once a frame. This
## script only turns that Dictionary into movement and firing.
##
## A wingman is not a special case in the data: it is the "fighter"
## (Skirmisher) profile from the SAME table, `faction` set to "player"
## instead of "hostile" so it hunts the enemy_hull group instead of
## player_hull and its shots land on the friendly_shot/enemy_hull side of
## Projectile's layers instead of the reverse. Nothing about
## daedalus_ai.nova changes for that -- the Skirmisher's standoff, burst
## and strafe timing apply exactly as tuned, just pointed the other way.
##
## Every hit this script deals is resolved the same way projectile.gd
## resolves a player shot: gun damage goes through
## Daedalus.effective_damage(raw, attacker_class, target_class) (the same
## class-scaling matrix, generalised to any target rather than assuming a
## player SHIPS key -- see projectile.gd's own note), a Dive-Bomber's ram
## goes through Daedalus.dart_ram_damage() (deliberately never scaled by
## class, per daedalus_ai.nova), and an Ori's beam applies its own
## pre-resolved beam_dps from the behavior Dictionary directly (already
## carries its player-class reaction baked in -- see daedalus_ai.nova's
## _ori_behavior(), which is its own documented exception to the general
## matrix, the same way Stage 3's Asgard beam is).

signal died(kind: String, score: int, is_wingman: bool)

const KIND_COLORS := {
	"fighter": Color(0.85, 0.35, 0.35),
	"capital": Color(0.75, 0.2, 0.2),
	"dart": Color(0.9, 0.55, 0.25),
	"hive": Color(0.55, 0.2, 0.6),
	"replicator": Color(0.3, 0.8, 0.45),
	"ori": Color(0.9, 0.85, 0.3),
}
const WINGMAN_COLOR := Color(0.4, 0.7, 1.0)

const BURST_ROUND_INTERVAL := 0.15
const DIVE_TIMEOUT := 3.0
const INFECT_STEP := 0.18
const RAM_HIT_RADIUS := 30.0

var kind := "fighter"
var faction := "hostile"       # "hostile" or "player" (wingman)
var player_key := "daedalus"

var behavior: Dictionary = {}
var ship_class_name := "fighter"

var shield := 0.0
var shield_max := 0.0
var hull := 0.0
var hull_max := 0.0
var max_speed := 0.0
var turn_rate := 0.0    # rad/s
var alive := true

var _keep_dist := 300.0
var _strafe_dir := 1.0

var _fire_timer := 1.0
var _burst_remaining := 0
var _burst_shot_timer := 0.0
var _flak_timer := 1.0

var _dive_timer := 3.0
var _diving := false
var _dive_elapsed := 0.0

var _spawn_timer := 5.0
var _stored_darts := 0

var _fleeing := false

var _charging := false
var _charge_timer := 1.0
var _beam_firing := false
var _beam_fire_timer := 0.0
var _beam_recharge_timer := 1.0

var projectiles_root: Node = null
var combatants_root: Node = null   # where a Hive's launched Darts (or a wingman's own spawns) are added
var projectile_scene: PackedScene = preload("res://scenes/projectile.tscn")
var enemy_scene: PackedScene = preload("res://scenes/enemy.tscn")

@onready var _hurtbox: Area2D = $Hurtbox
@onready var _muzzle: Marker2D = $Muzzle
var _hull_poly: Polygon2D = null
var _beam_line: Line2D = null


func setup(cfg: Dictionary) -> void:
	kind = String(cfg.get("kind", "fighter"))
	faction = String(cfg.get("faction", "hostile"))
	player_key = String(cfg.get("player_key", "daedalus"))
	global_position = cfg.get("position", Vector2.ZERO)

	behavior = Daedalus.get_enemy_behavior(kind, player_key)
	ship_class_name = String(behavior.get("class", "fighter"))
	shield_max = float(behavior.get("shield", 100.0))
	hull_max = float(behavior.get("hull", 100.0))
	max_speed = float(behavior.get("max_speed", 200.0))
	turn_rate = deg_to_rad(float(behavior.get("turn_rate", 100.0)))
	shield = shield_max
	hull = hull_max
	alive = true

	var kd: Array = behavior.get("keep_dist", [200.0, 300.0])
	_keep_dist = randf_range(float(kd[0]), float(kd[1]))
	_strafe_dir = 1.0 if randf() < 0.5 else -1.0

	var fc: Array = behavior.get("fire_cd", [1.0, 2.0])
	_fire_timer = randf_range(float(fc[0]), float(fc[1]))

	if kind == "dart" and bool(behavior.get("dive_enabled", false)):
		var dc: Array = behavior.get("dive_cd", [3.0, 5.0])
		_dive_timer = randf_range(float(dc[0]), float(dc[1]))

	if kind == "hive":
		var sc: Array = behavior.get("spawn_cd", [5.0, 9.0])
		_spawn_timer = randf_range(float(sc[0]), float(sc[1]))
		_stored_darts = int(behavior.get("max_stored", 6))

	if kind == "capital":
		var fk: Array = behavior.get("flak_cd", [2.5, 4.0])
		_flak_timer = randf_range(float(fk[0]), float(fk[1]))

	if kind == "ori":
		_beam_recharge_timer = randf_range(float(fc[0]), float(fc[1]))

	# This scene plays both sides, so unlike Player's fixed Hurtbox layer,
	# the physics layer itself (not just the group) has to be set here:
	# Projectile's area_entered/raycast checks match collision_layer bits,
	# groups are only ever used for the AoE and nearest-target *searches*.
	if faction == "hostile":
		_hurtbox.collision_layer = Projectile.LAYER_ENEMY_HULL
		_hurtbox.add_to_group("enemy_hull")
	else:
		_hurtbox.collision_layer = Projectile.LAYER_PLAYER_HULL
		_hurtbox.add_to_group("player_hull")
	_hurtbox.collision_mask = 0
	_hurtbox.monitoring = false
	_hurtbox.monitorable = true
	add_to_group("wingmen" if faction == "player" else "hostiles")
	_build_visual()


func get_ship_class() -> String:
	return ship_class_name


func is_wingman() -> bool:
	return faction == "player"


# ==========================================================================
# Visuals
# ==========================================================================

func _build_visual() -> void:
	_hull_poly = Polygon2D.new()
	_hull_poly.polygon = Player._hull_shape_for(ship_class_name)
	_hull_poly.color = WINGMAN_COLOR if is_wingman() else KIND_COLORS.get(kind, Color.WHITE)
	add_child(_hull_poly)
	move_child(_hull_poly, 0)

	_beam_line = Line2D.new()
	_beam_line.width = 5.0
	_beam_line.default_color = Color(1.0, 0.3, 0.2, 0.85)
	_beam_line.visible = false
	add_child(_beam_line)


# ==========================================================================
# Frame loop
# ==========================================================================

func _physics_process(delta: float) -> void:
	if not alive:
		return

	if kind == "replicator":
		_fleeing = (hull / maxf(hull_max, 1.0)) < float(behavior.get("flee_hull_frac", 0.3))

	var target := _find_target()
	_tick_timers(delta, target)
	_move(delta, target)


func _find_target() -> Node2D:
	var group := "player_hull" if faction == "hostile" else "enemy_hull"
	var best: Node2D = null
	var best_dist := INF
	for hb in get_tree().get_nodes_in_group(group):
		if not is_instance_valid(hb):
			continue
		var victim = hb.get_parent()
		if victim == null or not is_instance_valid(victim):
			continue
		if "alive" in victim and not victim.alive:
			continue
		if "cloaked" in victim and victim.cloaked:
			continue
		var d := global_position.distance_to(victim.global_position)
		if d < best_dist:
			best_dist = d
			best = victim
	return best


# ==========================================================================
# Movement
# ==========================================================================

func _move(delta: float, target: Node2D) -> void:
	if target == null:
		velocity = velocity.move_toward(Vector2.ZERO, max_speed * delta)
		move_and_slide()
		return

	if kind == "dart" and _diving:
		_move_dart_dive(delta, target)
	elif kind == "replicator" and _fleeing:
		_move_flee(delta, target)
	else:
		_move_orbit(delta, target)
	move_and_slide()


static func _turn_toward(current: float, target: float, max_delta: float) -> float:
	var diff := wrapf(target - current, -PI, PI)
	return current + clampf(diff, -max_delta, max_delta)


func _move_orbit(delta: float, target: Node2D) -> void:
	var to_target := target.global_position - global_position
	var dist := to_target.length()
	var desired_dir: Vector2
	if dist > _keep_dist * 1.08:
		desired_dir = to_target.normalized()
	elif dist < _keep_dist * 0.92:
		desired_dir = -to_target.normalized()
	else:
		desired_dir = to_target.normalized().rotated(PI * 0.5 * _strafe_dir)

	rotation = _turn_toward(rotation, desired_dir.angle(), turn_rate * delta)
	var desired_velocity := Vector2.RIGHT.rotated(rotation) * max_speed * 0.85
	velocity = velocity.move_toward(desired_velocity, max_speed * 2.0 * delta)


func _move_dart_dive(delta: float, target: Node2D) -> void:
	_dive_elapsed += delta
	var desired_angle := (target.global_position - global_position).angle()
	rotation = _turn_toward(rotation, desired_angle, turn_rate * delta)
	velocity = Vector2.RIGHT.rotated(rotation) * max_speed

	var dist := global_position.distance_to(target.global_position)
	if dist < RAM_HIT_RADIUS:
		var dmg := Daedalus.dart_ram_damage(velocity.length())
		if target.has_method("take_damage"):
			target.take_damage(dmg)
		_end_dive()
	elif _dive_elapsed > DIVE_TIMEOUT:
		_end_dive()


func _end_dive() -> void:
	_diving = false
	_dive_elapsed = 0.0
	var dc: Array = behavior.get("dive_cd", [3.0, 5.0])
	_dive_timer = randf_range(float(dc[0]), float(dc[1]))


func _move_flee(delta: float, target: Node2D) -> void:
	var away := (global_position - target.global_position).normalized()
	rotation = _turn_toward(rotation, away.angle(), turn_rate * delta)
	var flee_speed := float(behavior.get("flee_speed", max_speed))
	velocity = velocity.move_toward(Vector2.RIGHT.rotated(rotation) * flee_speed, flee_speed * 2.0 * delta)


# ==========================================================================
# Timers -- firing, diving, spawning, beam cycling
# ==========================================================================

func _tick_timers(delta: float, target: Node2D) -> void:
	if kind == "dart" and bool(behavior.get("dive_enabled", false)) and not _diving:
		_dive_timer -= delta
		if _dive_timer <= 0.0 and target != null:
			_diving = true
			_dive_elapsed = 0.0

	if target == null:
		return

	match kind:
		"fighter":
			_handle_burst_fire(delta, target)
		"capital":
			_handle_burst_fire(delta, target)
			_handle_flak(delta, target)
		"dart":
			if not _diving:
				_handle_single_fire(delta, target)
		"hive":
			_handle_hive_spawn(delta, target)
		"replicator":
			if not _fleeing and not bool(behavior.get("infect_blocked", false)):
				_handle_infection(delta, target)
		"ori":
			_handle_beam_cycle(delta, target)


func _handle_burst_fire(delta: float, target: Node2D) -> void:
	if _burst_remaining <= 0:
		_fire_timer -= delta
		if _fire_timer <= 0.0:
			var burst_min := int(behavior.get("burst_min", 1))
			var burst_max := int(behavior.get("burst_max", 1))
			_burst_remaining = randi_range(mini(burst_min, burst_max), maxi(burst_min, burst_max))
			_burst_shot_timer = 0.0
	else:
		_burst_shot_timer -= delta
		if _burst_shot_timer <= 0.0:
			_fire_gun_at(target)
			_burst_remaining -= 1
			_burst_shot_timer = BURST_ROUND_INTERVAL
			if _burst_remaining <= 0:
				var fc: Array = behavior.get("fire_cd", [1.0, 2.0])
				_fire_timer = randf_range(float(fc[0]), float(fc[1]))


func _handle_flak(delta: float, target: Node2D) -> void:
	_flak_timer -= delta
	if _flak_timer <= 0.0:
		_fire_gun_at(target)
		var fk: Array = behavior.get("flak_cd", [2.5, 4.0])
		_flak_timer = randf_range(float(fk[0]), float(fk[1]))


func _handle_single_fire(delta: float, target: Node2D) -> void:
	_fire_timer -= delta
	if _fire_timer <= 0.0:
		_fire_gun_at(target)
		var fc: Array = behavior.get("fire_cd", [0.5, 0.8])
		_fire_timer = randf_range(float(fc[0]), float(fc[1]))


func _fire_gun_at(target: Node2D) -> void:
	if projectiles_root == null:
		return
	var dir := (target.global_position - _muzzle.global_position).normalized()
	var shot := projectile_scene.instantiate() as Projectile
	projectiles_root.add_child(shot)
	shot.setup({
		"weapon_type": "enemy_gun",
		"attacker_kind": kind,
		"friendly": is_wingman(),
		"position": _muzzle.global_position,
		"direction": dir,
		"ship_velocity": velocity,
	})


func _handle_hive_spawn(delta: float, target: Node2D) -> void:
	var release_range := float(behavior.get("release_range", 300.0))
	var dist := global_position.distance_to(target.global_position)
	if dist <= release_range and _stored_darts > 0:
		var n := _stored_darts
		_stored_darts = 0
		for i in range(n):
			_spawn_dart()
		return
	_spawn_timer -= delta
	if _spawn_timer <= 0.0 and _stored_darts > 0:
		_spawn_dart()
		_stored_darts -= 1
		var sc: Array = behavior.get("spawn_cd", [5.0, 9.0])
		_spawn_timer = randf_range(float(sc[0]), float(sc[1]))


func _spawn_dart() -> void:
	if combatants_root == null:
		return
	var dart := enemy_scene.instantiate() as Enemy
	combatants_root.add_child(dart)
	dart.projectiles_root = projectiles_root
	dart.combatants_root = combatants_root
	dart.setup({
		"kind": "dart",
		"faction": faction,
		"player_key": player_key,
		"position": global_position + Vector2(randf_range(-24.0, 24.0), randf_range(-24.0, 24.0)),
	})


## No projectile object for an infection bolt -- the bolt's payload is not
## kinetic or energy damage (daedalus_ai.nova's gun_dmg is literally 0 for
## this kind), it is a direct increment to the target's infestation meter.
func _handle_infection(delta: float, target: Node2D) -> void:
	_fire_timer -= delta
	if _fire_timer <= 0.0:
		if target.has_method("add_infestation"):
			target.add_infestation(INFECT_STEP)
		var fc: Array = behavior.get("fire_cd", [1.7, 2.3])
		_fire_timer = randf_range(float(fc[0]), float(fc[1]))


func _handle_beam_cycle(delta: float, target: Node2D) -> void:
	if _charging:
		_charge_timer -= delta
		if _charge_timer <= 0.0:
			_charging = false
			_beam_firing = true
			_beam_fire_timer = float(behavior.get("fire_time", 1.5))
	elif _beam_firing:
		_beam_fire_timer -= delta
		var dps := float(behavior.get("beam_dps", 0.0))
		if target.has_method("take_damage"):
			target.take_damage(dps * delta)
		_beam_line.visible = true
		_beam_line.points = PackedVector2Array([Vector2.ZERO, to_local(target.global_position)])
		if _beam_fire_timer <= 0.0:
			_beam_firing = false
			_beam_line.visible = false
			var bc: Array = behavior.get("beam_cooldown", [2.1, 2.6])
			_beam_recharge_timer = randf_range(float(bc[0]), float(bc[1]))
	else:
		_beam_recharge_timer -= delta
		if _beam_recharge_timer <= 0.0:
			_charging = true
			_charge_timer = float(behavior.get("charge_time", 1.2))


# ==========================================================================
# Damage / death
# ==========================================================================

func take_damage(amount: float) -> void:
	if not alive or amount <= 0.0:
		return
	var remaining := amount
	if shield > 0.0:
		var absorbed := minf(shield, remaining)
		shield -= absorbed
		remaining -= absorbed
	if remaining > 0.0:
		hull -= remaining
	if hull <= 0.0:
		_die()


func _die() -> void:
	if not alive:
		return
	alive = false
	AudioBus.play_explosion()
	var score := int(behavior.get("score", 0))
	died.emit(kind, score, is_wingman())
	queue_free()
