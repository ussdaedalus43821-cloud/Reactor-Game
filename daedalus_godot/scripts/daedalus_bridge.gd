class_name DaedalusBridge
extends Node

## The one NovaLang bridge for the whole game -- ships, enemy AI, weapons,
## power, sectors and the live tactical advisor, all through a single
## loaded daedalus_rules.nova.
##
## This is an autoload singleton (see project.godot's [autoload] section,
## name "Daedalus"), so it loads once when the game starts and survives
## every scene change -- the title screen, ship select, a run in progress
## and the pause menu all share the exact same NovaVM. That is also what
## makes "Resume" on the title screen possible without re-deriving
## anything: GameState (scripts/game_state.gd) snapshots the *player's*
## numbers, not the interpreter's, because the interpreter never went away.
##
## Stage 1-3 of the NovaLang conversion shipped three separate bridges
## (DaedalusBridge / AIBridge / WeaponsBridge) because each one loaded its
## own NovaVM to demonstrate that daedalus_ai.nova and daedalus_weapons.nova
## are standalone, ship-registry-agnostic modules. That property still
## holds here -- this file does not change either .nova file's design, only
## how many VMs load them. One playable game only ever needs the composed
## view daedalus_rules.nova already builds (`import ... as ai`,
## `import ... as weapons`), so this bridge loads exactly one VM and adds
## two re-exports to its own copy of daedalus_rules.nova
## (`let ENEMY = ai.ENEMY` and `let WEAPONS = weapons.WEAPONS`, both no-op
## aliases of already-exported dicts) so the full raw tables are reachable
## from one vm.get_global() each, the same way SHIPS always was.
##
## Hot path / cold path follows the exact rule Stage 1-3 established:
## per-frame formulas (damage_multiplier, beam DPS, blast/splash falloff,
## power_balance, hostiles_for) are cached GDScript, cross-checked against
## a fresh NovaLang call at load time; per-shot or per-spawn calls
## (fire_weapon, enemy_behavior, dart_ram_damage -- all bounded by a
## cooldown, a spawn timer or a single collision event) stay real
## interpreter calls.
##
##     Daedalus.get_ship_stats("daedalus")
##     Daedalus.get_enemy_behavior("dart", "atlantis")     # player_key, not class
##     Daedalus.fire_weapon("rocket", "daedalus", "fighter", 97.4)
##     Daedalus.fire_weapon_at("beam", "daedalus", "capital", enemy.global_position,
##             global_position, Vector2.RIGHT, beam_elapsed)

signal data_loaded(info: Dictionary)
signal load_failed(message: String)

const RULES_PATH := "daedalus_rules.nova"
const NOVA_DIR := "res://scripts_nova/"

const STAT_KEYS := [
	"shield", "hull", "speed", "turn",
	"gun_dmg", "rocket_dmg", "homing_dmg", "beam_dmg",
]

const TARGET_CLASSES := ["fighter", "battlecruiser", "capital"]

const WEAPON_FIELDS := [
	"name", "role", "velocity", "lifetime", "cooldown", "spread_deg",
	"energy_cost", "projectile_radius", "blast_radius", "blast_falloff",
	"turn_rate", "acquire_range", "splash_radius", "splash_falloff",
	"salvo_overrides", "ramp_time", "max_range", "beam_width",
	"energy_drain", "min_energy", "class_multiplier", "port_count",
	"twin_bolts", "energy_cost_per_bolt", "turret_count", "range", "damage",
]

## Vocabulary daedalus_rules.nova's advisor `then` blocks may call. Only
## log() and alarm() are actually used by the current rule set; the rest
## are registered as harmless no-ops so a future edit that reaches for one
## (matching reactor_rules.nova's vocabulary) never fails to parse.
const HOST_FUNCTIONS := [
	"log", "alarm", "scram", "reset_trip", "meltdown", "victory",
	"inject_fault", "clear_fault",
]

var vm: NovaVM = null
var ready := false
var error := ""

# -- ships -------------------------------------------------------------
var ships: Dictionary = {}
var ship_order: Array = []
var damage_scaling: Dictionary = {}

# -- enemies (Stage 2) ---------------------------------------------------
var enemy_order: Array = []
var enemy_stats: Dictionary = {}

