class_name NovaCompiler
extends RefCounted

## Walks a NovaResolver-annotated AST and emits NovaCode -- the bytecode
## compiler half of the Resolver -> Compiler -> VM pipeline, mirroring
## reference/novalang.py's `Compiler` class for this dialect's grammar.
##
## Must run on a program NovaResolver has already resolved (every `var`,
## assignment target, bare-name call, `let`, `import` and `func` node
## carries its `_loc`/`_frame`/`_cells`/`_thunk_frame`/`_body_frame`
## annotation). This pass does not change any of that; it only reads it
## and emits instructions.
##
## NEW_CELLS is not a separate runtime concern here -- it is just another
## instruction this pass places at the top of whichever block or frame
## owns the captured slot(s), so a block re-entered by a loop re-runs it
## and gets a fresh Cell each lap. See nova_opcodes.gd for the full
## contract each opcode promises the VM.

const OP := NovaOpcodes.OP

var error := ""


## One frame's worth of in-progress emission state: the NovaCode being
## built, plus the backpatch lists for whichever `while` loops are
## currently open (so `break`/`continue` can find the right one).
class _Ctx:
	var code: NovaCode
	var loop_breaks: Array = []      # stack of Array[int] (patch sites)
	var loop_continues: Array = []

	func _init(c: NovaCode) -> void:
		code = c

	func emit(op: int, arg, line: int) -> int:
		code.ops.append(op)
		code.args.append(arg)
		code.positions.append(line)
		return code.ops.size() - 1

	func here() -> int:
		return code.ops.size()

	func patch(at: int, target: int = -1) -> void:
		code.args[at] = (here() if target < 0 else target)

	func const_index(value) -> int:
		code.constants.append(value)
		return code.constants.size() - 1


# ==========================================================================
# Entry point
# ==========================================================================

## Returns a Dictionary: {"module": NovaCode, "params": [[name, NovaCode]],
## "effects": [[name, NovaCode, persistent]], "signals": [[name, NovaCode]],
## "rules": [{"name","priority","once","edge","cond":NovaCode,"body":NovaCode}],
## "faults": [{"name","weight","label","duration":NovaCode,"body":NovaCode}]}
func compile_program(program: Dictionary) -> Dictionary:
	var out := {
		"module": _compile_frame(program["statements"], program["_frame"], "<module>", 0),
		"params": [], "effects": [], "signals": [], "rules": [], "faults": [],
	}
	for entry in program["params"]:
		out["params"].append([entry[0], _compile_expr_thunk(entry[1])])
	for entry in program["effects"]:
		out["effects"].append([entry[0], _compile_expr_thunk(entry[1]), entry[2]])
	for entry in program["signal_defs"]:
		out["signals"].append([entry[0], _compile_expr_thunk(entry[1])])

	for rule in program["rules"]:
		var cond_code := _compile_expr_thunk(rule["cond"])
		var body_code := _compile_frame(rule["body"], rule["_body_frame"],
				"rule:" + String(rule["name"]), 0)
		out["rules"].append({
			"name": rule["name"], "priority": rule["priority"],
			"once": rule["once"], "edge": rule["edge"],
			"cond": cond_code, "body": body_code,
		})

	for fault in program["faults"]:
		var dur_code := _compile_expr_thunk(fault["duration"])
		var fbody_code := _compile_frame(fault["body"], fault["_body_frame"],
				"fault:" + String(fault["name"]), 0)
		out["faults"].append({
			"name": fault["name"], "weight": fault["weight"], "label": fault["label"],
			"duration": dur_code, "body": fbody_code,
		})
	return out


func _compile_expr_thunk(expr_node: Dictionary) -> NovaCode:
	var finfo: Dictionary = expr_node["_thunk_frame"]
	var code := NovaCode.new()
	code.name = "<expr>"
	code.nslots = int(finfo["nslots"])
	code.param_count = 0
	var ctx := _Ctx.new(code)
	_emit_new_cells(ctx, finfo["root_cells"])
	_compile_expr(expr_node, ctx)
	ctx.emit(OP.RETURN, null, int(expr_node.get("line", 0)))
	return code


func _compile_frame(stmts: Array, finfo: Dictionary, name: String, param_count: int) -> NovaCode:
	var code := NovaCode.new()
	code.name = name
	code.nslots = int(finfo["nslots"])
	code.param_count = param_count
	var ctx := _Ctx.new(code)
	_emit_new_cells(ctx, finfo["root_cells"])
	_compile_stmt_list(stmts, ctx)
	ctx.emit(OP.LOAD_CONST, ctx.const_index(null), 0)
	ctx.emit(OP.RETURN, null, 0)
	return code


func _emit_new_cells(ctx: _Ctx, slots: Array) -> void:
	if slots.size() > 0:
		ctx.emit(OP.NEW_CELLS, slots.duplicate(), 0)


# ==========================================================================
# Locations
# ==========================================================================

