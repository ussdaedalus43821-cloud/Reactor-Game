extends SceneTree

## nova_compiler_test.gd -- Phase 1 acceptance check for the Resolver +
## Compiler: prove they run over the real shipping scripts and the full
## conformance corpus without crashing, and print readable disassembly
## for a representative sample. Does not execute any bytecode -- NovaVM2
## does not exist yet (Phase 2).
##
## Run headless:
##
##     godot --headless --path godot --script res://scripts/nova/nova_compiler_test.gd
##
## Exits non-zero if the opcode tables disagree with each other or if any
## script in the corpus fails to compile.

const CONFORMANCE := "res://scripts/nova/conformance.json"

var failures := 0
var compiled := 0


func _initialize() -> void:
	print("NovaLang compiler smoke test (Phase 1: Resolver + Compiler, no VM yet)")

	if not NovaOpcodes.tables_agree():
		print("  FAIL: NovaOpcodes.NAMES and NovaOpcodes.OP disagree")
		_finish(2)
		return
	print("  opcode tables agree (" + str(NovaOpcodes.NAMES.size()) + " opcodes)")

	_show_sample("reactor_rules.nova", _read_res("res://scripts/reactor_rules.nova"),
			Callable(self, "_read_no_imports"))

	var daedalus_reader := Callable(self, "_read_under_scripts")
	_show_sample("daedalus_rules.nova (fixture)",
			_read_res("res://scripts/nova/fixtures/daedalus_rules.nova"), daedalus_reader)

	_show_sample("closures (conformance case)",
			"func counter() { let n = 0  return func() { n = n + 1 return n } }\n" +
			"let a = counter()\nlet b = counter()\na() a()\nprint(a(), b())",
			Callable(self, "_read_no_imports"))

	_run_conformance_corpus()

	print("")
	print(str(compiled) + " program(s) compiled, " + str(failures) + " failure(s).")
	_finish(1 if failures > 0 else 0)


func _finish(code: int) -> void:
	quit(code)


# ==========================================================================
# One annotated sample, disassembled in full
# ==========================================================================

func _show_sample(label: String, source, module_reader: Callable) -> void:
	print("")
	print("==================== " + label + " ====================")
	if source == null:
		print("  SKIP: could not read source")
		return
	var result = _compile_source(String(source), label, module_reader)
	if result == null:
		return
	var compiled_program: Dictionary = result
	var module_code: NovaCode = compiled_program["module"]
	print(module_code.disassemble())
	for entry in compiled_program["rules"]:
		print("")
		print("-- rule " + String(entry["name"]) + " : cond --")
		print((entry["cond"] as NovaCode).disassemble())
		print("-- rule " + String(entry["name"]) + " : body --")
		print((entry["body"] as NovaCode).disassemble())


# ==========================================================================
# Compile one source string; returns the NovaCompiler result or null
# ==========================================================================

func _compile_source(source: String, label: String, module_reader: Callable) -> Variant:
	var parser := NovaParser.new()
	var program := parser.parse(source, label)
	if parser.error != "":
		print("  PARSE FAIL: " + parser.error)
		failures += 1
		return null

	var resolver := NovaResolver.new(module_reader)
	resolver.resolve_program(program)
	if resolver.error != "":
		print("  RESOLVE FAIL: " + resolver.error)
		failures += 1
		return null

	var compiler := NovaCompiler.new()
	var result := compiler.compile_program(program)
	if compiler.error != "":
		print("  COMPILE FAIL: " + compiler.error)
		failures += 1
		return null

	compiled += 1
	return result


# ==========================================================================
# The full 51-case conformance corpus, as a crash/compile smoke test
# ==========================================================================

func _run_conformance_corpus() -> void:
	print("")
	print("==================== conformance corpus ====================")
	var doc := _load_conformance()
	if doc.is_empty():
		print("  SKIP: could not read " + CONFORMANCE)
		return
	var modules: Dictionary = doc.get("modules", {})
	var reader := func(path): return modules.get(path)
	var cases: Array = doc.get("cases", [])
	var ok := 0
	for entry in cases:
		var case: Dictionary = entry
		var res = _compile_source(String(case["source"]), String(case["name"]), reader)
		if res != null:
			ok += 1
	print("  " + str(ok) + "/" + str(cases.size()) + " conformance cases compiled")


func _load_conformance() -> Dictionary:
	if not FileAccess.file_exists(CONFORMANCE):
		return {}
	var f := FileAccess.open(CONFORMANCE, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


# ==========================================================================
# File readers
# ==========================================================================

func _read_res(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	return text


## For a script with no imports at all (reactor_rules.nova, the closures
## sample): any import would be a real failure, so return null rather than
## silently resolving something unintended.
func _read_no_imports(_path: String):
	return null


## Mirrors nova_vm.gd's default reader: relative paths resolve under
## res://scripts/, same as `NovaVM.SCRIPT_DIR`.
func _read_under_scripts(path: String):
	return _read_res("res://scripts/" + path)
