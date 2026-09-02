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


static func _close(a: float, b: float) -> bool:
	var scale := maxf(1.0, maxf(absf(a), absf(b)))
	return absf(a - b) <= FLOAT_TOLERANCE * scale
