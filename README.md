# Reactor Sim — Godot + NovaLang

A nuclear reactor control room, and the small language its control logic is
written in. Six-group delayed-neutron point kinetics integrated with
fixed-step RK4, a policy written in NovaLang, and a Godot panel with a GPU
core map, analog gauges, a strip-chart recorder and a scram button that
will not sit still.

**NovaLang is now a pure GDScript interpreter.** No Python, no
`OS.execute`, no sockets, no fallback path. The whole thing is GDScript and
a text file, so the same code runs on macOS, iOS and Web.

```
┌──────────────────────── Godot ────────────────────────┐
│  control_room.gd            the panel                 │
│        │                                              │
│  nova_bridge.gd             host: physics + policy    │
│        ├── reactor_physics.gd      RK4 core, GDScript │
│        └── scripts/nova/                              │
│              nova_lexer.gd      source  -> tokens     │
│              nova_parser.gd     tokens  -> AST        │
│              nova_evaluator.gd  AST     -> behaviour  │
│              nova_vm.gd         load / eval / call    │
│                    │                                  │
│              res://scripts/reactor_rules.nova         │
│              res://scripts/daedalus_rules.nova        │
│              res://scripts/lib/combat.nova            │
└───────────────────────────────────────────────────────┘
```

## Using the interpreter

```gdscript
var vm := NovaVM.new()

# NovaLang -> GDScript: expose your own functions.
vm.register_function("core_temp", func(args): return $Core.fuel_temp())
vm.register_function("log", func(args): $Log.add_line(str(args[0])))

# Load a policy from res://scripts/ (works in the editor and in a .pck).
if not vm.load_file("reactor_rules.nova"):
    push_error(vm.error)

# ...or evaluate source directly.
vm.eval('func greet(who) { return "hello " + who }')

# GDScript -> NovaLang: call a function the script defined.
print(vm.call_function("greet", ["operator"]))     # hello operator

# Read anything the program left in its globals.
print(vm.get_global("trip_flux_pct", 0.0))         # 150
```

`call_function()` is not spelled `call()` — every Godot `Object` already has
a `call()` method and shadowing it is a hard error, so both this and the
reference implementation use the longer name.

### Driving the rule engine

`rule`, `fault`, `effects` and `signals` declarations are run by
`vm.tick()`, once per simulation step:

```gdscript
vm.tick(0.05, {
    "flux_pct": core.flux_percent(),
    "fuel_temp_c": core.fuel_temp(),
    "scram": scram_latched,
}, true)                                  # true = fault injector enabled

flow_frac = vm.get_global("flow_frac", 1.0)
```

Everything the policy decided arrives two ways: values in globals (read
with `get_global`), and calls into the functions you registered.
`nova_bridge.gd` is the worked example — 8 host functions, one `tick()` per
substep, one state Dictionary out.

## The language

A superset of the original rules DSL. `reactor_rules.nova` is byte-for-byte
what it was and behaves identically; everything below is new.

```nova
import "lib/combat.nova" as combat        # modules, with export/import

func fib(n) {                             # functions and recursion
    if n < 2 { return n }
    return fib(n - 1) + fib(n - 2)
}

func counter() {                          # closures
    let n = 0
    return func() { n = n + 1  return n }
}

let xs = [1, 2, 3]                        # lists and dicts
let d  = { name: "core", temp: 812.5 }
d.temp = d.temp + 1
while len(xs) > 0 { remove_at(xs, 0) }    # while / break / continue

print("threat:", combat.threat_score(["capital", "wdart"]))
```

Numbers, strings, booleans, lists, dicts, `null` and functions;
`and or not == != < > <= >= + - * / %`; 33 builtins. Full reference in
[docs/NOVALANG.md](docs/NOVALANG.md).

Two guards mean a bad policy file cannot take the game down: a step budget
(`while true {}` fails the tick instead of hanging the render thread) and a
call-depth limit (runaway recursion is an error, not a crash).

## Running it

Open `godot/` in Godot 4.3+ and press F5. There is nothing to install.

Edit `godot/scripts/reactor_rules.nova` and the reactor behaves differently
on the next reset — on every platform, with no rebuild.

## Playing it

You are holding a reactor at power for fifteen minutes while it tries to
get away from you.

* **Drag the two vertical sliders** to command control-rod bank A and B. Up
  is withdrawn. The bright handle is what you asked for; the filled column
  behind it is where the rods actually are — they move at 20 %/s, and rod
  worth is cubic, so the last few percent is worth far more than the first.
* **SCRAM** (the button, or `SPACE`) drops both banks instantly. Decay heat
  keeps the core warm for another ten minutes and the drives stay locked
  out until it has died away.
* **`R`** starts a new shift after a meltdown or a win.
* Every 45–90 s the fault injector picks something: turbine trip, feedwater
  pump failure, a seized rod bank, xenon poisoning.

