class_name NovaEvaluator
extends RefCounted

## NovaLang tree-walking evaluator.
##
## Owns everything about *running* a parsed program: scope chains, closures,
## the value model, the builtin library, and the registry through which
## GDScript exposes its own functions to NovaLang.
##
## Mirrors reference/nova_evaluator.py statement for statement. Two things
## are load-bearing for that:
##
##   * Control flow uses no exceptions in either implementation. A statement
##     returns null for "fell off the end", or a small Dictionary
##     {"flow": "return"|"break"|"continue", "value": ...}. Errors are
##     reported through `error` and unwind by the same mechanism.
##   * Numbers are always floats, `==` on them is exact (never approximate),
##     and text formatting is pinned in NovaLexer.number_text(). Anything
##     fuzzier drifts between the two runtimes.
##
## Two guards keep a bad .nova file from taking the game down: a step budget
## (a `while true {}` fails the tick instead of hanging the render thread)
## and a call-depth limit (runaway recursion is an error, not a crash).

const MAX_CALL_DEPTH := 128
const MAX_STEPS := 500000

const FLOW_RETURN := "return"
const FLOW_BREAK := "break"
const FLOW_CONTINUE := "continue"

## The builtin vocabulary, name -> minimum arity. tools/check_parity.py
## asserts the reference implements exactly this set with these arities.
const BUILTIN_ARITY := {
	# numeric
	"abs": 1, "min": 1, "max": 1, "clamp": 3, "exp": 1, "sqrt": 1,
	"floor": 1, "round": 1, "pow": 2, "ramp": 1, "lerp": 3,
	"pick": 1, "rand": 2, "held": 2,
	# types and conversion
	"type": 1, "str": 1, "num": 1, "bool": 1, "int": 1,
	# collections and strings
	"len": 1, "keys": 1, "has": 2, "get": 3, "append": 2, "remove_at": 2,
	"slice": 3, "range": 1, "join": 2, "split": 2, "contains": 2,
	"upper": 1, "lower": 1,
	# output
	"print": 0,
}


## One lexical scope. `parent` is null only for a module's global scope.
class Env:
	var values: Dictionary = {}
	var parent = null

	func _init(p = null) -> void:
		parent = p

	func has_var(name: String) -> bool:
		var env = self
		while env != null:
			if env.values.has(name):
				return true
			env = env.parent
		return false

	func get_var(name: String):
		var env = self
		while env != null:
			if env.values.has(name):
				return env.values[name]
			env = env.parent
		return null

	## `let` -- always creates a binding in *this* scope.
	func declare(name: String, value) -> void:
		values[name] = value

	## `set` / bare `=` -- rebinds the nearest existing binding, or creates a
	## global one if there is none. The fallback is what keeps v1 policies
	## working, where rules `set` variables no one declared.
	func assign(name: String, value) -> void:
		var env = self
		while env != null:
			if env.values.has(name):
				env.values[name] = value
				return
			env = env.parent
		var root = self
		while root.parent != null:
			root = root.parent
		root.values[name] = value


## A user-defined function plus the environment it closed over.
class NovaFunc:
	var name: String
	var params: Array
	var body: Dictionary
	var closure

	func _init(n: String, p: Array, b: Dictionary, c) -> void:
		name = n
		params = p
		body = b
		closure = c


# ==========================================================================
# Value model -- identical rules on both sides
# ==========================================================================

static func type_name(v) -> String:
	match typeof(v):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "bool"
		TYPE_INT, TYPE_FLOAT:
			return "number"
		TYPE_STRING, TYPE_STRING_NAME:
			return "string"
		TYPE_ARRAY:
			return "list"
		TYPE_DICTIONARY:
			return "dict"
		TYPE_OBJECT:
			if v is NovaFunc:
				return "func"
	return "unknown"


## Public number coercion for host code reading NovaLang values.
static func to_number(v, fallback: float = 0.0) -> float:
	match typeof(v):
		TYPE_BOOL:
			return 1.0 if v else 0.0
		TYPE_INT, TYPE_FLOAT:
			return float(v)
	return fallback


static func truthy(v) -> bool:
	match typeof(v):
		TYPE_NIL:
			return false
		TYPE_BOOL:
			return v
		TYPE_INT, TYPE_FLOAT:
			return float(v) != 0.0
		TYPE_STRING, TYPE_STRING_NAME:
			return String(v).length() > 0
		TYPE_ARRAY:
			var l: Array = v
			return l.size() > 0
		TYPE_DICTIONARY:
			var d: Dictionary = v
			return d.size() > 0
	return true


