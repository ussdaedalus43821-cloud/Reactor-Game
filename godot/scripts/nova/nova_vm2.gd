class_name NovaVM2
extends RefCounted

## The bytecode VM: runs NovaCode (nova_code.gd) produced by NovaResolver +
## NovaCompiler. Implements the opcode contract documented in
## nova_opcodes.gd exactly -- `nova_compiler_test.gd`'s disassembly and
## `parity_check.gd`'s dual-backend run are what hold this to that.
##
## No GDScript recursion for a Nova-to-Nova call. `_run()` is one
## `while true: match op:` loop with a *local* explicit call stack
## (`call_frames`); CALL/CALL_NAME push the caller's Frame there and swap
## the loop's working `frame`/`ip` to the callee's, RETURN pops it back.
## GDScript recursion only happens for a call this VM doesn't itself own:
## IMPORT re-entering `execute()` through the owning NovaVM's
## `load_module()`, bounded by the module graph's depth, not by anything
## a NovaLang program controls -- the same shape the tree-walker already
## has today (`_import` calling `exec_block` reentrantly).
##
## Value model is the tree-walker's, unchanged: NovaLang values are plain
## GDScript Variants (float/String/bool/null/Array/Dictionary), plus
## `NovaEvaluator.NovaFunc` for a callable. A VM2 closure is a NovaFunc
## with `code`/`cells` set instead of `body`/`closure` -- the SAME class,
## so `NovaEvaluator.type_name()`/`text()`/`truthy()`/`deep_equal()` need
## no changes to recognize a function value made by either backend, and
## the two backends can never disagree about what a function prints as.
##
## Builtins are delegated to a scratch NovaEvaluator instance (`_builtins`)
## sharing this VM's `rng` -- not reimplemented, so there is exactly one
## copy of `call_builtin()`'s 30-odd functions to keep correct. `held()`
## is small enough (nova_evaluator.gd's `_eval_held`) to port directly
## instead.
##
## Every opcode is cached as a local int constant before the dispatch
## loop (`_LOAD_CONST` etc. below) instead of matched against
## `NovaOpcodes.OP.LOAD_CONST` directly, inside the loop -- same reason
## reference/novalang.py's `execute()` does this: one dict lookup per
## opcode kind instead of one per instruction executed.

const MAX_CALL_DEPTH := NovaEvaluator.MAX_CALL_DEPTH
const MAX_STEPS := NovaEvaluator.MAX_STEPS

const _LOAD_CONST := NovaOpcodes.OP.LOAD_CONST
const _POP := NovaOpcodes.OP.POP
const _LOAD_FAST := NovaOpcodes.OP.LOAD_FAST
const _STORE_FAST := NovaOpcodes.OP.STORE_FAST
const _LOAD_CELL := NovaOpcodes.OP.LOAD_CELL
const _STORE_CELL := NovaOpcodes.OP.STORE_CELL
const _LOAD_FREE := NovaOpcodes.OP.LOAD_FREE
const _STORE_FREE := NovaOpcodes.OP.STORE_FREE
const _LOAD_GLOBAL := NovaOpcodes.OP.LOAD_GLOBAL
const _STORE_GLOBAL := NovaOpcodes.OP.STORE_GLOBAL
const _NEW_CELLS := NovaOpcodes.OP.NEW_CELLS
const _ADD := NovaOpcodes.OP.ADD
const _SUB := NovaOpcodes.OP.SUB
const _MUL := NovaOpcodes.OP.MUL
const _DIV := NovaOpcodes.OP.DIV
const _MOD := NovaOpcodes.OP.MOD
const _NEG := NovaOpcodes.OP.NEG
const _NOT := NovaOpcodes.OP.NOT
const _EQ := NovaOpcodes.OP.EQ
const _NE := NovaOpcodes.OP.NE
const _LT := NovaOpcodes.OP.LT
const _GT := NovaOpcodes.OP.GT
const _LE := NovaOpcodes.OP.LE
const _GE := NovaOpcodes.OP.GE
const _JUMP := NovaOpcodes.OP.JUMP
const _JUMP_IF_FALSE := NovaOpcodes.OP.JUMP_IF_FALSE
const _JUMP_IF_FALSE_KEEP := NovaOpcodes.OP.JUMP_IF_FALSE_KEEP
const _JUMP_IF_TRUE_KEEP := NovaOpcodes.OP.JUMP_IF_TRUE_KEEP
const _BUILD_LIST := NovaOpcodes.OP.BUILD_LIST
const _BUILD_DICT := NovaOpcodes.OP.BUILD_DICT
const _INDEX := NovaOpcodes.OP.INDEX
const _GET_MEMBER := NovaOpcodes.OP.GET_MEMBER
const _STORE_INDEX := NovaOpcodes.OP.STORE_INDEX
const _STORE_MEMBER := NovaOpcodes.OP.STORE_MEMBER
const _MAKE_FUNCTION := NovaOpcodes.OP.MAKE_FUNCTION
const _CALL := NovaOpcodes.OP.CALL
const _CALL_NAME := NovaOpcodes.OP.CALL_NAME
const _RETURN := NovaOpcodes.OP.RETURN
const _IMPORT := NovaOpcodes.OP.IMPORT


