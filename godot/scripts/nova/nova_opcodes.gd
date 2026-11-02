class_name NovaOpcodes
extends RefCounted

## The bytecode NovaCompiler emits and (in Phase 2) NovaVM2 runs.
##
## Values are plain GDScript Variants throughout -- a NovaLang number is a
## GDScript float, a NovaLang list is a GDScript Array, and so on -- so the
## VM needs no boxing beyond Cell (see below). `null` doubles as NovaLang's
## own `null`; there is no separate "nothing" sentinel.
##
## Stack machine, one CodeObject per frame (module / function / rule body /
## fault body / a bare param-effect-signal expression). Every opcode below
## is documented by the stack effect it has and, where it isn't obvious,
## by the exact argument shape the compiler puts in `args[ip]`.
##
## Closures: a captured local lives in a Cell (nova_code.gd) instead of
## directly in `slots`. NEW_CELLS runs at the top of whichever block (or
## frame) declares the captured name, boxing whatever is currently in that
## slot -- for a parameter, its argument value; for a `let` not yet run,
## garbage that the `let`'s own STORE_FAST/STORE_CELL overwrites a moment
## later. Because NEW_CELLS sits in the bytecode at the block's own
## position, a block re-entered by a loop gets a *fresh* Cell every lap --
## which is what lets `closure_capture_loop` (see conformance.json) latch
## a different value per iteration.
##
## LOAD_CELL/STORE_CELL address a Cell boxed in *this* frame's own
## `slots`. LOAD_FREE/STORE_FREE address a Cell this function's closure
## captured from an *enclosing* frame (MAKE_FUNCTION copies the Cell
## reference itself, never the value, into the new function's `cells`).
##
## Stack-effect contract Phase 2's VM must honor (NovaCompiler already
## emits to this exact convention):
##
##   LOAD_CONST c        -- -> const[c]
##   POP                 -- v ->
##   LOAD_FAST i          -- -> slots[i]
##   STORE_FAST i         -- v -> (slots[i] = v)
##   LOAD_CELL i          -- -> (slots[i] as Cell).value
##   STORE_CELL i         -- v -> (sets (slots[i] as Cell).value = v)
##   LOAD_FREE i          -- -> (cells[i] as Cell).value
##   STORE_FREE i         -- v -> (sets (cells[i] as Cell).value = v)
##   LOAD_GLOBAL name     -- -> globals[name]  (error if absent)
##   STORE_GLOBAL name    -- v -> (globals[name] = v; creates if absent)
##   NEW_CELLS [slots]    -- -> (for each i in slots: slots[i] = Cell.new(slots[i]))
##   ADD/SUB/MUL/DIV/MOD  -- a, b -> a OP b   (+ also does string/list concat)
##   NEG                  -- a -> -a
##   NOT                  -- a -> not truthy(a)
##   EQ/NE/LT/GT/LE/GE    -- a, b -> bool
##   JUMP target               -- unconditional
##   JUMP_IF_FALSE target      -- v -> (pop always; jump if not truthy(v))
##   JUMP_IF_FALSE_KEEP target -- coerces top to bool(truthy); if false,
##                                KEEP it and jump; if true, POP it and
##                                fall through (used for `and`)
##   JUMP_IF_TRUE_KEEP target  -- mirror of the above (used for `or`)
##   BUILD_LIST n              -- v1..vn -> [v1..vn]
##   BUILD_DICT n              -- k1,v1..kn,vn -> {k1:v1, ...}
##   INDEX                     -- obj, idx -> obj[idx]
##   GET_MEMBER name           -- obj -> obj[name]
##   STORE_INDEX               -- value, obj, idx -> (obj[idx] = value)
##   STORE_MEMBER name         -- value, obj -> (obj[name] = value)
##   MAKE_FUNCTION {child,captures} -- -> a callable value bound to
##       child_codes[child], whose `cells` array is built by reading, for
##       each entry in `captures` (in order): slots[index] if source is
##       "cell", or cells[index] (this frame's own) if source is "free".
##   CALL n                    -- callee, a1..an -> result (callee must be
##                                a NovaLang function value)
##   CALL_NAME {name,loc,argc,held_slot} -- a1..aargc -> result. Checks, in
##       order: (1) does `loc` name a bound function value (loc may be
##       "fast"/"cell"/"free"/"global" -- read it like LOAD_* above) --
##       skip to (2) if it's bound to something non-callable instead of
##       erroring (mirrors nova_evaluator.gd's _eval_call); (2) if nothing
##       callable was bound and held_slot >= 0, run the held() timer logic
##       against that slot -- `held` is in BUILTIN_ARITY but the
##       tree-walker special-cases it *before* the builtin table (see
##       _eval_call), so step (3) below must never be reached for it; (3)
##       is `name` an ordinary builtin; (4) is `name` a host-registered
##       function; else "unknown function".
##   RETURN                    -- v -> (pops this frame, pushes v onto the
##                                caller's stack)
##   IMPORT path                -- -> the target module's exports Dictionary
##       (calls back into the host's module loader; cached there same as
##       today)

const NAMES := [
	"LOAD_CONST", "POP",
	"LOAD_FAST", "STORE_FAST",
	"LOAD_CELL", "STORE_CELL",
	"LOAD_FREE", "STORE_FREE",
	"LOAD_GLOBAL", "STORE_GLOBAL",
	"NEW_CELLS",
	"ADD", "SUB", "MUL", "DIV", "MOD", "NEG", "NOT",
	"EQ", "NE", "LT", "GT", "LE", "GE",
	"JUMP", "JUMP_IF_FALSE", "JUMP_IF_FALSE_KEEP", "JUMP_IF_TRUE_KEEP",
	"BUILD_LIST", "BUILD_DICT",
	"INDEX", "GET_MEMBER", "STORE_INDEX", "STORE_MEMBER",
	"MAKE_FUNCTION", "CALL", "CALL_NAME",
	"RETURN", "IMPORT",
]

## name -> opcode number. Must stay in lockstep with NAMES above; the test
## harness (nova_compiler_test.gd) asserts they agree before trusting
## anything else.
const OP := {
	"LOAD_CONST": 0, "POP": 1,
	"LOAD_FAST": 2, "STORE_FAST": 3,
	"LOAD_CELL": 4, "STORE_CELL": 5,
	"LOAD_FREE": 6, "STORE_FREE": 7,
	"LOAD_GLOBAL": 8, "STORE_GLOBAL": 9,
	"NEW_CELLS": 10,
	"ADD": 11, "SUB": 12, "MUL": 13, "DIV": 14, "MOD": 15, "NEG": 16, "NOT": 17,
	"EQ": 18, "NE": 19, "LT": 20, "GT": 21, "LE": 22, "GE": 23,
	"JUMP": 24, "JUMP_IF_FALSE": 25, "JUMP_IF_FALSE_KEEP": 26, "JUMP_IF_TRUE_KEEP": 27,
	"BUILD_LIST": 28, "BUILD_DICT": 29,
	"INDEX": 30, "GET_MEMBER": 31, "STORE_INDEX": 32, "STORE_MEMBER": 33,
	"MAKE_FUNCTION": 34, "CALL": 35, "CALL_NAME": 36,
	"RETURN": 37, "IMPORT": 38,
}


## Self-check: NAMES[OP[name]] == name for every name. Called by the test
## harness; failing this means the two tables above drifted apart.
static func tables_agree() -> bool:
	if NAMES.size() != OP.size():
		return false
	for name in OP:
		var number: int = OP[name]
		if number < 0 or number >= NAMES.size() or NAMES[number] != name:
			return false
	return true