## Display form: what print() shows and what `+` concatenates.
static func text(v) -> String:
	match typeof(v):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if v else "false"
		TYPE_INT, TYPE_FLOAT:
			return NovaLexer.number_text(float(v))
		TYPE_STRING, TYPE_STRING_NAME:
			return String(v)
		TYPE_ARRAY:
			var list_in: Array = v
			var parts := PackedStringArray()
			for item in list_in:
				parts.append(inner_text(item))
			return "[" + ", ".join(parts) + "]"
		TYPE_DICTIONARY:
			var dict_in: Dictionary = v
			var pairs := PackedStringArray()
			for key in dict_in:
				pairs.append(String(key) + ": " + inner_text(dict_in[key]))
			return "{" + ", ".join(pairs) + "}"
		TYPE_OBJECT:
			if v is NovaFunc:
				var fn: NovaFunc = v
				return "<func %s>" % (fn.name if fn.name != "" else "anonymous")
	return "<unknown>"


## Inside a list or dict, strings are quoted so nesting stays readable.
static func inner_text(v) -> String:
	if typeof(v) == TYPE_STRING or typeof(v) == TYPE_STRING_NAME:
		return "\"" + String(v) + "\""
	return text(v)


static func deep_equal(a, b) -> bool:
	var ta := type_name(a)
	var tb := type_name(b)
	if ta != tb:
		return false
	match ta:
		"null":
			return true
		"number":
			return float(a) == float(b)        # exact, never approximate
		"bool":
			return bool(a) == bool(b)
		"string":
			return String(a) == String(b)
		"list":
			var la: Array = a
			var lb: Array = b
			if la.size() != lb.size():
				return false
			for i in range(la.size()):
				if not deep_equal(la[i], lb[i]):
					return false
			return true
		"dict":
			var da: Dictionary = a
			var db: Dictionary = b
			if da.size() != db.size():
				return false
			for key in da:
				if not db.has(key) or not deep_equal(da[key], db[key]):
					return false
			return true
	return a == b


# ==========================================================================
# Evaluator state
# ==========================================================================

var rng: RandomNumberGenerator
var vm = null                       # for `import`; may be null
var globals: Env = Env.new()
var host_functions: Dictionary = {}  # name -> Callable(Array) -> Variant
var held_timers: Array = []
var output: Array = []               # everything print() has emitted
var error := ""
var dt := 0.0

var _steps := 0
var _depth := 0


func _init(generator: RandomNumberGenerator = null, owner = null) -> void:
	rng = generator if generator != null else RandomNumberGenerator.new()
	vm = owner


## Expose a host function to NovaLang. Called as a plain function from
## .nova source; receives the evaluated argument list as an Array.
func register_function(name: String, fn: Callable) -> void:
	host_functions[name] = fn


func fail(line: int, message: String) -> Dictionary:
	if error == "":
		error = ("line %d: %s" % [line, message]) if line > 0 else message
	return {"flow": FLOW_RETURN, "value": null}


func _tick_budget(line: int) -> bool:
	_steps += 1
	if _steps > MAX_STEPS:
		fail(line, "step budget exhausted (%d) -- runaway loop?" % MAX_STEPS)
		return false
	return true


## Reset the per-entry guards. Called once per tick / per public call, not
## per statement.
func begin_run() -> void:
	_steps = 0
	_depth = 0
	error = ""


# ==========================================================================
# Statements
# ==========================================================================

func exec_block(stmts: Array, env) -> Variant:
	for entry in stmts:
		var stmt: Dictionary = entry
		var signal_out = exec_stmt(stmt, env)
		if error != "":
			return {"flow": FLOW_RETURN, "value": null}
		if signal_out != null:
			return signal_out
	return null