## One boxed local, shared by every LOAD_CELL/STORE_CELL/LOAD_FREE/
## STORE_FREE that addresses the same captured name.
class Cell:
	var value


## One suspended-or-running activation: a CodeObject, its locals, the
## Cells its own closure (if any) captured, and its own operand stack.
class Frame:
	var code: NovaCode
	var slots: Array
	var cells: Array
	var stack: Array = []
	var ip: int = 0

	func _init(c: NovaCode, closure_cells: Array) -> void:
		code = c
		cells = closure_cells
		slots = []
		slots.resize(c.nslots)


var rng: RandomNumberGenerator
var owner_vm = null                  # NovaVM, for IMPORT's load_module() callback
var globals: Dictionary = {}
var held_timers: Array = []
var dt := 0.0
var host_functions: Dictionary = {}  # name -> Callable(Array) -> Variant
var error := ""

var _steps := 0
var _builtins: NovaEvaluator        # delegate for call_builtin(); owns `output` too


func _init(generator: RandomNumberGenerator = null, owner = null) -> void:
	rng = generator if generator != null else RandomNumberGenerator.new()
	owner_vm = owner
	_builtins = NovaEvaluator.new(rng, owner)


func register_function(name: String, fn: Callable) -> void:
	host_functions[name] = fn


## Everything print() has emitted since the last drain. `output` lives on
## `_builtins`, never exposed as a field here directly -- a field holding
## the same Array by reference would silently stop being the same array
## the moment either side reassigned it (`x = []` makes a new Array; it
## does not clear the old one in place), and print() and drain both need
## to agree on which Array that is.
func drain_output() -> Array:
	var lines: Array = _builtins.output.duplicate()
	_builtins.output.clear()
	return lines


## Resets the per-entry guards. Called once per tick / per public call
## from the façade, not once per `execute()` -- matches
## `NovaEvaluator.begin_run()`: the step budget is shared across every
## rule body and fault body a single tick runs, not reset between them.
func begin_run() -> void:
	_steps = 0
	error = ""
	_builtins.error = ""


# ==========================================================================
# Public entry points
# ==========================================================================

## Runs a module/rule-body/fault-body/bare-expression CodeObject -- never
## a closure, so it captures nothing (`cells` is always empty here).
func execute(code: NovaCode, args: Array = []) -> Variant:
	error = ""
	var frame := Frame.new(code, [])
	for i in range(mini(args.size(), code.param_count)):
		frame.slots[i] = args[i]
	return _run(frame)


