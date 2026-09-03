class_name WeaponsBridge
extends Node

## Loads weapon systems out of NovaLang into typed GDScript.
##
## Stage 3 of the conversion. daedalus_weapons.nova is the authority for
## ballistics, energy cost, and every damage-shaping curve (blast falloff,
## splash falloff, beam ramp, the beam's own class multiplier table,
## homing turn-rate reactions); this node loads it standalone -- exactly
## like AIBridge loads daedalus_ai.nova -- and caches its tables and
## formulas into GDScript.
##
## What this bridge does NOT do: resolve a ship key into a raw per-shot
## damage figure or apply Stage 1's class-vs-class matrix. daedalus_
## weapons.nova cannot do that either -- it takes no ship key anywhere, by
## design, so it stays importable with no risk of a cycle with
## daedalus_rules.nova. The one function that needs both SHIPS and the
## weapons module is fire_weapon(), and it lives on DaedalusBridge, which
## already owns the loaded daedalus_rules.nova VM:
##
##     var daedalus := DaedalusBridge.new()
##     add_child(daedalus); daedalus.load_rules()
##     var result := daedalus.fire_weapon("primary", "x302", "capital", 0.0)
##
## What THIS bridge is for: everything that does not need a ship key.
##
##     var weapons := WeaponsBridge.new()
##     add_child(weapons)
##     if weapons.load_weapons():
##         var range := weapons.effective_range("rocket")
##         var dps := weapons.beam_dps(2431.0, elapsed, "fighter")   # per-frame, no interpreter call
##         var shot := weapons.fire_ballistic("primary", 12.3, 1.0, 0.0)  # per-shot, real interpreter call
##
## Two calls in this file run every frame a weapon is doing something
## (beam_dps while a beam is firing, falloff_damage when a splash hits
## several targets in the same instant), so both are reimplemented here in
## GDScript against the cached tables and cross-checked at load time
## against a fresh NovaLang call, exactly like Stage 1's
## damage_multiplier(). fire_ballistic()/fire_beam() are not hot -- bounded
## by weapon cooldowns, the same order of magnitude as the reactor's 20 Hz
## tick -- so they stay real interpreter calls.

signal weapons_loaded(info: Dictionary)
signal load_failed(message: String)

const RULES_PATH := "daedalus_weapons.nova"

const TARGET_CLASSES := ["fighter", "battlecruiser", "capital"]

## Every field a weapon's cached stat block may carry, across all six
## kinds, used only by the self-check -- a field silently absent from a
## future edit is caught at load time rather than at first use.
const WEAPON_FIELDS := [
	"name", "role", "velocity", "lifetime", "cooldown", "spread_deg",
	"energy_cost", "projectile_radius", "blast_radius", "blast_falloff",
	"turn_rate", "acquire_range", "splash_radius", "splash_falloff",
	"salvo_overrides", "ramp_time", "max_range", "beam_width",
	"energy_drain", "min_energy", "class_multiplier", "port_count",
	"twin_bolts", "energy_cost_per_bolt", "turret_count", "range", "damage",
]

var vm: NovaVM = null
var ready := false
var error := ""

var weapon_order: Array = []
var weapons: Dictionary = {}          # weapon_type -> cached stat block

## Cached beam class multipliers and ramp_time, read out once so beam_dps()
## never touches the interpreter.
var _beam_ramp_time := 0.0
var _beam_class_multiplier: Dictionary = {}

## Cached homing turn-rate reaction factors -- 1.0 for battlecruiser (the
## neutral case), read out once for the same reason.
var _homing_base_turn_rate := 0.0
var _homing_turn_factor: Dictionary = {}


# ==========================================================================
# Loading
# ==========================================================================

func load_weapons(path: String = RULES_PATH) -> bool:
	error = ""
	ready = false

	vm = NovaVM.new()
	if not vm.load_file(path):
		return _abort("NovaLang: " + vm.error)

	_cache_weapons()
	if error != "":
		return _abort(error)

	_cache_beam()
	_cache_homing()
	if error != "":
		return _abort(error)

	_self_check()
	if error != "":
		return _abort(error)

	ready = true
	weapons_loaded.emit(summary())
	return true


