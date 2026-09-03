class_name Projectile
extends Area2D

## One projectile: primary/rocket/homing/omni/turret player shots, or a
## generic hostile gun round ("enemy_gun", the one weapon_type that is not
## a daedalus_weapons.nova key -- hostile guns have no ballistics table of
## their own, only a gun_dmg scalar; see daedalus_ai.nova's own note that
## Stage 3's ballistics spec covers player weapons only).
##
## Position/velocity integration, collision and particles are entirely
## this file's job, never NovaLang's -- exactly the split established in
## Stages 1-3. What NovaLang decides is how much damage lands: every hit,
## direct or splash, is resolved through Daedalus.fire_weapon() (or
## Daedalus.enemy_weapon_damage() for a hostile round), never computed
## here. That keeps the falloff formula, the class-scaling matrix and the
## beam's own table declared exactly once, in one place, for the whole
## game -- this script only asks "how much" and applies the answer.
##
## Physics layers (see project.godot's [layer_names]):
##   1 player_hull   2 enemy_hull   3 player_shot   4 enemy_shot
## A friendly shot's mask is enemy_hull only; a hostile shot's mask is
## player_hull only -- there is no friendly fire, and a projectile can
## never even receive an area_entered for the wrong side.

const LAYER_PLAYER_HULL := 1
const LAYER_ENEMY_HULL := 2
const LAYER_PLAYER_SHOT := 4
const LAYER_ENEMY_SHOT := 8

const INHERIT_FACTOR := 0.25   # how much of the firing ship's own velocity carries into the shot

const ENEMY_GUN_VELOCITY := 700.0
const ENEMY_GUN_LIFETIME := 2.2
const ENEMY_GUN_RADIUS := 3.0

const WEAPON_COLORS := {
	"primary": Color(0.36, 0.78, 1.0),
	"rocket": Color(1.0, 0.55, 0.2),
	"homing": Color(1.0, 0.85, 0.25),
	"omni": Color(0.55, 0.85, 1.0),
	"turret": Color(0.7, 0.9, 0.5),
	"enemy_gun": Color(1.0, 0.3, 0.3),
}

var weapon_type := "primary"
var attacker_key := ""      # player ship key -- empty for a hostile round
var attacker_kind := ""     # hostile kind -- empty for a player round
var friendly := true

var velocity := Vector2.ZERO
var life := 2.0
var age := 0.0
var radius := 3.0
var blast_radius := 0.0
var color := Color.WHITE

var target: Node2D = null   # homing only
var turn_rate := 0.0        # rad/s, homing only

var _spawn_pos := Vector2.ZERO
var _spent := false
var _trail: GPUParticles2D = null


func setup(cfg: Dictionary) -> void:
	weapon_type = String(cfg.get("weapon_type", "primary"))
	attacker_key = String(cfg.get("attacker_key", ""))
	attacker_kind = String(cfg.get("attacker_kind", ""))
	friendly = bool(cfg.get("friendly", true))
	target = cfg.get("target", null)

	global_position = cfg.get("position", Vector2.ZERO)
	_spawn_pos = global_position
	var dir: Vector2 = (cfg.get("direction", Vector2.RIGHT) as Vector2).normalized()
	var ship_velocity: Vector2 = cfg.get("ship_velocity", Vector2.ZERO)

	if weapon_type == "enemy_gun":
		velocity = dir * ENEMY_GUN_VELOCITY
		life = ENEMY_GUN_LIFETIME
		radius = ENEMY_GUN_RADIUS
		blast_radius = 0.0
	else:
		var stats := Daedalus.projectile_stats(weapon_type)
		var spd := float(stats.get("velocity", 400.0))
		velocity = dir * spd + ship_velocity * INHERIT_FACTOR
		life = float(stats.get("lifetime", 2.0))
		radius = maxf(float(stats.get("projectile_radius", 3.0)), 1.5)
		blast_radius = float(stats.get("blast_radius", stats.get("splash_radius", 0.0)))

	color = WEAPON_COLORS.get(weapon_type, Color.WHITE)
	rotation = velocity.angle()

	if weapon_type == "homing" and target != null and is_instance_valid(target):
		var target_class := "battlecruiser"
		if target.has_method("get_ship_class"):
			target_class = target.get_ship_class()
		turn_rate = deg_to_rad(Daedalus.homing_turn_rate(target_class))

	_configure_visual()
	_configure_collision()


func _configure_visual() -> void:
	var poly := Polygon2D.new()
	var r := radius
	poly.polygon = PackedVector2Array([
		Vector2(r * 2.2, 0.0), Vector2(-r, r), Vector2(-r * 0.3, 0.0), Vector2(-r, -r),
	])
	poly.color = color
	add_child(poly)

	if weapon_type == "rocket" or weapon_type == "homing":
		_trail = GPUParticles2D.new()
		_trail.amount = 24
		_trail.lifetime = 0.6
		_trail.local_coords = false
		_trail.texture = PlaceholderGfx.dot_texture(5, Color(0.7, 0.7, 0.7, 0.6))
		var mat := ParticleProcessMaterial.new()
		mat.direction = Vector3(-1, 0, 0)
		mat.spread = 12.0
		mat.gravity = Vector3.ZERO
		mat.initial_velocity_min = 8.0
		mat.initial_velocity_max = 24.0
		mat.scale_min = 0.6
		mat.scale_max = 1.3
		mat.color = Color(1, 1, 1, 0.5)
		_trail.process_material = mat
		_trail.emitting = true
		add_child(_trail)