## Calls an already-known function value (a NovaEvaluator.NovaFunc with
## `code` set). Checks arity the same way `nova_evaluator.gd`'s
## `call_function()` does, including its exact error wording.
func call_closure(fn, args: Array) -> Variant:
	error = ""
	if not (fn is NovaEvaluator.NovaFunc) or fn.code == null:
		return _err(0, "cannot call a %s" % NovaEvaluator.type_name(fn))
	var code: NovaCode = fn.code
	if args.size() != code.param_count:
		return _err(0, "%s() takes %d argument(s), got %d" %
				[fn.name if fn.name != "" else "anonymous", code.param_count, args.size()])
	var frame := Frame.new(code, fn.cells)
	for i in range(code.param_count):
		frame.slots[i] = args[i]
	return _run(frame)


# ==========================================================================
# The loop
# ==========================================================================

func _run(entry_frame: Frame) -> Variant:
	var frame := entry_frame
	var call_frames: Array = []        # suspended callers, outermost first
	var ip := 0

	while true:
		_steps += 1
		if _steps > MAX_STEPS:
			return _err(_line(frame, ip), "step budget exhausted (%d) -- runaway loop?" % MAX_STEPS)

		var op: int = frame.code.ops[ip]
		var arg = frame.code.args[ip]
		var line: int = _line(frame, ip)
		ip += 1

		match op:
			_LOAD_CONST:
				frame.stack.push_back(frame.code.constants[arg])

			_POP:
				frame.stack.pop_back()

			_LOAD_FAST:
				frame.stack.push_back(frame.slots[arg])

			_STORE_FAST:
				frame.slots[arg] = frame.stack.pop_back()

			_LOAD_CELL:
				var cell: Cell = frame.slots[arg]
				frame.stack.push_back(cell.value)

			_STORE_CELL:
				var cell2: Cell = frame.slots[arg]
				cell2.value = frame.stack.pop_back()

			_LOAD_FREE:
				var fcell: Cell = frame.cells[arg]
				frame.stack.push_back(fcell.value)

			_STORE_FREE:
				var fcell2: Cell = frame.cells[arg]
				fcell2.value = frame.stack.pop_back()

			_LOAD_GLOBAL:
				var gname: String = arg
				if not globals.has(gname):
					return _err(line, "unknown identifier '%s'" % gname)
				frame.stack.push_back(globals[gname])

			_STORE_GLOBAL:
				globals[arg] = frame.stack.pop_back()

			_NEW_CELLS:
				var cell_slots: Array = arg
				for slot_index in cell_slots:
					var boxed := Cell.new()
					boxed.value = frame.slots[slot_index]
					frame.slots[slot_index] = boxed

			_ADD, _SUB, _MUL, _DIV, _MOD:
				var b_val = frame.stack.pop_back()
				var a_val = frame.stack.pop_back()
				var added = _binary_arith(op, a_val, b_val, line)
				if error != "":
					return null
				frame.stack.push_back(added)

			_NEG:
				var neg_v = frame.stack.pop_back()
				var neg_n := _num(neg_v, line)
				if error != "":
					return null
				frame.stack.push_back(-neg_n)

			_NOT:
				var not_v = frame.stack.pop_back()
				frame.stack.push_back(not NovaEvaluator.truthy(not_v))

			_EQ, _NE, _LT, _GT, _LE, _GE:
				var cb = frame.stack.pop_back()
				var ca = frame.stack.pop_back()
				var cmp = _compare(op, ca, cb, line)
				if error != "":
					return null
				frame.stack.push_back(cmp)

			_JUMP:
				ip = arg

			_JUMP_IF_FALSE:
				var jv = frame.stack.pop_back()
				if not NovaEvaluator.truthy(jv):
					ip = arg

			_JUMP_IF_FALSE_KEEP:
				var kv = frame.stack[frame.stack.size() - 1]
				var kb: bool = NovaEvaluator.truthy(kv)
				frame.stack[frame.stack.size() - 1] = kb
				if kb:
					frame.stack.pop_back()
				else:
					ip = arg

			_JUMP_IF_TRUE_KEEP:
				var tv = frame.stack[frame.stack.size() - 1]
				var tb: bool = NovaEvaluator.truthy(tv)
				frame.stack[frame.stack.size() - 1] = tb
				if tb:
					ip = arg
				else:
					frame.stack.pop_back()

			_BUILD_LIST:
				var n: int = arg
				var items: Array = []
				if n > 0:
					items = frame.stack.slice(frame.stack.size() - n, frame.stack.size())
					frame.stack.resize(frame.stack.size() - n)
				frame.stack.push_back(items)

			_BUILD_DICT:
				var pair_count: int = arg
				var out := {}
				if pair_count > 0:
					var flat: Array = frame.stack.slice(
							frame.stack.size() - pair_count * 2, frame.stack.size())
					frame.stack.resize(frame.stack.size() - pair_count * 2)
					for i in range(pair_count):
						var k = flat[i * 2]
						var v = flat[i * 2 + 1]
						out[k if typeof(k) == TYPE_STRING else NovaEvaluator.text(k)] = v
				frame.stack.push_back(out)

			_INDEX:
				var idx_v = frame.stack.pop_back()
				var idx_obj = frame.stack.pop_back()
				var idx_result = _get_element(idx_obj, idx_v, line)
				if error != "":
					return null
				frame.stack.push_back(idx_result)

			_GET_MEMBER:
				var mem_obj = frame.stack.pop_back()
				var mem_result = _get_element(mem_obj, arg, line)
				if error != "":
					return null
				frame.stack.push_back(mem_result)

			_STORE_INDEX:
				var si_idx = frame.stack.pop_back()
				var si_obj = frame.stack.pop_back()
				var si_value = frame.stack.pop_back()
				_set_element(si_obj, si_idx, si_value, line)
				if error != "":
					return null

			_STORE_MEMBER:
				var sm_obj = frame.stack.pop_back()
				var sm_value = frame.stack.pop_back()
				_set_element(sm_obj, arg, sm_value, line)
				if error != "":
					return null

			_MAKE_FUNCTION:
				var mk: Dictionary = arg
				var child: NovaCode = frame.code.child_codes[mk["child"]]
				var captured: Array = []
				for cap in mk["captures"]:
					if cap["source"] == "cell":
						captured.append(frame.slots[cap["index"]])
					else:
						captured.append(frame.cells[cap["index"]])
				var fn := NovaEvaluator.NovaFunc.new()
				fn.name = child.name
				fn.code = child
				fn.cells = captured
				frame.stack.push_back(fn)

			_CALL:
				var argc: int = arg
				var call_args: Array = []
				if argc > 0:
					call_args = frame.stack.slice(frame.stack.size() - argc, frame.stack.size())
					frame.stack.resize(frame.stack.size() - argc)
				var callee = frame.stack.pop_back()
				if not (callee is NovaEvaluator.NovaFunc) or callee.code == null:
					return _err(line, "cannot call a %s" % NovaEvaluator.type_name(callee))
				var pushed := _enter_call(callee, call_args, call_frames, frame, ip, line)
				if error != "":
					return null
				frame = pushed["frame"]
				call_frames = pushed["call_frames"]
				ip = 0
				continue

			_CALL_NAME:
				var info: Dictionary = arg
				var cargc: int = info["argc"]
				var cargs: Array = []
				if cargc > 0:
					cargs = frame.stack.slice(frame.stack.size() - cargc, frame.stack.size())
					frame.stack.resize(frame.stack.size() - cargc)
				var bound = _soft_read_loc(info["loc"], frame)
				if bound is NovaEvaluator.NovaFunc and bound.code != null:
					var pushed2 := _enter_call(bound, cargs, call_frames, frame, ip, line)
					if error != "":
						return null
					frame = pushed2["frame"]
					call_frames = pushed2["call_frames"]
					ip = 0
					continue
				var result = _call_by_name(info, bound, cargs, line)
				if error != "":
					return null
				frame.stack.push_back(result)

			_RETURN:
				var value = frame.stack.pop_back()
				if call_frames.is_empty():
					return value
				frame = call_frames.pop_back()
				ip = frame.ip
				frame.stack.push_back(value)

			_IMPORT:
				var exports = owner_vm.load_module(arg)
				if owner_vm.error != "":
					return _err(line, owner_vm.error)
				frame.stack.push_back(exports)

			_:
				return _err(line, "VM bug: unknown opcode %d" % op)