func exec_stmt(node: Dictionary, env) -> Variant:
	var kind: String = node["k"]
	var line: int = int(node.get("line", 0))
	if not _tick_budget(line):
		return {"flow": FLOW_RETURN, "value": null}

	match kind:
		"exprstmt":
			eval(node["expr"], env)
			return null
		"let":
			var value = eval(node["expr"], env)
			if value is NovaFunc and (value as NovaFunc).name == "":
				(value as NovaFunc).name = node["name"]
			env.declare(node["name"], value)
			return null
		"assign":
			return _assign(node, env)
		"block":
			return exec_block(node["body"], Env.new(env))
		"if":
			if truthy(eval(node["cond"], env)):
				return exec_block(node["then"]["body"], Env.new(env))
			if node["else"] != null:
				return exec_block(node["else"]["body"], Env.new(env))
			return null
		"while":
			return _exec_while(node, env, line)
		"return":
			var result = null
			if node["expr"] != null:
				result = eval(node["expr"], env)
			return {"flow": FLOW_RETURN, "value": result}
		"break":
			return {"flow": FLOW_BREAK, "value": null}
		"continue":
			return {"flow": FLOW_CONTINUE, "value": null}
		"import":
			return _import(node, env)

	return fail(line, "cannot execute a '%s' statement" % kind)


func _exec_while(node: Dictionary, env, line: int) -> Variant:
	while true:
		if not _tick_budget(line):
			return {"flow": FLOW_RETURN, "value": null}
		if not truthy(eval(node["cond"], env)):
			return null
		if error != "":
			return {"flow": FLOW_RETURN, "value": null}
		var signal_out = exec_block(node["body"]["body"], Env.new(env))
		if signal_out == null:
			continue
		var flow: String = signal_out["flow"]
		if flow == FLOW_BREAK:
			return null
		if flow == FLOW_CONTINUE:
			continue
		return signal_out
	return null


func _assign(node: Dictionary, env) -> Variant:
	var target: Dictionary = node["target"]
	var value = eval(node["expr"], env)
	if error != "":
		return {"flow": FLOW_RETURN, "value": null}
	var line: int = int(node.get("line", 0))

	match target["k"]:
		"var":
			env.assign(target["name"], value)
			return null
		"index":
			var obj = eval(target["obj"], env)
			var idx = eval(target["idx"], env)
			return _set_element(obj, idx, value, line)
		"member":
			var owner_obj = eval(target["obj"], env)
			return _set_element(owner_obj, target["name"], value, line)

	return fail(line, "cannot assign to a '%s'" % target["k"])


func _set_element(obj, key, value, line: int) -> Variant:
	if typeof(obj) == TYPE_DICTIONARY:
		var d: Dictionary = obj
		d[key if typeof(key) == TYPE_STRING else text(key)] = value
		return null
	if typeof(obj) == TYPE_ARRAY:
		var l: Array = obj
		if type_name(key) != "number":
			return fail(line, "list index must be a number")
		var raw := int(float(key))
		var i := raw
		if i < 0:
			i += l.size()
		if i < 0 or i >= l.size():
			return fail(line, "list index %d out of range (size %d)"
					% [raw, l.size()])
		l[i] = value
		return null
	return fail(line, "cannot assign into a %s" % type_name(obj))


func _import(node: Dictionary, env) -> Variant:
	var line: int = int(node.get("line", 0))
	if vm == null:
		return fail(line, "import is not available here")
	var exports: Dictionary = vm.load_module(node["path"])
	if vm.error != "":
		return fail(line, vm.error)
	if node["alias"] != "":
		env.declare(node["alias"], exports)
	else:
		for name in exports:
			env.declare(name, exports[name])
	return null


# ==========================================================================
# Expressions
# ==========================================================================

func eval(node: Dictionary, env) -> Variant:
	var kind: String = node["k"]

	if kind == "num" or kind == "str" or kind == "bool":
		return node["v"]
	if kind == "null":
		return null

	if not _tick_budget(int(node.get("line", 0))):
		return null

	match kind:
		"var":
			var name: String = node["name"]
			if env.has_var(name):
				return env.get_var(name)
			fail(int(node.get("line", 0)), "unknown identifier '%s'" % name)
			return null
		"list":
			var items: Array = []
			for entry in node["items"]:
				items.append(eval(entry, env))
			return items
		"dict":
			var out: Dictionary = {}
			for pair in node["pairs"]:
				var key = eval(pair[0], env)
				out[key if typeof(key) == TYPE_STRING else text(key)] = \
					eval(pair[1], env)
			return out
		"func":
			return NovaFunc.new(node["name"], node["params"], node["body"], env)
		"unary":
			if node["op"] == "not":
				return not truthy(eval(node["a"], env))
			return -_num(eval(node["a"], env), int(node.get("line", 0)))
		"binary":
			return _eval_binary(node, env)
		"call":
			return _eval_call(node, env)
		"index":
			var obj = eval(node["obj"], env)
			return _get_element(obj, eval(node["idx"], env),
					int(node.get("line", 0)))
		"member":
			var owner_obj = eval(node["obj"], env)
			return _get_element(owner_obj, node["name"],
					int(node.get("line", 0)))

	fail(int(node.get("line", 0)), "cannot evaluate a '%s' node" % kind)
	return null


