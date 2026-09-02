class_name NovaVM
extends RefCounted

## NovaLang virtual machine, in GDScript.
##
## This is a faithful port of sim/nova_runtime.py. It exists so that
## reactor_rules.nova is the single source of the reactor's control policy
## on *every* target: on macOS the Python daemon runs the same file, and on
## iOS and Web -- where no external process can be spawned -- Godot parses
## and runs it itself. Change a setpoint in the .nova file and all three
## platforms change together.
##
## The one deliberate difference from the Python implementation is the
## random number generator: pick()/rand() and the fault scheduler use
## Godot's RandomNumberGenerator, so a given seed does not produce the same
## fault sequence in both runtimes. Everything else -- operator precedence,
## short-circuiting, held() timers, edge/once latches, priority ordering,
## effect reset semantics -- matches.
##
## GDScript has no exceptions, so errors are reported through `error`
## (parse time) and `runtime_error` (tick time). Both are empty when all is
## well; bridge.gd checks them and surfaces the message on the panel rather
## than letting the reactor run on half-evaluated rules.

# -- node kinds ------------------------------------------------------------
const K_NUM := "num"
const K_STR := "str"
const K_BOOL := "bool"
const K_VAR := "var"
const K_UNARY := "unary"
const K_BINARY := "binary"
const K_CALL := "call"
const K_SET := "set"
const K_ACTION := "action"

const KEYWORDS := {
	"reactor": true, "version": true, "params": true, "effects": true,
	"signals": true, "rule": true, "fault": true, "when": true, "then": true,
	"set": true, "priority": true, "once": true, "edge": true, "weight": true,
	"duration": true, "label": true, "persistent": true, "and": true,
	"or": true, "not": true, "true": true, "false": true,
}

# -- parse output ----------------------------------------------------------
var title := "UNNAMED REACTOR"
var version := 1
var params: Array = []      ## [[name, expr], ...] evaluated in order
var effects: Array = []     ## [[name, expr, persistent], ...]
var signal_defs: Array = [] ## [[name, expr], ...]
var rules: Array = []       ## Dictionaries, sorted by descending priority
var faults: Array = []      ## Dictionaries
var held_slots := 0
var error := ""

# -- runtime state ---------------------------------------------------------
var vars: Dictionary = {}
var param_values: Dictionary = {}
var held_timers: PackedFloat64Array = PackedFloat64Array()
var events: Array[String] = []
var runtime_error := ""

var effect_defaults: Dictionary = {}
var persistent_effects: Dictionary = {}

var active_fault: Dictionary = {}
var fault_started_at := 0.0
var next_fault_at := 60.0

var scram_requested := false
var scram_reason := ""
var trip_reset := false
var meltdown := false
var victory := false
var alarm_level := 0
var alarm_text := ""

var rng := RandomNumberGenerator.new()

var _toks: Array = []
var _i := 0
var _dt := 0.0


# ==========================================================================
# Tokenizer
# ==========================================================================

static func _is_digit(c: int) -> bool:
	return c >= 48 and c <= 57

static func _is_alpha(c: int) -> bool:
	return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95

static func _is_alnum(c: int) -> bool:
	return _is_alpha(c) or _is_digit(c)

static func _is_space(c: int) -> bool:
	return c == 32 or c == 9 or c == 13 or c == 10


func _tok(kind: String, value, line: int) -> Dictionary:
	return {"kind": kind, "value": value, "line": line}


