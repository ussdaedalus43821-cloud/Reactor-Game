class_name NovaResolver
extends RefCounted

## Assigns every name reference in a parsed NovaLang program a storage
## location, and annotates the AST in place with the answer -- mirrors
## reference/novalang.py's Resolver, adapted to this dialect's smaller
## grammar (no try/catch, no for-loops, no REPL-style ambiguity).
##
## Four kinds of location, same vocabulary as novalang.py:
##   "fast"   a slot in the CURRENT frame's own `slots` array
##   "cell"   a slot in the CURRENT frame's `slots`, boxed in a Cell
##            because some closure captures it
##   "free"   a Cell this function's closure captured from an *enclosing*
##            frame; indexes this frame's own `cells` array, not `slots`
##   "global" the single shared globals dictionary
##
## Frames: the module's top-level statements, each function body, each
## rule body, each fault body, and each bare params/effects/signals
## expression are all separate frames. Only the module frame has the
## "direct statement becomes a global" promotion rule -- a `let` (or
## `import`, or a top-level `func` declaration, which is sugar for `let`)
## written directly in the module's statement list is a global; the same
## `let` written inside a nested `if`/`while` block, or anywhere inside a
## function/rule/fault body, is always an ordinary frame-local slot. This
## matches the tree-walker exactly: top-level statements run straight
## against `ev.globals`, while every block (including a function call or
## a rule's per-tick body) gets its own child Env.
##
## Closure capture needs one pass to finish before locations can be
## trusted: a name read early in a frame, then captured by a closure
## later in the same frame, must retroactively become "cell" instead of
## "fast" (see `_finish_frame`'s fixup pass) -- the slot ends up holding a
## Cell by the time the frame actually runs, even though the resolver
## didn't know that yet at the earlier reference. A forward reference to a
## *not-yet-declared* name in the same frame is not handled (it isn't used
## anywhere in this dialect's shipped scripts or conformance corpus); it
## resolves as a global and the parity check will say so if that's ever
## wrong.

var error := ""

var _module_reader: Callable
var _export_cache: Dictionary = {}     # path -> Array[String]


func _init(module_reader: Callable = Callable()) -> void:
	_module_reader = module_reader


## One declared name: a parameter or a `let` target, native to exactly one
## frame and one lexical slot within it.
class Var:
	var name := ""
	var slot := -1
	var captured := false


## One function/module/rule/fault/expression's worth of local storage.
class Frame:
	var parent = null              # enclosing Frame, or null (globals-only)
	var is_module := false         # only the module frame promotes-to-global
	var vars: Array = []           # every Var ever allocated here, slot == index
	var scopes: Array = []         # stack of {name: Var}, current lexical scopes
	var free: Array = []           # [{"source": "cell"|"free", "index": int}]
	var _free_index_by_name: Dictionary = {}
	var pending_fast_refs: Array = []   # [{"node": Dictionary, "var": Var}]

	func new_slot(name: String) -> Var:
		var v := Var.new()
		v.name = name
		v.slot = vars.size()
		vars.append(v)
		scopes[scopes.size() - 1][name] = v
		return v

	func push_scope() -> void:
		scopes.append({})

	func pop_scope() -> Dictionary:
		var top: Dictionary = scopes[scopes.size() - 1]
		scopes.remove_at(scopes.size() - 1)
		return top

	func find_local(name: String) -> Var:
		for i in range(scopes.size() - 1, -1, -1):
			var s: Dictionary = scopes[i]
			if s.has(name):
				return s[name]
		return null

	func ensure_free(name: String, source: String, index: int) -> int:
		if _free_index_by_name.has(name):
			return _free_index_by_name[name]
		var idx := free.size()
		free.append({"source": source, "index": index})
		_free_index_by_name[name] = idx
		return idx


# ==========================================================================
# Entry point
# ==========================================================================

## Resolves the whole program in place. After this call, every `var` node,
## every `assign` target, every `call` with a bare-name callee, every
## `let`/`import`, and every `func` literal in `program` carries the
## annotations NovaCompiler needs (`_loc`, `_cells`, `_frame`,
## `_thunk_frame`, `_body_frame`). Check `error` afterward.
func resolve_program(program: Dictionary) -> void:
	var module_frame := Frame.new()
	module_frame.is_module = true
	module_frame.push_scope()
	_resolve_stmt_list(program["statements"], module_frame)
	program["_frame"] = _frame_info(module_frame)

	for entry in program["params"]:
		_resolve_thunk_expr(entry[1])
	for entry in program["effects"]:
		_resolve_thunk_expr(entry[1])
	for entry in program["signal_defs"]:
		_resolve_thunk_expr(entry[1])

	for rule in program["rules"]:
		_resolve_thunk_expr(rule["cond"])
		_resolve_thunk_stmts(rule, "body")

	for fault in program["faults"]:
		_resolve_thunk_expr(fault["duration"])
		_resolve_thunk_stmts(fault, "body")