# -- weapons (Stage 3) ----------------------------------------------------
var weapon_order: Array = []
var weapons: Dictionary = {}
var _beam_ramp_time := 0.0
var _beam_class_multiplier: Dictionary = {}
var _homing_base_turn_rate := 0.0
var _homing_turn_factor: Dictionary = {"fighter": 1.14, "battlecruiser": 1.0, "capital": 0.89}

# -- power ------------------------------------------------------------
var power: Dictionary = {}
var _power_cache: Dictionary = {}   # "t1c1s1" style key -> net /s

# -- sectors ------------------------------------------------------------
var danger_bands: Array = []
var sectors: Array = []
var _sector_by_key: Dictionary = {}

# -- advisor / encounter director (live rule engine) ----------------------
var events: Array = []
var _t_elapsed := 0.0
var _alarm_level := 0
var _alarm_text := ""


func _ready() -> void:
	load_rules()


# ==========================================================================
# Loading
# ==========================================================================

func load_rules(path: String = RULES_PATH) -> bool:
	error = ""
	ready = false
	events.clear()
	_t_elapsed = 0.0

	vm = NovaVM.new(null, Callable(), NOVA_DIR)
	for fn_name in HOST_FUNCTIONS:
		vm.register_function(String(fn_name), _host_fn(String(fn_name)))

	if not vm.load_file(path):
		return _abort("NovaLang: " + vm.error)

	_cache_ships()
	_cache_damage_scaling()
	_cache_enemy()
	_cache_weapons()
	_cache_beam()
	_cache_homing()
	_cache_power()
	_cache_danger()
	_cache_sectors()
	if error != "":
		return _abort(error)

	_self_check()
	if error != "":
		return _abort(error)

	ready = true
	data_loaded.emit(summary())
	return true


func _abort(message: String) -> bool:
	error = message
	ready = false
	push_error("[DaedalusBridge] " + error)
	load_failed.emit(error)
	return false


func _fail(message: String) -> void:
	if error == "":
		error = message


func _require(source: Dictionary, keys: Array, where: String) -> bool:
	var missing: Array = []
	for key in keys:
		if not source.has(key):
			missing.append(key)
	if missing.is_empty():
		return true
	_fail("%s is missing %s" % [where, ", ".join(PackedStringArray(missing))])
	return false


# ==========================================================================
# Host functions -- the advisor's vocabulary
# ==========================================================================

func _host_fn(name: String) -> Callable:
	match name:
		"log":
			return _fn_log
		"alarm":
			return _fn_alarm
	return func(_args: Array): return null


static func _arg_text(args: Array, index: int, fallback: String = "") -> String:
	return NovaEvaluator.text(args[index]) if args.size() > index else fallback


func _fn_log(args: Array):
	events.append(_arg_text(args, 0))
	return null


func _fn_alarm(args: Array):
	if args.is_empty():
		return null
	var level := int(NovaEvaluator.to_number(args[0]))
	if level > _alarm_level:
		_alarm_level = level
		_alarm_text = _arg_text(args, 1)
	return null


# ==========================================================================
# Caching: ships
# ==========================================================================

func _cache_ships() -> void:
	var raw = vm.get_global("SHIPS", null)
	if typeof(raw) != TYPE_DICTIONARY:
		_fail("SHIPS is missing or not a dict")
		return
	var table: Dictionary = raw

	var order = vm.get_global("SHIP_ORDER", null)
	ship_order = order if typeof(order) == TYPE_ARRAY else table.keys()

	ships = {}
	for key in table:
		if typeof(table[key]) != TYPE_DICTIONARY:
			_fail("SHIPS.%s is not a dict" % key)
			continue
		var src: Dictionary = table[key]
		if not _require(src, STAT_KEYS + ["name", "class", "hardened"],
				"SHIPS.%s" % key):
			continue
		var entry := {
			"key": String(key),
			"name": String(src["name"]),
			"class": String(src["class"]),
			"hardened": bool(src["hardened"]),
		}
		for stat_name in STAT_KEYS:
			entry[stat_name] = float(src[stat_name])
		ships[String(key)] = entry

	for key in ship_order:
		if not ships.has(String(key)):
			_fail("SHIP_ORDER names '%s', which is not in SHIPS" % key)


