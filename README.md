# Reactor Sim — Godot + NovaLang

A nuclear reactor control room. Six-group delayed-neutron point kinetics
integrated with fixed-step RK4, a control policy written in NovaLang, and a
Godot panel with a GPU core map, analog gauges, a strip-chart recorder and
a scram button that will not sit still.

```
┌──────────── Godot (panel) ────────────┐
│  control_room.gd                      │
│      │                                │
│  bridge.gd  ──┬── PIPE ──► python3 reactor_server.py
│               │              ├── reactor_physics.py   RK4 core (NumPy)
│               │              └── nova_runtime.py      NovaLang interpreter
│               │                        │
│               ├── TCP  ──► the same daemon on 127.0.0.1:8642
│               │                        │
│               └── LOCAL ─► sim_local.gd                 ◄── iOS / Web
│                              ├── reactor_physics.gd   the same RK4 core
│                              └── nova_vm.gd           the same NovaLang
└───────────────────────────────────────┘
                                   ▲
                          reactor_rules.nova
                    one policy file, read by both runtimes
```

## Read this first: iOS and Web cannot run Python

`OS.execute` and `OS.execute_with_pipe` do not exist on iOS or in the
browser. There is no way for a Godot app on those targets to spawn
`python3`, and no amount of bridge code changes that.

So the bridge has three interchangeable backends and picks one at startup:

| Target | Backend | What runs the reactor |
|---|---|---|
| macOS, Windows, Linux | `PIPE` | `python3 reactor_server.py` as a child process, one line of JSON each way |
| any desktop, daemon already running | `TCP` | the same daemon on `127.0.0.1:8642` |
| **iOS, Web**, or any failure above | `LOCAL` | `sim_local.gd` — the RK4 core ported to GDScript |

The important part: **all three run the same `reactor_rules.nova`.** The
NovaLang interpreter exists twice — `nova_runtime.py` for the Python
backends and `nova_vm.gd` for the in-engine one — so the trip setpoints,
alarm tiers, fault injector and state machine are defined exactly once, in
one file, for every platform. `tools/check_parity.py` diffs the two
runtimes on every build to keep them from drifting.

The panel shows which backend answered, in the top right. On desktop you
should see `SIM: PYTHON / NUMPY`; on iOS and Web, `SIM: GODOT / NovaLang VM`.

## Running it

**In Godot** (4.3 or newer — `OS.execute_with_pipe` landed in 4.3):

```bash
# open godot/ as a project, then press F5
```

Nothing to install: without NumPy the Python core falls back to a pure
Python path, and if `python3` cannot be found at all the bridge quietly
runs the reactor in-engine instead. For the fast core:

```bash
python3 -m pip install -r godot/sim/requirements.txt
```

**Without Godot**, headlessly:

```bash
python3 godot/sim/reactor_server.py --selftest --seconds 300
python3 godot/sim/reactor_server.py --validate      # parse the .nova policy
python3 godot/sim/reactor_server.py --tcp 8642      # daemon for the TCP backend
```

**Force a backend** (useful for testing the iOS/Web path on your Mac):

```bash
godot --path godot -- --backend=local
```

## Playing it

You are holding a reactor at power for fifteen minutes while it tries to
get away from you.

* **Drag the two vertical sliders** to command control-rod bank A and B.
  Up is withdrawn. The bright handle is what you asked for; the filled
  column behind it is where the rods actually are — they move at 20 %/s,
  and rod worth is cubic, so the last few percent of withdrawal is worth
  far more than the first.
* **SCRAM** (the button, or `SPACE`) drops both banks instantly. Decay heat
  keeps the core warm for another ten minutes and the drives stay locked
  out until it has died away.
* **`R`** starts a new shift after a meltdown or a win.
* Every 45–90 seconds the fault injector picks something: turbine trip,
  feedwater pump failure, a seized rod bank, xenon poisoning. The banner
  tells you what and how long you have.

Hold fuel temperature under 2800 °C for 15:00 and you have survived the
shift. Let it sit above that for five continuous seconds and the core
disassembles.

## Layout

