# Daedalus Stage 3 — Weapons Logic

Six weapon systems, each with its own ballistics, energy cost and
damage-shaping curve. `daedalus_weapons.nova` is the authority; it knows
nothing about `SHIPS`, ship classes or `DAMAGE_SCALING` (same
ship-registry-agnostic design as Stage 2's `daedalus_ai.nova`), so
`daedalus_rules.nova`'s `fire_weapon()` is the one place a raw per-ship
damage figure, a target's class and a weapon's own shaping formula
actually meet.

```
daedalus_weapons.nova    WEAPONS table + fire_ballistic() / fire_beam()   <- authority
     │  (standalone load)                              │ (import "daedalus_weapons.nova" as weapons)
     ▼                                                  ▼
weapons_bridge.gd                             daedalus_rules.nova
  cached stats, hot-path formulas               fire_weapon(type, ship, target_class,
  (beam ramp, falloff) reimplemented                       distance, elapsed)
  natively and self-checked                     homing_turn_rate() / homing_salvo_size()
```

Two consumers, one source of truth. `weapons_bridge.gd` is what a
projectile-spawning or beam-rendering system calls for raw weapon tuning
and for the formulas that run every frame; `daedalus_rules.nova`'s
`fire_weapon()` is what combat code calls when a shot needs to cross from
"this ship's raw gun stat" to "damage that lands on a target of a given
class, at a given range."

## Why two entry points, not one

Every weapon except the beam resolves its class multiplier from Stage 1's
`DAMAGE_SCALING` matrix — the same fighter/battlecruiser/capital table
`daedalus_ai.nova`'s hostiles pass through — and that resolution needs
`ship_class()`, which lives in `daedalus_rules.nova`, not in the
weapons file. So `fire_weapon()` resolves `class_mult` itself and hands
it to `weapons.fire_ballistic(weapon_type, raw_damage, class_mult,
distance)` already computed.

The Asgard beam is the stated exception: it uses its own
vs-fighter/vs-battlecruiser/vs-capital table, declared inside
`WEAPONS.beam.class_multiplier` and never touched by the general matrix.
Because it resolves its own multiplier internally, `fire_weapon()` calls
`weapons.fire_beam(base_dps, target_class, distance, elapsed)` instead,
passing a class *string*, not a pre-multiplied number.

## The six systems

### Primary Guns — Direct Fire

Every ship's default weapon (velocity 1024.3, cooldown 0.073s — 13.7
rounds/s, the fastest trigger in the game — spread 1.9°, 9.4 power/shot,
effective range ≈1311u). Damage is per-ship (`SHIPS.<key>.gun_dmg`, Stage
1), scaled by `DAMAGE_SCALING` at the moment of the hit — the F-302's 4.7
lands as 4.7 against a fellow fighter, but 4.7 × 3.14 = 14.76 against a
capital-class hull hit *by* a capital, and only 4.7 × 0.047 = 0.221
when the F-302 itself is the one firing at a capital.

### Rockets — Area Denial (dumb-fire)

Slower (617.8), longer-lived (3.14s, ≈1940u range), reloads in 0.82s at
31.2 power/shot. Blast radius 97.4, falloff 0.37:

```
damage = base_dmg * (1 - (distance / blast_radius) * blast_falloff)
```

