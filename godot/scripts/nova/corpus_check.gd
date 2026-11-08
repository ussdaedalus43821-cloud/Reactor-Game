extends SceneTree

## corpus_check.gd -- run the policy dialect's conformance corpus on the GDScript interpreter.
##
## The corpus is written and maintained in the Nova_Lang repository (tests/conformance/cases/policy-*.json,
## specified by docs/spec/12- to 15-policy-*.md there); tools/export_policy_corpus.py in that repository
## copies it to res://scripts/nova/policy_corpus/. Each case is a program with the output, error and host
## calls it must produce, and some are scripts for the rule engine ("engine": a list of steps -- tick, reset,
## inject or clear a fault, call a function, set a global, describe -- with the result of each step). The
## cases with "host": "reactor" run under the reactor host model below, which is the contract of
## docs/spec/15-policy-reactor.md, including the 900-step trace.
##
## It is not parity_check.gd: that replays the recorded oracle (conformance.json) and the end-to-end
## trace through NovaBridge; this replays the specification's cases. The oracle programs are in both.
##
## Run it headless, from the godot/ folder (import once first: Godot --headless --path . --import):
##
##     Godot --headless --path . --script res://scripts/nova/corpus_check.gd
##     Godot --headless --path . --script res://scripts/nova/corpus_check.gd -- --backend=vm2 --only=policy_limits
##
## Options after `--`:  --backend=vm2|tree|both (default both)   --only=PREFIX (case names)   --verbose
## Exits 1 if any case differs. Numbers are compared with a relative tolerance of 1e-9, as parity_check.gd does.

const CORPUS_DIR := "res://scripts/nova/policy_corpus/"
const FLOAT_TOLERANCE := 1e-9
const SHOW_FAILURES := 60

var failures: Array = []
var checked := 0
var _use_vm2 := true
var _only := ""
var _verbose := false


func _initialize() -> void:
	print("NovaLang policy-dialect corpus check")
	print("  corpus: %s (from the Nova_Lang repository)" % CORPUS_DIR)
	var backends: Array = [true, false]
	for arg in OS.get_cmdline_user_args():
		var a := String(arg)
		if a.begins_with("--backend="):
			var which := a.substr(10)
			backends = [true] if which == "vm2" else ([false] if which == "tree" else [true, false])
		elif a.begins_with("--only="):
			_only = a.substr(7)
		elif a == "--verbose":
			_verbose = true

	var files := _corpus_files()
	if files.is_empty():
		print("  no policy-*.json in %s -- run tools/export_policy_corpus.py in Nova_Lang" % CORPUS_DIR)
		quit(2)
		return

	var overall_ok := true
	for use_vm2 in backends:
		_use_vm2 = use_vm2
		var label := "bytecode VM" if use_vm2 else "tree-walker"
		failures = []
		checked = 0
		print("")
		print("---- backend: %s ----" % label)
		for path in files:
			_run_file(String(path))
		print("")
		if failures.is_empty():
			print("corpus OK (%s) -- %d cases, GDScript matches the specification" % [label, checked])
		else:
			overall_ok = false
			print("%d of %d cases differ (%s):" % [failures.size(), checked, label])
			var shown := 0
			for f in failures:
				print("  FAIL  " + String(f))
				shown += 1
				if shown >= SHOW_FAILURES and not _verbose:
					print("  ... %d more (use --verbose to list them all)" % (failures.size() - shown))
					break
	quit(0 if overall_ok else 1)


func _corpus_files() -> Array:
	var out: Array = []
	var dir := DirAccess.open(CORPUS_DIR)
	if dir == null:
		return out
	for file_name in dir.get_files():
		if file_name.begins_with("policy-") and file_name.ends_with(".json"):
			out.append(CORPUS_DIR + file_name)
	out.sort()
	return out