func _num(v, line: int) -> float:
	match typeof(v):
		TYPE_BOOL:
			return 1.0 if v else 0.0
		TYPE_INT, TYPE_FLOAT:
			return float(v)
	fail(line, "expected a number, got %s" % type_name(v))
	return 0.0


func _get_element(obj, key, line: int) -> Variant:
	if typeof(obj) == TYPE_DICTIONARY:
		var d: Dictionary = obj
		var k = key if typeof(key) == TYPE_STRING else text(key)
		if not d.has(k):
			fail(line, "dict has no key '%s'" % String(k))
			return null
		return d[k]
	if typeof(obj) == TYPE_ARRAY:
		var l: Array = obj
		if type_name(key) != "number":
			fail(line, "list index must be a number")
			return null
		var raw := int(float(key))
		var i := raw
		if i < 0:
			i += l.size()
		if i < 0 or i >= l.size():
			fail(line, "list index %d out of range (size %d)" % [raw, l.size()])
			return null
		return l[i]
	if typeof(obj) == TYPE_STRING or typeof(obj) == TYPE_STRING_NAME:
		var s := String(obj)
		if type_name(key) != "number":
			fail(line, "string index must be a number")
			return null
		var raw2 := int(float(key))
		var j := raw2
		if j < 0:
			j += s.length()
		if j < 0 or j >= s.length():
			fail(line, "string index %d out of range (length %d)"
					% [raw2, s.length()])
			return null
		return s.substr(j, 1)
	fail(line, "cannot index a %s" % type_name(obj))
	return null


func _eval_binary(node: Dictionary, env) -> Variant:
	var op: String = node["op"]
	var line: int = int(node.get("line", 0))

	if op == "and":
		if not truthy(eval(node["a"], env)):
			return false
		return truthy(eval(node["b"], env))
	if op == "or":
		if truthy(eval(node["a"], env)):
			return true
		return truthy(eval(node["b"], env))

	var a = eval(node["a"], env)
	var b = eval(node["b"], env)
	if error != "":
		return null

	if op == "==":
		return deep_equal(a, b)
	if op == "!=":
		return not deep_equal(a, b)

	# `+` doubles as string concatenation and list concatenation.
	if op == "+":
		if typeof(a) == TYPE_STRING or typeof(b) == TYPE_STRING:
			return text(a) + text(b)
		if typeof(a) == TYPE_ARRAY and typeof(b) == TYPE_ARRAY:
			var left: Array = a
			var right: Array = b
			var joined: Array = left.duplicate()
			joined.append_array(right)
			return joined

	var x := _num(a, line)
	var y := _num(b, line)
	match op:
		"<": return x < y
		">": return x > y
		"<=": return x <= y
		">=": return x >= y
		"+": return x + y
		"-": return x - y
		"*": return x * y
		"/": return (x / y) if y != 0.0 else 0.0
		"%": return fmod(x, y) if y != 0.0 else 0.0
	fail(line, "unknown operator '%s'" % op)
	return null


# ==========================================================================
# Calls
# ==========================================================================

func _eval_call(node: Dictionary, env) -> Variant:
	var callee: Dictionary = node["callee"]
	var line: int = int(node.get("line", 0))

	if callee["k"] == "var":
		# Resolution order for a bare name in call position: a user function
		# bound to it, then a builtin, then a host function. A *non-callable*
		# binding is skipped rather than being an error, which is what lets
		# the reactor policy have both a `scram` variable (the trip latch)
		# and a `scram()` host function without either shadowing the other.
		var name: String = callee["name"]
		var bound = env.get_var(name) if env.has_var(name) else null
		if not (bound is NovaFunc):
			# held() is a special form: its condition must stay unevaluated
			# so the timer only advances on ticks where the surrounding
			# guard actually reached this call site.
			if name == "held":
				return _eval_held(node, env)
			if BUILTIN_ARITY.has(name):
				var bargs := _eval_args(node["args"], env)
				if error != "":
					return null      # an argument failed; do not call
				return call_builtin(name, bargs, line)
			if host_functions.has(name):
				var hargs := _eval_args(node["args"], env)
				if error != "":
					return null
				var callable: Callable = host_functions[name]
				return callable.call(hargs)
			if bound != null:
				fail(line, "cannot call a %s" % type_name(bound))
			else:
				fail(line, "unknown function '%s'" % name)
			return null

	var fn = eval(callee, env)
	if error != "":
		return null
	if not (fn is NovaFunc):
		fail(line, "cannot call a %s" % type_name(fn))
		return null
	var args := _eval_args(node["args"], env)
	if error != "":
		return null
	return call_function(fn, args, line)