A direct hit (distance 0) lands the full scaled figure; a hit at the very
edge of the 97.4u ring still carries **63%** of it (`1 - 1.0*0.37`), not
zero — the formula is continuous across the boundary by design (see "The
falloff boundary bug," below). Past 97.4u the target takes nothing.

### Homing Missiles — Guided (Ancient drone tech)

Slowest player projectile (468.2) but the longest flight time (5.47s) and
a 1482.6u lock-on range — notably *shorter* than its own flight envelope
(468.2 × 5.47 ≈ 2561u), so a missile can physically outfly its own seeker
and needs a target before launch, never a hope of finding one in flight.
Splash radius 78.3, falloff 0.28 — gentler than a rocket's, same formula.

Two ships load more than one round per trigger pull: **Aurora fires 3**,
**Atlantis fires 6** (both drone-carrier doctrines); every other hull
fires 1. Baseline turn authority is 212.4°/s, adjusted by what it is
chasing: **+14% against a fighter** (a tight turn radius matters more
than raw agility once you're actually tracking something that small),
**−11% against a capital** (a big, slow hull needs less correction per
second to stay locked). A battlecruiser target gets the unmodified
baseline.

### Asgard Beam — Directed Energy (Daedalus & Phoenix only)

The only ships with a non-zero `beam_dmg` in Stage 1's `SHIPS` table are
Daedalus (2431) and Phoenix (3422); every other hull's `beam_dmg` is `0`,
which is what actually gates the weapon — `fire_beam()` returns `{hit:
false, effect: "no beam emitter"}` the moment `base_dps <= 0`, so no
separate ship-key check is needed for this one weapon.

Output ramps from 60% to 100% of `base_dps` over 1.42s of continuous
fire, held at 100% afterward:

```
frac(elapsed) = 0.6                                  elapsed <= 0
              = 0.6 + 0.4 * (elapsed / ramp_time)     0 < elapsed < ramp_time
              = 1.0                                   elapsed >= ramp_time
```

Then its **own** class table — not `DAMAGE_SCALING` — applies:
**2.8× vs fighter** (a single-emitter shield ring cannot dissipate a
coherent beam at all), **1.0× vs battlecruiser**, **0.64× vs capital** (a
distributed lattice sheds most of it, but not all). At max range
(942.7u) there is no falloff — a beam either reaches or it doesn't.

### Omni-Broadsides — Area Denial (broadside, Atlantis only)

The *same gun* as Primary Guns, fired through 8 rim ports as twin bolts
instead of one forward emitter — `WEAPONS.omni` carries no independent
damage figure; `fire_weapon("omni", "atlantis", ...)` resolves
`SHIPS.atlantis.gun_dmg` (16.3) itself, the same number Atlantis's own
primary gun would use. Everything ballistic is otherwise different:
faster (1187.4), shorter-lived (1.13s), much wider spread (4.3° vs the
primary's 1.9°), cheaper per bolt (8.7 vs 9.4) — sixteen simultaneous
bolts at the primary's own cost would be 150.4 power in one trigger pull,
more than the whole 1047-power reactor budget in seven pulls. Firing from
any hull but Atlantis returns `{hit: false, effect: "no omni ports"}`.

### Auto-Turrets — Point Defense (automated, Destiny only)

**Not** the same gun as Destiny's primary — Destiny carries both
independently. Five turrets, each a slower, shorter-ranged automated
cannon (938.6, range 642.8) doing 14.7 damage per shot on a 0.47s
cadence, at the cheapest energy cost of any weapon (4.2/shot) — point
defense has to be affordable to run continuously. The 14.7 figure lives
in `daedalus_weapons.nova` as a fixed literal, deliberately independent of
Destiny's own `gun_dmg` (11.1): two different weapon systems bolted to
the same hull. Firing from any hull but Destiny returns `{hit: false,
effect: "no turrets"}`.

## Damage scaling: the matrix, and the one exception

Every weapon except the beam reuses Stage 1's exact `DAMAGE_SCALING`
matrix, the same one Stage 2's hostiles pass through:

```
fighter -> battlecruiser   0.082        battlecruiser -> fighter   2.37
fighter -> capital         0.047        capital -> fighter         3.14
battlecruiser -> capital   0.74         capital -> battlecruiser   1.12
```

A fighter's own guns barely scratch a capital hull; a capital's own guns
are a one-shot kill against a fighter. The beam ignores this matrix
entirely and reads its own three-entry table instead (2.8× / 1.0× /
0.64×, above) — this is the sole place in the whole weapons stage where
"class effectiveness" does not mean "look up `DAMAGE_SCALING`."

## The falloff boundary bug

The rocket and homing splash formula's own comment promises "the edge of
the ring still carries 63% of a direct hit." The first implementation of
`falloff_damage()` checked `if distance >= radius { return 0.0 }` —
which meant a hit at *exactly* the blast radius silently jumped to zero
instead of the promised 63%, contradicting the file's own documentation.
Caught in self-review before any downstream test was written against it;
fixed by changing the guard to `if distance > radius { return 0.0 }` so
the boundary case falls through to the continuous formula. Verified
directly: `falloff_damage(100.0, 97.4, 97.4, 0.37)` now returns exactly
`63.0`; a hair past the boundary (`97.40001`) still correctly returns
`0.0`.

## Hot path vs. cold path

Firing a shot is bounded by a weapon's own cooldown (worst case ≈14/s for
the primary gun) — comparable to the reactor's 20 Hz tick, not a
per-frame hot loop, so `fire_weapon()` / `fire_ballistic()` / `fire_beam()`
are real NovaLang interpreter calls every time. A beam's damage-per-frame
and a splash hit's potential multi-victim falloff evaluation are
genuinely hot, so `weapons_bridge.gd` reimplements `beam_ramp_frac()`,
`beam_dps()` and `falloff_damage()` natively in GDScript, and its
`_self_check()` re-derives a sample of each against a fresh NovaLang call
at load time — any drift between the cached GDScript and the authority
file fails loudly instead of silently.

## Projectile lifecycle stays in Godot

Position/velocity integration, life countdown, collision detection,
on-hit particle sizing and rocket/homing smoke trails are not part of
this file or `fire_weapon()`'s contract — they are Godot's responsibility,
the same split established for the reactor's own physics loop.
`fire_weapon()` answers one question only: "did this shot land, for how
much, and what should the hit look like" — `{hit, damage_dealt, effect}`,
always exactly these three keys regardless of weapon type or outcome.

## Using it from Godot

```gdscript
# Raw tuning, no ship or class resolution:
var weapons := WeaponsBridge.new()
add_child(weapons)
weapons.load_weapons()
var rocket := weapons.projectile_stats("rocket")   # {velocity, lifetime, blast_radius, ...}
var turn := weapons.homing_turn_rate("fighter")     # 212.4 * 1.14

# Resolved combat: ship key + target class + range -> what lands.
var daedalus := DaedalusBridge.new()
add_child(daedalus)
daedalus.load_rules()
var shot := daedalus.fire_weapon("rocket", "daedalus", "fighter", 97.4)
print(shot.hit, shot.damage_dealt, shot.effect)     # true  175.44  "blast hit"

var beam := daedalus.fire_weapon("beam", "daedalus", "capital", 100.0, 1.42)
print(beam.effect)                                  # "absorbed"
```

## Verifying it

```bash
./tools/run_checks.sh
```

runs 32 new tests (146 total in the reference suite) covering every table
entry, the falloff boundary fix, the beam's own multiplier table, the
per-ship salvo overrides and turn-rate reactions, every gating rule
(beam/omni/turret), and the full `fire_weapon()` integration through
`daedalus_rules.nova`. The same samples are recorded as conformance
goldens and replayed inside Godot by `parity_check.gd` — the actual
shipping interpreter, not the reference, is what a real build depends on.