func _cache_damage_scaling() -> void:
	var raw = vm.get_global("DAMAGE_SCALING", null)
	if typeof(raw) != TYPE_DICTIONARY:
		_fail("DAMAGE_SCALING is missing or not a dict")
		return
	damage_scaling = {}
	for attacker in (raw as Dictionary):
		var row = (raw as Dictionary)[attacker]
		if typeof(row) != TYPE_DICTIONARY:
			_fail("DAMAGE_SCALING.%s is not a dict" % attacker)
			continue
		var out: Dictionary = {}
		for defender in (row as Dictionary):
			out[String(defender)] = float((row as Dictionary)[defender])
		damage_scaling[String(attacker)] = out


# ==========================================================================
# Caching: enemies (Stage 2)
# ==========================================================================

func _cache_enemy() -> void:
	var raw = vm.get_global("ENEMY", null)
	if typeof(raw) != TYPE_DICTIONARY:
		_fail("ENEMY is missing or not a dict (needs the Stage 4 `let ENEMY " +
				"= ai.ENEMY` re-export in daedalus_rules.nova)")
		return
	var order = vm.get_global("ENEMY_ORDER", null)
	enemy_order = order if typeof(order) == TYPE_ARRAY else (raw as Dictionary).keys()

	enemy_stats = {}
	for kind in (raw as Dictionary):
		enemy_stats[String(kind)] = (raw as Dictionary)[kind].duplicate(true)

	for kind in enemy_order:
		if not enemy_stats.has(String(kind)):
			_fail("ENEMY_ORDER names '%s', which is not in ENEMY" % kind)


# ==========================================================================
# Caching: weapons (Stage 3)
# ==========================================================================

func _cache_weapons() -> void:
	var raw = vm.get_global("WEAPONS", null)
	if typeof(raw) != TYPE_DICTIONARY:
		_fail("WEAPONS is missing or not a dict (needs the Stage 4 `let " +
				"WEAPONS = weapons.WEAPONS` re-export in daedalus_rules.nova)")
		return
	var order = vm.get_global("WEAPON_ORDER", null)
	weapon_order = order if typeof(order) == TYPE_ARRAY else (raw as Dictionary).keys()

	weapons = {}
	for weapon_type in (raw as Dictionary):
		weapons[String(weapon_type)] = (raw as Dictionary)[weapon_type].duplicate(true)

	for weapon_type in weapon_order:
		if not weapons.has(String(weapon_type)):
			_fail("WEAPON_ORDER names '%s', which is not in WEAPONS" % weapon_type)


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
	# The reaction factors themselves are not exposed as data by
	# daedalus_weapons.nova (they are inlined in homing_turn_rate()'s own
	# logic), so this bridge names them once, here -- the self-check below
	# is what keeps them honest against the real formula.
	_homing_turn_factor = {"fighter": 1.14, "battlecruiser": 1.0, "capital": 0.89}


# ==========================================================================
# Caching: power
# ==========================================================================

func _cache_power() -> void:
	var raw = vm.get_global("POWER", null)
	if typeof(raw) != TYPE_DICTIONARY:
		_fail("POWER is missing or not a dict")
		return
	var src: Dictionary = raw
	if not _require(src, ["max", "recharge", "shield_draw", "thrust_drain",
			"cloak_drain", "primary_cost", "rocket_cost", "homing_cost"],
			"POWER"):
		return
	power = {}
	for key in src:
		power[String(key)] = float(src[key])

	_power_cache = {}
	for thrusting in [false, true]:
		for cloaked in [false, true]:
			for shields_charging in [false, true]:
				var net := float(power.get("recharge", 0.0))
				if thrusting:
					net -= float(power.get("thrust_drain", 0.0))
				if cloaked:
					net -= float(power.get("cloak_drain", 0.0))
				if shields_charging:
					net -= float(power.get("shield_draw", 0.0))
				_power_cache[_power_key(thrusting, cloaked, shields_charging)] = net


static func _power_key(thrusting: bool, cloaked: bool, shields_charging: bool) -> String:
	return "%d%d%d" % [int(thrusting), int(cloaked), int(shields_charging)]


# ==========================================================================
# Caching: sectors
# ==========================================================================

func _cache_danger() -> void:
	var raw = vm.get_global("DANGER", null)
	if typeof(raw) != TYPE_ARRAY:
		_fail("DANGER is missing or not a list")
		return
	danger_bands = []
	for entry in (raw as Array):
		if typeof(entry) != TYPE_DICTIONARY:
			_fail("DANGER contains a non-dict band")
			return
		var band: Dictionary = entry
		if not _require(band, ["base", "per_gen"], "a DANGER band"):
			return
		danger_bands.append({
			"base": float(band["base"]),
			"per_gen": float(band["per_gen"]),
		})
	if danger_bands.size() < 4:
		_fail("DANGER has %d bands; 0..3 are required" % danger_bands.size())