func _eval_args(arg_nodes: Array, env) -> Array:
	var out: Array = []
	for entry in arg_nodes:
		out.append(eval(entry, env))
	return out


func call_function(fn: NovaFunc, args: Array, line: int = 0) -> Variant:
	if args.size() != fn.params.size():
		fail(line, "%s() takes %d argument(s), got %d"
				% [fn.name if fn.name != "" else "anonymous",
				   fn.params.size(), args.size()])
		return null
	if _depth >= MAX_CALL_DEPTH:
		fail(line, "call depth limit (%d) exceeded -- infinite recursion?"
				% MAX_CALL_DEPTH)
		return null

	var scope := Env.new(fn.closure)
	for i in range(fn.params.size()):
		scope.declare(fn.params[i], args[i])

	_depth += 1
	var signal_out = exec_block(fn.body["body"], scope)
	_depth -= 1

	if signal_out != null and signal_out["flow"] == FLOW_RETURN:
		return signal_out["value"]
	return null


func _eval_held(node: Dictionary, env) -> Variant:
	var line: int = int(node.get("line", 0))
	var args: Array = node["args"]
	if args.size() != 2:
		fail(line, "held(cond, seconds) takes 2 argument(s), got %d" % args.size())
		return false
	var cond := truthy(eval(args[0], env))
	var secs := _num(eval(args[1], env), line)
	var slot: int = int(node["slot"])
	if slot < 0 or slot >= held_timers.size():
		return false
	if cond:
		held_timers[slot] = float(held_timers[slot]) + dt
	else:
		held_timers[slot] = 0.0
	return float(held_timers[slot]) >= secs


# ==========================================================================
# Builtins
# ==========================================================================

