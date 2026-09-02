class_name DaedalusBridge
extends Node

## Loads the DAEDALUS data tables out of NovaLang into typed GDScript.
##
## Stage 1 of the conversion. daedalus_rules.nova is the authority for ship
## stats, class-vs-class damage scaling, the power budget and the sector
## table; this node reads them once at startup, validates them, and caches
## them into plain Dictionaries and Arrays.
##
## Why cache rather than call into NovaLang per use: damage_multiplier() is
## on the bullet path, and a tree-walking interpreter has no business
## there. So the *data* lives in .nova and the *hot lookups* are GDScript
## reading a cached Dictionary.
##
## That split is only safe if the two cannot disagree, so `load_rules()`
## finishes by cross-checking every GDScript fast path against the NovaLang
## function it shadows -- all nine class pairs, every danger band, every
## ship stat. A mismatch fails the load loudly instead of quietly running
## the wrong numbers.
##
##     var data := DaedalusBridge.new()
##     add_child(data)
##     if data.load_rules():
##         var dmg := data.weapon_damage("daedalus", "gun_dmg", "x302")

signal data_loaded(info: Dictionary)
signal load_failed(message: String)

const RULES_PATH := "daedalus_rules.nova"

## The eight measured figures every hull must declare. Missing any of them
## is a load failure, not a zero -- silent zeros in balance data are how you
## ship a gun that does nothing.
const STAT_KEYS := [
	"shield", "hull", "speed", "turn",
	"gun_dmg", "rocket_dmg", "homing_dmg", "beam_dmg",
]

## How each NovaLang stat name maps onto the engine's existing ship
## dictionary (the `_SHIP_BASE` shape in daedalus.py). Used by apply_to().
const ENGINE_FIELD := {
	"shield": "shield_max",
	"hull": "hull_max",
	"speed": "max_speed",
	"turn": "turn",
	"gun_dmg": "gun_dmg",
	"rocket_dmg": "rocket_dmg",
	"homing_dmg": "homing_dmg",
	"beam_dmg": "beam_dmg",
}

const REQUIRED_SECTOR_KEYS := [
	"key", "name", "danger", "spawns", "capital_chance", "charge", "travel",
]

## Vocabulary the policy may call. Stage 1 only needs the advisor's set;
## Stage 2 (enemy AI) will extend it.
const HOST_FUNCTIONS := [
	"log", "alarm", "scram", "reset_trip", "meltdown", "victory",
	"inject_fault", "clear_fault",
]

var vm: NovaVM = null
var ready := false
var error := ""

# -- cached tables ---------------------------------------------------------
var ships: Dictionary = {}            # key -> {name, class, shield, ...}
var ship_order: Array = []
var damage_scaling: Dictionary = {}   # attacker class -> defender class -> f
var power: Dictionary = {}
var danger_bands: Array = []          # index = danger level
var sectors: Array = []
var events: Array = []                # anything the policy log()ged

var _sector_by_key: Dictionary = {}


# ==========================================================================
# Loading
# ==========================================================================

func load_rules(path: String = RULES_PATH) -> bool:
	error = ""
	ready = false
	events.clear()

	vm = NovaVM.new()
	for name in HOST_FUNCTIONS:
		vm.register_function(String(name), _make_sink(String(name)))

	if not vm.load_file(path):
		return _abort("NovaLang: " + vm.error)

	_cache_ships()
	_cache_damage_scaling()
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


## Stage 1 has no simulation to drive, so the policy's vocabulary is wired
## to a log sink. Stage 2 replaces these with real behaviour.
func _make_sink(name: String) -> Callable:
	return func(args: Array):
		if name == "log" and not args.is_empty():
			events.append(NovaEvaluator.text(args[0]))
		return null


func _fail(message: String) -> void:
	if error == "":
		error = message


## Every field a table must carry, checked once at load.
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
# Caching
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
		for stat in STAT_KEYS:
			entry[stat] = float(src[stat])
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
		if not _require(src, REQUIRED_SECTOR_KEYS, "a SECTORS entry"):
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


## `[["wdart", 7], ["whive", 1]]` -> `[{kind, weight}, ...]`.
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
# Self-check: the cached fast paths must agree with the NovaLang source
# ==========================================================================