func _configure_collision() -> void:
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = radius
	shape.shape = circle
	add_child(shape)

	monitoring = true
	monitorable = false
	if friendly:
		collision_layer = LAYER_PLAYER_SHOT
		collision_mask = LAYER_ENEMY_HULL
	else:
		collision_layer = LAYER_ENEMY_SHOT
		collision_mask = LAYER_PLAYER_HULL
	area_entered.connect(_on_area_entered)


func _physics_process(delta: float) -> void:
	age += delta

	if turn_rate > 0.0 and target != null and is_instance_valid(target):
		var desired := (target.global_position - global_position).angle()
		var current := velocity.angle()
		var diff := wrapf(desired - current, -PI, PI)
		var max_delta := turn_rate * delta
		var new_angle := current + clampf(diff, -max_delta, max_delta)
		velocity = Vector2.RIGHT.rotated(new_angle) * velocity.length()

	global_position += velocity * delta
	rotation = velocity.angle()

	if age >= life and not _spent:
		_expire()


func _on_area_entered(area: Area2D) -> void:
	if _spent:
		return
	_spent = true
	if blast_radius > 0.0:
		_detonate(global_position)
	else:
		_direct_hit(area)
	queue_free()


## No target within the lifetime: rockets and homing missiles proximity-
## detonate in place (still splashing anything nearby); a direct-fire
## round is just a clean miss, marked only by a small fade.
func _expire() -> void:
	_spent = true
	if blast_radius > 0.0:
		_detonate(global_position)
	else:
		_spawn_burst(global_position, 0.0, false)
	queue_free()


func _direct_hit(area: Area2D) -> void:
	var victim := area.get_parent()
	if victim == null or not is_instance_valid(victim) or not victim.has_method("take_damage"):
		return
	var target_class: String = victim.get_ship_class() if victim.has_method("get_ship_class") else "fighter"
	var damage := 0.0
	if weapon_type == "enemy_gun":
		# Generalised so this covers both directions with one formula: a
		# hostile shooting the player, and a wingman (a "fighter"-kind
		# hostile stat block flying under the player's colours) shooting a
		# hostile back. effective_damage(raw, attacker_class, target_class)
		# is exactly what enemy_weapon_damage() computes when the defender
		# is a player ship -- this is that same formula, just accepting
		# any target's class rather than assuming one is a SHIPS key.
		var raw := Daedalus.enemy_stat(attacker_kind, "gun_dmg", 0.0)
		var attacker_class := Daedalus.enemy_class(attacker_kind)
		damage = Daedalus.effective_damage(raw, attacker_class, target_class)
		victim.take_damage(damage)
	else:
		var dist := _spawn_pos.distance_to(global_position)
		var result := Daedalus.fire_weapon(weapon_type, attacker_key, target_class, dist, 0.0)
		if bool(result.get("hit", false)):
			damage = float(result.get("damage_dealt", 0.0))
			victim.take_damage(damage)
	_spawn_burst(global_position, damage, damage > 0.0)


## Rocket/homing blast: every hull of the opposing side within blast_radius
## takes its own falloff-scaled hit, resolved by one fire_weapon() call per
## victim -- see the file header on why that call already includes both
## the falloff curve and the class-scaling matrix, so nothing here needs
## to reimplement either.
func _detonate(center: Vector2) -> void:
	if weapon_type == "enemy_gun":
		_spawn_burst(center, 0.0, false)
		return
	var group := "enemy_hull" if friendly else "player_hull"
	var best_damage := 0.0
	var hit_any := false
	for hb in get_tree().get_nodes_in_group(group):
		if not is_instance_valid(hb):
			continue
		var dist := center.distance_to(hb.global_position)
		if dist > blast_radius:
			continue
		var victim = hb.get_parent()
		if victim == null or not is_instance_valid(victim) or not victim.has_method("take_damage"):
			continue
		var target_class: String = victim.get_ship_class() if victim.has_method("get_ship_class") else "fighter"
		var result := Daedalus.fire_weapon(weapon_type, attacker_key, target_class, dist, 0.0)
		if bool(result.get("hit", false)):
			var dealt := float(result.get("damage_dealt", 0.0))
			victim.take_damage(dealt)
			best_damage = maxf(best_damage, dealt)
			hit_any = true
	_spawn_burst(center, best_damage, hit_any)


## Impact particles sized by damage dealt; a "no damage landed" burst
## (a clean miss's fade, or a blast with nothing in range) is small and
## dim rather than skipped outright, so a rocket that detonates on empty
## space still reads as an explosion.
func _spawn_burst(pos: Vector2, damage: float, hit: bool) -> void:
	if hit and damage > 0.0:
		AudioBus.play_explosion()
	var burst := GPUParticles2D.new()
	burst.one_shot = true
	burst.explosiveness = 1.0
	burst.lifetime = 0.5
	burst.amount = clampi(int(8 + damage * 0.15), 6, 64)
	var burst_color := color if hit else Color(0.6, 0.6, 0.6, 0.5)
	burst.texture = PlaceholderGfx.dot_texture(7, burst_color)

	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 0, 0)
	mat.spread = 180.0
	mat.gravity = Vector3.ZERO
	mat.initial_velocity_min = 30.0
	mat.initial_velocity_max = 40.0 + clampf(damage, 0.0, 260.0)
	mat.scale_min = 0.4
	mat.scale_max = 1.0 + clampf(damage / 120.0, 0.0, 3.0)
	burst.process_material = mat

	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	scene_root.add_child(burst)
	burst.global_position = pos
	burst.emitting = true
	get_tree().create_timer(burst.lifetime + 0.3).timeout.connect(burst.queue_free)