func _cache_sectors() -> void:
	var raw = vm.get_global("SECTORS", null)
	if typeof(raw) != TYPE_ARRAY:
		_fail("SECTORS is missing or not a list")
		return
	sectors = []
	_sector_by_key = {}
	for entry in (raw as Array):
		if typeof(entry) != TYPE_DICTIONARY:
			_fail("SECTORS contains a non-dict entry")
			continue
		var src: Dictionary = entry
		if not _require(src, ["key", "name", "danger", "spawns",
				"capital_chance", "charge", "travel"], "a SECTORS entry"):
			continue
		var key := int(float(src["key"]))
		var out := {
			"key": key,
			"name": String(src["name"]),
			"danger": int(float(src["danger"])),
			"spawns": bool(src["spawns"]),
			"capital_chance": float(src["capital_chance"]),
			"charge": float(src["charge"]),
			"travel": float(src["travel"]),
			"fighter_cd": _float_pair(src.get("fighter_cd", [5.0, 9.0])),
			"mix": _weighted_mix(src.get("mix", [])),
			"unique": String(src.get("unique", "")),
		}
		if _sector_by_key.has(key):
			_fail("two sectors both use key %d" % key)
		_sector_by_key[key] = out
		sectors.append(out)


static func _float_pair(value) -> Array:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() < 2:
		return [5.0, 9.0]
	var pair: Array = value
	return [float(pair[0]), float(pair[1])]


static func _weighted_mix(value) -> Array:
	var out: Array = []
	if typeof(value) != TYPE_ARRAY:
		return out
	for entry in (value as Array):
		if typeof(entry) == TYPE_ARRAY and (entry as Array).size() >= 2:
			var pair: Array = entry
			out.append({"kind": String(pair[0]), "weight": int(float(pair[1]))})
	return out


# ==========================================================================
# Self-check: every cached fast path must agree with a fresh NovaLang call
# ==========================================================================