func _emit_load(loc: Array, ctx: _Ctx, line: int) -> void:
	match loc[0]:
		"fast": ctx.emit(OP.LOAD_FAST, loc[1], line)
		"cell": ctx.emit(OP.LOAD_CELL, loc[1], line)
		"free": ctx.emit(OP.LOAD_FREE, loc[1], line)
		"global": ctx.emit(OP.LOAD_GLOBAL, loc[1], line)
		_: error = "unknown location kind '%s'" % str(loc[0])


func _emit_store(loc: Array, ctx: _Ctx, line: int) -> void:
	match loc[0]:
		"fast": ctx.emit(OP.STORE_FAST, loc[1], line)
		"cell": ctx.emit(OP.STORE_CELL, loc[1], line)
		"free": ctx.emit(OP.STORE_FREE, loc[1], line)
		"global": ctx.emit(OP.STORE_GLOBAL, loc[1], line)
		_: error = "unknown location kind '%s'" % str(loc[0])


# ==========================================================================
# Statements
# ==========================================================================

func _compile_stmt_list(stmts: Array, ctx: _Ctx) -> void:
	for s in stmts:
		_compile_stmt(s, ctx)


func _compile_stmt(node: Dictionary, ctx: _Ctx) -> void:
	var kind: String = node["k"]
	var line: int = int(node.get("line", 0))
	match kind:
		"exprstmt":
			_compile_expr(node["expr"], ctx)
			ctx.emit(OP.POP, null, line)
		"let":
			_compile_expr(node["expr"], ctx)
			_emit_store(node["_loc"], ctx, line)
		"assign":
			_compile_assign(node, ctx, line)
		"block":
			_compile_nested_block(node, ctx)
		"if":
			_compile_if(node, ctx, line)
		"while":
			_compile_while(node, ctx, line)
		"return":
			if node["expr"] != null:
				_compile_expr(node["expr"], ctx)
			else:
				ctx.emit(OP.LOAD_CONST, ctx.const_index(null), line)
			ctx.emit(OP.RETURN, null, line)
		"break":
			if ctx.loop_breaks.is_empty():
				error = "line %d: 'break' is not inside a loop" % line
				return
			var bi := ctx.emit(OP.JUMP, -1, line)
			(ctx.loop_breaks[ctx.loop_breaks.size() - 1] as Array).append(bi)
		"continue":
			if ctx.loop_continues.is_empty():
				error = "line %d: 'continue' is not inside a loop" % line
				return
			var ci := ctx.emit(OP.JUMP, -1, line)
			(ctx.loop_continues[ctx.loop_continues.size() - 1] as Array).append(ci)
		"import":
			_compile_import(node, ctx, line)
		_:
			error = "line %d: cannot compile a '%s' statement" % [line, kind]


func _compile_nested_block(block_node: Dictionary, ctx: _Ctx) -> void:
	_emit_new_cells(ctx, block_node.get("_cells", []))
	_compile_stmt_list(block_node["body"], ctx)


func _compile_assign(node: Dictionary, ctx: _Ctx, line: int) -> void:
	_compile_expr(node["expr"], ctx)      # value, pushed first (matches eval order)
	var target: Dictionary = node["target"]
	match target["k"]:
		"var":
			_emit_store(target["_loc"], ctx, line)
		"index":
			_compile_expr(target["obj"], ctx)
			_compile_expr(target["idx"], ctx)
			ctx.emit(OP.STORE_INDEX, null, line)
		"member":
			_compile_expr(target["obj"], ctx)
			ctx.emit(OP.STORE_MEMBER, String(target["name"]), line)
		_:
			error = "line %d: cannot assign to a '%s'" % [line, target["k"]]


func _compile_if(node: Dictionary, ctx: _Ctx, line: int) -> void:
	_compile_expr(node["cond"], ctx)
	var jf := ctx.emit(OP.JUMP_IF_FALSE, -1, line)
	_compile_nested_block(node["then"], ctx)
	if node["else"] != null:
		var jend := ctx.emit(OP.JUMP, -1, line)
		ctx.patch(jf)
		_compile_nested_block(node["else"], ctx)
		ctx.patch(jend)
	else:
		ctx.patch(jf)


func _compile_while(node: Dictionary, ctx: _Ctx, line: int) -> void:
	var cond_start := ctx.here()
	_compile_expr(node["cond"], ctx)
	var jf := ctx.emit(OP.JUMP_IF_FALSE, -1, line)

	ctx.loop_breaks.append([])
	ctx.loop_continues.append([])
	_compile_nested_block(node["body"], ctx)

	var continues: Array = ctx.loop_continues.pop_back()
	for c in continues:
		ctx.patch(c, cond_start)
	ctx.emit(OP.JUMP, cond_start, line)
	ctx.patch(jf)

	var breaks: Array = ctx.loop_breaks.pop_back()
	for b in breaks:
		ctx.patch(b)