func _resolve_thunk_expr(expr_node: Dictionary) -> void:
	var frame := Frame.new()
	frame.push_scope()
	_resolve_expr(expr_node, frame)
	expr_node["_thunk_frame"] = _frame_info(frame)


func _resolve_thunk_stmts(container: Dictionary, key: String) -> void:
	var frame := Frame.new()
	frame.push_scope()
	_resolve_stmt_list(container[key], frame)
	container["_body_frame"] = _frame_info(frame)


func _frame_info(frame: Frame) -> Dictionary:
	_finish_frame(frame)
	var root_scope: Dictionary = frame.scopes[0]
	var root_cells: Array = []
	for name in root_scope:
		var v: Var = root_scope[name]
		if v.captured:
			root_cells.append(v.slot)
	root_cells.sort()
	var captures: Array = []
	for e in frame.free:
		captures.append({"source": e["source"], "index": e["index"]})
	return {"nslots": frame.vars.size(), "root_cells": root_cells, "captures": captures}


## Fixes up every "fast" annotation recorded before we knew its Var would
## end up captured. Call once, after the frame's *entire* body (including
## every nested function inside it) has been walked.
func _finish_frame(frame: Frame) -> void:
	for entry in frame.pending_fast_refs:
		var v: Var = entry["var"]
		if v.captured:
			var node: Dictionary = entry["node"]
			node["_loc"] = ["cell", v.slot]


# ==========================================================================
# Name resolution
# ==========================================================================

## Where `name` lives, as seen from `frame`, walking outward through
## enclosing frames and building the "free" capture chain as it goes.
## Mutates `.captured` on whichever Var this turns out to reference.
func _locate(name: String, frame: Frame) -> Array:
	var local := frame.find_local(name)
	if local != null:
		return ["cell" if local.captured else "fast", local.slot]
	if frame.parent == null:
		return ["global", name]
	var outer: Array = _locate(name, frame.parent)
	if outer[0] == "global":
		return ["global", name]
	if outer[0] == "fast" or outer[0] == "cell":
		var pvar: Var = frame.parent.find_local(name)
		pvar.captured = true
		var idx := frame.ensure_free(name, "cell", pvar.slot)
		return ["free", idx]
	# outer[0] == "free": the enclosing frame itself captured `name` from
	# further out still; forward it through this frame's own free list.
	var idx2 := frame.ensure_free(name, "free", int(outer[1]))
	return ["free", idx2]


func _resolve_name_ref(node: Dictionary, frame: Frame) -> void:
	var name: String = node["name"]
	var loc := _locate(name, frame)
	node["_loc"] = loc
	if loc[0] == "fast":
		frame.pending_fast_refs.append({"node": node, "var": frame.find_local(name)})


func _is_direct_module_statement(frame: Frame) -> bool:
	return frame.is_module and frame.scopes.size() == 1


# ==========================================================================
# Statements
# ==========================================================================

func _resolve_stmt_list(stmts: Array, frame: Frame) -> void:
	for s in stmts:
		_resolve_stmt(s, frame)


func _resolve_stmt(node: Dictionary, frame: Frame) -> void:
	var kind: String = node["k"]
	match kind:
		"exprstmt":
			_resolve_expr(node["expr"], frame)
		"let":
			_resolve_let(node, frame)
		"assign":
			_resolve_expr(node["expr"], frame)
			var target: Dictionary = node["target"]
			match target["k"]:
				"var":
					_resolve_name_ref(target, frame)
				"index":
					_resolve_expr(target["obj"], frame)
					_resolve_expr(target["idx"], frame)
				"member":
					_resolve_expr(target["obj"], frame)
				_:
					error = "cannot resolve assignment to a '%s'" % target["k"]
		"block":
			_resolve_nested_block(node, frame)
		"if":
			_resolve_expr(node["cond"], frame)
			_resolve_nested_block(node["then"], frame)
			if node["else"] != null:
				_resolve_nested_block(node["else"], frame)
		"while":
			_resolve_expr(node["cond"], frame)
			_resolve_nested_block(node["body"], frame)
		"return":
			if node["expr"] != null:
				_resolve_expr(node["expr"], frame)
		"break", "continue":
			pass
		"import":
			_resolve_import(node, frame)
		_:
			error = "cannot resolve a '%s' statement" % kind