func _abort(message: String) -> bool:
	error = message
	ready = false
	push_error("[WeaponsBridge] " + error)
	load_failed.emit(error)
	return false


# ==========================================================================
# Caching
# ==========================================================================

func _cache_weapons() -> void:
	var raw = vm.get_global("WEAPONS", null)
	if typeof(raw) != TYPE_DICTIONARY:
		error = "WEAPONS is missing or not a dict"
		return
	var order = vm.get_global("WEAPON_ORDER", null)
	weapon_order = order if typeof(order) == TYPE_ARRAY else (raw as Dictionary).keys()

	weapons = {}
	for weapon_type in (raw as Dictionary):
		weapons[String(weapon_type)] = (raw as Dictionary)[weapon_type].duplicate(true)

	for weapon_type in weapon_order:
		if not weapons.has(String(weapon_type)):
			error = "WEAPON_ORDER names '%s', which is not in WEAPONS" % weapon_type
			return


func _cache_beam() -> void:
	var beam: Dictionary = weapons.get("beam", {})
	_beam_ramp_time = float(beam.get("ramp_time", 0.0))
	_beam_class_multiplier = {}
	var mult = beam.get("class_multiplier", {})
	if typeof(mult) == TYPE_DICTIONARY:
		for cls in (mult as Dictionary):
			_beam_class_multiplier[String(cls)] = float((mult as Dictionary)[cls])


func _cache_homing() -> void:
	var homing: Dictionary = weapons.get("homing", {})
	_homing_base_turn_rate = float(homing.get("turn_rate", 0.0))
	# 212.4 baseline, +14% vs a fighter, -11% vs a capital, unmodified vs a
	# battlecruiser -- the reaction factors themselves are not exposed by
	# daedalus_weapons.nova as data (they are inlined in
	# homing_turn_rate()'s logic), so this bridge names them once, here,
	# and the self-check below is what keeps them honest against the
	# actual NovaLang formula rather than trusting they were transcribed
	# correctly.
	_homing_turn_factor = {"fighter": 1.14, "battlecruiser": 1.0, "capital": 0.89}


func _self_check() -> void:
	for weapon_type in weapon_order:
		var w: Dictionary = weapons[String(weapon_type)]
		# The reverse of the usual "is a field missing" check: WEAPON_FIELDS
		# is the union across all six kinds, so no single weapon needs all
		# of it, but every field it DOES carry must be one this bridge
		# knows about -- otherwise a stat added to daedalus_weapons.nova
		# would silently never reach projectile_stats() callers who expect
		# WEAPON_FIELDS to be a complete list.
		for field in w:
			if not WEAPON_FIELDS.has(field):
				error = "WEAPONS.%s has an unrecognised field '%s' -- " 						% [weapon_type, field] + 						"add it to WeaponsBridge.WEAPON_FIELDS"
				return
		var fast_range := effective_range(String(weapon_type))
		var slow_range := float(vm.call_function("effective_range", [String(weapon_type)]))
		if not is_equal_approx(maxf(fast_range, 1e-9), maxf(slow_range, 1e-9)):
			error = "effective_range(%s): cached %f but NovaLang says %f" \
					% [weapon_type, fast_range, slow_range]
			return

	for cls in TARGET_CLASSES:
		var fast_turn := homing_turn_rate(cls)
		var slow_turn := float(vm.call_function("homing_turn_rate", [cls]))
		if not is_equal_approx(fast_turn, slow_turn):
			error = "homing_turn_rate(%s): cached %f but NovaLang says %f" \
					% [cls, fast_turn, slow_turn]
			return

		for elapsed in [0.0, 0.71, 1.42, 3.0]:
			var fast_dps := beam_dps(2431.0, elapsed, cls)
			var slow_dps := float(vm.call_function("beam_damage_per_second",
					[2431.0, elapsed, cls]))
			if not is_equal_approx(maxf(fast_dps, 1e-9), maxf(slow_dps, 1e-9)):
				error = "beam_dps(2431, %s, %s): cached %f but NovaLang says %f" \
						% [elapsed, cls, fast_dps, slow_dps]
				return

	for sample in [[100.0, 0.0, 97.4, 0.37], [100.0, 48.7, 97.4, 0.37],
			[100.0, 97.4, 97.4, 0.37], [100.0, 200.0, 97.4, 0.37]]:
		var fast_fall := falloff_damage(sample[0], sample[1], sample[2], sample[3])
		var slow_fall := float(vm.call_function("falloff_damage", sample))
		if not is_equal_approx(maxf(fast_fall, 1e-9), maxf(slow_fall, 1e-9)):
			error = "falloff_damage%s: cached %f but NovaLang says %f" \
					% [sample, fast_fall, slow_fall]
			return

	for key in ["aurora", "atlantis", "daedalus"]:
		var fast_salvo := homing_salvo_size(key)
		var slow_salvo := int(vm.call_function("homing_salvo_size", [key]))
		if fast_salvo != slow_salvo:
			error = "homing_salvo_size(%s): cached %d but NovaLang says %d" \
					% [key, fast_salvo, slow_salvo]
			return


