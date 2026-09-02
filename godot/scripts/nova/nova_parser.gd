class_name NovaParser
extends RefCounted

## NovaLang recursive-descent parser.
##
## Produces a plain-data AST: every node is a Dictionary with a "k" (kind)
## field. Dictionaries rather than classes because the reference parser in
## reference/nova_parser.py produces exactly the same shapes -- which is
## what lets tools/check_parity.py compare the two node vocabularies and
## lets the conformance goldens be plain JSON.
##
## Grammar (see docs/NOVALANG.md for the full reference):
##
##     program    := decl*
##     decl       := 'reactor' STRING ['version' NUMBER]
##                 | 'params' | 'signals' assignBlock | 'effects' effectBlock
##                 | 'rule'  NAME {mods} '{' 'when' expr 'then' stmt* '}'
##                 | 'fault' NAME {mods} '{' stmt* '}'
##                 | statement
##     statement  := let | set | func | import | export | if | while
##                 | return | break | continue | block | expr ['=' expr]
##
## A `{` in statement position always opens a block, never a dict literal;
## parenthesise a dict used as a statement. That is the only ambiguity in
## the grammar, and it is resolved the same way in both implementations.

## check_parity.py asserts the reference declares exactly these.
const NODE_KINDS := [
	"num", "str", "bool", "null", "list", "dict", "var", "unary", "binary",
	"call", "index", "member", "func",
	"let", "assign", "exprstmt", "if", "while", "return", "break",
	"continue", "block", "import",
]

var error := ""

var _toks: Array = []
var _i := 0
var _prog: Dictionary = {}


static func new_program(name: String = "<source>") -> Dictionary:
	return {
		"name": name,
		"title": "UNNAMED REACTOR",
		"version": 1,
		"params": [],        # [[name, expr], ...]
		"effects": [],       # [[name, expr, persistent], ...]
		"signal_defs": [],   # [[name, expr], ...]
		"rules": [],
		"faults": [],
		"statements": [],
		"held_slots": 0,
		"exports": [],
	}


## Returns the program Dictionary; check `error` for failure.
func parse(src: String, name: String = "<source>") -> Dictionary:
	error = ""
	_prog = new_program(name)

	var lexer := NovaLexer.new()
	_toks = lexer.tokenize(src)
	if lexer.error != "":
		error = lexer.error
		return _prog
	_i = 0

	while not _at(NovaLexer.TOK_EOF) and error == "":
		if _accept(NovaLexer.TOK_KEYWORD, "reactor"):
			var t := _expect(NovaLexer.TOK_STRING)
			if error != "":
				break
			_prog["title"] = str(t["value"])
			if _accept(NovaLexer.TOK_KEYWORD, "version"):
				_prog["version"] = int(_expect(NovaLexer.TOK_NUMBER)["value"])
		elif _accept(NovaLexer.TOK_KEYWORD, "params"):
			_assign_block(_prog["params"])
		elif _accept(NovaLexer.TOK_KEYWORD, "signals"):
			_assign_block(_prog["signal_defs"])
		elif _accept(NovaLexer.TOK_KEYWORD, "effects"):
			_effect_block()
		elif _accept(NovaLexer.TOK_KEYWORD, "rule"):
			var r := _rule()
			if error == "":
				_prog["rules"].append(r)
		elif _accept(NovaLexer.TOK_KEYWORD, "fault"):
			var f := _fault()
			if error == "":
				_prog["faults"].append(f)
		else:
			var s := _statement()
			if error == "":
				_prog["statements"].append(s)

	if error == "":
		_prog["rules"].sort_custom(
			func(a, b): return float(a["priority"]) > float(b["priority"]))
	return _prog


# ==========================================================================
# Token helpers
# ==========================================================================

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
	_fail("expected '%s', got '%s'"
			% [want, NovaLexer.token_text(_cur()["value"])])
	var eof_tok: Dictionary = _toks[_toks.size() - 1]
	return eof_tok


func _fail(message: String) -> void:
	if error == "":
		error = "line %d: %s" % [int(_cur()["line"]), message]
	_i = _toks.size() - 1     # park on EOF so every parse loop unwinds


## Rule and fault names are allowed to look like keywords.
func _name_token() -> Dictionary:
	var t: Dictionary = _toks[_i]
	if t["kind"] == NovaLexer.TOK_IDENT or t["kind"] == NovaLexer.TOK_KEYWORD:
		_i += 1
		return t
	_fail("expected a name, got '%s'" % NovaLexer.token_text(t["value"]))
	return t


# ==========================================================================
# Declarations
# ==========================================================================

