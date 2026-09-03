extends SceneTree

## parity_check.gd -- verify the GDScript interpreter matches the reference.
##
## The NovaLang implementation that ships is this one, in GDScript. The
## reference implementation in reference/ is Python and never ships -- its
## job is to state, precisely, what the answer is supposed to be.
##
## tools/gen_conformance.py runs a corpus of NovaLang programs through the
## reference and records, for each, the exact lines print() emitted, the
## exact host calls made and the exact error text. It also records a
## deterministic reactor trace: reactor_rules.nova driven through a scripted
## rod program with the fault injector off. This script replays all of it
## inside Godot and diffs.
##
## That is how an interpreter no CI machine can run still gets verified.
##
## Run it headless -- exits non-zero on any mismatch, so it drops straight
## into a build pipeline:
##
##     godot --headless --path godot --script res://scripts/nova/parity_check.gd
##
## Floats are compared with a relative tolerance: both runtimes use IEEE-754
## doubles and the same operation order, so they agree far inside it, but
## an exact bit compare would be a brittle promise to make.

const CONFORMANCE := "res://scripts/nova/conformance.json"
const FLOAT_TOLERANCE := 1e-9

var failures: Array = []
var checked := 0


func _initialize() -> void:
	print("NovaLang parity check")
	print("  reference: reference/ (python), replayed in GDScript")

	var doc := _load_conformance()
	if doc.is_empty():
		_finish(2)
		return

	var modules: Dictionary = doc.get("modules", {})
	for entry in doc.get("cases", []):
		_check_case(entry, modules)

	if doc.has("reactor_trace"):
		_check_reactor_trace(doc["reactor_trace"])

	if doc.has("daedalus_data"):
		_check_daedalus_data(doc["daedalus_data"])

	if doc.has("ai_data"):
		_check_ai_data(doc["ai_data"])

	if doc.has("weapons_data"):
		_check_weapons_data(doc["weapons_data"])

	print("")
	if failures.is_empty():
		print("parity OK -- %d checks, GDScript matches the reference" % checked)
		_finish(0)
	else:
		print("%d parity failure(s) out of %d checks:" % [failures.size(), checked])
		for f in failures:
			print("  FAIL  " + String(f))
		_finish(1)


func _finish(code: int) -> void:
	quit(code)


func _load_conformance() -> Dictionary:
	if not FileAccess.file_exists(CONFORMANCE):
		print("  missing %s -- run: python3 tools/gen_conformance.py" % CONFORMANCE)
		return {}
	var f := FileAccess.open(CONFORMANCE, FileAccess.READ)
	if f == null:
		print("  cannot open %s" % CONFORMANCE)
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		print("  %s is not valid JSON" % CONFORMANCE)
		return {}
	return parsed


func _fail(name: String, what: String, expected, got) -> void:
	failures.append("%s: %s\n          expected %s\n          got      %s"
			% [name, what, JSON.stringify(expected), JSON.stringify(got)])


# ==========================================================================
# Language cases
# ==========================================================================

func _check_case(entry: Dictionary, modules: Dictionary) -> void:
	var name := String(entry["name"])
	checked += 1

	var host_calls: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var vm := NovaVM.new(rng, func(path): return modules.get(path))

	for fn_name in entry.get("_host", ["log", "alarm", "scram", "reset_trip",
			"meltdown", "victory", "inject_fault", "clear_fault"]):
		var captured := String(fn_name)
		vm.register_function(captured, func(args: Array):
			var parts: Array = []
			for a in args:
				parts.append(NovaEvaluator.text(a))
			host_calls.append(captured + "(" + ", ".join(parts) + ")")
			return null)

	var ok := vm.eval(String(entry["source"]), name)

	if ok != bool(entry["ok"]):
		_fail(name, "ok flag", entry["ok"], ok)
		return
	if vm.error != String(entry["error"]):
		_fail(name, "error text", entry["error"], vm.error)
		return

	var got_output := vm.drain_output()
	if not _same_string_list(got_output, entry["output"]):
		_fail(name, "print output", entry["output"], got_output)
		return
	if not _same_string_list(host_calls, entry["host_calls"]):
		_fail(name, "host calls", entry["host_calls"], host_calls)


func _same_string_list(got: Array, expected) -> bool:
	var want: Array = expected
	if got.size() != want.size():
		return false
	for i in range(got.size()):
		if String(got[i]) != String(want[i]):
			return false
	return true


# ==========================================================================
# End-to-end reactor trace
# ==========================================================================