func tokenize(src: String) -> Array:
	var out: Array = []
	var n := src.length()
	var i := 0
	var line := 1
	while i < n:
		var c := src.unicode_at(i)

		if _is_space(c):
			if c == 10:
				line += 1
			i += 1
			continue

		# Comments: `# ...` and `// ...` both run to end of line.
		if c == 35 or (c == 47 and i + 1 < n and src.unicode_at(i + 1) == 47):
			while i < n and src.unicode_at(i) != 10:
				i += 1
			continue

		if _is_digit(c) or (c == 46 and i + 1 < n and _is_digit(src.unicode_at(i + 1))):
			var start := i
			while i < n and _is_digit(src.unicode_at(i)):
				i += 1
			if i < n and src.unicode_at(i) == 46:
				i += 1
				while i < n and _is_digit(src.unicode_at(i)):
					i += 1
			if i < n and (src.unicode_at(i) == 101 or src.unicode_at(i) == 69):
				var save := i
				i += 1
				if i < n and (src.unicode_at(i) == 43 or src.unicode_at(i) == 45):
					i += 1
				if i < n and _is_digit(src.unicode_at(i)):
					while i < n and _is_digit(src.unicode_at(i)):
						i += 1
				else:
					i = save
			out.append(_tok("number", src.substr(start, i - start).to_float(), line))
			continue

		if c == 34:  # string literal
			i += 1
			var buf := ""
			while i < n and src.unicode_at(i) != 34:
				var ch := src.unicode_at(i)
				if ch == 92 and i + 1 < n:
					i += 1
					var esc := src.unicode_at(i)
					match esc:
						110: buf += "\n"
						116: buf += "\t"
						34: buf += "\""
						92: buf += "\\"
						_: buf += char(esc)
				else:
					if ch == 10:
						line += 1
					buf += char(ch)
				i += 1
			if i >= n:
				return _fail_tok(line, "unterminated string literal")
			i += 1
			out.append(_tok("string", buf, line))
			continue

		if _is_alpha(c):
			var s := i
			while i < n and _is_alnum(src.unicode_at(i)):
				i += 1
			var word := src.substr(s, i - s)
			out.append(_tok("keyword" if KEYWORDS.has(word) else "ident", word, line))
			continue

		# Two-character operators first.
		if i + 1 < n:
			var two := src.substr(i, 2)
			if two == "<=" or two == ">=" or two == "==" or two == "!=":
				out.append(_tok("op", two, line))
				i += 2
				continue

		var one := src.substr(i, 1)
		if "+-*/%<>=(){},".contains(one):
			out.append(_tok("op", one, line))
			i += 1
			continue

		return _fail_tok(line, "unexpected character '%s'" % one)

	out.append(_tok("eof", null, line))
	return out


func _fail_tok(line: int, msg: String) -> Array:
	error = "line %d: %s" % [line, msg]
	return [_tok("eof", null, line)]


# ==========================================================================
# Parser
# ==========================================================================

func parse(src: String) -> bool:
	title = "UNNAMED REACTOR"
	version = 1
	params = []
	effects = []
	signal_defs = []
	rules = []
	faults = []
	held_slots = 0
	error = ""

	_toks = tokenize(src)
	_i = 0
	if error != "":
		return false

	while not _at("eof") and error == "":
		if _accept("keyword", "reactor"):
			var t := _expect("string")
			if error != "":
				break
			title = str(t["value"])
			if _accept("keyword", "version"):
				version = int(_expect("number")["value"])
		elif _accept("keyword", "params"):
			_assign_block(params)
		elif _accept("keyword", "signals"):
			_assign_block(signal_defs)
		elif _accept("keyword", "effects"):
			_effect_block()
		elif _accept("keyword", "rule"):
			var r := _parse_rule()
			if error == "":
				rules.append(r)
		elif _accept("keyword", "fault"):
			var f := _parse_fault()
			if error == "":
				faults.append(f)
		else:
			_fail("unexpected '%s' at top level" % str(_cur()["value"]))

	if error != "":
		return false

	rules.sort_custom(func(a, b): return a["priority"] > b["priority"])
	return true


func _cur() -> Dictionary:
	var t: Dictionary = _toks[_i]
	return t


func _at(kind: String, value = null) -> bool:
	var t: Dictionary = _toks[_i]
	return t["kind"] == kind and (value == null or t["value"] == value)


func _accept(kind: String, value = null) -> bool:
	if _at(kind, value):
		_i += 1
		return true
	return false


func _expect(kind: String, value = null) -> Dictionary:
	if _at(kind, value):
		var t: Dictionary = _toks[_i]
		_i += 1
		return t
	var want: String = str(value) if value != null else kind
	_fail("expected '%s', got '%s'" % [want, str(_cur()["value"])])
	var eof_tok: Dictionary = _toks[_toks.size() - 1]
	return eof_tok


