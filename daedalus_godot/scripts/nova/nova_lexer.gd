class_name NovaLexer
extends RefCounted

## NovaLang tokenizer.
##
## A hand-written scanner -- no RegEx -- because the reference
## implementation in reference/nova_lexer.py is also hand-written and the
## two must agree character for character. Keyword set, operator set,
## escape sequences and error wording are all mirrored there, and
## tools/check_parity.py fails the build if they drift.
##
## GDScript has no exceptions, so failure is reported through `error`.

## Anything here can still be used as a *rule* or *fault* name -- the parser
## accepts a keyword token where a declaration name is expected -- but not
## as a variable.
const KEYWORDS := {
	# v1 reactor DSL
	"reactor": true, "version": true, "params": true, "effects": true,
	"signals": true, "rule": true, "fault": true, "when": true, "then": true,
	"set": true, "priority": true, "once": true, "edge": true, "weight": true,
	"duration": true, "label": true, "persistent": true,
	# operators that read as words
	"and": true, "or": true, "not": true,
	# literals
	"true": true, "false": true, "null": true,
	# v2 imperative core
	"let": true, "func": true, "return": true, "if": true, "else": true,
	"while": true, "break": true, "continue": true,
	"import": true, "export": true, "as": true,
}

## Longest first, so "<=" wins over "<".
const OPERATORS := [
	"==", "!=", "<=", ">=",
	"+", "-", "*", "/", "%", "<", ">", "=",
	"(", ")", "{", "}", "[", "]", ",", ".", ":",
]

const TOK_NUMBER := "number"
const TOK_STRING := "string"
const TOK_IDENT := "ident"
const TOK_KEYWORD := "keyword"
const TOK_OP := "op"
const TOK_EOF := "eof"

var error := ""


## Integers print without a decimal point; everything else gets up to six
## decimal places with trailing zeros trimmed. Defined explicitly, here
## where numbers are parsed, because str(float) does not agree between
## GDScript and Python -- and a value that reads differently in the two
## runtimes is a parity failure.
static func number_text(v: float) -> String:
	if is_nan(v):
		return "nan"
	if is_inf(v):
		return "inf" if v > 0.0 else "-inf"
	if v == floor(v) and absf(v) < 1e15:
		return str(int(v))
	var s := "%.6f" % v
	while s.ends_with("0"):
		s = s.substr(0, s.length() - 1)
	if s.ends_with("."):
		s = s.substr(0, s.length() - 1)
	return s


## How a token appears inside a parser diagnostic.
static func token_text(value) -> String:
	match typeof(value):
		TYPE_NIL:
			return "eof"
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_FLOAT, TYPE_INT:
			return number_text(float(value))
	return str(value)


static func _is_digit(c: int) -> bool:
	return c >= 48 and c <= 57


static func _is_alpha(c: int) -> bool:
	return c == 95 or (c >= 97 and c <= 122) or (c >= 65 and c <= 90)


static func _is_alnum(c: int) -> bool:
	return _is_alpha(c) or _is_digit(c)


static func _is_space(c: int) -> bool:
	return c == 32 or c == 9 or c == 13 or c == 10


func _tok(kind: String, value, line: int) -> Dictionary:
	return {"kind": kind, "value": value, "line": line}


func tokenize(src: String) -> Array:
	error = ""
	var tokens: Array = []
	var i := 0
	var line := 1
	var n := src.length()

	while i < n:
		var c := src.unicode_at(i)

		if _is_space(c):
			if c == 10:
				line += 1
			i += 1
			continue

		# Comments: `#` and `//` both run to end of line.
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
					i = save        # "2e" is the number 2 followed by `e`
			tokens.append(_tok(TOK_NUMBER, src.substr(start, i - start).to_float(), line))
			continue

		if c == 34:
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
						114: buf += "\r"
						34: buf += "\""
						92: buf += "\\"
						_: buf += String.chr(esc)
				else:
					if ch == 10:
						line += 1
					buf += String.chr(ch)
				i += 1
			if i >= n:
				error = "line %d: unterminated string literal" % line
				return [_tok(TOK_EOF, null, line)]
			i += 1
			tokens.append(_tok(TOK_STRING, buf, line))
			continue

		if _is_alpha(c):
			var s := i
			while i < n and _is_alnum(src.unicode_at(i)):
				i += 1
			var word := src.substr(s, i - s)
			tokens.append(_tok(TOK_KEYWORD if KEYWORDS.has(word) else TOK_IDENT,
					word, line))
			continue

		var matched := ""
		for op in OPERATORS:
			var text: String = op
			if src.substr(i, text.length()) == text:
				matched = text
				break
		if matched == "":
			error = "line %d: unexpected character '%s'" % [line, src.substr(i, 1)]
			return [_tok(TOK_EOF, null, line)]
		tokens.append(_tok(TOK_OP, matched, line))
		i += matched.length()

	tokens.append(_tok(TOK_EOF, null, line))
	return tokens