```
godot/                         the Godot project — open this
  project.godot                1440x900 design space, letterboxed, GL Compatibility
  export_presets.cfg           macOS / iOS / Web
  scenes/Main.tscn             the whole panel
  scenes/widgets/*.tscn        one scene per instrument
  scripts/
    control_room.gd            the conductor: fixed-step loop, state fan-out
    bridge.gd                  backend selection, JSON protocol, failover
    sim_local.gd               in-engine reactor host (iOS / Web)
    reactor_physics.gd         RK4 six-group core, GDScript
    nova_vm.gd                 NovaLang interpreter, GDScript
    reactor_theme.gd           shared palette and drawing helpers
    widgets/*.gd               dial, core map, strip chart, scram button,
                               rod slider, event log, fault banner, header
  shaders/
    core_heatmap.gdshader      the 10x10 core map, one draw call
    control_room_bg.gdshader   procedural dark-industrial backdrop
  sim/
    reactor_physics.py         RK4 six-group core, NumPy with a pure fallback
    nova_runtime.py            NovaLang interpreter, Python
    reactor_rules.nova         >>> the control policy, for every platform <<<
    reactor_server.py          the bridge daemon (stdio / TCP / one-shot)
    tests/test_reactor.py      32 tests: physics, language, protocol
tools/
  run_checks.sh                everything verifiable without opening Godot
  check_parity.py              Python core == GDScript core
  check_project.py             scenes, res:// paths, node paths, exports
docs/
  ARCHITECTURE.md              how a frame gets from a keypress to a pixel
  NOVALANG.md                  the language reference
reactor_simulator.py           the original standalone pygame prototype
```

## Verifying

```bash
./tools/run_checks.sh
```

Runs the 32 unit tests (including a convergence test that proves the
integrator really is 4th-order and not a dressed-up Euler), diffs the two
runtimes for parity, statically validates every scene and `res://` path,
parses the NovaLang policy, and plays a headless five-minute shift.

## Exporting

Install the export templates for your Godot version
(**Editor → Manage Export Templates**), then:

```bash
godot --path godot --headless --export-release "macOS" ../build/macos/ReactorSim.app
godot --path godot --headless --export-release "Web"   ../build/web/index.html
godot --path godot --headless --export-release "iOS"   ../build/ios/ReactorSim.xcodeproj
```

Notes per target:

* **macOS** — exports universal (arm64 + x86_64). The preset ships the
  Python sources inside the `.pck`; on first launch the bridge unpacks them
  to `user://sim/` and runs them from there, because you cannot execute a
  file that lives inside a `.pck`. Signing is off in the preset, so
  Gatekeeper will want a right-click → Open the first time, or fill in
  `codesign/*` with your own identity. If the user has no `python3`, the
  app falls back to the in-engine sim and says so on the panel.
* **iOS** — produces an Xcode project; open, set your team, and build.
  Nothing extra to do about Python: the `LOCAL` backend is the only one
  iOS can use, and it is the default there. The panel is touch-driven —
  the rod sliders and the scram button both handle `InputEventScreenTouch`.
* **Web** — needs to be served over HTTP, not opened as a `file://` URL
  (`python3 -m http.server` from the export directory is enough). The
  project uses the GL Compatibility renderer so it works without
  `SharedArrayBuffer` or cross-origin isolation headers.

All three presets set `include_filter` to ship `reactor_rules.nova`. Godot
does not import `.nova` or `.py` files as resources, so without that filter
they would be silently dropped from the build and the exported app would
have no control policy — `check_project.py` fails the build if a preset
loses it.

## Changing the reactor

Almost everything you would want to tune is in
`godot/sim/reactor_rules.nova` and takes effect on the next reset, on every
platform, with no code change:

```nova
params {
    trip_flux_pct    = 150.0     # lower this and the plant trips sooner
    meltdown_temp_c  = 2800.0
    survive_time_s   = 900.0     # a longer shift
    auto_rod_control = 0.0       # set to 1 and NovaLang flies the rods
}

rule flux_high_trip priority 290 {
    when  running and not scram and flux_pct > trip_flux_pct
    then  scram("AUTO SCRAM -- NEUTRON FLUX HIGH")
}
```

See `docs/NOVALANG.md` for the full language, and validate your edits with
`python3 godot/sim/reactor_server.py --validate` before launching.
