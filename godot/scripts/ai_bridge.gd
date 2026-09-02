class_name AIBridge
extends Node

## Loads enemy AI behavior definitions out of NovaLang into typed GDScript.
##
## Stage 2 of the conversion. daedalus_ai.nova is the authority for what
## each of the six hostile archetypes does and how it reacts to what the
## player is flying; this node loads it once, resolves every
## (kind, player_class, hardened) combination up front, and hands back
## cached behavior Dictionaries on demand.
##
## Behavior resolution runs once per relevant event -- a spawn, or the
## player switching ships -- never once a frame, so calling straight into
## NovaLang would be defensible here in a way it is not for Stage 1's
## per-bullet damage_multiplier(). It is still precached, for the same
## reason Stage 1 precaches: there are only 36 combinations (6 kinds x 3
## classes x hardened/not), so caching all of them costs nothing and turns
## every query into a Dictionary lookup with no interpreter on the call
## stack at all.
##
## That cache is only trustworthy if it agrees with the source it was built
## from, so `load_ai()` finishes with a self-check: every cached entry is
## re-resolved fresh through NovaLang and compared field by field.
##
##     var ai := AIBridge.new()
##     add_child(ai)
##     if ai.load_ai():
##         var hardened := daedalus.ship_stats(player_key).get("hardened", false)
##         var behavior := ai.get_behavior("fighter", player_class, hardened)
##         # behavior.keep_dist == [251.68, 362.56] if player_class == "capital"

signal ai_loaded(info: Dictionary)
signal load_failed(message: String)

const RULES_PATH := "daedalus_ai.nova"

const PLAYER_CLASSES := ["fighter", "battlecruiser", "capital"]

## Uniform key set every behavior Dictionary carries, whatever the kind --
## used only for the self-check, so a field silently missing from a future
## per-kind function is caught at load time instead of at first use.
const BEHAVIOR_KEYS := [
	"kind", "class", "name", "role",
	"shield", "hull", "score", "max_speed", "turn_rate", "gun_dmg",
	"keep_dist", "engage_range", "fire_cd",
	"burst_min", "burst_max", "strafe_interval", "flak_cd",
	"dive_cd", "dive_enabled", "ram_dmg_base",
	"spawn_cd", "release_range", "max_stored", "prioritize_distance",
	"flee_hull_frac", "flee_speed", "infect_blocked", "hide_behind_allies",
	"charge_time", "fire_time", "beam_dps", "beam_cooldown",
	"tactical_role",
]

## Old engine contact-kind strings still resolve; kept in sync with
## daedalus_ai.nova's own KIND_ALIAS by the self-check.
const KIND_ALIAS := {"wdart": "dart", "whive": "hive"}

var vm: NovaVM = null
var ready := false
var error := ""

var enemy_order: Array = []
var enemy_stats: Dictionary = {}     # kind -> {name, class, role, shield, ...}

## kind -> player_class -> hardened(0/1) -> resolved behavior Dictionary
var _cache: Dictionary = {}


# ==========================================================================
# Loading
# ==========================================================================

func load_ai(path: String = RULES_PATH) -> bool:
	error = ""
	ready = false

	vm = NovaVM.new()
	if not vm.load_file(path):
		return _abort("NovaLang: " + vm.error)

	_cache_enemy_stats()
	if error != "":
		return _abort(error)

	_build_cache()
	if error != "":
		return _abort(error)

	_self_check()
	if error != "":
		return _abort(error)

	ready = true
	ai_loaded.emit(summary())
	return true


func _abort(message: String) -> bool:
	error = message
	ready = false
	push_error("[AIBridge] " + error)
	load_failed.emit(error)
	return false


func resolve_kind(kind: String) -> String:
	return String(KIND_ALIAS.get(kind, kind))


# ==========================================================================
# Caching
# ==========================================================================

func _cache_enemy_stats() -> void:
	var raw = vm.get_global("ENEMY", null)
	if typeof(raw) != TYPE_DICTIONARY:
		error = "ENEMY is missing or not a dict"
		return
	var order = vm.get_global("ENEMY_ORDER", null)
	enemy_order = order if typeof(order) == TYPE_ARRAY else (raw as Dictionary).keys()

	enemy_stats = {}
	for kind in (raw as Dictionary):
		var src: Dictionary = (raw as Dictionary)[kind]
		enemy_stats[String(kind)] = {
			"name": String(src.get("name", kind)),
			"class": String(src.get("class", "fighter")),
			"role": String(src.get("role", "")),
			"shield": float(src.get("shield", 0.0)),
			"hull": float(src.get("hull", 0.0)),
			"score": float(src.get("score", 0.0)),
			"max_speed": float(src.get("max_speed", 0.0)),
			"turn_rate": float(src.get("turn_rate", 0.0)),
			"gun_dmg": float(src.get("gun_dmg", 0.0)),
		}
	for kind in enemy_order:
		if not enemy_stats.has(String(kind)):
			error = "ENEMY_ORDER names '%s', which is not in ENEMY" % kind
			return


func _build_cache() -> void:
	_cache = {}
	for kind in enemy_order:
		var by_class: Dictionary = {}
		for player_class in PLAYER_CLASSES:
			var by_hardened: Dictionary = {}
			for hardened in [false, true]:
				var behavior = vm.call_function("get_behavior",
						[String(kind), player_class, hardened])
				if vm.error != "":
					error = "get_behavior(%s, %s, %s): %s" \
							% [kind, player_class, hardened, vm.error]
					return
				if typeof(behavior) != TYPE_DICTIONARY:
					error = "get_behavior(%s, %s, %s) returned no data" \
							% [kind, player_class, hardened]
					return
				by_hardened[hardened] = behavior
			by_class[player_class] = by_hardened
		_cache[String(kind)] = by_class