func _check_reactor_trace(trace: Dictionary) -> void:
	var bridge := NovaBridge.new()
	bridge.start(String(trace.get("rules", "reactor_rules.nova")))
	if not bridge.is_ready():
		failures.append("reactor trace: policy failed to load -- " + bridge.error)
		checked += 1
		return

	var program: Array = trace["rod_program"]
	var frames: Array = trace["frames"]
	var by_index := {}
	for entry in frames:
		var frame: Dictionary = entry
		by_index[int(frame["i"])] = frame

	var steps := int(trace["steps"])
	for i in range(steps):
		var target := float(program[i])
		var snap := bridge.tick(1, target, target, false, false)
		if not by_index.has(i):
			continue
		checked += 1
		_compare_frame(by_index[i], snap, i)

	bridge.free()


func _compare_frame(want: Dictionary, got: Dictionary, index: int) -> void:
	var label := "reactor frame %d (t=%s)" % [index, String(want["t"])]
	for key in ["flux_pct", "fuel_temp_c", "pressure_mpa", "reactivity_pcm",
			"rod_a", "t"]:
		var a := float(want[key])
		var b := float(got[key])
		if not _close(a, b):
			_fail(label, key, a, b)
			return
	for key in ["state", "scram", "alarm_level"]:
		if String(want[key]) != String(got[key]):
			_fail(label, key, want[key], got[key])
			return
	if not _same_string_list(got["events"], want["events"]):
		_fail(label, "events", want["events"], got["events"])


# ==========================================================================
# Stage 1 balance tables
#
# Loads the real daedalus_rules.nova through the shipping interpreter and
# diffs every number against what the reference read out of the same file.
# A hull stat that parses differently in the two runtimes fails here.
# ==========================================================================

func _check_daedalus_data(data: Dictionary) -> void:
	var vm := NovaVM.new()
	for fn_name in ["log", "alarm", "scram", "reset_trip", "meltdown",
			"victory", "inject_fault", "clear_fault"]:
		vm.register_function(String(fn_name), func(_args: Array): return null)

	checked += 1
	if not vm.load_file("daedalus_rules.nova"):
		failures.append("daedalus_rules.nova failed to load: " + vm.error)
		return

	var order: Array = data["ship_order"]
	var got_order = vm.get_global("SHIP_ORDER", [])
	if not _same_string_list(got_order, order):
		_fail("daedalus SHIP_ORDER", "order", order, got_order)

	var want_ships: Dictionary = data["ships"]
	var got_ships = vm.get_global("SHIPS", {})
	if typeof(got_ships) != TYPE_DICTIONARY:
		failures.append("daedalus SHIPS is not a dict")
		return
	for key in want_ships:
		checked += 1
		var want: Dictionary = want_ships[key]
		if not (got_ships as Dictionary).has(key):
			failures.append("daedalus SHIPS is missing hull '%s'" % key)
			continue
		var got: Dictionary = (got_ships as Dictionary)[key]
		for stat in want:
			var expected = want[stat]
			var actual = got.get(stat, null)
			if typeof(expected) == TYPE_STRING:
				if String(actual) != String(expected):
					_fail("daedalus %s.%s" % [key, stat], "value",
							expected, actual)
			elif not _close(float(expected), float(actual)):
				_fail("daedalus %s.%s" % [key, stat], "value",
						expected, actual)

	for entry in data["damage_pairs"]:
		var pair: Dictionary = entry
		checked += 1
		var got_mult := float(vm.call_function("damage_multiplier",
				[pair["a"], pair["b"]]))
		if not _close(float(pair["mult"]), got_mult):
			_fail("daedalus damage_multiplier(%s, %s)" % [pair["a"], pair["b"]],
					"value", pair["mult"], got_mult)

	var want_power: Dictionary = data["power"]
	var got_power = vm.get_global("POWER", {})
	for key in want_power:
		checked += 1
		var actual = (got_power as Dictionary).get(key, null)
		if actual == null or not _close(float(want_power[key]), float(actual)):
			_fail("daedalus POWER.%s" % key, "value", want_power[key], actual)

	for entry in data["danger_samples"]:
		var sample: Dictionary = entry
		checked += 1
		var got_n := float(vm.call_function("hostiles_for",
				[float(sample["danger"]), float(sample["gen"])]))
		if not _close(float(sample["hostiles"]), got_n):
			_fail("daedalus hostiles_for(%s, %s)"
					% [sample["danger"], sample["gen"]], "value",
					sample["hostiles"], got_n)

	for entry in data["sector_hostiles"]:
		var sample2: Dictionary = entry
		checked += 1
		var got_s := float(vm.call_function("sector_hostiles",
				[float(sample2["key"]), float(sample2["gen"])]))
		if not _close(float(sample2["hostiles"]), got_s):
			_fail("daedalus sector_hostiles(%s)" % sample2["key"], "value",
					sample2["hostiles"], got_s)

	for entry in data["power_balance"]:
		var pb: Dictionary = entry
		checked += 1
		var got_net := float(vm.call_function("power_balance",
				[bool(pb["thrust"]), bool(pb["cloak"]), bool(pb["shields"])]))
		if not _close(float(pb["net"]), got_net):
			_fail("daedalus power_balance(%s,%s,%s)"
					% [pb["thrust"], pb["cloak"], pb["shields"]], "value",
					pb["net"], got_net)

	var want_keys: Array = data["sector_keys"]
	var got_sectors = vm.get_global("SECTORS", [])
	var got_keys: Array = []
	for entry in (got_sectors as Array):
		got_keys.append(int(float((entry as Dictionary)["key"])))
	checked += 1
	if String(got_keys) != String(want_keys):
		_fail("daedalus SECTORS", "keys", want_keys, got_keys)


