# NovaLang Modding — Quick Reference

One page, Reactor Sim only. For explanations, worked examples, and
troubleshooting in full, see the full guide:
[`MODDING_REACTOR.md`](MODDING_REACTOR.md) ·
[`docs/NOVALANG.md`](docs/NOVALANG.md) (full language syntax).

(Daedalus — the space-combat game also built on NovaLang — lives in its
own repository, [DaedalusGodot](https://github.com/ussdaedalus43821-cloud/DaedalusGodot),
with its own `MODDING_DAEDALUS.md`.)

## Quick Start

1. Open `godot/scripts/reactor_rules.nova` in any text editor.
2. Find the value you want to change.
3. Change it and save.
4. Launch the game — your mod is active immediately. No build step, ever.

**Sandboxed:** NovaLang has no file system access, no network access,
and no way to reach anything outside the game it's loaded into. The
worst a bad mod does is fail to load (with a clear error) or make the
game unbalanced.

---

## File location

| File | Path |
|---|---|
| `reactor_rules.nova` | `godot/scripts/reactor_rules.nova` |

Validate a file before launching (catches syntax errors with a line
number), run from the repository root:

```bash
python3 reference/reactor_host.py --validate --rules reactor_rules.nova
```

---

## `params { }`

| Param | Default | Meaning |
|---|---|---|
| `trip_flux_pct` | 150.0 | Auto-SCRAM: neutron flux (%). |
| `trip_fuel_temp_c` | 1800.0 | Auto-SCRAM: fuel temp (°C). |
| `trip_pressure_mpa` | 18.5 | Auto-SCRAM: primary pressure (MPa). |
| `trip_lowflow_frac` | 0.5 | Auto-SCRAM: flow fraction floor. |
| `trip_lowflow_power_pct` | 50.0 | Loss-of-flow trip arms above this power. |
| `warn_flux_pct` | 115.0 | Caution alarm threshold, flux. |
| `warn_fuel_temp_c` | 1200.0 | Caution alarm threshold, fuel temp. |
| `warn_pressure_mpa` | 17.5 | Caution alarm threshold, pressure. |
| `meltdown_temp_c` | 2800.0 | Core loss threshold if sustained. |
| `meltdown_sustain_s` | 5.0 | Seconds above `meltdown_temp_c` before loss. |
| `overheat_temp_c` | 1500.0 | "OVERHEAT" state threshold (cosmetic). |
| `startup_flux_pct` | 3.0 | Below this: "STARTUP" state. |
| `ascension_flux_pct` | 60.0 | Above this: "STEADY" instead of "POWER ASCENSION". |
| `survive_time_s` | 900.0 | Seconds survived to win (900 = 15 min). |
| `scram_cooldown_s` | 600.0 | Seconds locked out after a SCRAM. |
| `fault_first_min_s` / `_max_s` | 45.0 / 90.0 | First fault timing window. |
| `fault_gap_min_s` / `_max_s` | 45.0 / 90.0 | Gap between faults. |
| `xenon_max_pcm` | 400.0 | Max xenon poisoning magnitude (pcm). |
| `xenon_ramp_s` | 60.0 | Xenon ramp-in/decay time (s). |
| `auto_rod_control` | 0.0 | `1` enables the optional autopilot. |
| `auto_target_power_pct` | 100.0 | Autopilot's target power. |
| `auto_rod_gain` | 0.010 | Autopilot aggressiveness. |

**`effects { }` — the only four levers a fault can pull:** `flow_frac`,
`load_frac`, `stuck_bank`, `xenon_pcm`. A fault body runs every tick for
its `duration` — always assign an absolute value, never `x = x + n`.

**Built-in faults:** `turbine_trip` (40s, `load_frac=0`),
`feedwater_failure` (45s, `flow_frac=0.3`), `rod_stuck` (35s,
`stuck_bank` seized), `xenon_poisoning` (60s, ramped `xenon_pcm`).

**Scripted scenario trigger pattern:**
```nova
fault my_event weight 0.0 duration 999999.0 label "..." { set flow_frac = 0.15 }
rule my_trigger priority 999 once {
    when running and t >= 300.0
    then clear_fault()
          inject_fault("my_event")
}
```
`clear_fault()` before `inject_fault()` is required — injection
silently no-ops if any fault is already active.

**Physics NOT exposed to NovaLang** (fixed in `reactor_physics.gd`):
reactivity feedback coefficients (`ALPHA_FUEL_PCM_PER_C = -1.8`,
`ALPHA_MOD_PCM_PER_C = -6.0`, both negative — no void coefficient
modeled), decay heat curve, rod insertion time (instantaneous). A "real"
RBMK-style positive void coefficient cannot be built from a `.nova`
file — see `MODDING_REACTOR.md`'s [Different reactor
types](MODDING_REACTOR.md#different-reactor-types-pwr-rbmk-bwr) section
for the accurate alternative.

---

## Common syntax

```nova
reactor "TITLE" version 1        # program header

params  { name = value }                    # constants
effects { name = value [persistent] }       # what faults may write
signals { name = expression }               # recomputed every tick

rule NAME [priority N] [once] [edge] {
    when <condition>
    then <statement>...
}

fault NAME [weight W] [duration S] [label "TEXT"] {
    <statement>...   # runs every tick for `duration` seconds
}
```

Builtins you'll actually use: `clamp(v,lo,hi)` `min` `max` `abs` `round`
`floor` `ramp(x)` (clamps 0..1) `lerp(a,b,t)` `pick(...)` `rand(lo,hi)`
`held(cond,seconds)` `get(dict,key,default)` `len` `str`. Full list:
[`docs/NOVALANG.md`](docs/NOVALANG.md#builtins).

`==` is deep and exact (no float tolerance). Division/modulo by zero
returns `0`, never an error. `{` in statement position is always a
block, never a dict literal.

---

## Troubleshooting one-liners

| Symptom | Cause |
|---|---|
| "NO POLICY LOADED" / console parse error | Syntax error — check braces, commas, straight vs. smart quotes. |
| A scripted fault "sometimes doesn't fire" | Missing `clear_fault()` before `inject_fault()`. |
| A fault's effect compounds wildly | Fault body does `set x = x + n` instead of an absolute value — bodies run every tick, not once. |

**Revert:** `git checkout -- <path>` if you have git, or restore from a
backup copy you made before editing (any filename other than the exact
original is ignored by the game, so backups are always safe to keep
alongside).

---

## Safety

NovaLang cannot touch your file system or network — the full builtin
and host-function list (see `MODDING_REACTOR.md`) has nothing that does
either. A mod's worst-case outcome is a broken *game*, never a broken
computer. Share mods with an honest description of what they change,
especially large balance shifts.
