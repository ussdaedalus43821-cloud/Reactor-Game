# Modding Reactor Sim

Reactor Sim's control policy — trip setpoints, alarms, and every
equipment failure the fault injector can throw at you — is written in
**NovaLang**, a small scripting language that lives in one plain text
file: `godot/scripts/reactor_rules.nova`. Change that file, save it,
relaunch the game. No compiler, no build step, no Godot project to
touch.

This guide gets you from "never seen NovaLang" to "wrote a working
scenario" in about thirty minutes, and then keeps going into the parts
an experienced modder will want: exactly which numbers do what, how the
fault engine is wired, and where the line sits between "a text edit"
and "you'd need to touch the physics engine for that."

> **New to modding in general?** Read the [Quick Start](#quick-start)
> section below, then come back for the rest as you need it. You don't
> have to read this whole document before making your first change.

## Contents

- [What is NovaLang, and why mod in it?](#what-is-novalang-and-why-mod-in-it)
- [Installing and editing .nova files](#installing-and-editing-nova-files)
- [Where the files live](#where-the-files-live)
- [How mods load](#how-mods-load)
- [Safety and limitations](#safety-and-limitations)
- [Quick Start](#quick-start)
- [Inside reactor_rules.nova](#inside-reactor_rulesnova)
- [About "reactor_events.nova"](#about-reactor_eventsnova)
- [Creating a custom scenario](#creating-a-custom-scenario)
- [Different reactor types: PWR, RBMK, BWR](#different-reactor-types-pwr-rbmk-bwr)
- [Example mods](#example-mods)
- [Modding examples: beginner to advanced](#modding-examples-beginner-to-advanced)
- [Troubleshooting](#troubleshooting)
- [Safety and ethics](#safety-and-ethics)

---

## What is NovaLang, and why mod in it?

NovaLang is a small scripting language written specifically for this
project. It looks a little like a stripped-down mix of Python and a
spreadsheet's `IF()` formulas: numbers, `if`/`while`, functions — plus
two things built just for a control-room simulator, `rule` and `fault`
blocks, which is where most of your modding will actually happen.

Reactor Sim embeds a full NovaLang interpreter directly in Godot
(`godot/scripts/nova/` — four GDScript files, no external engine or
runtime). When the game boots, it reads `reactor_rules.nova` as plain
text, parses it, and runs it. There is no separate "compile the mod"
step, because there is nothing to compile — the interpreter reads the
text file itself, every time the game starts.

**Why a scripting language instead of, say, a JSON config file or exposed
GDScript?**

- **JSON can't express behavior.** A JSON file can say
  `"trip_flux_pct": 150`, but it can't say "and if flux stays above
  115% for five straight seconds, raise a caution and log a message."
  Reactor Sim's protection logic, alarms, and fault behavior are all
  *logic*, not just numbers — NovaLang can express that logic in the
  same file as the numbers.
- **GDScript would need a rebuild.** Godot compiles/exports a project;
  handing out modified `.gd` files to run without recompiling Godot's
  own systems isn't how the engine works, and a bad edit can crash the
  whole game. NovaLang is interpreted at load time and sandboxed (see
  [Safety and limitations](#safety-and-limitations)), so a bad mod fails
  to load with an error message instead of crashing anything.
- **One file, cross-platform, no toolchain.** The exact same
  `reactor_rules.nova` runs unmodified on macOS, iOS and Web, because
  the interpreter is GDScript, not a native plugin. You need nothing
  but a text editor to mod this game on any platform it runs on.

---

## Installing and editing .nova files

You don't need to install anything beyond a text editor.

- **Windows:** Notepad works. [VS Code](https://code.visualstudio.com/)
  (free) is much nicer — it shows line numbers, which matters a lot
  when NovaLang reports an error "at line 42."
- **macOS:** TextEdit works if you turn off "smart quotes" (Preferences
  → General) — smart quotes will silently break every `"string"` in the
  file. VS Code sidesteps this entirely and is the recommended choice.
- **Linux:** anything — `gedit`, `kate`, `vim`, `nano`, VS Code.

**Recommended: VS Code.** There's no official NovaLang syntax highlighter,
but setting a `.nova` file's language mode to **JavaScript** or
**Rust** in VS Code's bottom-right language picker gets you serviceable
highlighting for free — comments, strings, and numbers all light up
correctly since the syntax is close enough. Don't rely on it to catch
NovaLang-specific mistakes, though (that's what
[validating a mod](#troubleshooting) is for).

Whatever editor you use: save as **plain text**, not rich text
(`.rtf` or `.docx`), and make sure the file extension stays `.nova`
after saving.

---

## Where the files live

```
Reactor-Game/
├── godot/                          the actual game project — open this in Godot
│   └── scripts/
│       └── reactor_rules.nova      <-- THE file you're modding
├── reference/                      a Python copy of the interpreter, used for testing only
├── docs/
│   └── NOVALANG.md                 the full language reference (syntax, builtins)
└── MODDING_REACTOR.md              this file
```

There is exactly **one** `.nova` file for Reactor Sim:
`godot/scripts/reactor_rules.nova`. It contains the entire control
policy — setpoints, alarms, operating-state logic, and the fault
injector — in one place. See
["About reactor_events.nova"](#about-reactor_eventsnova) below if you
came looking for a separate events file.

---

## How mods load

There is no mod manager, no load order, no plugin folder. The game reads
`godot/scripts/reactor_rules.nova` from disk every time it starts:

1. Edit the file in your text editor.
2. Save it.
3. Launch (or relaunch) the game.

That's it — your change is live. If you're running from the Godot
editor, press **F5** again after saving; if you're running an exported
build, quit and reopen it.

If the file has a syntax error, the game does not crash — the reactor
panel comes up showing **"NO POLICY LOADED"** and the exact parse error
(with a line number) is printed to Godot's output console. Fix the line
it names and try again.

---

## Safety and limitations

NovaLang is **sandboxed by design**. The entire language is: numbers,
strings, lists, dicts, `if`/`while`, functions, and a fixed list of about
30 built-in functions (math, string, and list helpers — the complete
list is in [`docs/NOVALANG.md`](docs/NOVALANG.md)). That's it. There is:

- **no file system access** — a `.nova` file cannot read or write any
  file on your computer, including other `.nova` files, save games, or
  anything else;
- **no network access** — no sockets, no HTTP, nothing that could send
  or receive data;
- **no way to call into the operating system** — no shelling out, no
  process spawning;
- **no way to affect anything outside the game** it's loaded into. The
  *only* things a `.nova` file can do are the specific, hand-picked
  "host functions" the game registers for it — for Reactor Sim, that's
  `log()`, `alarm()`, `scram()`, `reset_trip()`, `meltdown()`,
  `victory()`, `inject_fault()`, and `clear_fault()`, and nothing else.

Two more guards exist purely to keep a *broken* mod from hanging the
game rather than just failing to load:

- **Step budget:** a policy gets 500,000 evaluation steps per tick. An
  accidental `while true { }` fails that tick with an error instead of
  freezing the render thread.
- **Call depth:** 128 stack frames. Runaway recursion is an error, not
  a crash.

**Bottom line: the worst a bad Reactor Sim mod can do is fail to load,
or make the in-game reactor behave in a way you don't like.** It cannot
touch anything on your computer outside the game itself.

---

## Quick Start

The same four steps work for every mod in this guide, simple or
advanced:

1. **Open `godot/scripts/reactor_rules.nova` in any text editor.**
2. **Find the value you want to change.** Everything tunable lives in
   the `params { }` block near the top, or in one of the `fault { }`
   blocks near the bottom.
3. **Change it and save.**
4. **Launch the game** — press F5 in the Godot editor, or reopen an
   exported build. Your mod is active immediately; there's nothing else
   to do.

If you only read one more section before diving in, make it
[Inside reactor_rules.nova](#inside-reactor_rulesnova) — it explains what
every block in the file is actually for.

---

## Inside reactor_rules.nova

The file has five parts, always in roughly this order. You will spend
almost all of your time in the first and last of these.

### 1. The header

```nova
reactor "CHERNOBYL-1" version 1
```

`"CHERNOBYL-1"` is the plant's display name (shown in Godot's console
and by the validator tool — it does not currently appear on the in-game
panel). `version` is just a number you can bump for your own reference;
the game doesn't require any particular value. Give your scenario its
own title here — it's the first thing that shows up when you validate
your file (see [Troubleshooting](#troubleshooting)).

### 2. `params { }` — the numbers you'll change most

Every setpoint, threshold, and timing constant the policy uses. This is
**the single most important block for modding** — the large majority of
useful mods are a one-line change in here.

| Param | Default | What it does |
|---|---|---|
| `trip_flux_pct` | `150.0` | Neutron flux (% of rated power) that triggers an automatic SCRAM. |
| `trip_fuel_temp_c` | `1800.0` | Fuel temperature (°C) that triggers an automatic SCRAM. |
| `trip_pressure_mpa` | `18.5` | Primary loop pressure (MPa) that triggers an automatic SCRAM. |
| `trip_lowflow_frac` | `0.5` | Coolant flow fraction (0–1) below which a loss-of-flow SCRAM can trigger. |
| `trip_lowflow_power_pct` | `50.0` | The loss-of-flow trip only arms above this power level — a shutdown reactor at low flow isn't dangerous. |
| `warn_flux_pct` | `115.0` | Advisory "CAUTION" alarm threshold for flux — below the trip point, just a warning. |
| `warn_fuel_temp_c` | `1200.0` | Advisory alarm threshold for fuel temperature. |
| `warn_pressure_mpa` | `17.5` | Advisory alarm threshold for pressure. |
| `meltdown_temp_c` | `2800.0` | Fuel temperature that starts the meltdown countdown if sustained. |
| `meltdown_sustain_s` | `5.0` | How many continuous seconds above `meltdown_temp_c` before the core is lost. |
| `overheat_temp_c` | `1500.0` | Threshold for the "OVERHEAT" operating state (cosmetic/informational, not a trip). |
| `startup_flux_pct` | `3.0` | Below this, the state machine reads "STARTUP." |
| `ascension_flux_pct` | `60.0` | Above this, the state machine reads "STEADY" instead of "POWER ASCENSION." |
| `survive_time_s` | `900.0` | Seconds of survival needed for a win (900 = 15 minutes). |
| `scram_cooldown_s` | `600.0` | Seconds after a SCRAM before rod drives are restored and the trip can be reset. |
| `fault_first_min_s` / `fault_first_max_s` | `45.0` / `90.0` | Range for when the *first* random fault of a run can strike. |
| `fault_gap_min_s` / `fault_gap_max_s` | `45.0` / `90.0` | Range for the gap between one fault clearing and the next one being rolled. |
| `xenon_max_pcm` | `400.0` | Maximum magnitude (in pcm — percent-milli-rho, the standard reactivity unit) of xenon poisoning. |
| `xenon_ramp_s` | `60.0` | Seconds for xenon poisoning to ramp fully in, or to decay fully out. |
| `auto_rod_control` | `0.0` | `0` = manual (default). Set to `1` to enable the optional autopilot. |
| `auto_target_power_pct` | `100.0` | The power level the autopilot tries to hold, if enabled. |
| `auto_rod_gain` | `0.010` | How aggressively the autopilot corrects — higher reacts faster but can overshoot. |

Changing one of these is exactly as simple as it looks:

```nova
# Before
trip_flux_pct = 150.0

# After: the automatic trip doesn't step in until 200% power
trip_flux_pct = 200.0
```

### 3. `effects { }` — what faults are allowed to touch

```nova
effects {
    flow_frac       = 1.0
    load_frac       = 1.0
    stuck_bank      = ""
    xenon_pcm       = 0.0   persistent
    stuck_bank_pick = "A"   persistent
}
```

These are the **only four physical levers** a fault (or a rule) can
actually pull: coolant flow fraction, electrical load fraction, which
rod bank (if any) is seized, and the xenon poisoning level. Every
non-`persistent` value here snaps back to its default at the start of
every tick — that's the mechanism that makes a fault clearing actually
*stop* affecting the plant, with no cleanup code required anywhere.
`persistent` values (like `xenon_pcm`) keep whatever they were last set
to, because xenon doesn't vanish the instant a fault clears — it decays
over time, which is handled by a `rule` further down (see below).

**This is the important limitation to understand before writing a new
fault:** if you invent a new effect name that isn't one of these four
(or one you add here yourself, following the same pattern), it does
nothing to the actual physics — the physics engine
(`godot/scripts/reactor_physics.gd`) only ever reads `flow_frac`,
`load_frac`, `stuck_bank`, and `xenon_pcm` back from NovaLang, once per
tick. A new fault can only act on the reactor through one of these four
channels (or by calling `alarm()`/`log()` for flavor text, or `scram()`
for a hard trip). See
[Different reactor types](#different-reactor-types-pwr-rbmk-bwr) for
exactly where that boundary sits.

### 4. `signals { }` — values recomputed every tick

```nova
signals {
    power_ok      = flux_pct < warn_flux_pct and fuel_temp_c < warn_fuel_temp_c
    thermal_slack = meltdown_temp_c - fuel_temp_c
    hot           = fuel_temp_c > overheat_temp_c
    running       = not game_over
}
```

These are convenience expressions, recomputed fresh every tick before
any rule runs, so rules can read `hot` instead of repeating
`fuel_temp_c > overheat_temp_c` five times. You can add your own here if
a mod's rules end up repeating the same condition — it's purely for
readability, not required.

### 5. `rule { }` blocks — the actual logic

```nova
rule flux_high_trip priority 290 {
    when  running and not scram and flux_pct > trip_flux_pct
    then  scram("AUTO SCRAM -- NEUTRON FLUX HIGH")
}
```

A rule has a name, an optional `priority` (higher runs first — this
matters because **the last rule to `set` a variable wins**, so mutually
exclusive states like the operating-state machine are written as
separate rules with non-overlapping conditions rather than depending on
order), and two optional modifiers:

- **`once`** — fires at most one time per run, ever. Used for win/loss
  conditions (`core_disassembly`, `shift_survived`) that shouldn't keep
  re-triggering.
- **`edge`** — fires only on the instant its condition becomes true
  (the "rising edge"), not on every tick it stays true. Used for
  one-time log lines like `warn_flux_entry`, so a caution message
  doesn't spam the log every single tick flux stays high.

The existing rules fall into five groups, in priority order:
**protection** (the four SCRAM trips, priority 275–300), **end of run**
(meltdown/victory, priority ~195–200), **alarms** (priority 125–160),
**operating state** (the STARTUP/STEADY/SCRAM/etc. state machine,
priority 50–60), and **housekeeping** (xenon decay and the optional
autopilot, priority 10–20). Read `reactor_rules.nova` top to bottom —
it's organized in exactly this order with section-header comments, and
it's short enough (about 270 lines) to read in full in a few minutes.

### 6. `fault { }` blocks — equipment failures

```nova
fault feedwater_failure weight 1.0 duration 45.0 label "FEEDWATER PUMP FAILURE" {
    set flow_frac = 0.3
}
```

The four faults shipped with the game:

| Fault | Duration | What it does |
|---|---|---|
| `turbine_trip` | 40s | `load_frac = 0.0` — the turbine stops accepting steam. |
| `feedwater_failure` | 45s | `flow_frac = 0.3` — coolant flow drops to 30%. |
| `rod_stuck` | 35s | `stuck_bank = "A"` or `"B"` (picked once, on entry) — that bank's drive seizes and won't move. |
| `xenon_poisoning` | 60s | Ramps `xenon_pcm` down toward `-xenon_max_pcm` over `xenon_ramp_s` seconds. |

At any moment, **at most one fault is active.** The engine picks by
`weight` (higher = more likely relative to the others; a fault with
`weight 0` never fires on its own — see
[Creating a custom scenario](#creating-a-custom-scenario) for why that's
useful), runs its body every tick for `duration` seconds, logs
`ALARM: <label>` on entry and `<label> CLEARED` on exit automatically,
then waits somewhere between `fault_gap_min_s` and `fault_gap_max_s`
before rolling the next one. Inside a fault's body, `fault_elapsed`
(seconds since it started), `fault_label`, and `active_fault` (its name)
are all readable.

---

## About "reactor_events.nova"

If you came looking for a separate `reactor_events.nova` file for fault
injection and scenario triggers — **there isn't one, and that's not a
missing file.** Reactor Sim's design puts the fault injector in the
*same* file as the physics setpoints, on purpose: a `fault` block is
just another top-level declaration in `reactor_rules.nova`, exactly like
a `rule` or a `params` entry. There is one file because there is one
policy — the setpoints and the failure modes are two views of the same
thing, and keeping them together means a mod that changes how dangerous
a fault is can see the trip thresholds it's playing against on the same
screen. Every example scenario below lives entirely inside
`reactor_rules.nova`.

---

## Creating a custom scenario

The classic ask — **"a coolant leak at exactly 5 minutes"** — needs two
pieces: a `fault` describing what the leak does, and a `rule` that
triggers it at a specific time rather than waiting for the random
scheduler.

**Step 1 — write the fault, with `weight 0` so it never fires on its
own:**

```nova
fault coolant_leak weight 0.0 duration 999999.0 label "COOLANT LEAK" {
    set flow_frac = 0.15
}
```

`weight 0.0` keeps it out of the random rotation entirely — the
built-in scheduler only ever picks from faults with weight greater than
zero. `duration 999999.0` is a deliberately huge number: this leak isn't
meant to self-clear, it's a "keep going until the operator fixes it"
scenario. (If you *do* want it to clear on its own after some time, just
give it a normal `duration`.)

**Step 2 — trigger it at the 5-minute mark with a rule:**

```nova
rule coolant_leak_trigger priority 999 once {
    when  running and t >= 300.0
    then  clear_fault()
          inject_fault("coolant_leak")
          log("SCENARIO: A COOLANT LEAK HAS DEVELOPED")
}
```

`t` is seconds since the run started, so `t >= 300.0` means "five
minutes in." `once` is essential here — without it, this rule would try
to re-inject the fault on every single tick after the five-minute mark.

**The `clear_fault()` before it matters more than it looks.** At most
one fault can be active at a time, and `inject_fault()` **silently does
nothing if a fault is already active** — including one of the four
default faults the random scheduler happened to pick right before your
5-minute mark. Without clearing first, your scripted coolant leak would
sometimes just... not happen, with no error anywhere, depending on
what the random scheduler was doing at that moment. Calling
`clear_fault()` immediately before `inject_fault()` guarantees your
scripted event actually fires every time, regardless of what else was
going on. (If a *different* random fault happening to override your
scenario is exactly the chaos you want, you can leave `clear_fault()`
out — just know that's what you're choosing.)

`priority 999` just makes sure it runs early enough in the tick to
matter; in practice anything higher than the rules it doesn't interact
with is fine.

That's the whole pattern for **any** scripted scenario trigger: a
`fault` with `weight 0` describing *what happens*, and a `once` rule
watching for *when* it should happen, calling `clear_fault()` then
`inject_fault("name")`. Want two staged events? Add a second fault and
a second timed rule. Want the leak to only trigger if the reactor is
already running hot? Change the `when` condition to include
`fuel_temp_c > 1000.0` alongside
the time check.

You can also end a scripted fault early with `clear_fault()`, from any
rule, at any time — useful if you want an event to end when the player
does something right, not just after its `duration` expires.

---

## Different reactor types: PWR, RBMK, BWR

Before tuning a "reactor type," it's worth being precise about what
`reactor_rules.nova` actually controls versus what's fixed in the
physics engine underneath it, because the honest answer shapes what a
"BWR mod" can and can't be.

**Fixed in `godot/scripts/reactor_physics.gd` (not moddable via
`.nova`):** the point-kinetics equations themselves, the six-group
delayed-neutron data, the fuel and moderator temperature reactivity
coefficients (`ALPHA_FUEL_PCM_PER_C = -1.8`, `ALPHA_MOD_PCM_PER_C =
-6.0` — both negative, meaning this model is inherently self-stabilizing
the way a PWR is, with no void-coefficient term at all), the shape of
the decay-heat curve, and how fast rods physically move once a SCRAM
latches (instantaneous, in this model — there's no modeled insertion
time). Changing any of *these* means editing GDScript and would need
you to run the project from source in the Godot editor; it's a real
code change, not a text-file mod, and it's the one honest limitation in
this whole guide.

**Fully moddable via `reactor_rules.nova`:** how tightly the *protection
system* watches those fixed physics — the trip setpoints, alarm
thresholds, meltdown margins, fault timing and severity, and xenon
behavior. That's actually most of what makes different real-world
reactor eras *feel* different to operate, since a huge part of the
Chernobyl story, specifically, is a protection and operating culture
failure layered on top of physics — not something this simulator needs
a positive void coefficient to gesture at.

Three illustrative parameter sets, all just edits to the `params { }`
block:

**PWR-flavored (tight, well-protected, forgiving)** — closer to the
game's own defaults, just pushed further:

```nova
params {
    trip_flux_pct      = 118.0   # trips early, well short of danger
    trip_fuel_temp_c   = 1400.0
    warn_flux_pct      = 108.0
    meltdown_sustain_s = 8.0     # a bit more grace once things go wrong
    fault_gap_min_s    = 70.0
    fault_gap_max_s    = 140.0   # faults are rarer
}
```

**RBMK-flavored (loose margins, protection arrives late)** — the trips
are set close to where trouble already exists, so there's very little
runway between "caution" and "automatic scram," and the meltdown window
is unforgiving once you're past the trip:

```nova
params {
    trip_flux_pct      = 135.0   # trips closer to the danger zone
    trip_fuel_temp_c   = 2200.0  # runs hotter before the trip even engages
    warn_flux_pct       = 122.0  # the caution and the trip are close together
    meltdown_sustain_s = 2.5     # very little grace once you're over temp
    xenon_max_pcm      = 600.0   # bigger xenon swings to manage
    fault_gap_min_s    = 30.0
    fault_gap_max_s    = 60.0    # faults come faster
}
```

**BWR-flavored (flow-sensitive)** — since a BWR's power is tied tightly
to coolant flow/void fraction in ways this model approximates only
through `flow_frac`, lean on the loss-of-flow trip and feedwater fault
specifically:

```nova
params {
    trip_lowflow_frac       = 0.7   # trips on a much smaller flow loss
    trip_lowflow_power_pct  = 30.0  # arms at a much lower power level
    fault_gap_min_s         = 40.0
    fault_gap_max_s         = 75.0
}
```

None of these claim to be a physically rigorous BWR/RBMK/PWR model —
they're tuning presets that make the *protection system's* character
differ, which is the lever this modding surface actually gives you.

---

## Example mods

### Hardcore Mode

Wider power swings, later automatic protection, more frequent and more
severe faults, less time to react once something goes wrong. Nothing
here needs anything beyond `params`:

```nova
params {
    trip_flux_pct         = 170.0    # runs hotter before the trip saves you
    trip_fuel_temp_c      = 2000.0
    warn_flux_pct         = 130.0    # less warning before the trip fires
    meltdown_sustain_s    = 2.0      # almost no grace period once critical
    scram_cooldown_s      = 900.0    # a mistake costs you 15 minutes, not 10
    fault_first_min_s     = 15.0
    fault_first_max_s     = 30.0     # trouble starts fast
    fault_gap_min_s       = 20.0
    fault_gap_max_s       = 40.0     # and keeps coming
}
```

### Chernobyl Scenario

The real April 1986 accident involved a positive void coefficient and a
control-rod design flaw (the "positive scram effect") that this
simulator's physics model doesn't implement — see
[Different reactor types](#different-reactor-types-pwr-rbmk-bwr) above
for exactly why, and don't build a mod that promises either one, since
it can't actually be made true from a `.nova` file. What *is* faithfully
modeled, and what this scenario leans on instead, is a real Chernobyl
mechanism: **the xenon well.** Reduce power, xenon poisons the core,
you withdraw more rod to compensate, and if the poisoning then clears
(or you're forced to trip) with that rod margin still out, you get a
sharp, dangerous reactivity swing you didn't plan for. Combine that
with RBMK-style loose protection margins. **Find the existing
`xenon_poisoning` fault already in the file and edit it in place** —
don't paste a second `fault xenon_poisoning { ... }` block anywhere
else in the file. NovaLang doesn't merge or override a repeated fault
name; a second declaration would just sit alongside the first as a
separate entry in the random rotation, doubling up on that name in a
confusing way instead of replacing it. One name, one declaration,
edited where it already lives:

```nova
params {
    trip_flux_pct      = 140.0
    warn_flux_pct       = 122.0
    meltdown_sustain_s = 2.5
    xenon_max_pcm      = 700.0    # a much deeper xenon well to manage
    xenon_ramp_s       = 45.0     # and it ramps in and clears faster
}

# Edit the fault below in place -- it's already in reactor_rules.nova,
# just change the weight from 1.0 to 3.0:
fault xenon_poisoning weight 3.0 duration 90.0 label "XENON TRANSIENT" {
    set xenon_pcm = 0.0 - xenon_max_pcm * ramp(fault_elapsed / xenon_ramp_s)
}
```

Raising `xenon_poisoning`'s own `weight` relative to the other three
(left untouched) makes the xenon well the *defining* danger of the
scenario instead of one hazard among four, which is the honest way to
capture "operate through a xenon transient with almost no protection
margin" without asserting a reactivity coefficient this engine doesn't
have.

### Fukushima Scenario

This one *is* fully and accurately achievable, because "total loss of
cooling, and the decay heat does the rest" is exactly what this engine's
decay-heat model already simulates — no fixed physics needs bending at
all. The trick is a **two-stage fault chain**: a "tsunami" event that
knocks out normal flow, followed automatically by a second fault
representing backup power failing too:

```nova
fault tsunami_strike weight 0.0 duration 20.0 label "TSUNAMI -- MAIN COOLANT PUMPS OFFLINE" {
    set flow_frac = 0.4
}

fault station_blackout weight 0.0 duration 999999.0 label "STATION BLACKOUT -- BACKUP GENERATORS FAILED" {
    set flow_frac = 0.0
    set load_frac = 0.0
}

rule tsunami_trigger priority 999 once {
    when  running and t >= 300.0
    then  clear_fault()
          inject_fault("tsunami_strike")
          log("SCENARIO: TSUNAMI WARNING -- SEA WALL OVERTOPPED")
}

rule backup_power_fails priority 998 once {
    when  running and active_fault == "tsunami_strike" and held(active_fault == "tsunami_strike", 15.0)
    then  clear_fault()
          inject_fault("station_blackout")
          log("SCENARIO: BACKUP GENERATORS HAVE FAILED -- NO COOLANT FLOW")
}
```

Both stages call `clear_fault()` immediately before `inject_fault()` —
without it, the second rule's injection would silently fail, because
`tsunami_strike` (a fault) is still active at that moment and
`inject_fault()` refuses to override whatever fault is currently
running (see the callout in
[Creating a custom scenario](#creating-a-custom-scenario) above). The
same reasoning applies to the first stage, in case a random fault
happened to already be active at the 5-minute mark.

Fifteen seconds after the tsunami fault starts, the second rule fires,
clearing it and overwriting it with total, permanent loss of flow *and*
load — from
there, decay heat alone (already modeled, no changes needed) does
exactly what it did at Fukushima Daiichi: a slow climb with nothing
pushing back, unless the player finds another way to manage it.

---

## Modding examples: beginner to advanced

**Beginner — give yourself more warning before the automatic trip:**

1. Open `godot/scripts/reactor_rules.nova`.
2. Find `warn_flux_pct = 115.0` in the `params { }` block.
3. Change it to `warn_flux_pct = 105.0` — the caution alarm now fires
   ten percentage points earlier, giving you more time to react before
   `trip_flux_pct` (still 150.0) actually scrams the plant.
4. Save, relaunch. That's a complete, working mod.

**Intermediate — add a brand-new fault:**

1. Pick a name, a weight relative to the existing four (weight `1.0` is
   "about as common as the others"), a duration, and a label.
2. Decide what it does using only `flow_frac`, `load_frac`,
   `stuck_bank`, and `xenon_pcm` — for example, a brief negative xenon
   shift representing a sensor glitch:

   ```nova
   fault sensor_glitch weight 1.0 duration 15.0 label "FLUX SENSOR GLITCH" {
       set xenon_pcm = -20.0
   }
   ```

   **Important gotcha:** a fault's body runs **every tick** for its
   whole `duration`, not once on entry. `set xenon_pcm = -20.0` is safe
   because it assigns the same fixed value every tick — but
   `set xenon_pcm = xenon_pcm - 20.0` would be a real bug: at 20 ticks
   per second, that "small nudge" would actually subtract 20 pcm
   *twenty times a second* for the whole duration, draining thousands of
   pcm in a few seconds. If you want an effect that changes smoothly
   over a fault's lifetime, do what the built-in `xenon_poisoning` fault
   does and compute an absolute value from `fault_elapsed` (seconds
   since the fault started), e.g. `set xenon_pcm = -20.0 * ramp(fault_elapsed / 5.0)`
   to ramp in over 5 seconds — never accumulate onto the variable's own
   current value.
3. Save it into `reactor_rules.nova` anywhere among the other `fault`
   blocks — order doesn't matter.
4. Relaunch. It's now in the random rotation alongside the original
   four, at its stated weight.

**Advanced — a scripted, multi-stage scenario director:**

Combine several `weight 0` faults with a chain of `once` rules, each
watching `t` or `held(active_fault == "...", seconds)` on the previous
stage, the way the Fukushima example above does. This is the same
pattern a full "campaign" mod would use for a scripted sequence of
escalating trouble instead of the default random mix — nothing about
the language changes at this scale, it's just more of the same two
building blocks (`fault` + timed `rule`) chained together. If a stage
needs to make a decision based on player behavior rather than just
elapsed time, that's an ordinary `rule` condition too — for example,
only escalating to `station_blackout` if the operator hasn't already
raised `flow_frac` back up manually is just
`when ... and flow_frac < 0.5`.

---

## Troubleshooting

**"NO POLICY LOADED" on the panel, or a parse error in the console.**
This means `reactor_rules.nova` has a syntax error. The two most common
causes:

- **A mismatched brace.** Every `{` needs a matching `}`. If you added
  a new `fault` or `rule` block, count your braces — a good editor will
  highlight the matching one when your cursor is next to it. A missing
  `}` after the `params` block, for example, produces an error like
  `line 71: expected 'ident', got 'effects'` — the line number points at
  where the parser gave up, which is often a little *after* the actual
  missing brace, not exactly on it. If the named line looks fine,
  check the block just above it first.
- **A missing comma or quote inside a dict/list**, or (if you used
  TextEdit or Word) **smart quotes** (`"like this"` instead of
  `"like this"`) — NovaLang only accepts straight ASCII quotes.

**Validate your file before launching the game** — this catches almost
everything, with the exact line number, faster than trial-and-error in
Godot:

```bash
python3 reference/reactor_host.py --validate --rules reactor_rules.nova
```

Run it from the repository root. It prints the parsed program (title,
every param, every rule and fault by name) on success, or the first
error and its line number on failure.

**Values out of range / the reactor feels broken, not hard.** NovaLang
won't stop you from typing a number that breaks the game's balance or
even its internal logic — a few specific traps:

- `warn_flux_pct` set *higher* than `trip_flux_pct` means the caution
  alarm never fires before the trip does — harmless, but pointless.
- `meltdown_sustain_s = 0.0` means the instant fuel temperature crosses
  `meltdown_temp_c`, the core is gone with no reaction time at all.
- `xenon_max_pcm` in the thousands can produce reactivity swings large
  enough that the reactor becomes uncontrollable by rod position alone
  — check `godot/scripts/reactor_physics.gd`'s `ROD_W_MIN_PCM`/
  `ROD_W_MAX_PCM` (-3000 to +6000 pcm) for a sense of scale if you want
  xenon to matter without completely dominating rod authority.
- A fault `duration` of `0.0` will log "ALARM:" and "CLEARED" back to
  back on the very next tick — probably not what you meant; use a small
  positive number if you want something nearly instantaneous.

There's no "this value is illegal" check for game balance — only for
NovaLang syntax. If a mod feels unplayable, that's a tuning problem, not
an error; dial the number back.

**Reverting to the original file.** Two options, in order of
preference:

- **If you have the repository cloned with git:**
  ```bash
  git checkout -- godot/scripts/reactor_rules.nova
  ```
  This restores the exact original file and discards your edits.
- **If you don't use git, or just downloaded the game:** before you
  start modding, copy `reactor_rules.nova` to
  `reactor_rules.nova.backup` in the same folder. If a mod goes wrong,
  delete your edited version and rename the backup back to
  `reactor_rules.nova`. (A backup copy with any other extension is
  ignored by the game — only the exact filename `reactor_rules.nova` is
  ever loaded — so it's completely safe to keep spare copies sitting
  right next to it.)

---

## Safety and ethics

- **NovaLang cannot access your file system or network.** This isn't a
  policy promise, it's a fact about what the language *is*: the full
  list of things a `.nova` file can call is documented in
  [Safety and limitations](#safety-and-limitations) above, and none of
  it touches disk or network I/O.
- **A mod can only affect the game it's loaded into.** The worst
  outcome of running someone else's `reactor_rules.nova` is an
  unbalanced or broken *reactor simulation* — not your computer, your
  other files, or your other software.
- **Share mods responsibly.** If you publish a scenario, say plainly
  what it changes and how extreme it is (a "Hardcore" mod that's
  actually unwinnable is a fair thing to make, but say so in the
  filename or description rather than letting someone discover it the
  hard way). Crediting the numbers and scenario names you built on top
  of — like the historical scenarios in this guide — is good community
  practice, not a requirement, but it's appreciated.

---

For every value not covered above, and for a side-by-side reference
with Daedalus's own moddable numbers, see
[`MODDING_QUICKREF.md`](MODDING_QUICKREF.md). For the full language
syntax (every operator, every builtin, module imports, closures), see
[`docs/NOVALANG.md`](docs/NOVALANG.md).