func _self_check() -> void:
	for attacker in TARGET_CLASSES:
		for defender in TARGET_CLASSES:
			var fast := damage_multiplier(attacker, defender)
			var slow := float(vm.call_function("damage_multiplier", [attacker, defender]))
			if not is_equal_approx(fast, slow):
				_fail("damage_multiplier(%s, %s): cached %f but NovaLang says %f"
						% [attacker, defender, fast, slow])
				return

	for band in range(danger_bands.size()):
		for gen in [0.0, 2.5, 7.0, 30.0]:
			var fast_h := hostiles_for(band, gen)
			var slow_h := int(vm.call_function("hostiles_for", [float(band), gen]))
			if fast_h != slow_h:
				_fail("hostiles_for(%d, %s): cached %d but NovaLang says %d"
						% [band, gen, fast_h, slow_h])
				return

	for key in ships:
		for stat_name in STAT_KEYS:
			var fast_s: float = ships[key][stat_name]
			var slow_s := float(vm.call_function("ship_stat", [key, stat_name, -1.0]))
			if not is_equal_approx(fast_s, slow_s):
				_fail("%s.%s: cached %f but NovaLang says %f" % [key, stat_name, fast_s, slow_s])
				return
		var hard_fast: bool = ships[key]["hardened"]
		var hard_slow := bool(vm.call_function("ship_hardened", [key]))
		if hard_fast != hard_slow:
			_fail("%s.hardened: cached %s but NovaLang says %s" % [key, hard_fast, hard_slow])
			return

	var hardened_keys: Array = []
	for key in ships:
		if bool(ships[key]["hardened"]):
			hardened_keys.append(key)
	hardened_keys.sort()
	if hardened_keys != ["atlantis", "aurora"]:
		_fail("expected exactly {aurora, atlantis} to be hardened, got %s" % [hardened_keys])
		return

	for kind in enemy_order:
		var fast_dmg := enemy_weapon_damage(String(kind), "x302")
		var slow_dmg := float(vm.call_function("enemy_weapon_damage", [String(kind), "x302"]))
		if not is_equal_approx(maxf(fast_dmg, 1e-9), maxf(slow_dmg, 1e-9)):
			_fail("enemy_weapon_damage(%s, x302): %f vs %f" % [kind, fast_dmg, slow_dmg])
			return
		for stat_name in ["shield", "hull", "max_speed", "turn_rate", "gun_dmg", "score"]:
			var fast_e := float(enemy_stats[String(kind)].get(stat_name, -1.0))
			var slow_e := float(vm.call_function("enemy_stat", [String(kind), stat_name, -2.0]))
			if not is_equal_approx(fast_e, slow_e):
				_fail("ENEMY.%s.%s: cached %f but NovaLang says %f"
						% [kind, stat_name, fast_e, slow_e])
				return

	for weapon_type in weapon_order:
		var w: Dictionary = weapons[String(weapon_type)]
		for field in w:
			if not WEAPON_FIELDS.has(field):
				_fail("WEAPONS.%s has an unrecognised field '%s' -- add it to " \
						% [weapon_type, field] + "DaedalusBridge.WEAPON_FIELDS")
				return
		var fast_range := effective_range(String(weapon_type))
		var slow_range := float(vm.call_function("effective_range", [String(weapon_type)]))
		if not is_equal_approx(maxf(fast_range, 1e-9), maxf(slow_range, 1e-9)):
			_fail("effective_range(%s): cached %f but NovaLang says %f"
					% [weapon_type, fast_range, slow_range])
			return

	for cls in TARGET_CLASSES:
		var fast_turn := homing_turn_rate(cls)
		var slow_turn := float(vm.call_function("homing_turn_rate", [cls]))
		if not is_equal_approx(fast_turn, slow_turn):
			_fail("homing_turn_rate(%s): cached %f but NovaLang says %f" % [cls, fast_turn, slow_turn])
			return
		for elapsed in [0.0, 0.71, 1.42, 3.0]:
			var fast_dps := beam_dps(2431.0, elapsed, cls)
			var slow_dps := float(vm.call_function("beam_damage_per_second", [2431.0, elapsed, cls]))
			if not is_equal_approx(maxf(fast_dps, 1e-9), maxf(slow_dps, 1e-9)):
				_fail("beam_dps(2431, %s, %s): cached %f but NovaLang says %f"
						% [elapsed, cls, fast_dps, slow_dps])
				return

	for sample in [[100.0, 0.0, 97.4, 0.37], [100.0, 48.7, 97.4, 0.37],
			[100.0, 97.4, 97.4, 0.37], [100.0, 200.0, 97.4, 0.37]]:
		var fast_fall := falloff_damage(sample[0], sample[1], sample[2], sample[3])
		var slow_fall := float(vm.call_function("falloff_damage", sample))
		if not is_equal_approx(maxf(fast_fall, 1e-9), maxf(slow_fall, 1e-9)):
			_fail("falloff_damage%s: cached %f but NovaLang says %f" % [sample, fast_fall, slow_fall])
			return

	for key in ["aurora", "atlantis", "daedalus"]:
		var fast_salvo := homing_salvo_size(key)
		var slow_salvo := int(vm.call_function("homing_salvo_size", [key]))
		if fast_salvo != slow_salvo:
			_fail("homing_salvo_size(%s): cached %d but NovaLang says %d" % [key, fast_salvo, slow_salvo])
			return

	for thrusting in [false, true]:
		for cloaked in [false, true]:
			for shields_charging in [false, true]:
				var fast_net := power_balance(thrusting, cloaked, shields_charging)
				var slow_net := float(vm.call_function("power_balance", [thrusting, cloaked, shields_charging]))
				if not is_equal_approx(fast_net, slow_net):
					_fail("power_balance(%s,%s,%s): cached %f but NovaLang says %f"
							% [thrusting, cloaked, shields_charging, fast_net, slow_net])
					return

	for key in ["x302", "daedalus", "atlantis", "destiny"]:
		var fast_fire := fire_weapon("primary", key, ship_class(key), 0.0)
		var slow_fire = vm.call_function("fire_weapon", ["primary", key, ship_class(key), 0.0, 0.0])
		if not _dict_close(fast_fire, slow_fire):
			_fail("fire_weapon(primary, %s): %s vs %s" % [key, fast_fire, slow_fire])
			return

	var fast_ram := dart_ram_damage(587.2)
	var slow_ram := float(vm.call_function("dart_ram_damage", [587.2]))
	if not is_equal_approx(fast_ram, slow_ram):
		_fail("dart_ram_damage(587.2): %f vs %f" % [fast_ram, slow_ram])
		return