## Shared by CALL and CALL_NAME: build the callee's Frame, park the
## caller. Returns {"frame", "call_frames"} rather than mutating `frame`/
## `call_frames` in place, since GDScript has no by-reference locals.
func _enter_call(fn, args: Array, call_frames: Array, frame: Frame, ip: int, line: int) -> Dictionary:
	var code: NovaCode = fn.code
	if args.size() != code.param_count:
		_err(line, "%s() takes %d argument(s), got %d" %
				[fn.name if fn.name != "" else "anonymous", code.param_count, args.size()])
		return {}
	if call_frames.size() >= MAX_CALL_DEPTH:
		_err(line, "call depth limit (%d) exceeded -- infinite recursion?" % MAX_CALL_DEPTH)
		return {}
	var new_frame := Frame.new(code, fn.cells)
	for i in range(code.param_count):
		new_frame.slots[i] = args[i]
	frame.ip = ip
	call_frames.push_back(frame)
	return {"frame": new_frame, "call_frames": call_frames}


## CALL_NAME once the bound-value check has already failed to find a
## callable: held() (if this call site has one), then builtin, then host
## function -- same order and wording as `nova_evaluator.gd`'s
## `_eval_call`.
func _call_by_name(info: Dictionary, bound, args: Array, line: int) -> Variant:
	var name: String = info["name"]
	var held_slot: int = info["held_slot"]
	if held_slot >= 0:
		return _eval_held(args, held_slot, line)
	if NovaEvaluator.BUILTIN_ARITY.has(name):
		var result = _builtins.call_builtin(name, args, line)
		if _builtins.error != "":
			error = _builtins.error
			return null
		return result
	if host_functions.has(name):
		var callable: Callable = host_functions[name]
		return callable.call(args)
	if bound != null:
		return _err(line, "cannot call a %s" % NovaEvaluator.type_name(bound))
	return _err(line, "unknown function '%s'" % name)