Hold fuel temperature under 2800 °C for 15:00 and you survive the shift.
Let it sit above that for five continuous seconds and the core disassembles.

## Layout

```
godot/                          the Godot project — open this
  project.godot                 1440x900 design space, GL Compatibility
  export_presets.cfg            macOS / iOS / Web, all the same shape now
  scenes/                       Main.tscn + one scene per instrument
  scripts/
    control_room.gd             fixed-step loop, state fan-out
    nova_bridge.gd              NovaLang <-> reactor physics + UI
    daedalus_bridge.gd          NovaLang -> Daedalus ship/power/sector data
    ai_bridge.gd                NovaLang -> Daedalus enemy AI behavior
    weapons_bridge.gd           NovaLang -> Daedalus weapon stats/ballistics
    reactor_physics.gd          RK4 six-group core
    reactor_theme.gd            shared palette
    reactor_rules.nova          >>> the reactor's control policy <<<
    daedalus_rules.nova         >>> Daedalus ship stats, damage scaling,
                                    power budget, sectors, advisor <<<
    daedalus_ai.nova            >>> enemy AI: six archetypes, tuning,
                                    reactions to player ship class <<<
    daedalus_weapons.nova       >>> weapon ballistics, energy cost,
                                    falloff, beam ramp, class effectiveness <<<
    lib/combat.nova             a NovaLang module
    nova/
      nova_lexer.gd             tokenizer
      nova_parser.gd            recursive-descent parser
      nova_evaluator.gd         tree-walking interpreter
      nova_vm.gd                load / eval / call + the rule engine
      parity_check.gd           replays the goldens in-engine
      conformance.json          generated goldens
    widgets/                    dial, core map, strip chart, scram button…
  shaders/                      core heatmap, industrial backdrop
reference/                      Python reference implementation (never ships)
  nova_lexer.py  nova_parser.py  nova_evaluator.py  nova_vm.py
  reactor_physics.py  reactor_host.py  tests/test_reactor.py
tools/
  run_checks.sh                 everything verifiable without Godot
  gen_conformance.py            record the goldens from the reference
  check_parity.py               reference vs GDScript, surface by surface
  check_project.py              scenes, paths, exports, Python-freeness
docs/  ARCHITECTURE.md  NOVALANG.md
reactor_simulator.py            the original standalone pygame prototype
```

## Why there is still Python in the repo

`reference/` is a second implementation of NovaLang, in Python. **It is
never shipped and the game never runs it.** It exists for one reason: a
2 500-line interpreter needs a specification you can execute.

* 77 unit tests run against it in CI.
* `tools/gen_conformance.py` runs a corpus of 51 NovaLang programs through
  it and records the exact output, host calls and error text of each, plus
  a 900-step reactor trace — into `conformance.json`.
* `parity_check.gd` replays all of that **inside Godot** and diffs.
* `tools/check_parity.py` compares the two implementations surface by
  surface — keywords, operators, AST node kinds, builtin arities, runtime
  limits, physics constants — and fails if `conformance.json` is stale.

Delete `reference/` and the game still runs. You just lose the ability to
prove the interpreter is correct.

## Verifying

```bash
./tools/run_checks.sh      # tests, parity, project structure, headless run
```

then, in Godot:

```bash
godot --headless --path godot --script res://scripts/nova/parity_check.gd
```

which replays the goldens through the shipping interpreter and exits
non-zero on any mismatch.

## Exporting

Install the export templates, then:

```bash
godot --path godot --headless --export-release "macOS" ../build/macos/ReactorSim.app
godot --path godot --headless --export-release "Web"   ../build/web/index.html
godot --path godot --headless --export-release "iOS"   ../build/ios/ReactorSim.xcodeproj
```

All three presets are now identical in shape, because all three targets run
the same interpreter. The one thing that matters is `include_filter`:
`.nova` files are not Godot resources, so without `scripts/*.nova` they are
silently dropped from the `.pck` and the exported build launches with no
control policy. `check_project.py` fails the build if a preset loses it.

* **macOS** — universal (arm64 + x86_64). Signing is off in the preset, so
  Gatekeeper wants a right-click → Open the first time.
* **iOS** — produces an Xcode project; set your team and build. The panel
  is touch-driven: the rod sliders and scram button handle
  `InputEventScreenTouch`.
* **Web** — serve over HTTP, not `file://`. GL Compatibility renderer, so
  no `SharedArrayBuffer` or cross-origin isolation headers needed.

## Daedalus — the other game built on this language

`daedalus_godot/` is a separate, standalone Godot 4 project: a
space-combat game whose ship stats, enemy AI and weapons logic are all
written in NovaLang, using the same interpreter (`scripts/nova/`, copied
in unmodified) that runs the reactor above. It has its own
`project.godot` and its own README; open `daedalus_godot/` directly in
Godot rather than this repository's root.