# ==========================================================================
# Ships
# ==========================================================================

func get_ship_stats(key: String) -> Dictionary:
	return ships.get(key, {})


## Alias kept for readability at call sites that read like the design doc
## ("get the ship stats for daedalus"); identical to get_ship_stats().
func ship_stats(key: String) -> Dictionary:
	return get_ship_stats(key)


func ship_class(key: String) -> String:
	return String(ships.get(key, {}).get("class", "fighter"))


func ship_name(key: String) -> String:
	return String(ships.get(key, {}).get("name", key))


func ship_hardened(key: String) -> bool:
	return bool(ships.get(key, {}).get("hardened", false))


func stat(key: String, name: String, fallback: float = 0.0) -> float:
	return float(ships.get(key, {}).get(name, fallback))


# ==========================================================================
# Combat scaling
# ==========================================================================

func damage_multiplier(attacker_class: String, defender_class: String) -> float:
	var row = damage_scaling.get(attacker_class, null)
	if typeof(row) != TYPE_DICTIONARY:
		return 1.0
	return float((row as Dictionary).get(defender_class, 1.0))


func effective_damage(raw: float, attacker_class: String, defender_class: String) -> float:
	return raw * damage_multiplier(attacker_class, defender_class)


func weapon_damage(attacker_key: String, weapon: String, defender_key: String) -> float:
	return effective_damage(stat(attacker_key, weapon), ship_class(attacker_key),
			ship_class(defender_key))


# ==========================================================================
# Enemies (Stage 2)
# ==========================================================================

## Raw, unmodified stat block for one hostile -- no player-class reaction.
func get_enemy_stats(kind: String) -> Dictionary:
	return enemy_stats.get(kind, {})


func enemy_class(kind: String) -> String:
	return String(get_enemy_stats(kind).get("class", "fighter"))


func enemy_name(kind: String) -> String:
	return String(get_enemy_stats(kind).get("name", kind))


func enemy_stat(kind: String, name: String, fallback: float = 0.0) -> float:
	return float(get_enemy_stats(kind).get(name, fallback))


## What a hostile's gun does to a named player hull. Bounded by the
## hostile's own fire_cd (never more than a few times a second, for the
## fastest kind), so this stays a real interpreter call.
func enemy_weapon_damage(kind: String, defender_key: String) -> float:
	return float(vm.call_function("enemy_weapon_damage", [kind, defender_key]))


func player_weapon_vs_enemy(attacker_key: String, weapon: String, kind: String) -> float:
	return float(vm.call_function("player_weapon_vs_enemy", [attacker_key, weapon, kind]))


## The fully-resolved behavior for `kind` against whatever `player_key` is
## flying. Called once per spawn (and again if the player switches ships),
## never once a frame -- see daedalus_ai.nova's own note on why that is
## fine as a real interpreter call.
##
##     Daedalus.get_enemy_behavior("dart", "atlantis")   # player_key, not class
func get_enemy_behavior(kind: String, player_key: String) -> Dictionary:
	var result = vm.call_function("enemy_behavior", [kind, player_key])
	return result if typeof(result) == TYPE_DICTIONARY else {}


## Alias matching the Stage 1-3 bridges' own naming.
func enemy_behavior(kind: String, player_key: String) -> Dictionary:
	return get_enemy_behavior(kind, player_key)


## Ram damage at the moment of impact -- once per dive, not once a frame.
func dart_ram_damage(dive_speed: float) -> float:
	return float(vm.call_function("dart_ram_damage", [dive_speed]))


# ==========================================================================
# Weapons (Stage 3)
# ==========================================================================

func weapon_stat(weapon_type: String, stat_name: String, fallback: float = 0.0) -> float:
	var w: Dictionary = weapons.get(weapon_type, {})
	if not w.has(stat_name):
		return fallback
	var v = w[stat_name]
	return float(v) if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) else fallback


func weapon_name(weapon_type: String) -> String:
	return String(weapons.get(weapon_type, {}).get("name", weapon_type))


## Everything the projectile spawner needs: velocity, lifetime, cooldown,
## spread, energy cost, collision radius, blast/splash figures.
func projectile_stats(weapon_type: String) -> Dictionary:
	return weapons.get(weapon_type, {}).duplicate(true)


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