func _eval_held(args: Array, slot: int, line: int) -> Variant:
	if args.size() != 2:
		return _err(line, "held(cond, seconds) takes 2 argument(s), got %d" % args.size())
	var cond := NovaEvaluator.truthy(args[0])
	var secs := _num(args[1], line)
	if error != "":
		return null
	if slot < 0 or slot >= held_timers.size():
		return false
	if cond:
		held_timers[slot] = float(held_timers[slot]) + dt
	else:
		held_timers[slot] = 0.0
	return float(held_timers[slot]) >= secs


# ==========================================================================
# Locations (for CALL_NAME's bound-value check only -- the ordinary
# LOAD_*/STORE_* opcodes above are each already specific to one kind)
# ==========================================================================

func _soft_read_loc(loc: Array, frame: Frame) -> Variant:
	match loc[0]:
		"fast":
			return frame.slots[loc[1]]
		"cell":
			var c: Cell = frame.slots[loc[1]]
			return c.value
		"free":
			var fc: Cell = frame.cells[loc[1]]
			return fc.value
		"global":
			return globals.get(loc[1])
	return null


# ==========================================================================
# Value operations -- mirrors nova_evaluator.gd's _num/_eval_binary/
# _get_element/_set_element exactly, wording included, so parity_check.gd
# sees identical error text from either backend.
# ==========================================================================

func _num(v, line: int) -> float:
	match typeof(v):
		TYPE_BOOL:
			return 1.0 if v else 0.0
		TYPE_INT, TYPE_FLOAT:
			return float(v)
	_err(line, "expected a number, got %s" % NovaEvaluator.type_name(v))
	return 0.0


