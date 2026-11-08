# Architecture

## Why pure GDScript is better

The previous design shipped a Python daemon and spoke to it over a pipe,
with an in-engine GDScript mirror as a fallback for iOS and Web. It worked.
It was also the wrong shape, and the rewrite is worth explaining.

### 1. The fallback was the only path that worked everywhere

`OS.execute` and `OS.execute_with_pipe` do not exist on iOS or in the
browser. So the "real" backend — the Python one — was the one that ran on
the fewest targets, and the "fallback" was the one that had to be correct
everywhere. That is upside down. Every bug that mattered lived in the code
path labelled *fallback*, which is precisely the path that gets the least
attention.

Now there is one path. The code that runs on your Mac is the code that runs
on the phone.

### 2. Two implementations of the *policy engine* is a bug factory

The old design had NovaLang implemented twice and *both copies shipped*.
The parity checker compared their vocabularies, but nothing compared their
behaviour, because nothing could run GDScript in CI. Two shipped
interpreters means two chances to be wrong and one chance to notice.

There is still a second implementation — `reference/`, in Python — but it
**never ships and the game never runs it**. Its only job is to be the
oracle: it states what the answer is, `gen_conformance.py` records those
answers, and `parity_check.gd` makes the shipping interpreter reproduce
them inside Godot. One implementation ships; one implementation judges.

### 3. Process spawning is a liability the game gained nothing from

The pipe backend needed: unpacking `.py` files from the `.pck` to `user://`
because you cannot execute a file inside an archive; probing four
filesystem paths for `python3` because an app launched from Finder gets a
minimal `PATH`; a liveness check on every frame; a mid-run failover that
restarted the reactor from cold when the child died; and a documented
warning that a hung child would block the render thread on a pipe read.

All of that was infrastructure for crossing a process boundary that bought
the simulation nothing. The core is ten state variables and six precursor
groups — about 150 µs per step in pure Python and far less in GDScript. It
was never the bottleneck. Deleting the boundary deleted every failure mode
that came with it, and about 800 lines of code.

### 4. A distributable game should be one artifact

"Install Python, optionally install NumPy, then run the game" is not a
thing you can ship on the App Store. Now the deliverable is a `.app`, an
`.xcodeproj` and an `index.html`, and none of them have a runtime
dependency beyond Godot itself.

### What it costs

Honest accounting, because there are real trade-offs:

* **NumPy is gone.** The RK4 core is GDScript now. For a ten-element state
  vector that is fine — the vectorised path was never the reason the sim
  was fast — but a genuinely large model would want a `GDExtension`, not a
  subprocess.
* **A tree-walking interpreter is slower than CPython.** NovaLang runs
  *game logic*: ~25 rules at 20 Hz. Do not put a hot loop in it; that is
  what `reactor_physics.gd` is for. The step budget exists partly to make
  that boundary impossible to cross by accident.
* **The reference has to be kept in step by hand.** `check_parity.py` and
  the conformance goldens are what make that a mechanical check rather than
  a discipline.

## The three-layer split

| Layer | Owns | Files |
|---|---|---|
| **Physics** | integrating the core | `reactor_physics.gd` |
| **Policy** | what to do about it | `reactor_rules.nova` |
| **Panel** | showing it | `control_room.gd`, `scripts/widgets/` |

None of them reach into the others. The physics has no notion of a trip
setpoint; the policy has no notion of a pixel; the panel does no arithmetic
on reactor state beyond formatting it.

The seam between policy and everything else is the **host function
registry**. In the old design `scram()`, `log()` and `alarm()` were
hard-coded actions inside the interpreter — the language knew what a
reactor was. Now they are ordinary functions the host registers:

```gdscript
vm.register_function("scram", _fn_scram)
```

which is why `daedalus_rules.nova` can run in the same interpreter with a
completely different vocabulary, and why NovaLang is a general-purpose
scripting language rather than a reactor DSL with delusions.

## One frame

```
_process(delta)                          control_room.gd
  accumulate delta, take N whole 0.05 s steps
  bridge.tick(N, rod_target_a, rod_target_b, scram_pressed)
        │
   for each of the N substeps:           nova_bridge.gd
     1. drive the rods (20 %/s; a seized bank stays put)
     2. compute decay heat if the plant is tripped
     3. RK4 one 0.05 s step of the 10-element state vector
     4. vm.tick() -- fault scheduler, signals, rules in priority order;
        the policy's outputs become the plant's boundary conditions for
        the *next* substep
     5. append [flux, fuel_temp] to this reply's history
        │
  state Dictionary -> the instruments    control_room.gd
```

### Fixed step, variable frame rate

The reactor always advances in exact 0.05 s ticks. `control_room.gd` keeps
an accumulator and asks for however many whole steps have elapsed, so a
dropped frame, a 120 Hz display and a stuttering browser tab all produce
identical physics. Catch-up is capped at 12 steps per frame: past that the
simulation drops time rather than spiralling.

Because one frame can advance several substeps, the reply carries a
`history` array with every substep's flux and fuel temperature. The strip
chart consumes all of them, so the trace stays continuous at the full 20 Hz
even though the panel polls at 60.

### The one-step lag