func _self_check() -> void:
	var classes := ["fighter", "battlecruiser", "capital"]
	for attacker in classes:
		for defender in classes:
			var fast := damage_multiplier(attacker, defender)
			var slow := float(vm.call_function("damage_multiplier",
					[attacker, defender]))
			if not is_equal_approx(fast, slow):
				_fail("damage_multiplier(%s, %s): cached %f but NovaLang says %f"
						% [attacker, defender, fast, slow])
				return

	for band in range(danger_bands.size()):
		for gen in [0.0, 2.5, 7.0, 30.0]:
			var fast := hostiles_for(band, gen)
			var slow := int(vm.call_function("hostiles_for",
					[float(band), gen]))
			if fast != slow:
				_fail("hostiles_for(%d, %s): cached %d but NovaLang says %d"
						% [band, gen, fast, slow])
				return

	for key in ships:
		for stat in STAT_KEYS:
			var fast: float = ships[key][stat]
			var slow := float(vm.call_function("ship_stat",
					[key, stat, -1.0]))
			if not is_equal_approx(fast, slow):
				_fail("%s.%s: cached %f but NovaLang says %f"
						% [key, stat, fast, slow])
				return
		var hard_fast: bool = ships[key]["hardened"]
		var hard_slow := bool(vm.call_function("ship_hardened", [key]))
		if hard_fast != hard_slow:
			_fail("%s.hardened: cached %s but NovaLang says %s"
					% [key, hard_fast, hard_slow])
			return

	# Exactly two hulls are hardened, and Destiny -- capital-class but not
	# hardened -- must not be one of them. If this ever fails, Stage 2's
	# dart-dive-avoidance and replicator-block logic are silently wrong for
	# every ship in the registry, so it is worth naming explicitly rather
	# than trusting the generic loop above to catch it.
	var hardened_keys: Array = []
	for key in ships:
		if bool(ships[key]["hardened"]):
			hardened_keys.append(key)
	hardened_keys.sort()
	if hardened_keys != ["atlantis", "aurora"]:
		_fail("expected exactly {aurora, atlantis} to be hardened, got %s"
				% [hardened_keys])
		return

	if vm.get_global("ENEMY_ORDER", null) != null:
		var enemy_order = vm.get_global("ENEMY_ORDER", [])
		for kind in enemy_order:
			var fast_dmg := enemy_weapon_damage(String(kind), "x302")
			var slow_dmg := float(vm.call_function("enemy_weapon_damage",
					[String(kind), "x302"]))
			if not is_equal_approx(maxf(fast_dmg, 1e-9), maxf(slow_dmg, 1e-9)):
				_fail("enemy_weapon_damage(%s, x302): %f vs %f"
						% [kind, fast_dmg, slow_dmg])
				return


# ==========================================================================
# Ships
# ==========================================================================

## The cached stat block, or an empty Dictionary for an unknown hull.
func ship_stats(key: String) -> Dictionary:
	return ships.get(key, {})


func ship_class(key: String) -> String:
	return String(ships.get(key, {}).get("class", "fighter"))


func ship_name(key: String) -> String:
	return String(ships.get(key, {}).get("name", key))


## Whether `key` carries a distributed Lantean/Ancient shield lattice --
## Aurora and Atlantis only. Not implied by ship_class(): Destiny is
## capital-class and NOT hardened, which is exactly the distinction
## Stage 2's enemy AI (a Wraith Dart's dive, a Replicator's infection
## bolt) has to get right.
func ship_hardened(key: String) -> bool:
	return bool(ships.get(key, {}).get("hardened", false))


func stat(key: String, name: String, fallback: float = 0.0) -> float:
	var entry: Dictionary = ships.get(key, {})
	return float(entry.get(name, fallback))


## Overlay the eight measured figures onto an engine-shaped ship dictionary
## (the `_SHIP_BASE` shape). Everything the table does not cover -- radius,
## damping, ammo counts, cooldowns -- is left exactly as it was, so this is
## safe to run over the existing SHIPS dicts during the port.
func apply_to(base: Dictionary, key: String) -> Dictionary:
	var entry: Dictionary = ships.get(key, {})
	if entry.is_empty():
		push_warning("[DaedalusBridge] no stats for hull '%s'; left as-is" % key)
		return base
	var out := base.duplicate(true)
	for stat_name in STAT_KEYS:
		out[String(ENGINE_FIELD[stat_name])] = float(entry[stat_name])
	out["name"] = entry["name"]
	out["class"] = entry["class"]
	return out


# ==========================================================================
# Combat scaling
# ==========================================================================

## Any pair not in the table is 1.0: same-band engagements need no
## correction, and an unrecognised class degrades to neutral rather than to
## zero damage.
func damage_multiplier(attacker_class: String, defender_class: String) -> float:
	var row = damage_scaling.get(attacker_class, null)
	if typeof(row) != TYPE_DICTIONARY:
		return 1.0
	return float((row as Dictionary).get(defender_class, 1.0))


func effective_damage(raw: float, attacker_class: String,
		defender_class: String) -> float:
	return raw * damage_multiplier(attacker_class, defender_class)