func _binary_arith(op: int, a, b, line: int) -> Variant:
	if op == _ADD:
		if typeof(a) == TYPE_STRING or typeof(b) == TYPE_STRING:
			return NovaEvaluator.text(a) + NovaEvaluator.text(b)
		if typeof(a) == TYPE_ARRAY and typeof(b) == TYPE_ARRAY:
			var left: Array = a
			var right: Array = b
			var joined: Array = left.duplicate()
			joined.append_array(right)
			return joined
	var x := _num(a, line)
	var y := _num(b, line)
	if error != "":
		return null
	match op:
		_ADD:
			return x + y
		_SUB:
			return x - y
		_MUL:
			return x * y
		_DIV:
			return (x / y) if y != 0.0 else 0.0
		_MOD:
			return fmod(x, y) if y != 0.0 else 0.0
	return _err(line, "VM bug: unknown arithmetic opcode %d" % op)


func _compare(op: int, a, b, line: int) -> Variant:
	if op == _EQ:
		return NovaEvaluator.deep_equal(a, b)
	if op == _NE:
		return not NovaEvaluator.deep_equal(a, b)
	var x := _num(a, line)
	var y := _num(b, line)
	if error != "":
		return null
	match op:
		_LT:
			return x < y
		_GT:
			return x > y
		_LE:
			return x <= y
		_GE:
			return x >= y
	return _err(line, "VM bug: unknown comparison opcode %d" % op)


func _get_element(obj, key, line: int) -> Variant:
	if typeof(obj) == TYPE_DICTIONARY:
		var d: Dictionary = obj
		var k = key if typeof(key) == TYPE_STRING else NovaEvaluator.text(key)
		if not d.has(k):
			return _err(line, "dict has no key '%s'" % String(k))
		return d[k]
	if typeof(obj) == TYPE_ARRAY:
		var l: Array = obj
		if NovaEvaluator.type_name(key) != "number":
			return _err(line, "list index must be a number")
		var raw := int(float(key))
		var i := raw
		if i < 0:
			i += l.size()
		if i < 0 or i >= l.size():
			return _err(line, "list index %d out of range (size %d)" % [raw, l.size()])
		return l[i]
	if typeof(obj) == TYPE_STRING or typeof(obj) == TYPE_STRING_NAME:
		var s := String(obj)
		if NovaEvaluator.type_name(key) != "number":
			return _err(line, "string index must be a number")
		var raw2 := int(float(key))
		var j := raw2
		if j < 0:
			j += s.length()
		if j < 0 or j >= s.length():
			return _err(line, "string index %d out of range (length %d)" % [raw2, s.length()])
		return s.substr(j, 1)
	return _err(line, "cannot index a %s" % NovaEvaluator.type_name(obj))


func _set_element(obj, key, value, line: int) -> void:
	if typeof(obj) == TYPE_DICTIONARY:
		var d: Dictionary = obj
		d[key if typeof(key) == TYPE_STRING else NovaEvaluator.text(key)] = value
		return
	if typeof(obj) == TYPE_ARRAY:
		var l: Array = obj
		if NovaEvaluator.type_name(key) != "number":
			_err(line, "list index must be a number")
			return
		var raw := int(float(key))
		var i := raw
		if i < 0:
			i += l.size()
		if i < 0 or i >= l.size():
			_err(line, "list index %d out of range (size %d)" % [raw, l.size()])
			return
		l[i] = value
		return
	_err(line, "cannot assign into a %s" % NovaEvaluator.type_name(obj))


func _line(frame: Frame, ip: int) -> int:
	var positions := frame.code.positions
	return positions[ip] if ip < positions.size() else 0


func _err(line: int, msg: String) -> Variant:
	if error == "":
		error = ("line %d: %s" % [line, msg]) if line > 0 else msg
	return null