func _fail(msg: String) -> void:
	if error == "":
		error = "line %d: %s" % [int(_cur()["line"]), msg]
	_i = _toks.size() - 1   # park on EOF so every parse loop unwinds


## Rule and fault names are allowed to look like keywords.
func _name_token() -> Dictionary:
	var t: Dictionary = _toks[_i]
	if t["kind"] == "ident" or t["kind"] == "keyword":
		_i += 1
		return t
	_fail("expected a name, got '%s'" % str(t["value"]))
	return t


func _assign_block(into: Array) -> void:
	_expect("op", "{")
	while error == "" and not _accept("op", "}"):
		if _at("eof"):
			_fail("unterminated block")
			return
		var name: String = str(_expect("ident")["value"])
		_expect("op", "=")
		into.append([name, _expr()])


func _effect_block() -> void:
	_expect("op", "{")
	while error == "" and not _accept("op", "}"):
		if _at("eof"):
			_fail("unterminated effects block")
			return
		var name: String = str(_expect("ident")["value"])
		_expect("op", "=")
		var value = _expr()
		var persistent := _accept("keyword", "persistent")
		effects.append([name, value, persistent])


func _parse_rule() -> Dictionary:
	var line := int(_cur()["line"])
	var name: String = str(_name_token()["value"])
	var priority := 0.0
	var once := false
	var edge := false
	while error == "":
		if _accept("keyword", "priority"):
			priority = float(_expect("number")["value"])
		elif _accept("keyword", "once"):
			once = true
		elif _accept("keyword", "edge"):
			edge = true
		else:
			break
	_expect("op", "{")
	_expect("keyword", "when")
	var cond = _expr()
	_expect("keyword", "then")
	var actions := _actions_until_brace()
	return {
		"name": name, "priority": priority, "once": once, "edge": edge,
		"cond": cond, "actions": actions, "fired": false, "was_true": false,
		"line": line,
	}


func _parse_fault() -> Dictionary:
	var line := int(_cur()["line"])
	var name: String = str(_name_token()["value"])
	var weight := 1.0
	var duration = {"k": K_NUM, "v": 30.0}
	var label := name.replace("_", " ").to_upper()
	while error == "":
		if _accept("keyword", "weight"):
			weight = float(_expect("number")["value"])
		elif _accept("keyword", "duration"):
			duration = _expr()
		elif _accept("keyword", "label"):
			label = str(_expect("string")["value"])
		else:
			break
	_expect("op", "{")
	var actions := _actions_until_brace()
	return {
		"name": name, "weight": weight, "duration": duration,
		"label": label, "actions": actions, "line": line,
	}


func _actions_until_brace() -> Array:
	var actions: Array = []
	while error == "" and not _accept("op", "}"):
		if _at("eof"):
			_fail("unterminated block")
			return actions
		actions.append(_action())
	return actions


func _action() -> Dictionary:
	var line := int(_cur()["line"])
	if _accept("keyword", "set"):
		var target: String = str(_expect("ident")["value"])
		_expect("op", "=")
		return {"k": K_SET, "target": target, "expr": _expr(), "line": line}
	var name: String = str(_expect("ident")["value"])
	_expect("op", "(")
	var args := _arg_list()
	return {"k": K_ACTION, "name": name, "args": args, "line": line}


func _arg_list() -> Array:
	var args: Array = []
	if not _at("op", ")"):
		args.append(_expr())
		while _accept("op", ","):
			args.append(_expr())
	_expect("op", ")")
	return args


# -- expressions -----------------------------------------------------------

func _expr() -> Dictionary:
	return _or_expr()


func _or_expr() -> Dictionary:
	var node := _and_expr()
	while error == "" and _accept("keyword", "or"):
		node = {"k": K_BINARY, "op": "or", "a": node, "b": _and_expr()}
	return node


func _and_expr() -> Dictionary:
	var node := _not_expr()
	while error == "" and _accept("keyword", "and"):
		node = {"k": K_BINARY, "op": "and", "a": node, "b": _not_expr()}
	return node


func _not_expr() -> Dictionary:
	if _accept("keyword", "not"):
		return {"k": K_UNARY, "op": "not", "a": _not_expr()}
	return _comparison()


