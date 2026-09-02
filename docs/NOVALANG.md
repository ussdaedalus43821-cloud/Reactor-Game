# NovaLang

A small scripting language, implemented in pure GDScript, that runs inside
Godot on every platform the engine targets.

* **Ships:** `godot/scripts/nova/` — `nova_lexer.gd`, `nova_parser.gd`,
  `nova_evaluator.gd`, `nova_vm.gd`.
* **Judges:** `reference/` — a second implementation in Python that is
  never shipped and never executed by the game. See
  [ARCHITECTURE.md](ARCHITECTURE.md).

## Embedding it

```gdscript
var vm := NovaVM.new()
vm.register_function("hull", func(args): return $Ship.hull)
vm.load_file("daedalus_rules.nova")          # from res://scripts/
vm.call_function("threat_score", [["capital", "wdart"]])
```

| Method | Purpose |
|---|---|
| `vm.eval(source, name)` | parse and initialise a program; `false` on failure, see `vm.error` |
| `vm.load_file(path)` | the same, reading `res://scripts/<path>` |
| `vm.call_function(name, args)` | call a NovaLang function from GDScript |
| `vm.register_function(name, callable)` | expose a GDScript function to NovaLang |
| `vm.get_global(name, fallback)` / `set_global` | read/write the program's globals |
| `vm.tick(dt, inputs, faults_enabled)` | run one cycle of the rule engine |
| `vm.drain_output()` | lines `print()` has emitted since the last drain |
| `vm.reset(seed)` | re-run the program from scratch |
| `vm.describe()` | title, params, rules, faults, exports |

`call_function()` rather than `call()`: every Godot `Object` already has a
`call()` method and redefining it is a hard error.

A registered function receives **one argument: an `Array` of the evaluated
arguments**, and its return value becomes the call's value in NovaLang.

## Program structure

Declarations may appear in any order.

```nova
reactor "TITLE" version 1     # program title (the keyword is a holdover
                              # from the first program written in NovaLang)

import "lib/util.nova" as u   # modules
let x = 1                     # top-level statements run at load
func f(a) { return a * 2 }

params  { name = <expr> ... }             # constants, evaluated at reset
effects { name = <expr> [persistent] ... } # vars faults write
signals { name = <expr> ... }             # derived, recomputed each tick

rule  NAME [priority N] [once] [edge] { when <expr> then <stmt>... }
fault NAME [weight W] [duration S] [label "TEXT"] { <stmt>... }
```

Comments run to end of line with `#` or `//`.

## Values

Numbers (always 64-bit floats), strings, booleans, `null`, lists, dicts,
and functions.

```nova
let n = 2.5e3
let s = "quotes \" and \n newlines"
let l = [1, "two", [3], null]
let d = { bare: 1, "quoted": 2, [key_expr]: 3 }
```

Indexing works on lists (negative indices count from the end), dicts and
strings. `d.name` is sugar for `d["name"]`.

```nova
l[0] = 7      d.temp = 812.5      print(l[-1], "abc"[1])
```

Out-of-range list indices and missing dict keys are **errors**, not `null`
— use `has(d, k)` or `get(d, k, default)`. Truthiness: `null` and `false`
are false, `0` is false, `""` is false, `[]` and `{}` are false.

`==` compares deeply and never approximately: `[1,[2]] == [1,[2]]` is true,
`1 == "1"` is false.

## Statements

```nova
let x = 1                     # declare in the current scope
x = 2                         # assign (nearest binding, else global)
set x = 3                     # v1 spelling of the same thing

if a { ... } else if b { ... } else { ... }
while cond { ... break ... continue ... }

func name(a, b) { return a + b }
let anon = func(x) { return x * 2 }

import "lib/util.nova"          # merge the module's exports into scope
import "lib/util.nova" as util  # or bind them to a name
export let VERSION = 3          # visible to importers
export func helper() { }
```

A `{` in statement position always opens a **block**, never a dict literal.
Parenthesise a dict used as a statement.

## Expressions

Precedence, loosest to tightest:

```
or
and
not
==  !=  <  <=  >  >=
+  -
*  /  %
unary -
call ()   index []   member .
literals, identifiers, ( )
```

`and` / `or` short-circuit. `+` is string concatenation when either side is
a string, and list concatenation when both are lists. Division and modulo
by zero yield `0` rather than an error — a policy file should not be able
to take the reactor down.

### Call resolution

A bare name in call position resolves in this order:

1. a **user function** bound to that name,
2. a **builtin**,
3. a **host function** registered by the embedder.

A *non-callable* binding is skipped rather than being an error. That is
deliberate: `reactor_rules.nova` has both a `scram` variable (the trip
latch) and a `scram()` host function, and neither shadows the other.

Builtins and host functions are **not first-class values** — only
user-defined functions can be passed around, returned and stored.

## Functions, recursion, closures

A named declaration is sugar for `let NAME = func...`, which is where
recursion and closures come from:

```nova
func fib(n) {
    if n < 2 { return n }
    return fib(n - 1) + fib(n - 2)
}

func counter() {
    let n = 0
    return func() { n = n + 1  return n }     # captures n
}
let tick = counter()
tick()  tick()  print(tick())                 # 3
```

Arity is checked; a call with the wrong number of arguments is an error.
A function that falls off the end returns `null`.

## Builtins

| Group | Functions |
|---|---|
| numeric | `abs` `min` `max` `clamp(v,lo,hi)` `exp` `sqrt` `floor` `round` `pow(b,e)` `ramp(x)` `lerp(a,b,t)` |
| random | `pick(...)` `rand(lo,hi)` |
| temporal | `held(cond, seconds)` |
| types | `type(v)` `str` `num` `bool` `int` |
| collections | `len` `keys` `has(c,k)` `get(d,k,default)` `append(l,v)` `remove_at(l,i)` `slice(seq,a,b)` `range(n)` / `range(a,b)` |
| strings | `join(l,sep)` `split(s,sep)` `contains(h,n)` `upper` `lower` |
| output | `print(...)` |

`ramp` clamps to 0..1; `lerp`'s `t` is clamped; `round` is half-away-from-
zero; `type` returns `"number"`, `"string"`, `"bool"`, `"list"`, `"dict"`,
`"func"` or `"null"`.

**`held(cond, seconds)`** is the temporal predicate — true once `cond` has
been continuously true for that long. Each call site gets its own timer,
allocated at parse time, so the same condition in two rules tracks two
clocks. Its condition is left unevaluated until reached, so a `held()`
behind a short-circuited `and` does not accumulate — which is exactly what
you want for a guarded trip:

```nova
rule core_disassembly priority 200 once {
    when  running and held(fuel_temp_c > meltdown_temp_c, 5.0)
    then  meltdown("CORE DISASSEMBLY")
}
```

## Modules

```nova
# lib/util.nova
export func double(x) { return x * 2 }
export let VERSION = 3
let private = 99                # not exported, invisible to importers
```

```nova
import "lib/util.nova" as u     # u.double(21), u.VERSION
import "lib/util.nova"          # double(21), VERSION
```

Modules are resolved relative to `res://scripts/`, evaluated **once** and
cached, and get their own global scope — a module sees the builtins and the
host functions, never the importer's variables. Circular imports are
reported rather than hanging.

## The rule engine

`vm.tick(dt, inputs, faults_enabled)` runs one cycle:

1. every non-`persistent` `effects` var is reset to its declared default,
2. `inputs` are written into the globals,
3. the fault scheduler runs (and executes the active fault's body),
4. `signals` are recomputed,
5. `rules` fire in descending `priority`.

Because `set` applies as rules run, **the lowest-priority rule that writes
a variable wins** — so write mutually exclusive guards when order should
not matter, as the operating-state rules do.

| Modifier | Effect |
|---|---|
| `priority N` | execution order, descending. Default 0. |
| `once` | fires at most once per run |
| `edge` | fires only on the rising edge of its condition |

`effects` declares what faults write. Resetting them every tick is what
makes a cleared fault stop acting on the plant with no cleanup code:

```nova
effects {
    flow_frac = 1.0              # snaps back to 1.0 every tick
    xenon_pcm = 0.0 persistent   # keeps its value; a rule decays it
}
```

A `fault` is scheduled by weight, runs its body **every tick** for
`duration` seconds, and logs `ALARM: <label>` on entry and
`<label> CLEARED` on exit through the host's `log()`.
`fault_elapsed`, `fault_label` and `active_fault` are readable inside it.

## Errors and limits

Parse errors abort the load; runtime errors abort the tick. Both land in
`vm.error` with a line number, and `nova_bridge.gd` surfaces them on the
panel rather than swallowing them.

Two guards make a bad policy file survivable:

* **step budget** — 500 000 evaluation steps per tick. `while true {}`
  fails the tick instead of hanging the render thread.
* **call depth** — 128 frames. Runaway recursion is an error, not a crash.

Both limits are identical in the reference and checked by
`tools/check_parity.py`.

## Deliberate differences between the two implementations

Only one: `pick()`, `rand()` and the fault scheduler draw from Godot's
`RandomNumberGenerator` in the shipping interpreter and Python's `random`
in the reference, so the same seed does **not** produce the same fault
sequence in both. Nothing in the conformance corpus depends on randomness.

Everything else — precedence, short-circuiting, number formatting, deep
equality, `held()` timers, `edge`/`once` latches, priority ordering, effect
reset semantics, and the exact text of every error message — is identical,
and `parity_check.gd` proves it by replaying 51 recorded programs and a
900-step reactor trace inside Godot.

## Validating a policy

```bash
python3 reference/reactor_host.py --validate --rules reactor_rules.nova
```

prints the parsed program — title, params, every rule and fault by name —
or the first error with its line. `tools/check_project.py` runs the same
parse over every `.nova` file in the project, so a syntax error is a failed
build check rather than a black panel at launch.
