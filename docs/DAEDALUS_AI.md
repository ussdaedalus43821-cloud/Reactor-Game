# Daedalus Stage 2 — Enemy AI

Six hostile archetypes, each with its own tuning table and its own
reaction to what the player is flying. `daedalus_ai.nova` is the
authority; `ai_bridge.gd` loads it, resolves and caches every
`(kind, player_class, hardened)` combination up front, and hands the
engine plain Dictionaries with no interpreter on the call path.

```
daedalus_ai.nova          ENEMY table + get_behavior()          <- authority
     │  (standalone load)                       │ (import "daedalus_ai.nova" as ai)
     ▼                                          ▼
ai_bridge.gd                          daedalus_rules.nova
  36 cached behaviors                   enemy_weapon_damage()
  get_behavior(kind, class, hard)       player_weapon_vs_enemy()
                                        enemy_behavior(kind, ship_key)
```

Two consumers, one source of truth. `ai_bridge.gd` is what a spawner calls
for raw AI tuning; `daedalus_rules.nova`'s three new functions are what
combat code calls when a number needs to cross from "enemy stat" to
"damage that lands on a specific player hull" — that crossing always goes
through Stage 1's `DAMAGE_SCALING` matrix, declared exactly once.

## The six archetypes

### Fighter — Skirmisher

A licensed hull, not a stolen one: roughly F-302-grade avionics on a
cheaper airframe (438.2 shield vs. the F-302's 397, 307.5 hull vs. 228). It
cannot win a straight fight with a real interceptor, so it never offers
one — it holds a standoff band (286–412u), strafes every 2.7–4.3s to deny
a firing solution, and bursts 2–4 rounds at a time on a 1.13–1.67s cycle.

**Reaction:** closes to 88% of its standoff against a capital-class player
(a heavy hull's point defense needs time to track something fighter-sized,
so pressing in denies it that time) and opens to 115% against a fellow
fighter (an even fight favors whoever fires first, so it declines to offer
one). A battlecruiser pilot gets neither adjustment — the baseline case.

### Capital — Brawler

No finesse: a heavy gun platform (17.3 per round, the hardest-hitting
direct-fire weapon in the registry) that closes to range and stays there
(58.4 max speed, 19.4 deg/s turn — the slowest hull in the game). Backed by
anti-fighter flak on a 2.7–4.1s cycle, independent of its 3-round main
battery on a 1.82–2.41s cycle.

**Reaction:** against a fighter, flak cadence tightens 18% — point defense
never stands down on something that small. Against a capital, the main
battery's burst cycle shortens 12% instead — a capital-scale target is a
direct-fire problem, not a point-defense one. The two reactions are
independent: pressing one never touches the other's cooldown.

### Wraith Dart — Dive-Bomber

Grown, not built. The lightest hull in the game by a wide margin (92.7
shield, 68.3 hull) paired with the highest speed and turn rate (587.2,
386.1) — it survives by never being where the last shot landed. It strafes
with a light cannon (5.1 dmg, 0.48–0.73s cycle) between commitments to a
full ram dive every 3.1–5.4s.

**Reaction:** a hardened shield lattice (Aurora, Atlantis — and *only*
those two) turns every dive away before it can connect, so against a
hardened target the Dart declines to dive at all and falls back to
circling at its own tight standoff (194–273u), working the cannon instead.
Against everything else, including Destiny — capital-class, but *not*
hardened — it dives on schedule. Ram damage itself scales with the
**square** of closing speed against the Dart's own 587.2 cap (kinetic
energy, not raw velocity), so a dive broken up early costs it most of the
payoff, not a proportional slice of it — full speed lands the nominal 26.4,
half speed lands 6.6, a quarter.

### Wraith Hive — Carrier

The one hostile that would rather not be found. Heaviest hull of anything
in the game, hostile or player-flown (5283.7 — within 11% of Atlantis's
own 5843), but barely mobile (42.3 max speed) and holds well outside gun
range (614–748u standoff) while launching Darts every 5.7–9.2s. Cross
inside half its minimum standoff (307u) and it stops trickling Darts out
one at a time and dumps all six stored in a single burst.

**Reaction:** none. A Hive's doctrine — launch from range, dump the bay if
approached — never depended on what's approaching, so it treats a fighter
and a capital identically. This is asserted, not just unimplemented: the
test suite checks that `get_behavior("hive", "fighter")` and
`get_behavior("hive", "capital")` return exactly equal Dictionaries.

### Replicator — Infestor

Deals no direct damage at all — `gun_dmg` is `0` by the brief's own
"(infest)" annotation. It wins by attrition: an infection bolt (fired every
1.72–2.31s) starts a countdown that only a hyperdrive jump or a hardened
shield stops. It breaks off and flees at a boosted 512u/s (33% over its own
384.6 cruise) the moment its hull drops under 30%, and always tries to
keep an ally between itself and the player rather than engage directly.

