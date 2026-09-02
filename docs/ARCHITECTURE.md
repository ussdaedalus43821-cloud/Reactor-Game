# Architecture

How a frame gets from a slider drag to a pixel, and why the pieces are
split the way they are.

## The three-layer split

| Layer | Owns | Files |
|---|---|---|
| **Physics** | integrating the core | `reactor_physics.py`, `reactor_physics.gd` |
| **Policy** | what to do about it | `reactor_rules.nova` |
| **Panel** | showing it | `control_room.gd`, `scripts/widgets/*` |

None of them reach into the others. The physics has no notion of a trip
setpoint; the policy has no notion of a pixel; the panel does no arithmetic
on the reactor state beyond formatting it. That separation is what lets the
same policy file drive a NumPy core on a Mac and a GDScript core on an
iPhone with no conditional code anywhere.

## One frame

```
_process(delta)                          control_room.gd
  accumulate delta, take N whole 0.05 s steps
  bridge.tick(N, rod_target_a, rod_target_b, scram_pressed)
        │
        ├─ PIPE:  write one JSON line to python3's stdin, read one back
        ├─ TCP:   the same, over a socket
        └─ LOCAL: call sim_local.gd directly
                                          ↓
   for each of the N substeps:            reactor_server.py / sim_local.gd
     1. drive the rods toward their targets (20 %/s; a seized bank stays put)
     2. compute decay heat if the plant is tripped
     3. RK4 one 0.05 s step of the 10-element state vector
     4. hand the measurements to NovaLang; its outputs become the plant's
        boundary conditions for the next substep
     5. append [flux, fuel_temp] to the history for this reply
                                          ↓
  state Dictionary → the instruments      control_room.gd
```

The reply is one flat dictionary with the same keys whichever backend
produced it. That is the whole contract; adding a backend means producing
that dictionary and nothing else.

### Fixed step, variable frame rate

The reactor always advances in exact 0.05 s ticks. `control_room.gd` keeps
an accumulator and asks for however many whole steps have elapsed, so a
dropped frame, a 120 Hz display and a stuttering browser tab all produce
identical physics. Catch-up is capped at 12 steps per frame: past that the
simulation drops time rather than spiralling.

Because one frame can advance several substeps, the reply carries a
`history` array with every substep's flux and fuel temperature. The strip
chart consumes all of them, so the trace is continuous at the full 20 Hz
even though the panel polls at 60.

### The one-step lag

Within a substep the core is integrated *before* NovaLang runs, so the
policy's outputs (coolant flow, turbine load, xenon worth, which bank is
seized) apply to the *next* substep. That is a deliberate 50 ms lag: it
keeps the loop acyclic, matches how a real protection system samples a
plant, and — critically — makes the Python and GDScript hosts agree,
because both do it in the same order.

The one exception is a trip. `scram()` latches into the variable table
immediately, so the lower-priority state and alarm rules later in the same
tick already see a scrammed plant. A protection system that took 50 ms to
notice its own trip would be a bug, not a feature.

## The bridge

`bridge.gd` presents one interface over three transports and degrades
rather than fails.

**Startup.** iOS and Web have no process API at all, so they go straight to
`LOCAL`. On desktop the bridge unpacks the Python sources (they live inside
the `.pck` in an exported build, and you cannot execute a file from inside
a `.pck`) to `user://sim/`, probes for a working `python3` — including the
Homebrew paths, because an app launched from Finder gets a minimal `PATH` —
and spawns it with `-u`. Then it handshakes. Any failure falls through to
TCP, then to `LOCAL`.

**Mid-run.** Every request checks that the child is still alive and that
the pipe is still open. If the daemon dies, `_fail_over()` switches to the
in-engine sim, logs it to the event log and the panel keeps running from a
cold core. The alternative — a frozen panel — is strictly worse.