## What one hull's named weapon actually does to another hull.
func weapon_damage(attacker_key: String, weapon: String,
		defender_key: String) -> float:
	return effective_damage(stat(attacker_key, weapon),
			ship_class(attacker_key), ship_class(defender_key))


# ==========================================================================
# Enemy-facing damage (Stage 2)
#
# The class matrix above is exactly the one Stage 2's enemy AI reuses --
# these three calls are the composition point, backed by the
# enemy_weapon_damage() / player_weapon_vs_enemy() / enemy_behavior()
# functions daedalus_rules.nova added when it started importing
# daedalus_ai.nova. Nothing here duplicates ENEMY or DAMAGE_SCALING; both
# stay declared exactly once.
# ==========================================================================

## What a named hostile's gun does to a named player hull.
func enemy_weapon_damage(kind: String, defender_key: String) -> float:
	return float(vm.call_function("enemy_weapon_damage", [kind, defender_key]))


## What a named player hull's weapon does to a named hostile.
func player_weapon_vs_enemy(attacker_key: String, weapon: String,
		kind: String) -> float:
	return float(vm.call_function("player_weapon_vs_enemy",
			[attacker_key, weapon, kind]))


## The fully-resolved AI behavior for `kind` against whatever `player_key`
## is flying -- resolves class and the hardened flag from SHIPS so the
## caller does not have to. Empty Dictionary if daedalus_ai.nova is not on
## the import path (e.g. an older daedalus_rules.nova).
func enemy_behavior(kind: String, player_key: String) -> Dictionary:
	var result = vm.call_function("enemy_behavior", [kind, player_key])
	return result if typeof(result) == TYPE_DICTIONARY else {}


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


## Net power per second for a loadout. Negative means the bank is draining
## and the pilot is on a clock -- which, with shield_draw above recharge, is
## the normal state of affairs in a fight.
func power_balance(thrusting: bool, cloaked: bool,
		shields_charging: bool) -> float:
	var net := float(power.get("recharge", 0.0))
	if thrusting:
		net -= float(power.get("thrust_drain", 0.0))
	if cloaked:
		net -= float(power.get("cloak_drain", 0.0))
	if shields_charging:
		net -= float(power.get("shield_draw", 0.0))
	return net


func max_power() -> float:
	return float(power.get("max", 0.0))


# ==========================================================================
# Sectors
# ==========================================================================

## Ambient hostiles a danger band wants at `gen` minutes survived.
func hostiles_for(danger: int, gen: float) -> int:
	if danger_bands.is_empty():
		return 0
	var band: Dictionary = danger_bands[clampi(danger, 0, danger_bands.size() - 1)]
	return int(floor(float(band["base"]) + gen * float(band["per_gen"])))


## Minutes until a band saturates `ceiling`; -1 if it never does.
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


## Zero for a sector that does not spawn at all, whatever its danger band.
func sector_hostiles(key: int, gen: float) -> int:
	var s := sector(key)
	if s.is_empty() or not bool(s["spawns"]):
		return 0
	return hostiles_for(int(s["danger"]), gen)


# ==========================================================================
# Reporting
# ==========================================================================

func summary() -> Dictionary:
	var d := vm.describe() if vm != null else {}
	return {
		"ok": ready,
		"title": d.get("title", ""),
		"version": d.get("version", 0),
		"ships": ships.size(),
		"sectors": sectors.size(),
		"danger_bands": danger_bands.size(),
		"scaling_rows": damage_scaling.size(),
		"error": error,
	}


## One-screen dump of everything that loaded. Handy from _ready() while
## porting, and the fastest way to see a typo in the table.
func debug_print() -> void:
	if not ready:
		print("[DaedalusBridge] NOT LOADED: ", error)
		return
	print("[DaedalusBridge] %s v%d" % [summary()["title"], summary()["version"]])
	for key in ship_order:
		var s: Dictionary = ships[String(key)]
		print("  %-9s %-14s shield %6.0f  hull %6.0f  spd %5.0f  turn %4.0f"
				% [s["key"], s["class"], s["shield"], s["hull"],
				   s["speed"], s["turn"]])
	print("  power: %.0f cap, %+.0f/s idle, %+.0f/s shields+thrust"
			% [max_power(), power_balance(false, false, false),
			   power_balance(true, false, true)])
	for band in range(1, danger_bands.size()):
		print("  danger %d: %d on arrival, +%.1f/min, saturates 26 at %.2f min"
				% [band, hostiles_for(band, 0.0),
				   float(danger_bands[band]["per_gen"]),
				   saturation_minutes(band, 26.0)])