**Reaction:** a hardened shield (Aurora, Atlantis) blocks its bolts
outright. Rather than disengage entirely when that happens, it keeps
shadowing the fight from behind its allies — blocked against you costs it
nothing against everyone else on the scope.

### Ori — Beam Satellite

Immobile by the standards of anything else here (18.2 max speed, 11.7
deg/s turn — station-keeping numbers, not flight numbers) because it
doesn't need to move: a 1024–1318u standoff already outranges every other
hostile's engagement envelope. It telegraphs a 1.14s charge, then fires for
1.52s at 1547 damage per second — devastating to a fighter-scale shield,
survivable-but-threatening to a capital one — before a 2.14–2.63s recharge.

**Reaction:** charges 8% faster against a fighter (less time to break the
lock before the beam fires); hits 12% harder against a capital (its own
fire-control assumes a capital-scale target and scales the coupling up to
match). The two reactions are independent — pressing one never moves the
other number, matching the Brawler's design.

## Class assignment and damage scaling

Enemy class follows displacement, the same rule Stage 1 uses for player
hulls, and matches the original engine's own tier split exactly: Fighter,
Wraith Dart and the Replicator are **fighter**-class; Capital, the Wraith
Hive and the Ori satellite are **capital**-class. Nothing hostile is
built to the battlecruiser doctrine — only flown to it, by the player.

Every hostile gun figure passes through the *exact same*
`fighter → battlecruiser → capital` matrix from Stage 1 before it lands —
`enemy_weapon_damage(kind, defender_key)` in `daedalus_rules.nova` is the
one place a raw `ENEMY` number and a player ship's class actually meet, so
the matrix is declared once and reused, never duplicated:

```
Wraith Dart (fighter) gun vs Atlantis (capital):     5.1  × 0.047 = 0.240
Hostile Cruiser (capital) gun vs an F-302 (fighter): 17.3 × 3.14  = 54.32
F-302 (fighter) gun vs a Wraith Hive (capital):      4.7  × 0.047 = 0.221
```

A Dart barely scratches a city-ship; a single capital round is a fighter
kill. Two exceptions, both deliberate: **ram damage** and **infection**
are never run through this matrix — a collision doesn't care what
frequency a shield rejects, and an infestation tick isn't a directed-energy
weapon either. Both are either fully blocked by a hardened shield or land
at full, unscaled value.

## The hardened-shield distinction

`hardened` is a per-*ship* boolean (Stage 1's `SHIPS.<key>.hardened`), not
implied by class. **Aurora and Atlantis are hardened; Destiny is not**,
despite being capital-class like both of them — its shield is tuned for
micrometeorites over millennia, not for shrugging off a sustained weapons
pass. This is the distinction the brief calls out by ship name rather than
by class, and it is the one case in this whole stage with a dedicated,
by-name regression test in both the reference suite and the Godot-side
conformance replay:

```
enemy_behavior("dart", "atlantis")  -> dive_enabled = false   (hardened)
enemy_behavior("dart", "destiny")   -> dive_enabled = true    (capital, not hardened)
enemy_behavior("dart", "daedalus")  -> dive_enabled = true    (battlecruiser, baseline)
```

## Using it from Godot

```gdscript
var ai := AIBridge.new()
add_child(ai)
ai.load_ai()

# Raw tuning, no player-class reaction:
var stats := ai.stats("dart")              # {name, class, role, shield, hull, ...}

# Resolved behavior -- the number a spawner or an AI controller actually wants:
var behavior := ai.get_behavior("fighter", "capital")       # hardened defaults false
var dive := ai.get_behavior("dart", "capital", true)         # e.g. vs. Atlantis
print(dive.dive_enabled)                                     # false

# Ram damage at a given closing speed:
var dmg := ai.dart_ram_damage(current_speed)

# Damage crossing from an enemy to a named player hull goes through
# daedalus_bridge.gd (Stage 1), which reuses the same class matrix:
var daedalus := DaedalusBridge.new()
add_child(daedalus)
daedalus.load_rules()
var landed := daedalus.enemy_weapon_damage("dart", "atlantis")   # 0.240
var full_behavior := daedalus.enemy_behavior("dart", player_ship_key)
```

`get_behavior()` always returns the same 33 keys regardless of kind —
fields that don't apply to a given hostile (a Hive's `dive_cd`, a
Fighter's `beam_dps`) sit at a neutral `0`, `[0.0, 0.0]`, or `false` rather
than being absent, so a caller never has to check whether a field exists
before reading it.

## Verifying it

```bash
./tools/run_checks.sh
```

runs 40 new tests (114 total in the reference suite) that assert every
number in this document literally, every player-class reaction in both
directions, the full 36-combination uniform-shape sweep, and the
Destiny/Aurora/Atlantis distinction by name. The same 36 combinations plus
the `daedalus_rules.nova` integration seam are recorded as conformance
goldens and replayed inside Godot by `parity_check.gd` — the actual
shipping interpreter, not the reference, is what a real build depends on.
