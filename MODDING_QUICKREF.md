# NovaLang Modding — Quick Reference

One page, both games. For explanations, worked examples, and the
GDScript-touching edge cases, see the full guides:
[`MODDING_REACTOR.md`](MODDING_REACTOR.md) ·
[`daedalus_godot/MODDING_DAEDALUS.md`](daedalus_godot/MODDING_DAEDALUS.md) ·
[`docs/NOVALANG.md`](docs/NOVALANG.md) (full language syntax).

## Quick Start (both games)

1. Open the `.nova` file in any text editor.
2. Find the value you want to change.
3. Change it and save.
4. Launch the game — your mod is active immediately. No build step, ever.

**Sandboxed:** NovaLang has no file system access, no network access,
and no way to reach anything outside the game it's loaded into. The
worst a bad mod does is fail to load (with a clear error) or make the
game unbalanced.

---

## File locations

| Game | File(s) | Path |
|---|---|---|
| Reactor Sim | `reactor_rules.nova` | `godot/scripts/reactor_rules.nova` |
| Daedalus | `daedalus_rules.nova`, `daedalus_ai.nova`, `daedalus_weapons.nova` | `daedalus_godot/scripts_nova/` |

Validate a file before launching (catches syntax errors with a line
number):

```bash
python3 reference/reactor_host.py --validate --rules reactor_rules.nova
```

(Reactor Sim only — run from the repository root. Daedalus's files
don't have a standalone validator; launch the game and read the
console.)

---

## Reactor Sim — `params { }`

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

## Daedalus — `daedalus_rules.nova`

**SHIPS** (`SHIP_ORDER`: x302, daedalus, phoenix, aurora, destiny, atlantis):

| Ship | Class | Shield | Hull | Speed | Turn | Gun | Rocket | Homing | Beam | Hardened |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|:--:|
| F-302 (x302) | fighter | 397 | 228 | 1142 | 348 | 4.7 | 74.2 | 55.3 | 0 | no |
| Daedalus | battlecruiser | 1583 | 1049 | 917 | 218 | 12.3 | 117.5 | 89.1 | 2431 | no |
| Phoenix | battlecruiser | 2471 | 1654 | 1035 | 241 | 14.1 | 163.0 | 114.6 | 3422 | no |
| Aurora | capital | 3682 | 2183 | 948 | 184 | 11.8 | 138.4 | 122.7 | 0 | **yes** |
| Destiny | capital | 1762 | 3517 | 806 | 139 | 11.1 | 134.8 | 94.2 | 0 | no |
| Atlantis | capital | 7124 | 5843 | 753 | 108 | 16.3 | 186.5 | 131.9 | 0 | **yes** |

Every ship needs all 9 fields (`name`, `class`, `shield`, `hull`,
`speed`, `turn`, `gun_dmg`, `rocket_dmg`, `homing_dmg`, `beam_dmg`,
`hardened`) or the self-check refuses to launch.

**DAMAGE_SCALING** (`[attacker_class][defender_class]`, unlisted = 1.0):

| Attacker \ Defender | fighter | battlecruiser | capital |
|---|--:|--:|--:|
| fighter | 1.0 | 0.082 | 0.047 |
| battlecruiser | 2.37 | 1.0 | 0.74 |
| capital | 3.14 | 1.12 | 1.0 |

**POWER:** max 1047, recharge +112/s, shield_draw 143/s, thrust_drain
48/s, cloak_drain 27/s, primary_cost 9.4, rocket_cost 31.2, homing_cost
22.7.