func _comparison() -> Dictionary:
	var node := _additive()
	while error == "" and _cur()["kind"] == "op" and \
			["<", ">", "<=", ">=", "==", "!="].has(_cur()["value"]):
		var op: String = str(_cur()["value"])
		_i += 1
		node = {"k": K_BINARY, "op": op, "a": node, "b": _additive()}
	return node


func _additive() -> Dictionary:
	var node := _multiplicative()
	while error == "" and _cur()["kind"] == "op" and \
			["+", "-"].has(_cur()["value"]):
		var op: String = str(_cur()["value"])
		_i += 1
		node = {"k": K_BINARY, "op": op, "a": node, "b": _multiplicative()}
	return node


func _multiplicative() -> Dictionary:
	var node := _unary()
	while error == "" and _cur()["kind"] == "op" and \
			["*", "/", "%"].has(_cur()["value"]):
		var op: String = str(_cur()["value"])
		_i += 1
		node = {"k": K_BINARY, "op": op, "a": node, "b": _unary()}
	return node


func _unary() -> Dictionary:
	if _accept("op", "-"):
		return {"k": K_UNARY, "op": "-", "a": _unary()}
	if _accept("op", "+"):
		return _unary()
	return _primary()


func _primary() -> Dictionary:
	var t: Dictionary = _cur()
	var line := int(t["line"])

	if t["kind"] == "number":
		_i += 1
		return {"k": K_NUM, "v": float(t["value"])}
	if t["kind"] == "string":
		_i += 1
		return {"k": K_STR, "v": str(t["value"])}
	if _accept("keyword", "true"):
		return {"k": K_BOOL, "v": true}
	if _accept("keyword", "false"):
		return {"k": K_BOOL, "v": false}
	if _accept("op", "("):
		var node := _expr()
		_expect("op", ")")
		return node
	if t["kind"] == "ident":
		_i += 1
		var name := str(t["value"])
		if _accept("op", "("):
			var args := _arg_list()
			var slot := -1
			if name == "held":
				slot = held_slots
				held_slots += 1
			return {"k": K_CALL, "name": name, "args": args,
					"slot": slot, "line": line}
		return {"k": K_VAR, "name": name, "line": line}

	_fail("unexpected '%s' in expression" % str(t["value"]))
	return {"k": K_NUM, "v": 0.0}


# ==========================================================================
# Runtime
# ==========================================================================

func reset(seed_value: int = 0) -> void:
	if seed_value != 0:
		rng.seed = seed_value
	else:
		rng.randomize()

	vars = {}
	param_values = {}
	held_timers = PackedFloat64Array()
	held_timers.resize(held_slots)
	events.clear()
	runtime_error = ""
	_dt = 0.0

	for entry in params:
		param_values[entry[0]] = _eval(entry[1])


	effect_defaults = {}
	persistent_effects = {}
	for entry in effects:
		var value = _eval(entry[1])
		effect_defaults[entry[0]] = value
		vars[entry[0]] = value
		if entry[2]:
			persistent_effects[entry[0]] = true

	for entry in rules:
		var rule: Dictionary = entry
		rule["fired"] = false
		rule["was_true"] = false

	active_fault = {}
	fault_started_at = 0.0
	next_fault_at = rng.randf_range(
		_num(_lookup("fault_first_min_s", 45.0)),
		_num(_lookup("fault_first_max_s", 90.0)))

	scram_requested = false
	scram_reason = ""
	trip_reset = false
	meltdown = false
	victory = false
	alarm_level = 0
	alarm_text = ""


func _lookup(name: String, fallback = null):
	if vars.has(name):
		return vars[name]
	if param_values.has(name):
		return param_values[name]
	if fallback != null:
		return fallback
	runtime_error = "unknown identifier '%s'" % name
	return 0.0


static func _truthy(v) -> bool:
	match typeof(v):
		TYPE_BOOL: return v
		TYPE_STRING, TYPE_STRING_NAME: return String(v).length() > 0
		TYPE_NIL: return false
		_: return bool(v)


func _num(v) -> float:
	match typeof(v):
		TYPE_BOOL: return 1.0 if v else 0.0
		TYPE_INT, TYPE_FLOAT: return float(v)
	runtime_error = "expected a number, got '%s'" % str(v)
	return 0.0