# ==========================================================================
# Stat queries
# ==========================================================================

func weapon_stat(weapon_type: String, stat_name: String, fallback: float = 0.0) -> float:
	var w: Dictionary = weapons.get(weapon_type, {})
	if not w.has(stat_name):
		return fallback
	var v = w[stat_name]
	return float(v) if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) else fallback


func weapon_name(weapon_type: String) -> String:
	return String(weapons.get(weapon_type, {}).get("name", weapon_type))


## Everything Godot's spawner needs to instantiate a projectile: velocity,
## lifetime, cooldown, spread, energy cost, and its collision radius. Not
## every weapon carries every field (a beam has no projectile_radius; a
## turret has no spread_deg) -- callers read what applies to the kind they
## asked about.
func projectile_stats(weapon_type: String) -> Dictionary:
	return weapons.get(weapon_type, {}).duplicate(true)


## How far a shot can reach before it is out of the question entirely --
## an explicit range/acquire_range stat where one exists, otherwise
## velocity * lifetime (how far the round can physically fly before it
## expires). Cached; cross-checked against daedalus_weapons.nova at load.
func effective_range(weapon_type: String) -> float:
	match weapon_type:
		"homing":
			return weapon_stat("homing", "acquire_range")
		"beam":
			return weapon_stat("beam", "max_range")
		"turret":
			return weapon_stat("turret", "range")
	return weapon_stat(weapon_type, "velocity") * weapon_stat(weapon_type, "lifetime")


func homing_salvo_size(ship_key: String) -> int:
	var overrides: Dictionary = weapons.get("homing", {}).get("salvo_overrides", {})
	return int(overrides.get(ship_key, 1))


## Missile turn authority against `target_class`, resolved once at
## lock-on -- not a per-frame call in practice, but cheap enough (and
## cached) that calling it every frame would not be a problem either.
func homing_turn_rate(target_class: String) -> float:
	var factor: float = _homing_turn_factor.get(target_class, 1.0)
	return _homing_base_turn_rate * factor


# ==========================================================================
# Damage shaping -- cached fast paths (the genuine per-frame hot calls)
# ==========================================================================

## Linear falloff within `radius`, zero beyond it. Generic: used for both
## rocket blast and homing splash, and safe to call for every simultaneous
## splash victim of one hit without touching the interpreter.
func falloff_damage(base_dmg: float, distance: float, radius: float,
		falloff: float) -> float:
	if radius <= 0.0:
		return base_dmg
	if distance > radius:
		return 0.0
	var ratio := distance / radius
	return base_dmg * (1.0 - ratio * falloff)


