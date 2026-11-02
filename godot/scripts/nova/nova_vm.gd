class_name NovaVM
extends RefCounted

## The NovaLang façade -- load, eval, call.
##
## Ties the lexer, parser and evaluator together and adds the two things a
## host actually needs: a public API, and the reactor rule engine that
## drives `rule`, `fault`, `effects` and `signals` declarations once per
## tick.
##
## Note what is *not* here: scram(), log(), alarm() and the rest are not
## interpreter built-ins. They are ordinary host functions registered by
## whoever embeds the VM (nova_bridge.gd for the reactor). The language
## knows nothing about reactors.
##
## Public API:
##     vm.load_file("reactor_rules.nova")   # parse + initialise
##     vm.eval(source, "<name>")            # same, from a string
##     vm.call_function("fib", [10.0])      # GDScript -> NovaLang
##     vm.register_function("hull", fn)     # NovaLang -> GDScript
##     vm.tick(dt, inputs, faults_enabled)  # one rule-engine cycle
##
## call_function() is not spelled call(): every Godot Object already has a
## call() method and shadowing it is a hard error, so both this and the
## reference implementation use the longer name.
##
## Two backends live behind this one API. `use_bytecode_vm` (default
## true) picks the Resolver -> Compiler -> NovaVM2 pipeline; set it to
## false before the first eval()/load_file() call to fall back to
## NovaEvaluator, the original tree-walker, kept as the reference the VM
## is checked against (parity_check.gd runs the whole suite through
## both). Every method below that touches program state picks its
## backend the same way: a tiny dispatcher, then one `_..._tree_walker()`
## and one `_..._vm2()` twin that otherwise mirror each other exactly.

## Where .nova files and modules are resolved from.
const SCRIPT_DIR := "res://scripts/"

## False falls back to the tree-walker (NovaEvaluator). Read once per
## eval()/load_file() call (when the program is parsed and compiled);
## changing it after that has no effect until the next eval()/load_file()
## or reset().
var use_bytecode_vm := true

var rng: RandomNumberGenerator
var base_dir := SCRIPT_DIR
var module_reader: Callable
var program: Dictionary = {}
var evaluator: NovaEvaluator
var vm2: NovaVM2
var compiled: Dictionary = {}     # NovaCompiler.compile_program(program)'s result
var error := ""
var source_name := "<empty>"

var _modules: Dictionary = {}     # path -> exports
var _loading: Array = []          # cycle detection
var _rules_by_name: Dictionary = {}    # name -> compiled["rules"] entry
var _faults_by_name: Dictionary = {}   # name -> compiled["faults"] entry

# -- rule-engine state -----------------------------------------------------
var effect_defaults: Dictionary = {}
var persistent_effects: Dictionary = {}
var active_fault = null
var fault_started_at := 0.0
var next_fault_at := 0.0


func _init(generator: RandomNumberGenerator = null,
		reader: Callable = Callable(), dir_path: String = SCRIPT_DIR) -> void:
	rng = generator if generator != null else RandomNumberGenerator.new()
	base_dir = dir_path
	module_reader = reader if reader.is_valid() else _read_from_res
	evaluator = NovaEvaluator.new(rng, self)
	vm2 = NovaVM2.new(rng, self)
	program = NovaParser.new_program()