func _assign_block(into: Array) -> void:
	_expect(NovaLexer.TOK_OP, "{")
	while error == "" and not _accept(NovaLexer.TOK_OP, "}"):
		if _at(NovaLexer.TOK_EOF):
			_fail("unterminated block")
			return
		var name: String = str(_expect(NovaLexer.TOK_IDENT)["value"])
		_expect(NovaLexer.TOK_OP, "=")
		into.append([name, _expr()])


func _effect_block() -> void:
	_expect(NovaLexer.TOK_OP, "{")
	while error == "" and not _accept(NovaLexer.TOK_OP, "}"):
		if _at(NovaLexer.TOK_EOF):
			_fail("unterminated effects block")
			return
		var name: String = str(_expect(NovaLexer.TOK_IDENT)["value"])
		_expect(NovaLexer.TOK_OP, "=")
		var value := _expr()
		var persistent := _accept(NovaLexer.TOK_KEYWORD, "persistent")
		_prog["effects"].append([name, value, persistent])


func _rule() -> Dictionary:
	var line := int(_cur()["line"])
	var name: String = str(_name_token()["value"])
	var priority := 0.0
	var once := false
	var edge := false
	while error == "":
		if _accept(NovaLexer.TOK_KEYWORD, "priority"):
			priority = float(_expect(NovaLexer.TOK_NUMBER)["value"])
		elif _accept(NovaLexer.TOK_KEYWORD, "once"):
			once = true
		elif _accept(NovaLexer.TOK_KEYWORD, "edge"):
			edge = true
		else:
			break
	_expect(NovaLexer.TOK_OP, "{")
	_expect(NovaLexer.TOK_KEYWORD, "when")
	var cond := _expr()
	_expect(NovaLexer.TOK_KEYWORD, "then")
	var body := _statements_until_brace()
	return {
		"name": name, "priority": priority, "once": once, "edge": edge,
		"cond": cond, "body": body, "fired": false, "was_true": false,
		"line": line,
	}


func _fault() -> Dictionary:
	var line := int(_cur()["line"])
	var name: String = str(_name_token()["value"])
	var weight := 1.0
	var duration := {"k": "num", "v": 30.0}
	var label := name.replace("_", " ").to_upper()
	while error == "":
		if _accept(NovaLexer.TOK_KEYWORD, "weight"):
			weight = float(_expect(NovaLexer.TOK_NUMBER)["value"])
		elif _accept(NovaLexer.TOK_KEYWORD, "duration"):
			duration = _expr()
		elif _accept(NovaLexer.TOK_KEYWORD, "label"):
			label = str(_expect(NovaLexer.TOK_STRING)["value"])
		else:
			break
	_expect(NovaLexer.TOK_OP, "{")
	var body := _statements_until_brace()
	return {
		"name": name, "weight": weight, "duration": duration,
		"label": label, "body": body, "line": line,
	}


func _statements_until_brace() -> Array:
	var out: Array = []
	while error == "" and not _accept(NovaLexer.TOK_OP, "}"):
		if _at(NovaLexer.TOK_EOF):
			_fail("unterminated block")
			return out
		out.append(_statement())
	return out


# ==========================================================================
# Statements
# ==========================================================================

func _block() -> Dictionary:
	_expect(NovaLexer.TOK_OP, "{")
	return {"k": "block", "body": _statements_until_brace()}


func _statement() -> Dictionary:
	var line := int(_cur()["line"])

	if _accept(NovaLexer.TOK_KEYWORD, "let"):
		return _let(line, false)

	if _accept(NovaLexer.TOK_KEYWORD, "func"):
		return _func_decl(line, false)

	if _accept(NovaLexer.TOK_KEYWORD, "export"):
		if _accept(NovaLexer.TOK_KEYWORD, "let"):
			return _let(line, true)
		if _accept(NovaLexer.TOK_KEYWORD, "func"):
			return _func_decl(line, true)
		_fail("export must be followed by let or func")
		return {"k": "block", "body": []}

	if _accept(NovaLexer.TOK_KEYWORD, "import"):
		var path: String = str(_expect(NovaLexer.TOK_STRING)["value"])
		var alias := ""
		if _accept(NovaLexer.TOK_KEYWORD, "as"):
			alias = str(_expect(NovaLexer.TOK_IDENT)["value"])
		return {"k": "import", "path": path, "alias": alias, "line": line}

	if _accept(NovaLexer.TOK_KEYWORD, "set"):
		var target := _expr()
		_expect(NovaLexer.TOK_OP, "=")
		return {"k": "assign", "target": target, "expr": _expr(), "line": line}

	if _accept(NovaLexer.TOK_KEYWORD, "if"):
		return _if_stmt(line)

	if _accept(NovaLexer.TOK_KEYWORD, "while"):
		var cond := _expr()
		return {"k": "while", "cond": cond, "body": _block(), "line": line}

	if _accept(NovaLexer.TOK_KEYWORD, "return"):
		var value = null
		if not _at(NovaLexer.TOK_OP, "}") and not _at(NovaLexer.TOK_EOF):
			value = _expr()
		return {"k": "return", "expr": value, "line": line}

	if _accept(NovaLexer.TOK_KEYWORD, "break"):
		return {"k": "break", "line": line}

	if _accept(NovaLexer.TOK_KEYWORD, "continue"):
		return {"k": "continue", "line": line}

	if _at(NovaLexer.TOK_OP, "{"):
		return _block()

	# Expression statement, or a bare assignment to an lvalue.
	var node := _expr()
	if _accept(NovaLexer.TOK_OP, "="):
		return {"k": "assign", "target": node, "expr": _expr(), "line": line}
	return {"k": "exprstmt", "expr": node, "line": line}