static func _as_text(v) -> String:
	match typeof(v):
		TYPE_BOOL: return "true" if v else "false"
		TYPE_FLOAT:
			if is_equal_approx(v, roundf(v)):
				return str(int(roundf(v)))
			return "%.2f" % v
	return str(v)


# -- expression evaluation -------------------------------------------------

func _eval(node: Dictionary):
	match node["k"]:
		K_NUM, K_STR, K_BOOL:
			return node["v"]
		K_VAR:
			return _lookup(node["name"])
		K_UNARY:
			if node["op"] == "not":
				return not _truthy(_eval(node["a"]))
			return -_num(_eval(node["a"]))
		K_BINARY:
			return _eval_binary(node)
		K_CALL:
			return _eval_call(node)
	runtime_error = "cannot evaluate node"
	return 0.0


func _eval_binary(node: Dictionary):
	var op: String = node["op"]

	if op == "and":
		if not _truthy(_eval(node["a"])):
			return false
		return _truthy(_eval(node["b"]))
	if op == "or":
		if _truthy(_eval(node["a"])):
			return true
		return _truthy(_eval(node["b"]))

	var a = _eval(node["a"])
	var b = _eval(node["b"])

	if op == "==":
		return _equal(a, b)
	if op == "!=":
		return not _equal(a, b)

	# `+` doubles as string concatenation so rules can build messages.
	if op == "+" and (typeof(a) == TYPE_STRING or typeof(b) == TYPE_STRING):
		return _as_text(a) + _as_text(b)

	var x := _num(a)
	var y := _num(b)
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
	runtime_error = "unknown operator '%s'" % op
	return 0.0


static func _equal(a, b) -> bool:
	var a_str := typeof(a) == TYPE_STRING
	var b_str := typeof(b) == TYPE_STRING
	if a_str != b_str:
		return false
	if a_str:
		return String(a) == String(b)
	if typeof(a) == TYPE_BOOL or typeof(b) == TYPE_BOOL:
		return _truthy(a) == _truthy(b)
	return is_equal_approx(float(a), float(b))


func _eval_call(node: Dictionary):
	var name: String = node["name"]

	# held() must see its condition unevaluated: the timer may only advance
	# on ticks where the surrounding guard actually reached this call.
	if name == "held":
		if node["args"].size() != 2:
			runtime_error = "line %d: held(cond, seconds) takes 2 arguments" % int(node["line"])
			return false
		var cond := _truthy(_eval(node["args"][0]))
		var secs := _num(_eval(node["args"][1]))
		var slot: int = node["slot"]
		if slot < 0 or slot >= held_timers.size():
			return false
		if cond:
			held_timers[slot] += _dt
		else:
			held_timers[slot] = 0.0
		return held_timers[slot] >= secs

	var args: Array = []
	for a in node["args"]:
		args.append(_eval(a))

	if args.size() < _min_arity(name):
		runtime_error = "line %d: %s() needs %d argument(s), got %d" \
			% [int(node["line"]), name, _min_arity(name), args.size()]
		return 0.0

	match name:
		"abs":
			return absf(_num(args[0]))
		"min":
			var lo := _num(args[0])
			for i in range(1, args.size()):
				lo = minf(lo, _num(args[i]))
			return lo
		"max":
			var hi := _num(args[0])
			for i in range(1, args.size()):
				hi = maxf(hi, _num(args[i]))
			return hi
		"clamp":
			return clampf(_num(args[0]), _num(args[1]), _num(args[2]))
		"exp":
			return exp(clampf(_num(args[0]), -700.0, 700.0))
		"sqrt":
			return sqrt(maxf(0.0, _num(args[0])))
		"floor":
			return floorf(_num(args[0]))
		"ramp":
			return clampf(_num(args[0]), 0.0, 1.0)
		"lerp":
			return lerpf(_num(args[0]), _num(args[1]),
					clampf(_num(args[2]), 0.0, 1.0))
		"pick":
			return args[rng.randi_range(0, args.size() - 1)]
		"rand":
			return rng.randf_range(_num(args[0]), _num(args[1]))

	runtime_error = "line %d: unknown function '%s'" % [int(node["line"]), name]
	return 0.0