func _run_file(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		failures.append("%s: cannot open" % path)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		failures.append("%s: not valid JSON" % path)
		return
	for entry in parsed.get("cases", []):
		var case_data: Dictionary = entry
		var case_name := String(case_data["name"])
		if _only != "" and not case_name.begins_with(_only):
			continue
		checked += 1
		var problem := _run_case(case_data)
		if problem != "":
			failures.append("%s [%s]: %s" % [case_name, ", ".join(PackedStringArray(case_data.get("spec", []))), problem])


# ==========================================================================
# One case
# ==========================================================================

func _make_vm(case_data: Dictionary) -> NovaVM:
	var files: Dictionary = case_data.get("files", {})
	var rng := RandomNumberGenerator.new()
	var seed_value := 12345
	if case_data.has("engine"):
		seed_value = int(case_data["engine"].get("seed", 12345))
	rng.seed = seed_value
	var vm := NovaVM.new(rng, func(path): return files.get(path))
	vm.use_bytecode_vm = _use_vm2
	return vm


func _run_case(case_data: Dictionary) -> String:
	var vm := _make_vm(case_data)
	var calls: Array = []
	var model: ReactorModel = null
	var is_engine := case_data.has("engine")
	if is_engine and String(case_data["engine"].get("host", "")) == "reactor":
		model = ReactorModel.new(vm, calls)
	else:
		for host_name in case_data.get("host_functions", []):
			var captured := String(host_name)
			vm.register_function(captured, func(args: Array):
				calls.append(_call_text(captured, args))
				return null)

	var ok := vm.eval(String(case_data["source"]), String(case_data["name"]))

	var want_exit := int(case_data.get("exit", 0))
	if (0 if ok else 1) != want_exit:
		return "exit status: expected %d, got %d (error %s)" % [want_exit, 0 if ok else 1, vm.error]
	if vm.error != String(case_data["error"]):
		return "error text:\n          expected %s\n          got      %s" % [JSON.stringify(case_data["error"]), JSON.stringify(vm.error)]
	var got_output := vm.drain_output()
	if not _same(case_data["output"], got_output):
		return "print output:\n          expected %s\n          got      %s" % [_short(case_data["output"]), _short(got_output)]
	if not _same(case_data.get("host_calls", []), calls):
		return "host calls:\n          expected %s\n          got      %s" % [_short(case_data.get("host_calls", [])), _short(calls)]
	if not is_engine or not ok:
		return ""

	calls.clear()
	var engine: Dictionary = case_data["engine"]
	var watch: Array = engine.get("watch", [])
	var want_results: Array = case_data.get("results", [])
	var steps: Array = engine.get("steps", [])
	if want_results.size() != steps.size():
		return "the case has %d steps and %d results" % [steps.size(), want_results.size()]
	for index in range(steps.size()):
		var step: Dictionary = steps[index]
		var got := _run_step(vm, model, step, calls, watch)
		var want: Dictionary = want_results[index]
		for key in ["ok", "error", "output", "host_calls", "watch", "value"]:
			if key == "value" and not want.has("value"):
				continue
			if not _same(want.get(key), got.get(key)):
				return "step %d (%s), %s:\n          expected %s\n          got      %s" % [
						index, _step_kind(step), key, _short(want.get(key)), _short(got.get(key))]
	return ""


func _step_kind(step: Dictionary) -> String:
	for key in step:
		return String(key)
	return "?"


func _run_step(vm: NovaVM, model: ReactorModel, step: Dictionary, calls: Array, watch: Array) -> Dictionary:
	var entry: Dictionary = {"ok": true, "value": null}
	if step.has("tick"):
		var tick_step: Dictionary = step["tick"]
		var inputs: Dictionary = tick_step.get("inputs", {}).duplicate(true)
		var dt := float(tick_step.get("dt", 0.05))
		var faults := bool(tick_step.get("faults", true))
		if model != null:
			entry["ok"] = model.tick(dt, inputs, faults)
		else:
			entry["ok"] = vm.tick(dt, inputs, faults)
	elif step.has("inject_fault"):
		entry["ok"] = vm.inject_fault(String(step["inject_fault"]))
	elif step.has("clear_fault"):
		vm.clear_fault()
	elif step.has("reset"):
		entry["ok"] = vm.reset(int(step["reset"]))
		if model != null:
			model.reset()
	elif step.has("call"):
		var call_args: Array = step["call"].duplicate(true)
		var fn_name := String(call_args.pop_front())
		vm.error = ""
		entry["value"] = _plain(vm.call_function(fn_name, call_args))
		entry["ok"] = vm.error == ""
	elif step.has("describe"):
		entry["value"] = _plain(vm.describe())
	elif step.has("set"):
		var assignments: Dictionary = step["set"]
		for key in assignments:
			vm.set_global(String(key), assignments[key])
	entry["error"] = "" if entry["ok"] else vm.error
	entry["output"] = vm.drain_output()
	entry["host_calls"] = calls.duplicate()
	calls.clear()
	var watched: Dictionary = {}
	for name in watch:
		watched[String(name)] = _plain(vm.get_global(String(name)))
	entry["watch"] = watched
	return entry


# ==========================================================================
# Comparing
# ==========================================================================

## A value as plain data: a function is its display text, collections are copied.
func _plain(v) -> Variant:
	match typeof(v):
		TYPE_ARRAY:
			var out_list: Array = []
			for item in v:
				out_list.append(_plain(item))
			return out_list
		TYPE_DICTIONARY:
			var out_dict: Dictionary = {}
			for key in v:
				out_dict[key] = _plain(v[key])
			return out_dict
		TYPE_OBJECT:
			return NovaEvaluator.text(v)
	return v


func _same(want, got) -> bool:
	var tw := typeof(want)
	var tg := typeof(got)
	var want_number := tw == TYPE_INT or tw == TYPE_FLOAT
	var got_number := tg == TYPE_INT or tg == TYPE_FLOAT
	if want_number and got_number:
		return _close(float(want), float(got))
	if want == null or got == null:
		return want == null and got == null
	if tw == TYPE_ARRAY and tg == TYPE_ARRAY:
		var wl: Array = want
		var gl: Array = got
		if wl.size() != gl.size():
			return false
		for i in range(wl.size()):
			if not _same(wl[i], gl[i]):
				return false
		return true
	if tw == TYPE_DICTIONARY and tg == TYPE_DICTIONARY:
		var wd: Dictionary = want
		var gd: Dictionary = got
		if wd.size() != gd.size():
			return false
		for key in wd:
			if not gd.has(key) or not _same(wd[key], gd[key]):
				return false
		return true
	if (tw == TYPE_STRING or tw == TYPE_STRING_NAME) and (tg == TYPE_STRING or tg == TYPE_STRING_NAME):
		return String(want) == String(got)
	if tw == TYPE_BOOL and tg == TYPE_BOOL:
		return want == got
	return false


static func _close(a: float, b: float) -> bool:
	if a == b:
		return true
	if is_nan(a) and is_nan(b):
		return true
	var scale := maxf(absf(a), absf(b))
	return absf(a - b) <= FLOAT_TOLERANCE * maxf(scale, 1.0)


func _short(v) -> String:
	var s := JSON.stringify(v)
	if s.length() > 300:
		return s.substr(0, 300) + "..."
	return s


static func _call_text(name: String, args: Array) -> String:
	var parts: Array = []
	for a in args:
		parts.append(NovaEvaluator.text(a))
	return name + "(" + ", ".join(parts) + ")"


# ==========================================================================
# The reactor host (docs/spec/15-policy-reactor.md)
# ==========================================================================

## What the reactor game's host gives the engine and keeps between ticks. A case supplies the plant's
## measurements; `scram`, `scram_elapsed`, `game_over`, `victory` and `meltdown` are the host's and are
## added here. The same model is ReactorModel in tests/conformance/engines.py of the Nova_Lang repository.
class ReactorModel extends RefCounted:
	var vm: NovaVM
	var calls: Array
	var scram := false
	var scram_t := 0.0
	var game_over := false
	var victory := false
	var meltdown := false
	var scram_requested := false
	var trip_reset := false

	func _init(machine: NovaVM, recorded: Array) -> void:
		vm = machine
		calls = recorded
		for host_name in ["log", "alarm", "scram", "reset_trip", "meltdown", "victory",
				"inject_fault", "clear_fault"]:
			var captured := String(host_name)
			vm.register_function(captured, func(args: Array): return _call(captured, args))

	func reset() -> void:
		scram = false
		scram_t = 0.0
		game_over = false
		victory = false
		meltdown = false
		scram_requested = false
		trip_reset = false

	func _call(host_name: String, args: Array) -> Variant:
		var parts: Array = []
		for a in args:
			parts.append(NovaEvaluator.text(a))
		calls.append(host_name + "(" + ", ".join(parts) + ")")
		match host_name:
			"scram":
				if not scram:
					scram_requested = true
					vm.set_global("scram", true)
			"reset_trip":
				trip_reset = true
				vm.set_global("scram", false)
			"meltdown":
				if not meltdown:
					meltdown = true
					_end_run()
			"victory":
				if not victory:
					victory = true
					_end_run()
			"inject_fault":
				if args.size() > 0:
					vm.inject_fault(NovaEvaluator.text(args[0]))
			"clear_fault":
				vm.clear_fault()
		return null

	func _end_run() -> void:
		game_over = true
		vm.set_global("game_over", true)
		vm.set_global("meltdown", meltdown)
		vm.set_global("victory", victory)
		vm.set_global("running", false)

	func tick(dt: float, inputs: Dictionary, faults: bool) -> bool:
		var given: Dictionary = inputs.duplicate()
		var t := float(given.get("t", 0.0))
		given["scram"] = scram
		given["scram_elapsed"] = (t - scram_t) if scram else 0.0
		given["game_over"] = game_over
		given["victory"] = victory
		given["meltdown"] = meltdown
		given["operator_scram"] = NovaEvaluator.truthy(given.get("operator_scram", false))
		scram_requested = false
		trip_reset = false
		var ok := vm.tick(dt, given, faults)
		if ok:
			if scram_requested and not scram:
				scram = true
				scram_t = t
			elif trip_reset and scram:
				scram = false
		return ok