**DANGER bands** (`{base, per_gen}`, index = a sector's `danger` field):
`0:` 0/0 (never spawns) · `1:` 4/0.8 · `2:` 9/1.3 · `3:` 15/2.1. Add a
5th band (index 4) for an extreme sector — the game reads however many
bands exist.

**SECTORS:** 10 sectors, keys 0–9 (the digit that jumps there). Fields:
`key`, `name`, `danger`, `spawns`, `capital_chance`, `charge` (hyperdrive
spool-up, s), `travel` (transit time, s), `fighter_cd`, `mix` (optional
weighted hostile list), `unique` (optional guaranteed-chance kind).

---

## Daedalus — `daedalus_ai.nova`

**ENEMY** (`ENEMY_ORDER`: fighter, capital, dart, hive, replicator, ori):

| Kind | Role | Class | Shield | Hull | Speed | Turn | Gun | Score |
|---|---|---|--:|--:|--:|--:|--:|--:|
| fighter | Skirmisher | fighter | 438.2 | 307.5 | 312.7 | 204.8 | 6.2 | 104 |
| capital | Brawler | capital | 1538.4 | 3172.8 | 58.4 | 19.4 | 17.3 | 3184 |
| dart | Dive-Bomber | fighter | 92.7 | 68.3 | 587.2 | 386.1 | 5.1 | 126 |
| hive | Carrier | capital | 2417.6 | 5283.7 | 42.3 | 14.7 | 18.7 | 6273 |
| replicator | Infestor | fighter | 837.5 | 967.2 | 384.6 | 226.3 | 0 | 3017 |
| ori | Beam Satellite | capital | 3421.8 | 3618.4 | 18.2 | 11.7 | 0 | 5817 |

Kind-specific extras: dart has `ram_dmg_base` 26.4 (scaled by closing
speed², never class-scaled); hive has `spawn_cd`/`release_range`
307.0/`max_stored` 6; replicator has `flee_hull_frac` 0.30/`flee_speed`
512.0 (infection bolts, `gun_dmg` 0, blocked outright by `hardened`);
ori has `charge_time` 1.14s/`fire_time` 1.52s/`beam_dps` 1547.0 (its own
class reaction, never the general matrix).

`hardened` (Aurora, Atlantis only) blocks Replicator bolts and stops
Dart dives — **not** implied by capital class (Destiny is capital,
not hardened).

Behavior pattern: `_<kind>_behavior(player_class[, player_hardened])`
reads `ENEMY.<kind>`, reacts to the player, returns a dict;
`get_behavior()` dispatches by kind name. A genuinely new, independently
-fireable kind needs one added line in `scripts/enemy.gd`'s
`match kind:` — see `MODDING_DAEDALUS.md`.

---

## Daedalus — `daedalus_weapons.nova`

| Weapon | Velocity | Lifetime | Cooldown | Energy | Special |
|---|--:|--:|--:|--:|---|
| primary | 1024.3 | 1.28s | 0.073s | 9.4 | spread 1.9°, radius 2.7 |
| rocket | 617.8 | 3.14s | 0.82s | 31.2 | blast_radius 97.4, falloff 0.37 |
| homing | 468.2 | 5.47s | 1.13s | 22.7 | acquire 1482.6, splash 78.3/0.28, turn_rate 212.4°/s |
| beam | — | — | — | 26.4/s drain, min 5.2 | ramp 1.42s, range 942.7, class×: fighter 2.8, bc 1.0, capital 0.64 |
| omni (Atlantis only) | 1187.4 | 1.13s | 0.11s | 8.7/bolt | 8 ports, spread 4.3°, damage = Atlantis's own gun_dmg |
| turret (Destiny only) | 938.6 | 1.08s | 0.47s | 4.2/shot | range 642.8, damage 14.7 (fixed, independent of Destiny's gun_dmg) |

Per-ship damage for primary/rocket/homing/omni lives in `SHIPS`, not
here. `falloff_damage(base, distance, radius, falloff)`:
`0` at `distance==0`, `base*(1-falloff)` at `distance==radius`, `0`
beyond it. Homing turn-rate reaction: ×1.14 vs fighter, ×0.89 vs
capital, unchanged vs battlecruiser. Homing salvo size: 1 (default), 3
(Aurora), 6 (Atlantis).

---

## Common syntax (both games)

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
| Reactor: scripted fault "sometimes doesn't fire" | Missing `clear_fault()` before `inject_fault()`. |
| Reactor: a fault's effect compounds wildly | Fault body does `set x = x + n` instead of an absolute value — bodies run every tick, not once. |
| Daedalus: launch fails naming a ship/enemy/weapon | Self-check caught a missing required field — the error names it. |
| Daedalus: new enemy archetype never fires | `scripts/enemy.gd`'s `match kind:` doesn't know the new name yet. |
| Daedalus: new ship looks white / wrong silhouette | Optional — add it to `HULL_COLORS` in `scripts/player.gd`. |

**Revert:** `git checkout -- <path>` if you have git, or restore from a
backup copy you made before editing (any filename other than the exact
original is ignored by the game, so backups are always safe to keep
alongside).

---

## Safety

NovaLang cannot touch your file system or network — the full builtin
and host-function list (see each game's `MODDING_*.md`) has nothing
that does either. A mod's worst-case outcome is a broken *game*, never
a broken computer. Share mods with an honest description of what they
change, especially large balance shifts.