func homing_turn_rate(target_class: String) -> float:
	var factor: float = _homing_turn_factor.get(target_class, 1.0)
	return _homing_base_turn_rate * factor


## Linear falloff within `radius`, zero beyond it -- rocket blast and
## homing splash share this shape. Safe to call once per victim of the
## same simultaneous hit without touching the interpreter.
func falloff_damage(base_dmg: float, distance: float, radius: float, falloff: float) -> float:
	if radius <= 0.0:
		return base_dmg
	if distance > radius:
		return 0.0
	var ratio := distance / radius
	return base_dmg * (1.0 - ratio * falloff)


func beam_ramp_frac(elapsed: float) -> float:
	if _beam_ramp_time <= 0.0 or elapsed >= _beam_ramp_time:
		return 1.0
	if elapsed <= 0.0:
		return 0.6
	return 0.6 + 0.4 * (elapsed / _beam_ramp_time)


func beam_class_multiplier(target_class: String) -> float:
	return float(_beam_class_multiplier.get(target_class, 1.0))


## Damage per second of beam contact right now -- the genuine per-frame hot
## call while a beam is firing. No interpreter call; only cached numbers.
func beam_dps(base_dps: float, elapsed: float, target_class: String) -> float:
	return base_dps * beam_ramp_frac(elapsed) * beam_class_multiplier(target_class)


## Resolve one weapon discharge. `attacker_key` is a player SHIP key;
## `target_class` is "fighter" / "battlecruiser" / "capital" (or "" for no
## target); `distance` is world units to the target (for rocket/homing,
## the distance from the blast/splash centre to *this* victim, so calling
## it once per splash victim gives each one its own falloff); `elapsed` is
## only read by the beam. Always returns {hit, damage_dealt, effect}.
## Bounded by the weapon's own cooldown, so this stays a real call.
func fire_weapon(weapon_type: String, attacker_key: String, target_class: String,
		distance: float, elapsed: float = 0.0) -> Dictionary:
	var result = vm.call_function("fire_weapon",
			[weapon_type, attacker_key, target_class, distance, elapsed])
	return result if typeof(result) == TYPE_DICTIONARY else \
			{"hit": false, "damage_dealt": 0.0, "effect": "bridge error"}


## Convenience overload for gameplay code that has world positions rather
## than a pre-measured range: distance is derived from `from_pos` to
## `target_pos`. `dir` is accepted for interface symmetry (the direction a
## shot is aimed matters to the projectile Godot spawns, and to whether it
## physically collides at all -- it plays no further role in *resolving*
## a hit that already landed, which only ever depends on range and class)
## and is not read here.
func fire_weapon_at(weapon_type: String, attacker_key: String, target_class: String,
		target_pos: Vector2, from_pos: Vector2, _dir: Vector2 = Vector2.RIGHT,
		elapsed: float = 0.0) -> Dictionary:
	return fire_weapon(weapon_type, attacker_key, target_class,
			from_pos.distance_to(target_pos), elapsed)


# ==========================================================================
# Power
# ==========================================================================

func weapon_cost(weapon: String) -> float:
	match weapon:
		"primary": return float(power.get("primary_cost", 0.0))
		"rocket": return float(power.get("rocket_cost", 0.0))
		"homing": return float(power.get("homing_cost", 0.0))
	return 0.0


func can_fire(reserve: float, weapon: String) -> bool:
	return reserve >= weapon_cost(weapon)


## Net power per second for a loadout -- one of eight combinations,
## precomputed at load, so this never touches the interpreter even though
## it is read every frame the HUD's power bar is on screen.
func power_balance(thrusting: bool, cloaked: bool, shields_charging: bool) -> float:
	return float(_power_cache.get(_power_key(thrusting, cloaked, shields_charging), 0.0))


func max_power() -> float:
	return float(power.get("max", 0.0))


## Seconds of continuous fire a full bank supports at `cycle_time` between
## shots, accounting for recharge; -1 for a weapon the bus sustains
## forever. Reads only cached POWER scalars.
func sustained_fire_seconds(weapon: String, cycle_time: float) -> float:
	if cycle_time <= 0.0:
		return -1.0
	var drain := weapon_cost(weapon) / cycle_time
	var net := drain - float(power.get("recharge", 0.0))
	if net <= 0.0:
		return -1.0
	return float(power.get("max", 0.0)) / net


# ==========================================================================
# Sectors
# ==========================================================================