func call_builtin(name: String, args: Array, line: int) -> Variant:
	var need: int = int(BUILTIN_ARITY[name])
	if args.size() < need:
		fail(line, "%s() needs %d argument(s), got %d"
				% [name, need, args.size()])
		return null

	match name:
		"print":
			var parts := PackedStringArray()
			for a in args:
				parts.append(text(a))
			output.append(" ".join(parts))
			return null
		"abs":
			return absf(_num(args[0], line))
		"min":
			var lo := _num(args[0], line)
			for i in range(1, args.size()):
				lo = minf(lo, _num(args[i], line))
			return lo
		"max":
			var hi := _num(args[0], line)
			for i in range(1, args.size()):
				hi = maxf(hi, _num(args[i], line))
			return hi
		"clamp":
			var v := _num(args[0], line)
			var c_lo := _num(args[1], line)
			var c_hi := _num(args[2], line)
			return c_lo if v < c_lo else (c_hi if v > c_hi else v)
		"exp":
			return exp(clampf(_num(args[0], line), -700.0, 700.0))
		"sqrt":
			return sqrt(maxf(0.0, _num(args[0], line)))
		"floor":
			return floor(_num(args[0], line))
		"round":
			# Half away from zero, spelled out so it cannot drift.
			var r := _num(args[0], line)
			return floor(r + 0.5) if r >= 0.0 else -floor(-r + 0.5)
		"pow":
			return pow(_num(args[0], line), _num(args[1], line))
		"ramp":
			return clampf(_num(args[0], line), 0.0, 1.0)
		"lerp":
			var la := _num(args[0], line)
			var lb := _num(args[1], line)
			var lt := clampf(_num(args[2], line), 0.0, 1.0)
			return la + (lb - la) * lt
		"pick":
			return args[rng.randi_range(0, args.size() - 1)]
		"rand":
			return rng.randf_range(_num(args[0], line), _num(args[1], line))

		"type":
			return type_name(args[0])
		"str":
			return text(args[0])
		"num":
			if typeof(args[0]) == TYPE_STRING:
				return String(args[0]).to_float()
			return _num(args[0], line)
		"bool":
			return truthy(args[0])
		"int":
			return float(int(_num(args[0], line)))

		"len":
			match typeof(args[0]):
				TYPE_ARRAY:
					var len_list: Array = args[0]
					return float(len_list.size())
				TYPE_DICTIONARY:
					var len_dict: Dictionary = args[0]
					return float(len_dict.size())
				TYPE_STRING:
					return float(String(args[0]).length())
			fail(line, "len() needs a list, dict or string")
			return 0.0
		"keys":
			if typeof(args[0]) != TYPE_DICTIONARY:
				fail(line, "keys() needs a dict")
				return []
			var keys_dict: Dictionary = args[0]
			var ks: Array = []
			for k in keys_dict:
				ks.append(k)
			return ks
		"has":
			if typeof(args[0]) == TYPE_DICTIONARY:
				var hd: Dictionary = args[0]
				var hk = args[1] if typeof(args[1]) == TYPE_STRING else text(args[1])
				return hd.has(hk)
			if typeof(args[0]) == TYPE_ARRAY:
				var hl: Array = args[0]
				for item in hl:
					if deep_equal(item, args[1]):
						return true
				return false
			fail(line, "has() needs a dict or list")
			return false
		"get":
			if typeof(args[0]) != TYPE_DICTIONARY:
				fail(line, "get() needs a dict")
				return args[2]
			var gk = args[1] if typeof(args[1]) == TYPE_STRING else text(args[1])
			var gd: Dictionary = args[0]
			return gd[gk] if gd.has(gk) else args[2]
		"append":
			if typeof(args[0]) != TYPE_ARRAY:
				fail(line, "append() needs a list")
				return null
			var al: Array = args[0]
			al.append(args[1])
			return al
		"remove_at":
			if typeof(args[0]) != TYPE_ARRAY:
				fail(line, "remove_at() needs a list")
				return null
			var rl: Array = args[0]
			var ri := int(_num(args[1], line))
			if ri < 0 or ri >= rl.size():
				fail(line, "remove_at() index %d out of range (size %d)"
						% [ri, rl.size()])
				return null
			var removed = rl[ri]
			rl.remove_at(ri)
			return removed
		"slice":
			return _builtin_slice(args, line)
		"range":
			var count := int(_num(args[0], line))
			var out_range: Array = []
			if args.size() > 1:
				var stop := int(_num(args[1], line))
				var i := count
				while i < stop:
					out_range.append(float(i))
					i += 1
				return out_range
			var j := 0
			while j < count:
				out_range.append(float(j))
				j += 1
			return out_range
		"join":
			if typeof(args[0]) != TYPE_ARRAY:
				fail(line, "join() needs a list")
				return ""
			var sep: String = args[1] if typeof(args[1]) == TYPE_STRING \
					else text(args[1])
			var jl: Array = args[0]
			var strs := PackedStringArray()
			for item in jl:
				strs.append(text(item))
			return sep.join(strs)
		"split":
			var s: String = args[0] if typeof(args[0]) == TYPE_STRING \
					else text(args[0])
			var ssep: String = args[1] if typeof(args[1]) == TYPE_STRING \
					else text(args[1])
			var pieces: Array = []
			if ssep == "":
				for ci in range(s.length()):
					pieces.append(s.substr(ci, 1))
				return pieces
			for piece in s.split(ssep):
				pieces.append(piece)
			return pieces
		"contains":
			var hay: String = args[0] if typeof(args[0]) == TYPE_STRING \
					else text(args[0])
			var needle: String = args[1] if typeof(args[1]) == TYPE_STRING \
					else text(args[1])
			return hay.contains(needle)
		"upper":
			return text(args[0]).to_upper()
		"lower":
			return text(args[0]).to_lower()

	fail(line, "unknown builtin '%s'" % name)
	return null


func _builtin_slice(args: Array, line: int):
	var start := int(_num(args[1], line))
	var stop := int(_num(args[2], line))
	if start < 0:
		start = 0
	if stop < 0:
		stop = 0
	if typeof(args[0]) == TYPE_ARRAY:
		var l: Array = args[0]
		if stop > l.size():
			stop = l.size()
		if start >= stop:
			return []
		return l.slice(start, stop)
	if typeof(args[0]) == TYPE_STRING:
		var s := String(args[0])
		if stop > s.length():
			stop = s.length()
		if start >= stop:
			return ""
		return s.substr(start, stop - start)
	fail(line, "slice() needs a list or string")
	return null