## Minimum argument count per builtin. Guarding here means a typo in the
## policy file surfaces as a readable error on the panel instead of an
## out-of-range crash somewhere in the middle of a shift.
static func _min_arity(name: String) -> int:
	match name:
		"clamp", "lerp": return 3
		"rand": return 2
		"abs", "exp", "sqrt", "floor", "ramp", "min", "max", "pick": return 1
	return 0


# -- actions ---------------------------------------------------------------

func _exec_action(action: Dictionary) -> void:
	if action["k"] == K_SET:
		vars[action["target"]] = _eval(action["expr"])
		return

	var name: String = action["name"]
	var args: Array = []
	for a in action["args"]:
		args.append(_eval(a))

	match name:
		"log":
			if args.size() > 0:
				events.append(_as_text(args[0]))
		"alarm":
			if args.is_empty():
				runtime_error = "line %d: alarm() needs a level" % int(action["line"])
				return
			var level := int(_num(args[0]))
			if level > alarm_level:
				alarm_level = level
				alarm_text = _as_text(args[1]) if args.size() > 1 else ""
		"scram":
			# Latching the trip in vars as well means the lower-priority
			# rules later in this same tick already see a scrammed plant.
			var reason: String = _as_text(args[0]) if args.size() > 0 else "SCRAM"
			if not _truthy(_lookup("scram", false)):
				scram_requested = true
				scram_reason = reason
				vars["scram"] = true
				events.append(reason)
		"reset_trip":
			trip_reset = true
			vars["scram"] = false
		"meltdown":
			if not meltdown:
				meltdown = true
				_end_run()
				events.append(_as_text(args[0]) if args.size() > 0 else "MELTDOWN")
		"victory":
			if not victory:
				victory = true
				_end_run()
				events.append(_as_text(args[0]) if args.size() > 0 else "VICTORY")
		"inject_fault":
			if args.is_empty():
				runtime_error = "line %d: inject_fault() needs a name" \
					% int(action["line"])
				return
			_activate_fault_by_name(_as_text(args[0]))
		"clear_fault":
			if not active_fault.is_empty():
				_clear_fault()
		_:
			runtime_error = "line %d: unknown action '%s'" % [int(action["line"]), name]


## Make the end of the run visible to the rest of this tick; `running` is an
## ordinary signal computed before the rules, so without this the state
## machine and the alarms would lag by one step.
func _end_run() -> void:
	vars["game_over"] = true
	vars["meltdown"] = meltdown
	vars["victory"] = victory
	vars["running"] = false


# -- fault scheduling ------------------------------------------------------

func _fault_by_name(name: String) -> Dictionary:
	for entry in faults:
		var f: Dictionary = entry
		if f["name"] == name:
			return f
	return {}


func _activate_fault_by_name(name: String) -> void:
	var f := _fault_by_name(name)
	if f.is_empty():
		runtime_error = "no such fault '%s'" % name
		return
	_activate_fault(f)


func _activate_fault(fault: Dictionary) -> void:
	if not active_fault.is_empty():
		return
	active_fault = fault
	fault_started_at = _num(_lookup("t", 0.0))
	vars["active_fault"] = fault["name"]
	vars["fault_label"] = fault["label"]
	vars["fault_elapsed"] = 0.0
	vars["fault_duration"] = _num(_eval(fault["duration"]))
	events.append("ALARM: " + str(fault["label"]))


func _clear_fault() -> void:
	if active_fault.is_empty():
		return
	events.append(str(active_fault["label"]) + " CLEARED")
	active_fault = {}
	vars["active_fault"] = ""
	vars["fault_label"] = ""
	vars["fault_elapsed"] = 0.0
	vars["fault_duration"] = 0.0
	var now := _num(_lookup("t", 0.0))
	next_fault_at = now + rng.randf_range(
		_num(_lookup("fault_gap_min_s", 45.0)),
		_num(_lookup("fault_gap_max_s", 90.0)))


func _pick_weighted_fault() -> Dictionary:
	var total := 0.0
	for f in faults:
		if f["weight"] > 0.0:
			total += f["weight"]
	if total <= 0.0:
		return {}
	var r := rng.randf_range(0.0, total)
	var acc := 0.0
	for entry in faults:
		var f: Dictionary = entry
		if f["weight"] <= 0.0:
			continue
		acc += f["weight"]
		if r <= acc:
			return f
	var last: Dictionary = faults[faults.size() - 1]
	return last


