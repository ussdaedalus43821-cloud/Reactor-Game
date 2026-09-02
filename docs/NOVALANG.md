# NovaLang

NovaLang is the small declarative language the reactor's control policy is
written in. One file — `godot/sim/reactor_rules.nova` — holds every trip
setpoint, alarm tier, fault definition and operating-state transition in
the simulation.

It is executed by two interpreters that are kept in step by
`tools/check_parity.py`:

* `godot/sim/nova_runtime.py` — Python, used by the desktop bridge daemon
* `godot/scripts/nova_vm.gd` — GDScript, used in-engine on iOS and Web

Both are hand-written recursive-descent parsers over the same grammar.
Neither knows anything about pixels, and neither integrates the core.

## Why it exists

The physics answers *what the reactor is doing*. The policy answers *what
should happen about it* — and that second question is the one you actually
want to iterate on. Pulling it out into a data file means a setpoint change
is a two-character edit that takes effect on macOS, iOS and Web at once,
with no Python change, no GDScript change and no rebuild.

## Program structure

A program is a sequence of top-level declarations in any order.

```nova
reactor "CHERNOBYL-1" version 1

params  { ... }
effects { ... }
signals { ... }

rule  <name> [priority N] [once] [edge] { when <expr> then <action>... }
fault <name> [weight W] [duration S] [label "TEXT"] { <action>... }
```

Comments run to end of line with either `#` or `//`. Whitespace and
newlines are insignificant.

### `params`

Constants. Evaluated once at reset, in order, so a later param may
reference an earlier one.

```nova
params {
    trip_flux_pct = 150.0
    warn_flux_pct = trip_flux_pct * 0.77
}
```

### `effects`

The variables faults write to. At the top of every tick each one is reset
to its declared default **unless** marked `persistent` — which is what
makes a fault stop acting on the plant the moment it clears, with no
cleanup code anywhere.

```nova
effects {
    flow_frac  = 1.0             # snaps back to 1.0 every tick
    xenon_pcm  = 0.0 persistent  # keeps its value; a rule decays it
}
```

### `signals`

Derived values, recomputed each tick after fault effects and before any
rule runs. Use them to name a condition once and read it everywhere.

```nova
signals {
    hot     = fuel_temp_c > overheat_temp_c
    running = not game_over
}
```

### `rule`

```nova
rule fuel_temp_trip priority 285 {
    when  running and not scram and fuel_temp_c > trip_fuel_temp_c
    then  scram("AUTO SCRAM -- FUEL TEMPERATURE HIGH")
}
```

Rules run every tick, highest `priority` first (default 0). Because `set`
actions are applied as they run, **the lowest-priority rule that writes a
variable wins** — so write mutually exclusive guards when order should not
matter, as the operating-state rules do.

Modifiers:

| Modifier | Effect |
|---|---|
| `priority N` | execution order, descending. Default 0. |
| `once` | fires at most once per run. For end-of-run events. |
| `edge` | fires only on the rising edge of its condition, not while it stays true. For log lines and one-shot latches. |

### `fault`

```nova
fault feedwater_failure weight 1.0 duration 45.0 label "FEEDWATER PUMP FAILURE" {
    set flow_frac = 0.3
}
```

One fault is active at a time. The scheduler waits
`fault_first_min_s..fault_first_max_s` for the first, picks by `weight`,
runs the body **every tick** for `duration` seconds, then waits
`fault_gap_min_s..fault_gap_max_s` and picks again. Entry logs
`ALARM: <label>`, exit logs `<label> CLEARED`. Inside the body,
`fault_elapsed` counts seconds since activation.

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
literals, identifiers, calls, ( )
```

`and` and `or` short-circuit. A `held()` inside a skipped branch does not
accumulate, which is the behaviour you want for guarded trips.

`+` is string concatenation when either side is a string. Division and
modulo by zero yield `0.0` rather than an error — a policy file should not
be able to take the reactor down.

### Builtins

| Function | Meaning |
|---|---|
| `abs(x)` `min(...)` `max(...)` `clamp(x,lo,hi)` | the usual |
| `exp(x)` `sqrt(x)` `floor(x)` | `sqrt` clamps negatives to 0 |
| `ramp(x)` | `clamp(x, 0, 1)` |
| `lerp(a,b,t)` | `t` clamped to 0..1 |
| `pick(a, b, ...)` | uniform random choice |
| `rand(lo, hi)` | uniform random float |
| `held(cond, seconds)` | **true once `cond` has been continuously true for that long** |

`held()` is the temporal predicate that makes sustained-condition trips
expressible in one line:

```nova
rule core_disassembly priority 200 once {
    when  running and held(fuel_temp_c > meltdown_temp_c, meltdown_sustain_s)
    then  meltdown("CORE DISASSEMBLY -- MELTDOWN")
}
```

Each `held()` call site gets its own timer, allocated at parse time, so the
same condition used in two rules tracks two independent clocks.

## Actions

| Action | Effect |
|---|---|
| `set NAME = expr` | write a variable |
| `log(text)` | append a line to the operator event log |
| `alarm(level, text)` | raise the alarm tier; highest in a tick wins (0 clear … 3 emergency) |
| `scram(reason)` | trip the plant; latches immediately, so lower-priority rules in the same tick already see `scram` true |
| `reset_trip()` | clear the latch and give the rod drives back |
| `meltdown(text)` | end the run badly |
| `victory(text)` | end the run well |
| `inject_fault(name)` | force a specific fault now |
| `clear_fault()` | end the active fault early |

`meltdown()` and `victory()` also set `game_over` and `running` for the
remainder of the tick, so the state machine never lags the event it is
reporting.

## Variables the host provides

Read-only, refreshed before every tick:

`t` `dt` `flux_pct` `fuel_temp_c` `mod_temp_c` `out_temp_c` `pressure_mpa`
`reactivity_pcm` `decay_heat_pct` `rod_a` `rod_b` `rod_target_a`
`rod_target_b` `scram` `scram_elapsed` `operator_scram` `game_over`
`victory` `meltdown`

Plus, maintained by the fault scheduler: `active_fault` `fault_label`
`fault_elapsed` `fault_duration`.

Values the host reads back: everything in `effects`, plus `state`,
`rod_target_a`, `rod_target_b`.

## Errors

Parse errors report a line number and abort the load. Runtime errors
(unknown identifier, wrong argument type) abort the tick and are surfaced
on the panel rather than swallowed:

```bash
python3 godot/sim/reactor_server.py --validate
```

prints the parsed program — title, counts, every rule and fault by name —
or the first error with its line. Run it after every edit.

## One deliberate difference between the runtimes

`pick()`, `rand()` and the fault scheduler draw from Python's `random` in
one interpreter and Godot's `RandomNumberGenerator` in the other, so the
same seed does **not** produce the same fault sequence on both. Everything
else — precedence, short-circuiting, `held()` timers, `edge`/`once`
latches, priority ordering, effect reset semantics — is identical, and the
parity checker fails the build if the keyword, builtin or action sets ever
diverge.