Within a substep the core is integrated *before* the policy runs, so
NovaLang's outputs (coolant flow, turbine load, xenon worth, which bank is
seized) apply to the *next* substep. That is a deliberate 50 ms lag: it
keeps the loop acyclic and matches how a real protection system samples a
plant.

The one exception is a trip. `scram()` latches into the VM's globals
immediately, so the lower-priority state and alarm rules later in the same
tick already see a scrammed plant. A protection system that took 50 ms to
notice its own trip would be a bug.

## Interpreter internals

**Lexer** (`nova_lexer.gd`) — a hand-written scanner, no `RegEx`, because
the reference is hand-written too and the two must agree character for
character. It also owns `number_text()`, the one true way to render a
number as a string: `str(float)` disagrees between Python and GDScript, and
a value that reads differently in the two runtimes is a parity failure.

**Parser** (`nova_parser.gd`) — recursive descent, producing plain
`Dictionary` nodes with a `"k"` kind field. Dictionaries rather than
classes because the reference produces exactly the same shapes, which is
what lets the node vocabulary be diffed and the goldens be plain JSON. A
named `func f() {...}` desugars to `let f = func...`, which is where
recursion and closures come from for free.

**Evaluator** (`nova_evaluator.gd`) — a tree walker over a scope chain.
Closures capture their defining `Env`. GDScript has no exceptions, so
control flow uses none in either implementation: a statement returns `null`
for "fell off the end", or `{"flow": "return"|"break"|"continue", "value":
…}`. Errors set `error` and unwind the same way.

Three details are load-bearing for cross-runtime agreement:

* numbers are always floats, and `==` on them is **exact**, never
  approximate — `is_equal_approx` would quietly diverge from Python's `==`;
* `deep_equal` is hand-written rather than relying on either language's
  container comparison;
* the step budget and call-depth limit are the same numbers in both.

**VM** (`nova_vm.gd`) — the façade (`load_file` / `eval` / `call_function` /
`register_function`), the module cache, and the reactor rule engine that
runs `effects` → fault scheduler → `signals` → `rules` once per tick.

## Keeping the two implementations honest

`tools/check_parity.py` diffs the surfaces mechanically: every physics
constant, the lexer's keyword set and its *ordered* operator table (it is
scanned longest-first, so a reordering silently changes how `<=`
tokenises), the parser's node kinds, the evaluator's 33 builtins with their
arities, the runtime limits, and the reactor host-function registry. It
also rebuilds `conformance.json` from the reference and fails if the
committed file differs — so a reference change nobody regenerated is caught
rather than trusted.

`tools/check_project.py` covers the Godot side, where mistakes otherwise
surface only when you open the editor: every `res://` path resolves, every
scene parses with unique resource ids and no dangling `ExtResource()`,
every node's parent is defined before it, every `$NodePath` in
`control_room.gd` exists in `Main.tscn`, no duplicated `class_name`, every
`.nova` policy parses, every export preset still ships `scripts/*.nova` —
and, enforcing the rewrite itself, that there is no `.py` anywhere under
`godot/` and no `OS.execute` / `OS.execute_with_pipe` / `OS.create_process`
in any GDScript file.

`parity_check.gd` is the behavioural check the other two cannot be: it runs
the shipping interpreter against 51 recorded programs and a 900-step
reactor trace and diffs output, host calls, error text and plant state.

## Physics

Six delayed-neutron groups (U-235 thermal) coupled to a two-node lumped
thermal model plus a lagging loop outlet, integrated as one 10-element
state vector by classical fourth-order Runge-Kutta at a fixed 0.05 s step.
Euler appears nowhere; `test_rk4_is_fourth_order` halves the step and
asserts the error drops by more than 8x, which a first-order method cannot
do.

**`LAMBDA_STAR = 0.01`.** The real prompt-neutron generation time of a
thermal reactor is about 2×10⁻⁵ s. At a 0.05 s step that makes the kinetics
equation far too stiff for explicit RK4 — stability needs `|dt·λ| < 2.785`,
and the true value violates it by about a hundredfold. Lengthening the
generation time keeps the six-group structure and the dynamics an operator
feels, at a step the panel can run at. The honest alternative is an
implicit integrator, which is a much larger change for a game.

**Cubic rod worth.** `bank_worth_pcm` is cubic in withdrawal, so 90 %→100 %
is worth roughly fifty times what 0 %→10 % is. That single non-linearity is
most of the difficulty: the rods feel dead until suddenly they are not.

Both temperature coefficients are negative, so the core is self-regulating,
and `test_reaches_a_stable_operating_point` asserts it settles within
20 pcm of critical.

## The core map

The 10×10 fuel-channel display is one `ColorRect` running
`core_heatmap.gdshader`. All 100 channel temperatures are reconstructed in
the fragment shader from four numbers the reply already carries — bulk fuel
temperature, a peaking tilt (x, y) and an amplitude — using the same law
the CPU uses:

```
T(i,j) = T_ref + (T_fuel - T_ref) · ((1 - amp) + amp · cos(r · π/2))
```

with `r` the normalised radius from the tilted flux centroid. Asymmetric
rod insertion tilts the centroid toward the withdrawn bank; losing coolant
flow pushes the hot spot toward the outlet. One draw call, zero per-frame
bandwidth, and it would cost the same at 100×100.