func _let(line: int, exported: bool) -> Dictionary:
	var name: String = str(_expect(NovaLexer.TOK_IDENT)["value"])
	_expect(NovaLexer.TOK_OP, "=")
	if exported:
		_prog["exports"].append(name)
	return {"k": "let", "name": name, "expr": _expr(),
			"exported": exported, "line": line}


func _func_decl(line: int, exported: bool) -> Dictionary:
	var name: String = str(_expect(NovaLexer.TOK_IDENT)["value"])
	var params := _param_list()
	var body := _block()
	if exported:
		_prog["exports"].append(name)
	var fn := {"k": "func", "name": name, "params": params, "body": body,
			"line": line}
	# A named function declaration is sugar for `let <name> = func...`,
	# which is what makes recursion and closures fall out for free.
	return {"k": "let", "name": name, "expr": fn, "exported": exported,
			"line": line}


func _param_list() -> Array:
	_expect(NovaLexer.TOK_OP, "(")
	var params: Array = []
	if not _at(NovaLexer.TOK_OP, ")"):
		params.append(str(_expect(NovaLexer.TOK_IDENT)["value"]))
		while _accept(NovaLexer.TOK_OP, ","):
			params.append(str(_expect(NovaLexer.TOK_IDENT)["value"]))
	_expect(NovaLexer.TOK_OP, ")")
	return params


func _if_stmt(line: int) -> Dictionary:
	var cond := _expr()
	var then_block := _block()
	var else_block = null
	if _accept(NovaLexer.TOK_KEYWORD, "else"):
		if _accept(NovaLexer.TOK_KEYWORD, "if"):
			else_block = {"k": "block", "body": [_if_stmt(int(_cur()["line"]))]}
		else:
			else_block = _block()
	return {"k": "if", "cond": cond, "then": then_block,
			"else": else_block, "line": line}


# ==========================================================================
# Expressions
# ==========================================================================

func _expr() -> Dictionary:
	return _or_expr()


func _or_expr() -> Dictionary:
	var node := _and_expr()
	while error == "" and _accept(NovaLexer.TOK_KEYWORD, "or"):
		node = {"k": "binary", "op": "or", "a": node, "b": _and_expr()}
	return node


func _and_expr() -> Dictionary:
	var node := _not_expr()
	while error == "" and _accept(NovaLexer.TOK_KEYWORD, "and"):
		node = {"k": "binary", "op": "and", "a": node, "b": _not_expr()}
	return node


func _not_expr() -> Dictionary:
	if _accept(NovaLexer.TOK_KEYWORD, "not"):
		return {"k": "unary", "op": "not", "a": _not_expr()}
	return _comparison()


func _comparison() -> Dictionary:
	var node := _additive()
	while error == "" and _cur()["kind"] == NovaLexer.TOK_OP and \
			["<", ">", "<=", ">=", "==", "!="].has(_cur()["value"]):
		var op: String = str(_cur()["value"])
		_i += 1
		node = {"k": "binary", "op": op, "a": node, "b": _additive()}
	return node


func _additive() -> Dictionary:
	var node := _multiplicative()
	while error == "" and _cur()["kind"] == NovaLexer.TOK_OP and \
			["+", "-"].has(_cur()["value"]):
		var op: String = str(_cur()["value"])
		_i += 1
		node = {"k": "binary", "op": op, "a": node, "b": _multiplicative()}
	return node


func _multiplicative() -> Dictionary:
	var node := _unary()
	while error == "" and _cur()["kind"] == NovaLexer.TOK_OP and \
			["*", "/", "%"].has(_cur()["value"]):
		var op: String = str(_cur()["value"])
		_i += 1
		node = {"k": "binary", "op": op, "a": node, "b": _unary()}
	return node