func _compile_import(node: Dictionary, ctx: _Ctx, line: int) -> void:
	var path: String = String(node["path"])
	if node.has("_names"):
		var names: Array = node["_names"]
		var locs: Array = node["_locs"]
		# IMPORT always runs at least once, even with zero known names, so
		# a module that can't be read or parse fails right here at run
		# time (same as the tree-walker) instead of silently doing
		# nothing. Re-running it per name after that is a cached, cheap
		# dict lookup on the host side (see nova_vm.gd's `_modules`).
		ctx.emit(OP.IMPORT, path, line)
		if names.is_empty():
			ctx.emit(OP.POP, null, line)
		else:
			for i in range(names.size()):
				if i > 0:
					ctx.emit(OP.IMPORT, path, line)
				ctx.emit(OP.GET_MEMBER, String(names[i]), line)
				_emit_store(locs[i], ctx, line)
	else:
		ctx.emit(OP.IMPORT, path, line)
		_emit_store(node["_loc"], ctx, line)


# ==========================================================================
# Expressions
# ==========================================================================

func _compile_expr(node: Dictionary, ctx: _Ctx) -> void:
	var kind: String = node["k"]
	var line: int = int(node.get("line", 0))
	match kind:
		"num", "str", "bool":
			ctx.emit(OP.LOAD_CONST, ctx.const_index(node["v"]), line)
		"null":
			ctx.emit(OP.LOAD_CONST, ctx.const_index(null), line)
		"var":
			_emit_load(node["_loc"], ctx, line)
		"unary":
			_compile_expr(node["a"], ctx)
			ctx.emit(OP.NOT if node["op"] == "not" else OP.NEG, null, line)
		"binary":
			_compile_binary(node, ctx, line)
		"list":
			for item in node["items"]:
				_compile_expr(item, ctx)
			ctx.emit(OP.BUILD_LIST, node["items"].size(), line)
		"dict":
			for pair in node["pairs"]:
				_compile_expr(pair[0], ctx)
				_compile_expr(pair[1], ctx)
			ctx.emit(OP.BUILD_DICT, node["pairs"].size(), line)
		"call":
			_compile_call(node, ctx, line)
		"index":
			_compile_expr(node["obj"], ctx)
			_compile_expr(node["idx"], ctx)
			ctx.emit(OP.INDEX, null, line)
		"member":
			_compile_expr(node["obj"], ctx)
			ctx.emit(OP.GET_MEMBER, String(node["name"]), line)
		"func":
			_compile_func_literal(node, ctx, line)
		_:
			error = "line %d: cannot compile a '%s' expression" % [line, kind]


const _BINARY_OP := {
	"+": "ADD", "-": "SUB", "*": "MUL", "/": "DIV", "%": "MOD",
	"==": "EQ", "!=": "NE", "<": "LT", ">": "GT", "<=": "LE", ">=": "GE",
}


func _compile_binary(node: Dictionary, ctx: _Ctx, line: int) -> void:
	var op: String = node["op"]
	if op == "and":
		_compile_expr(node["a"], ctx)
		var j := ctx.emit(OP.JUMP_IF_FALSE_KEEP, -1, line)
		ctx.emit(OP.POP, null, line)
		_compile_expr(node["b"], ctx)
		ctx.patch(j)
		return
	if op == "or":
		_compile_expr(node["a"], ctx)
		var j2 := ctx.emit(OP.JUMP_IF_TRUE_KEEP, -1, line)
		ctx.emit(OP.POP, null, line)
		_compile_expr(node["b"], ctx)
		ctx.patch(j2)
		return
	_compile_expr(node["a"], ctx)
	_compile_expr(node["b"], ctx)
	if not _BINARY_OP.has(op):
		error = "line %d: unknown operator '%s'" % [line, op]
		return
	ctx.emit(OP[_BINARY_OP[op]], null, line)


func _compile_call(node: Dictionary, ctx: _Ctx, line: int) -> void:
	var callee: Dictionary = node["callee"]
	var args: Array = node["args"]
	if callee["k"] == "var":
		for a in args:
			_compile_expr(a, ctx)
		var call_arg := {
			"name": String(callee["name"]),
			"loc": callee["_loc"],
			"argc": args.size(),
			"held_slot": int(node.get("slot", -1)),
		}
		ctx.emit(OP.CALL_NAME, call_arg, line)
	else:
		_compile_expr(callee, ctx)
		for a in args:
			_compile_expr(a, ctx)
		ctx.emit(OP.CALL, args.size(), line)


func _compile_func_literal(node: Dictionary, ctx: _Ctx, line: int) -> void:
	var finfo: Dictionary = node["_frame"]
	var params: Array = node["params"]
	var child := _compile_frame(node["body"]["body"], finfo,
			String(node.get("name", "")), params.size())
	var idx := ctx.code.child_codes.size()
	ctx.code.child_codes.append(child)
	ctx.emit(OP.MAKE_FUNCTION, {"child": idx, "captures": finfo["captures"]}, line)