func _update_faults(now: float, enabled: bool) -> void:
	if active_fault.is_empty():
		if enabled and now >= next_fault_at:
			var f := _pick_weighted_fault()
			if not f.is_empty():
				_activate_fault(f)
	else:
		var elapsed := now - fault_started_at
		vars["fault_elapsed"] = elapsed
		if elapsed >= _num(vars.get("fault_duration", 30.0)):
			_clear_fault()

	if not active_fault.is_empty():
		for entry in active_fault["actions"]:
			var action: Dictionary = entry
			_exec_action(action)


# ==========================================================================
# The tick
# ==========================================================================

## One control cycle. `inputs` is what the host measured this step; the
## returned Dictionary is what the host should feed back into the physics
## and show on the panel.
func tick(dt: float, inputs: Dictionary, faults_enabled: bool = true) -> Dictionary:
	_dt = dt
	events.clear()
	runtime_error = ""
	scram_requested = false
	scram_reason = ""
	trip_reset = false
	alarm_level = 0
	alarm_text = ""

	# Non-persistent effect vars fall back to their declared defaults, so a
	# fault that clears stops acting on the plant with no explicit cleanup.
	for name in effect_defaults:
		if not persistent_effects.has(name):
			vars[name] = effect_defaults[name]

	vars["dt"] = dt
	for key in inputs:
		vars[key] = inputs[key]
	if not vars.has("active_fault"):
		vars["active_fault"] = ""
	if not vars.has("fault_label"):
		vars["fault_label"] = ""
	if not vars.has("fault_elapsed"):
		vars["fault_elapsed"] = 0.0
	if not vars.has("fault_duration"):
		vars["fault_duration"] = 0.0

	_update_faults(_num(_lookup("t", 0.0)), faults_enabled)

	for entry in signal_defs:
		vars[entry[0]] = _eval(entry[1])

	for entry in rules:
		var rule: Dictionary = entry
		if rule["once"] and rule["fired"]:
			rule["was_true"] = false
			continue
		var cond := _truthy(_eval(rule["cond"]))
		var should_fire: bool = cond and (not rule["edge"] or not rule["was_true"])
		rule["was_true"] = cond
		if should_fire:
			rule["fired"] = true
			for entry2 in rule["actions"]:
				var action: Dictionary = entry2
				_exec_action(action)
		if runtime_error != "":
			runtime_error = "rule '%s': %s" % [rule["name"], runtime_error]
			break

	return outputs()


func outputs() -> Dictionary:
	return {
		"flow_frac": _num(_lookup("flow_frac", 1.0)),
		"load_frac": _num(_lookup("load_frac", 1.0)),
		"xenon_pcm": _num(_lookup("xenon_pcm", 0.0)),
		"stuck_bank": _as_text(_lookup("stuck_bank", "")),
		"rod_target_a": _num(_lookup("rod_target_a", 0.0)),
		"rod_target_b": _num(_lookup("rod_target_b", 0.0)),
		"state": _as_text(_lookup("state", "STARTUP")),
		"alarm_level": alarm_level,
		"alarm_text": alarm_text,
		"scram_requested": scram_requested,
		"scram_reason": scram_reason,
		"trip_reset": trip_reset,
		"meltdown": meltdown,
		"victory": victory,
		"active_fault": _as_text(_lookup("active_fault", "")),
		"fault_label": _as_text(_lookup("fault_label", "")),
		"fault_elapsed": _num(_lookup("fault_elapsed", 0.0)),
		"fault_duration": _num(_lookup("fault_duration", 0.0)),
		"events": events.duplicate(),
	}


## Convenience: parse a .nova file straight out of res:// (works in the
## editor and inside an exported .pck alike).
static func from_file(path: String) -> NovaVM:
	var vm := NovaVM.new()
	var text := ""
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			text = f.get_as_text()
			f.close()
	if text.is_empty():
		vm.error = "could not read '%s'" % path
		return vm
	vm.parse(text)
	return vm