## Default module reader: res:// works identically in the editor and inside
## an exported .pck, so a .nova file ships with the game.
func _read_from_res(path: String):
	var full := base_dir + path
	if not FileAccess.file_exists(full):
		return null
	var f := FileAccess.open(full, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	return text


# ==========================================================================
# Modules
# ==========================================================================

## `import "x.nova"` -- parse and run a module once, then hand back its
## exported bindings. Cached, so importing the same module from three
## places runs it once. Runs the module through whichever backend this VM
## is using, so an imported function value is always callable from the
## importer: the tree-walker never sees a VM2 closure and vice versa.
func load_module(path: String) -> Dictionary:
	if _modules.has(path):
		return _modules[path]
	if _loading.has(path):
		error = "circular import of '%s'" % path
		return {}

	var source = module_reader.call(path)
	if source == null:
		error = "cannot read module '%s'" % path
		return {}

	_loading.append(path)
	var parser := NovaParser.new()
	var module_prog := parser.parse(String(source), path)
	if parser.error != "":
		error = "%s: %s" % [path, parser.error]
		_loading.pop_back()
		return {}

	var exports: Dictionary
	if use_bytecode_vm:
		exports = _run_module_vm2(module_prog, path)
	else:
		exports = _run_module_tree_walker(module_prog, path)
	_loading.pop_back()
	if error != "":
		return {}

	_modules[path] = exports
	return exports


func _run_module_tree_walker(module_prog: Dictionary, path: String) -> Dictionary:
	# A module gets its own global scope: it can see the builtins and the
	# host functions, never the importer's variables.
	var module_env := NovaEvaluator.Env.new()
	var saved_held: Array = evaluator.held_timers
	evaluator.held_timers = _zeros(int(module_prog["held_slots"]))
	evaluator.exec_block(module_prog["statements"], module_env)
	evaluator.held_timers = saved_held

	if evaluator.error != "":
		error = "%s: %s" % [path, evaluator.error]
		return {}

	var exports: Dictionary = {}
	for name in module_prog["exports"]:
		var key := String(name)
		if module_env.has_var(key):
			exports[key] = module_env.get_var(key)
	return exports


func _run_module_vm2(module_prog: Dictionary, path: String) -> Dictionary:
	var resolver := NovaResolver.new(module_reader)
	resolver.resolve_program(module_prog)
	if resolver.error != "":
		error = "%s: %s" % [path, resolver.error]
		return {}
	var compiler := NovaCompiler.new()
	var module_compiled := compiler.compile_program(module_prog)
	if compiler.error != "":
		error = "%s: %s" % [path, compiler.error]
		return {}

	# A module gets its own global scope and its own held() timers, same
	# isolation the tree-walker path gives it -- saved and restored around
	# the nested run so the importer's own in-flight state is untouched.
	var saved_globals: Dictionary = vm2.globals
	var saved_held: Array = vm2.held_timers
	vm2.globals = {}
	vm2.held_timers = _zeros(int(module_prog.get("held_slots", 0)))
	vm2.execute(module_compiled["module"], [])
	var module_globals: Dictionary = vm2.globals
	var module_error: String = vm2.error
	vm2.globals = saved_globals
	vm2.held_timers = saved_held

	if module_error != "":
		error = "%s: %s" % [path, module_error]
		return {}

	var exports: Dictionary = {}
	for name in module_prog["exports"]:
		var key := String(name)
		if module_globals.has(key):
			exports[key] = module_globals[key]
	return exports


static func _zeros(count: int) -> Array:
	var out: Array = []
	for _i in range(count):
		out.append(0.0)
	return out


# ==========================================================================
# Public API
# ==========================================================================

## Expose a GDScript function to NovaLang source. Registered on both
## backends unconditionally -- hosts typically register before load_file()
## runs, and this way registration order never has to race `use_bytecode_vm`.
func register_function(name: String, fn: Callable) -> void:
	evaluator.register_function(name, fn)
	vm2.register_function(name, fn)


func load_file(path: String) -> bool:
	var source = module_reader.call(path)
	if source == null:
		error = "cannot read '%s'" % path
		return false
	return eval(String(source), path)


## Parse `source` as the main program and initialise it. Returns false and
## sets `error` on any lexer, parser, resolve or compile failure.
func eval(source: String, name: String = "<source>") -> bool:
	error = ""
	source_name = name
	var parser := NovaParser.new()
	program = parser.parse(source, name)
	if parser.error != "":
		error = parser.error
		return false

	if use_bytecode_vm:
		var resolver := NovaResolver.new(module_reader)
		resolver.resolve_program(program)
		if resolver.error != "":
			error = resolver.error
			return false
		var compiler := NovaCompiler.new()
		compiled = compiler.compile_program(program)
		if compiler.error != "":
			error = compiler.error
			return false
		_rules_by_name = {}
		for entry in compiled["rules"]:
			_rules_by_name[String(entry["name"])] = entry
		_faults_by_name = {}
		for entry in compiled["faults"]:
			_faults_by_name[String(entry["name"])] = entry

	return reset(0)


## Call a NovaLang function from GDScript.
func call_function(name: String, args: Array = []):
	if use_bytecode_vm:
		return _call_function_vm2(name, args)
	return _call_function_tree_walker(name, args)


func _call_function_tree_walker(name: String, args: Array):
	if not evaluator.globals.has_var(name):
		error = "no such function '%s'" % name
		return null
	var fn = evaluator.globals.get_var(name)
	if not (fn is NovaEvaluator.NovaFunc):
		error = "'%s' is not a function" % name
		return null
	evaluator.begin_run()
	var result = evaluator.call_function(fn, args, 0)
	if evaluator.error != "":
		error = evaluator.error
	return result


func _call_function_vm2(name: String, args: Array):
	if not vm2.globals.has(name):
		error = "no such function '%s'" % name
		return null
	var fn = vm2.globals[name]
	if not (fn is NovaEvaluator.NovaFunc) or fn.code == null:
		error = "'%s' is not a function" % name
		return null
	vm2.begin_run()
	var result = vm2.call_closure(fn, args)
	if vm2.error != "":
		error = vm2.error
	return result


func get_global(name: String, fallback = null):
	if use_bytecode_vm:
		return vm2.globals.get(name, fallback)
	if evaluator.globals.has_var(name):
		return evaluator.globals.get_var(name)
	return fallback


func set_global(name: String, value) -> void:
	if use_bytecode_vm:
		vm2.globals[name] = value
	else:
		evaluator.globals.declare(name, value)


func has_global(name: String) -> bool:
	if use_bytecode_vm:
		return vm2.globals.has(name)
	return evaluator.globals.has_var(name)


## Everything print() has emitted since the last drain.
func drain_output() -> Array:
	if use_bytecode_vm:
		return vm2.drain_output()
	var lines: Array = evaluator.output.duplicate()
	evaluator.output = []
	return lines


# ==========================================================================
# Lifecycle
# ==========================================================================

## Re-initialise: fresh globals, top-level statements re-run, params and
## effect defaults re-evaluated, every latch cleared.
func reset(seed_value: int = 0) -> bool:
	if seed_value != 0:
		rng.seed = seed_value
	if use_bytecode_vm:
		return _reset_vm2()
	return _reset_tree_walker()


func _reset_tree_walker() -> bool:
	var ev := evaluator
	ev.globals = NovaEvaluator.Env.new()
	ev.held_timers = _zeros(int(program.get("held_slots", 0)))
	ev.output = []
	ev.begin_run()

	ev.exec_block(program["statements"], ev.globals)
	if ev.error != "":
		error = ev.error
		return false

	for entry in program["params"]:
		ev.globals.declare(String(entry[0]), ev.eval(entry[1], ev.globals))

	effect_defaults = {}
	persistent_effects = {}
	for entry in program["effects"]:
		var name := String(entry[0])
		var value = ev.eval(entry[1], ev.globals)
		effect_defaults[name] = value
		ev.globals.declare(name, value)
		if entry[2]:
			persistent_effects[name] = true

	_reset_rule_latches()
	_reset_fault_schedule()

	if ev.error != "":
		error = ev.error
		return false
	return true


func _reset_vm2() -> bool:
	vm2.globals = {}
	vm2.held_timers = _zeros(int(program.get("held_slots", 0)))
	vm2.drain_output()
	vm2.begin_run()

	vm2.execute(compiled["module"], [])
	if vm2.error != "":
		error = vm2.error
		return false

	for entry in compiled["params"]:
		var value = vm2.execute(entry[1], [])
		if vm2.error != "":
			error = vm2.error
			return false
		vm2.globals[String(entry[0])] = value

	effect_defaults = {}
	persistent_effects = {}
	for entry in compiled["effects"]:
		var name := String(entry[0])
		var value2 = vm2.execute(entry[1], [])
		if vm2.error != "":
			error = vm2.error
			return false
		effect_defaults[name] = value2
		vm2.globals[name] = value2
		if entry[2]:
			persistent_effects[name] = true

	_reset_rule_latches()
	_reset_fault_schedule()
	return true


func _reset_rule_latches() -> void:
	for entry in program["rules"]:
		var rule: Dictionary = entry
		rule["fired"] = false
		rule["was_true"] = false


func _reset_fault_schedule() -> void:
	active_fault = null
	fault_started_at = 0.0
	next_fault_at = rng.randf_range(
		float(get_global("fault_first_min_s", 45.0)),
		float(get_global("fault_first_max_s", 90.0)))


# ==========================================================================
# The reactor rule engine
# ==========================================================================

## The scheduler's own announcements go through the host's log() like any
## other, so a host that renders logs differently gets fault messages free.
func _host_log(message: String) -> void:
	if evaluator.host_functions.has("log"):
		var fn: Callable = evaluator.host_functions["log"]
		fn.call([message])


func _fault_by_name(name: String):
	for entry in program["faults"]:
		var f: Dictionary = entry
		if f["name"] == name:
			return f
	return null


func _activate_fault(fault: Dictionary) -> void:
	if active_fault != null:
		return
	active_fault = fault
	fault_started_at = float(get_global("t", 0.0))
	set_global("active_fault", fault["name"])
	set_global("fault_label", fault["label"])
	set_global("fault_elapsed", 0.0)

	# float() is called only once the backend has confirmed there's a real
	# value to convert -- a failed eval()/execute() returns null, and
	# float(null) is not worth relying on either way.
	var duration_value := 0.0
	if use_bytecode_vm:
		var cfault: Dictionary = _faults_by_name[String(fault["name"])]
		var raw = vm2.execute(cfault["duration"], [])
		if vm2.error != "":
			error = vm2.error
		else:
			duration_value = float(raw)
	else:
		var raw2 = evaluator.eval(fault["duration"], evaluator.globals)
		if evaluator.error != "":
			error = evaluator.error
		else:
			duration_value = float(raw2)
	set_global("fault_duration", duration_value)
	_host_log("ALARM: " + String(fault["label"]))


func _clear_fault() -> void:
	if active_fault == null:
		return
	var fault: Dictionary = active_fault
	_host_log(String(fault["label"]) + " CLEARED")
	active_fault = null
	set_global("active_fault", "")
	set_global("fault_label", "")
	set_global("fault_elapsed", 0.0)
	set_global("fault_duration", 0.0)
	next_fault_at = float(get_global("t", 0.0)) + rng.randf_range(
		float(get_global("fault_gap_min_s", 45.0)),
		float(get_global("fault_gap_max_s", 90.0)))


func _pick_weighted_fault():
	var total := 0.0
	for entry in program["faults"]:
		var f: Dictionary = entry
		if float(f["weight"]) > 0.0:
			total += float(f["weight"])
	if total <= 0.0:
		return null
	var r := rng.randf_range(0.0, total)
	var acc := 0.0
	for entry in program["faults"]:
		var f: Dictionary = entry
		if float(f["weight"]) <= 0.0:
			continue
		acc += float(f["weight"])
		if r <= acc:
			return f
	return null


func inject_fault(name: String) -> bool:
	var fault = _fault_by_name(name)
	if fault == null:
		error = "no such fault '%s'" % name
		return false
	_activate_fault(fault)
	return true


func clear_fault() -> void:
	_clear_fault()


func _update_faults(now: float, enabled: bool) -> void:
	if active_fault == null:
		if enabled and now >= next_fault_at:
			var fault = _pick_weighted_fault()
			if fault != null:
				_activate_fault(fault)
	else:
		var elapsed := now - fault_started_at
		set_global("fault_elapsed", elapsed)
		if elapsed >= float(get_global("fault_duration", 30.0)):
			_clear_fault()

	if active_fault == null:
		return
	var fault2: Dictionary = active_fault
	if use_bytecode_vm:
		var cfault: Dictionary = _faults_by_name[String(fault2["name"])]
		vm2.execute(cfault["body"], [])
		if vm2.error != "":
			error = vm2.error
	else:
		evaluator.exec_block(fault2["body"], NovaEvaluator.Env.new(evaluator.globals))
		if evaluator.error != "":
			error = evaluator.error


## One control cycle: reset transient effects, take the host's
## measurements, run the fault scheduler, recompute signals, then fire every
## rule in priority order. The host reads results back with get_global() and
## through the functions it registered.
func tick(dt: float, inputs: Dictionary, faults_enabled: bool = true) -> bool:
	if use_bytecode_vm:
		return _tick_vm2(dt, inputs, faults_enabled)
	return _tick_tree_walker(dt, inputs, faults_enabled)


func _tick_prelude(dt: float, inputs: Dictionary) -> void:
	for name in effect_defaults:
		if not persistent_effects.has(name):
			set_global(name, effect_defaults[name])

	set_global("dt", dt)
	for key in inputs:
		set_global(String(key), inputs[key])
	for pair in [["active_fault", ""], ["fault_label", ""],
			["fault_elapsed", 0.0], ["fault_duration", 0.0]]:
		if not has_global(String(pair[0])):
			set_global(pair[0], pair[1])


func _tick_tree_walker(dt: float, inputs: Dictionary, faults_enabled: bool) -> bool:
	var ev := evaluator
	ev.begin_run()
	ev.dt = dt
	_tick_prelude(dt, inputs)

	_update_faults(float(get_global("t", 0.0)), faults_enabled)
	if error != "":
		return false

	for entry in program["signal_defs"]:
		ev.globals.declare(String(entry[0]), ev.eval(entry[1], ev.globals))

	for entry in program["rules"]:
		var rule: Dictionary = entry
		if rule["once"] and rule["fired"]:
			rule["was_true"] = false
			continue
		var cond := NovaEvaluator.truthy(ev.eval(rule["cond"], ev.globals))
		if ev.error != "":
			error = "rule '%s': %s" % [rule["name"], ev.error]
			return false
		var should_fire: bool = cond and (not rule["edge"] or not rule["was_true"])
		rule["was_true"] = cond
		if should_fire:
			rule["fired"] = true
			ev.exec_block(rule["body"], NovaEvaluator.Env.new(ev.globals))
			if ev.error != "":
				error = "rule '%s': %s" % [rule["name"], ev.error]
				return false
	return true


func _tick_vm2(dt: float, inputs: Dictionary, faults_enabled: bool) -> bool:
	vm2.begin_run()
	vm2.dt = dt
	_tick_prelude(dt, inputs)

	_update_faults(float(get_global("t", 0.0)), faults_enabled)
	if error != "":
		return false

	for entry in compiled["signals"]:
		var value = vm2.execute(entry[1], [])
		if vm2.error != "":
			error = vm2.error
			return false
		vm2.globals[String(entry[0])] = value

	for entry in program["rules"]:
		var rule: Dictionary = entry
		if rule["once"] and rule["fired"]:
			rule["was_true"] = false
			continue
		var crule: Dictionary = _rules_by_name[String(rule["name"])]
		var cond_value = vm2.execute(crule["cond"], [])
		if vm2.error != "":
			error = "rule '%s': %s" % [rule["name"], vm2.error]
			return false
		var cond := NovaEvaluator.truthy(cond_value)
		var should_fire: bool = cond and (not rule["edge"] or not rule["was_true"])
		rule["was_true"] = cond
		if should_fire:
			rule["fired"] = true
			vm2.execute(crule["body"], [])
			if vm2.error != "":
				error = "rule '%s': %s" % [rule["name"], vm2.error]
				return false
	return true


# ==========================================================================
# Introspection
# ==========================================================================

func describe() -> Dictionary:
	var params: Array = []
	for e in program["params"]:
		params.append(e[0])
	var effects: Array = []
	for e in program["effects"]:
		effects.append(e[0])
	var signals_out: Array = []
	for e in program["signal_defs"]:
		signals_out.append(e[0])
	var rules: Array = []
	for e in program["rules"]:
		rules.append(e["name"])
	var faults: Array = []
	for e in program["faults"]:
		faults.append(e["name"])
	return {
		"title": program["title"],
		"version": program["version"],
		"params": params,
		"effects": effects,
		"signals": signals_out,
		"rules": rules,
		"faults": faults,
		"statements": program["statements"].size(),
		"exports": program["exports"],
		"held_slots": program["held_slots"],
	}