func hostiles_for(danger: int, gen: float) -> int:
	if danger_bands.is_empty():
		return 0
	var band: Dictionary = danger_bands[clampi(danger, 0, danger_bands.size() - 1)]
	return int(floor(float(band["base"]) + gen * float(band["per_gen"])))


func saturation_minutes(danger: int, ceiling: float) -> float:
	if danger_bands.is_empty():
		return -1.0
	var band: Dictionary = danger_bands[clampi(danger, 0, danger_bands.size() - 1)]
	var rate := float(band["per_gen"])
	if rate <= 0.0:
		return -1.0
	return (ceiling - float(band["base"])) / rate


func sector(key: int) -> Dictionary:
	return _sector_by_key.get(key, {})


func sector_hostiles(key: int, gen: float) -> int:
	var s := sector(key)
	if s.is_empty() or not bool(s["spawns"]):
		return 0
	return hostiles_for(int(s["danger"]), gen)


# ==========================================================================
# Advisor / encounter director -- the live rule engine
#
# daedalus_rules.nova's `params` / `effects` / `signals` / `rule` / `fault`
# blocks are the same kind of tactical-advisor rule set reactor_rules.nova
# is, and they run the same way: one host-driven tick, reading the
# player's live numbers in and reading recommendations, alarms and
# scripted encounters back out. game.gd calls advisor_tick() at a fixed
# 10 Hz -- fast enough for a HUD warning to feel immediate, far short of
# a per-physics-frame interpreter call.
# ==========================================================================

func advisor_tick(dt: float, inputs: Dictionary) -> Dictionary:
	_t_elapsed += dt
	_alarm_level = 0
	_alarm_text = ""

	var full_inputs := inputs.duplicate()
	full_inputs["t"] = _t_elapsed
	full_inputs["dt"] = dt

	if not vm.tick(dt, full_inputs, true):
		push_error("[DaedalusBridge] advisor tick failed: " + vm.error)
		return {"alert_level": 0, "alarm_text": "", "recommend": "", "threat": 0.0,
				"threat_tier": "CLEAR", "focus": "", "active_fault": null, "events": []}

	var fault = null
	if vm.active_fault != null:
		var f: Dictionary = vm.active_fault
		fault = {
			"name": f["name"],
			"label": f["label"],
			"elapsed": float(vm.get_global("fault_elapsed", 0.0)),
			"duration": float(vm.get_global("fault_duration", 0.0)),
		}

	var out_events: Array = events.duplicate()
	events.clear()

	return {
		"alert_level": _alarm_level,
		"alarm_text": _alarm_text,
		"recommend": String(vm.get_global("recommend", "")),
		"threat": float(vm.get_global("threat", 0.0)),
		"threat_tier": String(vm.get_global("threat_tier", "CLEAR")),
		"focus": String(vm.get_global("focus", "")),
		"encounter_bonus": int(vm.get_global("encounter_bonus", 0)),
		"active_fault": fault,
		"events": out_events,
	}


# ==========================================================================
# Reporting
# ==========================================================================

static func _dict_close(a: Dictionary, b) -> bool:
	if typeof(b) != TYPE_DICTIONARY:
		return false
	var bd: Dictionary = b
	if a.size() != bd.size():
		return false
	for key in a:
		if not bd.has(key):
			return false
		var av = a[key]
		var bv = bd[key]
		if (typeof(av) == TYPE_FLOAT or typeof(av) == TYPE_INT) and \
				(typeof(bv) == TYPE_FLOAT or typeof(bv) == TYPE_INT):
			if not is_equal_approx(maxf(float(av), 1e-9), maxf(float(bv), 1e-9)):
				return false
		elif av != bv:
			return false
	return true


func summary() -> Dictionary:
	var d := vm.describe() if vm != null else {}
	return {
		"ok": ready,
		"title": d.get("title", ""),
		"version": d.get("version", 0),
		"ships": ships.size(),
		"enemies": enemy_order.size(),
		"weapons": weapon_order.size(),
		"sectors": sectors.size(),
		"error": error,
	}


func debug_print() -> void:
	if not ready:
		print("[DaedalusBridge] NOT LOADED: ", error)
		return
	print("[DaedalusBridge] %s v%d -- %d ships, %d enemy kinds, %d weapons, %d sectors"
			% [summary()["title"], summary()["version"], summary()["ships"],
			   summary()["enemies"], summary()["weapons"], summary()["sectors"]])