## Fraction of full beam output at `elapsed` seconds into a continuous
## burn: 60% at ignition, ramping linearly to 100% at ramp_time, held
## there after.
func beam_ramp_frac(elapsed: float) -> float:
	# The `_beam_ramp_time <= 0.0` half of this guard has no counterpart in
	# daedalus_weapons.nova's own beam_ramp_frac() -- it exists only so a
	# misconfigured ramp_time of zero can't divide by it below. ramp_time
	# is always 1.42 in the real data, so this never changes the result
	# for any input the self-check or the game actually exercises.
	if _beam_ramp_time <= 0.0 or elapsed >= _beam_ramp_time:
		return 1.0
	if elapsed <= 0.0:
		return 0.6
	return 0.6 + 0.4 * (elapsed / _beam_ramp_time)


func beam_class_multiplier(target_class: String) -> float:
	return float(_beam_class_multiplier.get(target_class, 1.0))


## Damage per second of beam contact right now. Called every frame a beam
## is firing -- reads only cached numbers, no interpreter call, which is
## what makes that safe. Unlike fire_beam() below, this does not gate on
## "is there actually a target" (an empty target_class quietly resolves to
## a 1.0 multiplier, not zero) -- it is a pure formula, matching
## daedalus_weapons.nova's own beam_damage_per_second(). Only call it once
## per frame *while a beam is confirmed to be hitting something*; use
## fire_beam() to make that determination in the first place.
func beam_dps(base_dps: float, elapsed: float, target_class: String) -> float:
	return base_dps * beam_ramp_frac(elapsed) * beam_class_multiplier(target_class)


# ==========================================================================
# Fire resolution -- not hot, real interpreter calls (bounded by cooldown)
# ==========================================================================

## Primary / Rocket / Homing / Omni / Turret, given an already-resolved
## raw damage figure and class multiplier. For the ship-aware version that
## resolves both of those for you, see DaedalusBridge.fire_weapon().
func fire_ballistic(weapon_type: String, raw_damage: float, class_mult: float,
		distance: float) -> Dictionary:
	if not ready:
		return {"hit": false, "damage_dealt": 0.0, "effect": "not loaded"}
	var result = vm.call_function("fire_ballistic",
			[weapon_type, raw_damage, class_mult, distance])
	return result if typeof(result) == TYPE_DICTIONARY else \
			{"hit": false, "damage_dealt": 0.0, "effect": "bridge error"}


## The beam, given an already-resolved base_dps (Stage 1's SHIPS.<key>.
## beam_dmg). Resolves its own class multiplier internally -- see the
## file header on why the beam does not take one as a parameter the way
## fire_ballistic() does.
func fire_beam(base_dps: float, target_class: String, distance: float,
		elapsed: float) -> Dictionary:
	if not ready:
		return {"hit": false, "damage_dealt": 0.0, "effect": "not loaded"}
	var result = vm.call_function("fire_beam",
			[base_dps, target_class, distance, elapsed])
	return result if typeof(result) == TYPE_DICTIONARY else \
			{"hit": false, "damage_dealt": 0.0, "effect": "bridge error"}


# ==========================================================================
# Reporting
# ==========================================================================

func summary() -> Dictionary:
	var d := vm.describe() if vm != null else {}
	return {
		"ok": ready,
		"title": d.get("title", ""),
		"version": d.get("version", 0),
		"weapon_count": weapon_order.size(),
		"error": error,
	}


func debug_print() -> void:
	if not ready:
		print("[WeaponsBridge] NOT LOADED: ", error)
		return
	print("[WeaponsBridge] %s v%d -- %d weapons"
			% [summary()["title"], summary()["version"], summary()["weapon_count"]])
	for weapon_type in weapon_order:
		print("  %-8s %-28s range %8.1f  cooldown %.3fs  energy %.1f"
				% [weapon_type, weapon_name(String(weapon_type)),
				   effective_range(String(weapon_type)),
				   weapon_stat(String(weapon_type), "cooldown"),
				   weapon_stat(String(weapon_type), "energy_cost")])
	for cls in TARGET_CLASSES:
		print("  homing turn_rate vs %-13s %.2f deg/s   beam dps (Daedalus, full ramp) vs %-13s %.1f"
				% [cls, homing_turn_rate(cls), cls, beam_dps(2431.0, 1.42, cls)])