func _resolve_nested_block(block_node: Dictionary, frame: Frame) -> void:
	frame.push_scope()
	_resolve_stmt_list(block_node["body"], frame)
	var popped := frame.pop_scope()
	var cells: Array = []
	for name in popped:
		var v: Var = popped[name]
		if v.captured:
			cells.append(v.slot)
	cells.sort()
	block_node["_cells"] = cells


func _resolve_let(node: Dictionary, frame: Frame) -> void:
	_resolve_expr(node["expr"], frame)
	var name: String = node["name"]
	if _is_direct_module_statement(frame):
		node["_loc"] = ["global", name]
	else:
		var v := frame.new_slot(name)
		node["_loc"] = ["fast", v.slot]
		frame.pending_fast_refs.append({"node": node, "var": v})


func _resolve_import(node: Dictionary, frame: Frame) -> void:
	var alias: String = String(node.get("alias", ""))
	var direct := _is_direct_module_statement(frame)
	if alias != "":
		if direct:
			node["_loc"] = ["global", alias]
		else:
			var v := frame.new_slot(alias)
			node["_loc"] = ["fast", v.slot]
			frame.pending_fast_refs.append({"node": node, "var": v})
		return

	# Bare `import "x.nova"`: every exported name is pulled straight into
	# this scope. The *names* (not their values) are knowable from the
	# source alone, so resolve them now by parsing (never running) the
	# target module.
	var names := _module_export_names(String(node["path"]))
	var locs: Array = []
	for export_name in names:
		if direct:
			locs.append(["global", export_name])
		else:
			var v2 := frame.new_slot(export_name)
			locs.append(["fast", v2.slot])
			frame.pending_fast_refs.append({"node": node, "var": v2})
	node["_names"] = names
	node["_locs"] = locs


## The export *names* a bare import pulls into scope, found by parsing
## (never running) the target module -- purely syntactic, so it needs no
## cycle guard: parsing path A to list its own `export`-marked names never
## has to ask what path B exports, even if A and B import each other.
##
## A module that can't be read or won't parse is *not* a resolve error
## here: it compiles to zero names (nothing to declare) and the IMPORT
## opcode NovaCompiler still emits unconditionally fails at run time with
## the same "cannot read module"/parse error the tree-walker would raise
## from `vm.load_module` -- matching its timing, not just its wording.
func _module_export_names(path: String) -> Array:
	if _export_cache.has(path):
		return _export_cache[path]
	if not _module_reader.is_valid():
		_export_cache[path] = []
		return []
	var source = _module_reader.call(path)
	if source == null:
		_export_cache[path] = []
		return []

	var parser := NovaParser.new()
	var parsed := parser.parse(String(source), path)
	if parser.error != "":
		_export_cache[path] = []
		return []
	_export_cache[path] = parsed["exports"]
	return parsed["exports"]


# ==========================================================================
# Expressions
# ==========================================================================

func _resolve_expr(node: Dictionary, frame: Frame) -> void:
	var kind: String = node["k"]
	match kind:
		"num", "str", "bool", "null":
			pass
		"var":
			_resolve_name_ref(node, frame)
		"unary":
			_resolve_expr(node["a"], frame)
		"binary":
			_resolve_expr(node["a"], frame)
			_resolve_expr(node["b"], frame)
		"list":
			for item in node["items"]:
				_resolve_expr(item, frame)
		"dict":
			for pair in node["pairs"]:
				_resolve_expr(pair[0], frame)
				_resolve_expr(pair[1], frame)
		"call":
			_resolve_call(node, frame)
		"index":
			_resolve_expr(node["obj"], frame)
			_resolve_expr(node["idx"], frame)
		"member":
			_resolve_expr(node["obj"], frame)
		"func":
			_resolve_function(node, frame)
		_:
			error = "cannot resolve a '%s' expression" % kind


func _resolve_call(node: Dictionary, frame: Frame) -> void:
	var callee: Dictionary = node["callee"]
	if callee["k"] == "var":
		# Resolved unconditionally, even for held(): a program is free to
		# shadow `held` with its own function, and the compiler needs to
		# know whether this name has *any* local/free binding to emit the
		# right runtime check (see NovaCompiler._compile_call).
		_resolve_name_ref(callee, frame)
	else:
		_resolve_expr(callee, frame)
	for a in node["args"]:
		_resolve_expr(a, frame)


func _resolve_function(node: Dictionary, parent_frame: Frame) -> void:
	var fn_frame := Frame.new()
	fn_frame.parent = parent_frame
	fn_frame.push_scope()
	for pname in node["params"]:
		fn_frame.new_slot(String(pname))
	_resolve_stmt_list(node["body"]["body"], fn_frame)
	node["_frame"] = _frame_info(fn_frame)