# ==========================================================================
# Stage 2 enemy AI
#
# Loads daedalus_ai.nova standalone (the ai_bridge.gd path) and diffs the
# raw ENEMY table and every one of the 36 (kind, player_class, hardened)
# behaviors against the reference. Then loads daedalus_rules.nova (the
# import path) and diffs the integration seam -- enemy_weapon_damage(),
# player_weapon_vs_enemy(), enemy_behavior() -- separately, since that
# exercises the aliased `import ... as ai` rather than the standalone load.
# ==========================================================================

func _check_ai_data(data: Dictionary) -> void:
	var vm := NovaVM.new()
	checked += 1
	if not vm.load_file("daedalus_ai.nova"):
		failures.append("daedalus_ai.nova failed to load: " + vm.error)
		return

	checked += 1
	var got_order = vm.get_global("ENEMY_ORDER", [])
	if not _same_string_list(got_order, data["enemy_order"]):
		_fail("ai ENEMY_ORDER", "order", data["enemy_order"], got_order)

	var want_enemy: Dictionary = data["enemy"]
	var got_enemy = vm.get_global("ENEMY", {})
	for kind in want_enemy:
		checked += 1
		if typeof(got_enemy) != TYPE_DICTIONARY or not (got_enemy as Dictionary).has(kind):
			failures.append("ai ENEMY is missing hull '%s'" % kind)
			continue
		_compare_stat_dict("ai ENEMY.%s" % kind, want_enemy[kind],
				(got_enemy as Dictionary)[kind])

	for entry in data["behaviors"]:
		var sample: Dictionary = entry
		checked += 1
		var got := vm.call_function("get_behavior",
				[sample["kind"], sample["player_class"], sample["hardened"]])
		var label := "ai get_behavior(%s, %s, %s)" % [sample["kind"],
				sample["player_class"], sample["hardened"]]
		if not _dict_matches(sample["behavior"], got):
			_fail(label, "behavior", sample["behavior"], got)

	for entry in data["ram_samples"]:
		var rs: Dictionary = entry
		checked += 1
		var got_dmg := float(vm.call_function("dart_ram_damage", [float(rs["speed"])]))
		if not _close(float(rs["damage"]), got_dmg):
			_fail("ai dart_ram_damage(%s)" % rs["speed"], "value",
					rs["damage"], got_dmg)

	# The integration seam: daedalus_rules.nova importing daedalus_ai.nova.
	var rules_vm := NovaVM.new()
	for fn_name in ["log", "alarm", "scram", "reset_trip", "meltdown",
			"victory", "inject_fault", "clear_fault"]:
		rules_vm.register_function(String(fn_name), func(_args: Array): return null)
	checked += 1
	if not rules_vm.load_file("daedalus_rules.nova"):
		failures.append("daedalus_rules.nova (ai import) failed to load: "
				+ rules_vm.error)
		return

	for entry in data["enemy_damage"]:
		var ed: Dictionary = entry
		checked += 1
		var got_ed := float(rules_vm.call_function("enemy_weapon_damage",
				[ed["kind"], ed["defender"]]))
		if not _close(float(ed["damage"]), got_ed):
			_fail("ai enemy_weapon_damage(%s, %s)" % [ed["kind"], ed["defender"]],
					"value", ed["damage"], got_ed)

	for entry in data["player_damage"]:
		var pd: Dictionary = entry
		checked += 1
		var got_pd := float(rules_vm.call_function("player_weapon_vs_enemy",
				[pd["attacker"], pd["weapon"], pd["kind"]]))
		if not _close(float(pd["damage"]), got_pd):
			_fail("ai player_weapon_vs_enemy(%s, %s, %s)"
					% [pd["attacker"], pd["weapon"], pd["kind"]],
					"value", pd["damage"], got_pd)

	for entry in data["resolved_behaviors"]:
		var rb: Dictionary = entry
		checked += 1
		var got_rb := rules_vm.call_function("enemy_behavior",
				[rb["kind"], rb["player_key"]])
		if not _dict_matches(rb["behavior"], got_rb):
			_fail("ai enemy_behavior(%s, %s)" % [rb["kind"], rb["player_key"]],
					"behavior", rb["behavior"], got_rb)