func _unary() -> Dictionary:
	if _accept(NovaLexer.TOK_OP, "-"):
		return {"k": "unary", "op": "-", "a": _unary()}
	if _accept(NovaLexer.TOK_OP, "+"):
		return _unary()
	return _postfix()


func _postfix() -> Dictionary:
	var node := _primary()
	while error == "":
		var line := int(_cur()["line"])
		if _accept(NovaLexer.TOK_OP, "("):
			var args := _arg_list()
			var slot := -1
			# held() is a special form: it needs a stable per-call-site
			# timer, allocated once here at parse time.
			if node.get("k", "") == "var" and node.get("name", "") == "held":
				slot = int(_prog["held_slots"])
				_prog["held_slots"] = slot + 1
			node = {"k": "call", "callee": node, "args": args,
					"slot": slot, "line": line}
		elif _accept(NovaLexer.TOK_OP, "["):
			var idx := _expr()
			_expect(NovaLexer.TOK_OP, "]")
			node = {"k": "index", "obj": node, "idx": idx, "line": line}
		elif _accept(NovaLexer.TOK_OP, "."):
			var member: String = str(_name_token()["value"])
			node = {"k": "member", "obj": node, "name": member, "line": line}
		else:
			return node
	return node


func _arg_list() -> Array:
	var args: Array = []
	if not _at(NovaLexer.TOK_OP, ")"):
		args.append(_expr())
		while _accept(NovaLexer.TOK_OP, ","):
			if _at(NovaLexer.TOK_OP, ")"):
				break            # tolerate a trailing comma
			args.append(_expr())
	_expect(NovaLexer.TOK_OP, ")")
	return args


func _primary() -> Dictionary:
	var t: Dictionary = _cur()
	var line := int(t["line"])

	if t["kind"] == NovaLexer.TOK_NUMBER:
		_i += 1
		return {"k": "num", "v": float(t["value"])}
	if t["kind"] == NovaLexer.TOK_STRING:
		_i += 1
		return {"k": "str", "v": str(t["value"])}
	if _accept(NovaLexer.TOK_KEYWORD, "true"):
		return {"k": "bool", "v": true}
	if _accept(NovaLexer.TOK_KEYWORD, "false"):
		return {"k": "bool", "v": false}
	if _accept(NovaLexer.TOK_KEYWORD, "null"):
		return {"k": "null"}

	if _accept(NovaLexer.TOK_KEYWORD, "func"):        # anonymous function
		var params := _param_list()
		var body := _block()
		return {"k": "func", "name": "", "params": params, "body": body,
				"line": line}

	if _accept(NovaLexer.TOK_OP, "("):
		var node := _expr()
		_expect(NovaLexer.TOK_OP, ")")
		return node

	if _accept(NovaLexer.TOK_OP, "["):
		var items: Array = []
		if not _at(NovaLexer.TOK_OP, "]"):
			items.append(_expr())
			while _accept(NovaLexer.TOK_OP, ","):
				if _at(NovaLexer.TOK_OP, "]"):
					break
				items.append(_expr())
		_expect(NovaLexer.TOK_OP, "]")
		return {"k": "list", "items": items}

	if _accept(NovaLexer.TOK_OP, "{"):
		var pairs: Array = []
		if not _at(NovaLexer.TOK_OP, "}"):
			pairs.append(_dict_pair())
			while _accept(NovaLexer.TOK_OP, ","):
				if _at(NovaLexer.TOK_OP, "}"):
					break
				pairs.append(_dict_pair())
		_expect(NovaLexer.TOK_OP, "}")
		return {"k": "dict", "pairs": pairs}

	if t["kind"] == NovaLexer.TOK_IDENT:
		_i += 1
		return {"k": "var", "name": str(t["value"]), "line": line}

	_fail("unexpected '%s' in expression" % NovaLexer.token_text(t["value"]))
	return {"k": "num", "v": 0.0}


## Keys may be bare identifiers, string literals, or a bracketed expression
## for a computed key.
func _dict_pair() -> Array:
	var key: Dictionary
	if _accept(NovaLexer.TOK_OP, "["):
		key = _expr()
		_expect(NovaLexer.TOK_OP, "]")
	elif _cur()["kind"] == NovaLexer.TOK_STRING:
		key = {"k": "str", "v": str(_expect(NovaLexer.TOK_STRING)["value"])}
	else:
		key = {"k": "str", "v": str(_name_token()["value"])}
	_expect(NovaLexer.TOK_OP, ":")
	return [key, _expr()]