**Protocol.** Newline-delimited JSON, one request per line, one reply per
line, `stdout` for protocol and `stderr` for diagnostics. Malformed frames
get `{"ok": false, "error": ...}` and the daemon stays up; there is a test
for that.

### Why a persistent process, not `OS.execute` per frame

The task description offers `OS.execute("python3", ["-c", script])` as an
option. It cannot work for the simulation loop: the reactor has state — ten
integrator variables, six precursor groups, rule latches, `held()` timers,
the fault scheduler — and a fresh process starts a fresh reactor. You would
have to serialise and re-send the entire plant every frame, and pay a
process spawn (tens of milliseconds on macOS) sixty times a second.

`reactor_server.py --once` exists anyway, for exactly the things that *are*
stateless: health checks, `--validate`, `--selftest`.

## Physics

Six delayed-neutron groups (U-235 thermal) coupled to a two-node lumped
thermal model plus a lagging loop outlet, integrated as one 10-element
state vector by classical fourth-order Runge-Kutta at a fixed 0.05 s step.
Euler appears nowhere; `test_rk4_is_fourth_order` halves the step and
asserts the error drops by more than 8x, which a first-order method cannot
do.

Two constants deserve explanation:

**`LAMBDA_STAR = 0.01`.** The real prompt-neutron generation time of a
thermal reactor is about 2×10⁻⁵ s. At a 0.05 s step that makes the kinetics
equation far too stiff for explicit RK4 — stability needs `|dt·λ| < 2.785`,
and the true value violates it by about a hundredfold for any realistic
reactivity swing. Lengthening the generation time keeps the six-group
structure and the qualitative dynamics an operator feels, at a step the
panel can actually run at. The honest alternative is an implicit
integrator, which is a much larger change for a game.

**Cubic rod worth.** `bank_worth_pcm` is cubic in withdrawal, so 90 %→100 %
is worth roughly fifty times what 0 %→10 % is. That single non-linearity is
most of the difficulty: the rods feel dead until suddenly they do not.

Both temperature coefficients are negative, so the core is self-regulating
— it will find an equilibrium on its own, and `test_reaches_a_stable_
operating_point` asserts it settles within 20 pcm of critical.

## The core map

The 10×10 fuel-channel display is one `ColorRect` running
`core_heatmap.gdshader`. All 100 channel temperatures are reconstructed in
the fragment shader from four numbers the reply already carries — bulk fuel
temperature, a peaking tilt (x, y) and an amplitude — using the same
peaking law the CPU uses:

```
T(i,j) = T_ref + (T_fuel - T_ref) · ((1 - amp) + amp · cos(r · π/2))
```

with `r` the normalised radius from the tilted flux centroid. Asymmetric
rod insertion tilts the centroid toward the withdrawn bank; losing coolant
flow pushes the hot spot toward the outlet. So the map costs one draw call
and zero per-frame bandwidth, and it would cost the same at 100×100.

## Keeping the two runtimes honest

The reactor exists twice, which is the price of shipping to iOS and Web
without giving up the Python core on desktop. Drift between them is the
worst failure mode available: the same policy would produce two different
reactors, and only on the platform you test least.

`tools/check_parity.py` diffs, mechanically:

* every physics constant, by name and value, plus the delayed-neutron
  arrays and a cross-check that `BETA_TOTAL` equals `sum(BETA_I)`
* the NovaLang keyword set
* the NovaLang builtin function set
* the NovaLang action set

`tools/check_project.py` covers the Godot side, where mistakes otherwise
surface only when you open the editor: every `res://` path resolves, every
scene parses with unique resource ids and no dangling `ExtResource()`, every
node's parent is defined before it, `load_steps` is consistent, every
`$NodePath` in `control_room.gd` exists in `Main.tscn`, no duplicated
`class_name`, and — the one that actually bites — every export preset still
ships `reactor_rules.nova`, without which an exported build would launch
with no control policy at all.

`./tools/run_checks.sh` runs both plus the 32 unit tests and a headless
five-minute shift.