func _compare_stat_dict(label: String, want: Dictionary, got) -> void:
	if typeof(got) != TYPE_DICTIONARY:
		_fail(label, "type", "dict", got)
		return
	var gd: Dictionary = got
	for field in want:
		var expected = want[field]
		var actual = gd.get(field, null)
		if typeof(expected) == TYPE_STRING:
			if String(actual) != String(expected):
				_fail("%s.%s" % [label, field], "value", expected, actual)
		elif typeof(expected) == TYPE_ARRAY:
			if not _dict_matches(expected, actual):
				_fail("%s.%s" % [label, field], "value", expected, actual)
		elif not _close(float(expected), float(actual)):
			_fail("%s.%s" % [label, field], "value", expected, actual)


## Deep structural comparison for JSON-shaped values: dicts, arrays,
## strings, bools and numbers (numbers within float tolerance).
func _dict_matches(want, got) -> bool:
	if typeof(want) != typeof(got):
		# A JSON `true`/`false` and a GDScript bool both parse as TYPE_BOOL,
		# and a JSON number always parses as TYPE_FLOAT, so a real type
		# mismatch here is a real mismatch, not a JSON-round-trip artifact.
		return false
	match typeof(want):
		TYPE_DICTIONARY:
			var wd: Dictionary = want
			var gd: Dictionary = got
			if wd.size() != gd.size():
				return false
			for key in wd:
				if not gd.has(key) or not _dict_matches(wd[key], gd[key]):
					return false
			return true
		TYPE_ARRAY:
			var wl: Array = want
			var gl: Array = got
			if wl.size() != gl.size():
				return false
			for i in range(wl.size()):
				if not _dict_matches(wl[i], gl[i]):
					return false
			return true
		TYPE_FLOAT, TYPE_INT:
			return _close(float(want), float(got))
		TYPE_STRING:
			return String(want) == String(got)
		TYPE_BOOL:
			return bool(want) == bool(got)
		TYPE_NIL:
			return got == null
	return want == got


# ==========================================================================
# Stage 3 weapons
#
# Loads daedalus_weapons.nova standalone and diffs the raw WEAPONS table
# and every recorded formula sample, then loads daedalus_rules.nova and
# diffs every recorded fire_weapon() call -- the same integration seam
# pattern as _check_ai_data, one file down.
# ==========================================================================

func _check_weapons_data(data: Dictionary) -> void:
	var vm := NovaVM.new()
	checked += 1
	if not vm.load_file("daedalus_weapons.nova"):
		failures.append("daedalus_weapons.nova failed to load: " + vm.error)
		return

	checked += 1
	var got_order = vm.get_global("WEAPON_ORDER", [])
	if not _same_string_list(got_order, data["weapon_order"]):
		_fail("weapons WEAPON_ORDER", "order", data["weapon_order"], got_order)

	var want_weapons: Dictionary = data["weapons"]
	var got_weapons = vm.get_global("WEAPONS", {})
	for weapon_type in want_weapons:
		checked += 1
		if typeof(got_weapons) != TYPE_DICTIONARY or 				not (got_weapons as Dictionary).has(weapon_type):
			failures.append("weapons WEAPONS is missing '%s'" % weapon_type)
			continue
		if not _dict_matches(want_weapons[weapon_type],
				(got_weapons as Dictionary)[weapon_type]):
			_fail("weapons WEAPONS.%s" % weapon_type, "table",
					want_weapons[weapon_type],
					(got_weapons as Dictionary)[weapon_type])

	var formulas: Dictionary = data["formulas"]
	for fn_name in formulas:
		for entry in (formulas[fn_name] as Array):
			var sample: Dictionary = entry
			checked += 1
			var got = vm.call_function(String(fn_name), sample["args"])
			if not _dict_matches(sample["result"], got):
				_fail("weapons %s(%s)" % [fn_name, sample["args"]], "result",
						sample["result"], got)

	var rules_vm := NovaVM.new()
	for fn_name in ["log", "alarm", "scram", "reset_trip", "meltdown",
			"victory", "inject_fault", "clear_fault"]:
		rules_vm.register_function(String(fn_name), func(_args: Array): return null)
	checked += 1
	if not rules_vm.load_file("daedalus_rules.nova"):
		failures.append("daedalus_rules.nova (weapons import) failed to load: "
				+ rules_vm.error)
		return

	for entry in data["fires"]:
		var fire: Dictionary = entry
		checked += 1
		var got_fire = rules_vm.call_function("fire_weapon", fire["args"])
		if not _dict_matches(fire["result"], got_fire):
			_fail("weapons fire_weapon(%s)" % [fire["args"]], "result",
					fire["result"], got_fire)


static func _close(a: float, b: float) -> bool:
	var scale := maxf(1.0, maxf(absf(a), absf(b)))
	return absf(a - b) <= FLOAT_TOLERANCE * scale