func _self_check() -> void:
	for kind in enemy_order:
		for player_class in PLAYER_CLASSES:
			for hardened in [false, true]:
				var cached: Dictionary = _cache[String(kind)][player_class][hardened]
				for key in BEHAVIOR_KEYS:
					if not cached.has(key):
						error = "get_behavior(%s, %s, %s) is missing '%s'" \
								% [kind, player_class, hardened, key]
						return
				var fresh = vm.call_function("get_behavior",
						[String(kind), player_class, hardened])
				if not _dict_equal(cached, fresh):
					error = "cached behavior for (%s, %s, %s) no longer " \
							"matches a fresh NovaLang call" \
							% [kind, player_class, hardened]
					return
	for alias in KIND_ALIAS:
		var resolved := resolve_kind(alias)
		var via_nova := String(vm.call_function("resolve_kind", [alias]))
		if resolved != via_nova:
			error = "KIND_ALIAS.%s = '%s' but daedalus_ai.nova resolves it " \
					"to '%s'" % [alias, resolved, via_nova]
			return


static func _dict_equal(a: Dictionary, b) -> bool:
	if typeof(b) != TYPE_DICTIONARY:
		return false
	var bd: Dictionary = b
	if a.size() != bd.size():
		return false
	for key in a:
		if not bd.has(key):
			return false
		if not _value_equal(a[key], bd[key]):
			return false
	return true


static func _value_equal(a, b) -> bool:
	if typeof(a) == TYPE_ARRAY and typeof(b) == TYPE_ARRAY:
		var la: Array = a
		var lb: Array = b
		if la.size() != lb.size():
			return false
		for i in range(la.size()):
			if not _value_equal(la[i], lb[i]):
				return false
		return true
	if (typeof(a) == TYPE_FLOAT or typeof(a) == TYPE_INT) and \
			(typeof(b) == TYPE_FLOAT or typeof(b) == TYPE_INT):
		return is_equal_approx(float(a), float(b)) or (float(a) == float(b))
	return a == b


# ==========================================================================
# Public API
# ==========================================================================

## The resolved behavior for one hostile against one player loadout.
## Returns an empty Dictionary for an unrecognised kind or class rather
## than null, so callers can `.get(field, fallback)` without a null check.
##
##     ai.get_behavior("fighter", "capital")            # hardened defaults false
##     ai.get_behavior("dart", "capital", true)          # e.g. player flying Atlantis
func get_behavior(kind: String, player_class: String,
		player_hardened: bool = false) -> Dictionary:
	var k := resolve_kind(kind)
	if not _cache.has(k):
		push_warning("[AIBridge] unknown enemy kind '%s'" % kind)
		return {}
	var by_class: Dictionary = _cache[k]
	if not by_class.has(player_class):
		push_warning("[AIBridge] unknown player class '%s'; treating as "
				% player_class + "battlecruiser, the neutral case")
		player_class = "battlecruiser"
	var by_hardened: Dictionary = by_class[player_class]
	# Duplicated so a caller mutating the returned dict cannot corrupt the
	# cache for every other query of the same combination.
	return (by_hardened[player_hardened] as Dictionary).duplicate(true)


## Raw, unmodified stat block for one hostile -- no player-class reaction
## applied. Empty Dictionary for an unrecognised kind.
func stats(kind: String) -> Dictionary:
	return enemy_stats.get(resolve_kind(kind), {})


func enemy_class(kind: String) -> String:
	return String(stats(kind).get("class", "fighter"))


func enemy_name(kind: String) -> String:
	return String(stats(kind).get("name", kind))


func stat(kind: String, name: String, fallback: float = 0.0) -> float:
	return float(stats(kind).get(name, fallback))


## Ram damage at the given closing speed, scaled by the square of speed
## against the Dart's own max_speed (kinetic energy, not raw velocity).
func dart_ram_damage(dive_speed: float) -> float:
	if not ready:
		return 0.0
	return float(vm.call_function("dart_ram_damage", [dive_speed]))


## Whether a Hive should dump its stored Darts in one burst rather than
## launch them one at a time. `release_range` does not vary with player
## class (a Hive treats a fighter and a capital identically), so this
## takes no player_class argument.
func hive_should_release(distance_to_player: float) -> bool:
	var release_range := float(
			get_behavior("hive", "battlecruiser").get("release_range", INF))
	return distance_to_player <= release_range


# ==========================================================================
# Reporting
# ==========================================================================

func summary() -> Dictionary:
	var d := vm.describe() if vm != null else {}
	return {
		"ok": ready,
		"title": d.get("title", ""),
		"version": d.get("version", 0),
		"enemy_kinds": enemy_order.size(),
		"cached_combinations": enemy_order.size() * PLAYER_CLASSES.size() * 2,
		"error": error,
	}


## One-screen dump of how every hostile reacts to every player loadout.
## Handy from _ready() while porting Stage 3's spawner.
func debug_print() -> void:
	if not ready:
		print("[AIBridge] NOT LOADED: ", error)
		return
	print("[AIBridge] %s v%d -- %d kinds, %d cached combinations"
			% [summary()["title"], summary()["version"],
			   summary()["enemy_kinds"], summary()["cached_combinations"]])
	for kind in enemy_order:
		var s := stats(String(kind))
		print("  %-11s %-9s %-14s shield %7.1f  hull %7.1f  score %6.0f"
				% [kind, s["class"], s["role"], s["shield"], s["hull"], s["score"]])
		for player_class in PLAYER_CLASSES:
			var b := get_behavior(String(kind), player_class)
			print("      vs %-13s %s" % [player_class, b["tactical_role"]])
