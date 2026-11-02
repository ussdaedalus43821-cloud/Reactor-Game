class_name NovaCode
extends RefCounted

## One compiled frame's bytecode: a module, a function body, a rule body,
## a fault body, or a bare param/effect/signal expression. NovaCompiler
## builds these; NovaVM2 (Phase 2) will run them.
##
## `ops`/`args`/`positions` are parallel arrays, one entry per instruction:
## `ops[ip]` is an opcode number (NovaOpcodes.OP), `args[ip]` is whatever
## that opcode needs (an int slot, a String name, a small Dictionary -- see
## nova_opcodes.gd), `positions[ip]` is the source line, for error messages.
## `constants` holds literal values (LOAD_CONST indexes into it).
## `child_codes` holds the NovaCode for every function literal lexically
## inside this one (MAKE_FUNCTION indexes into it).

var name := ""
var nslots := 0           ## size of this frame's `slots` array at runtime
var param_count := 0      ## the first `param_count` slots are parameters

var ops := PackedInt32Array()
var args: Array = []
var positions := PackedInt32Array()
var constants: Array = []
var child_codes: Array = []   # Array[NovaCode]


## Human-readable disassembly, recursing into every nested function. Mirrors
## `python3 novalang.py --dis` in spirit: index, opcode, argument, with the
## constant pool and child functions printed underneath.
func disassemble(indent: String = "") -> String:
	var out := PackedStringArray()
	var header_name := name if name != "" else "<anonymous>"
	out.append(indent + "== " + header_name + " (slots=" + str(nslots) +
			", params=" + str(param_count) + ", ops=" + str(ops.size()) + ") ==")
	for ip in range(ops.size()):
		var op: int = ops[ip]
		var op_name: String = NovaOpcodes.NAMES[op] if op >= 0 and op < NovaOpcodes.NAMES.size() \
				else "??" + str(op)
		var line: int = positions[ip] if ip < positions.size() else 0
		out.append(indent + _pad_right(str(ip), 5) + "line " + _pad_right(str(line), 6) +
				_pad_right(op_name, 22) + _format_arg(args[ip]))
	if constants.size() > 0:
		out.append(indent + "-- constants --")
		for i in range(constants.size()):
			out.append(indent + "  [" + str(i) + "] " + _format_arg(constants[i]))
	for i in range(child_codes.size()):
		var child: NovaCode = child_codes[i]
		out.append(indent + "-- child " + str(i) + " --")
		out.append(child.disassemble(indent + "    "))
	return "\n".join(out)


static func _pad_right(s: String, width: int) -> String:
	while s.length() < width:
		s += " "
	return s


static func _format_arg(arg) -> String:
	if arg == null:
		return ""
	return str(arg)
