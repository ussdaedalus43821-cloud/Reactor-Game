# Modding Daedalus

Every ship's stats, every hostile's AI, and every weapon's ballistics in
Daedalus are written in **NovaLang** — the same small scripting language
that runs Reactor Sim's control room, embedded here to run a space-combat
game instead. All of it lives in three plain text files under
`scripts_nova/`. Change one, save it, relaunch the game. No compiler, no
Godot rebuild.

This guide gets you from "never seen NovaLang" to "flying a ship you
invented" in about thirty minutes, then keeps going into the parts an
experienced modder wants: exactly which table holds which number, how
the AI's reactions to your ship class actually work, and precisely where
the line sits between "a text edit" and "you'd need to touch a GDScript
file too."

> **New to modding in general?** Read [Quick Start](#quick-start) first,
> then come back for the rest as you need it.

## Contents

- [What is NovaLang, and why mod in it?](#what-is-novalang-and-why-mod-in-it)
- [Installing and editing .nova files](#installing-and-editing-nova-files)
- [Where the files live](#where-the-files-live)
- [How mods load](#how-mods-load)
- [Safety and limitations](#safety-and-limitations)
- [Quick Start](#quick-start)
- [Inside daedalus_rules.nova](#inside-daedalus_rulesnova)
- [Inside daedalus_ai.nova](#inside-daedalus_ainova)
- [Inside daedalus_weapons.nova](#inside-daedalus_weaponsnova)
- [How to add a new ship](#how-to-add-a-new-ship)
- [How to add a new enemy archetype](#how-to-add-a-new-enemy-archetype)
- [How to balance weapons](#how-to-balance-weapons)
- [Example mods](#example-mods)
- [Modding examples: beginner to advanced](#modding-examples-beginner-to-advanced)
- [Troubleshooting](#troubleshooting)
- [Safety and ethics](#safety-and-ethics)

---

## What is NovaLang, and why mod in it?

NovaLang is a small scripting language, purpose-built for this project.
Daedalus embeds a full interpreter directly in Godot
(`scripts/nova/` — four GDScript files) and loads its three `.nova`
files as plain text the moment the game starts. There's no separate
"compile the mod" step — the interpreter parses the text itself, every
launch.

**Why not a JSON stat sheet?** Because a huge part of what makes
Daedalus feel the way it does isn't just numbers, it's *reactions* — a
Wraith Dart checks whether your shield is hardened before it decides to
ram you; a Brawler cruiser tightens its point-defense cadence
specifically against a fighter-class target; a rocket's blast damage
falls off smoothly with distance instead of being all-or-nothing. JSON
can hold `"gun_dmg": 4.7`. It can't hold "and open the range 15% if the
player is also flying a fighter." NovaLang can, in the same file as the
number.

**Why not just edit the GDScript?** You technically could — nothing
stops you from opening `scripts/player.gd` or `scripts/enemy.gd` in a
text editor, and this guide even shows you the couple of places where a
genuinely new *behavior* (not just new numbers) needs a small touch
there. But GDScript isn't sandboxed, and a mistake in it can crash the
whole game or corrupt state in ways that are hard to diagnose. NovaLang
mods, by contrast, either load correctly or fail to load with a clear
error — they can't half-break the game. That's why every stat table,
every damage formula, and every AI reaction lives in NovaLang, and
GDScript is only ever touched for the small number of things described
in this guide as needing it.

---

## Installing and editing .nova files

Any plain text editor works. **VS Code** (free,
[code.visualstudio.com](https://code.visualstudio.com/)) is the
recommended choice on every platform — set a `.nova` file's language
mode (bottom-right corner) to **JavaScript** or **Rust** for decent
highlighting; there's no dedicated NovaLang syntax mode, but either of
those lights up comments, strings and numbers correctly.

If you're on macOS and tempted to use TextEdit: turn off "smart quotes"
in Preferences → General first, or every `"string"` in the file will
silently become curly quotes NovaLang can't parse. Whatever you use,
save as **plain text** and keep the `.nova` extension.

---

## Where the files live

```
daedalus_godot/
├── project.godot                  the actual game project — open this in Godot
├── scripts_nova/                  <-- every file you're modding lives here
│   ├── daedalus_rules.nova        ships, damage scaling, power, sectors, the live advisor
│   ├── daedalus_ai.nova           the six hostile archetypes and their reactions
│   ├── daedalus_weapons.nova      the six weapon systems: ballistics, energy, falloff
│   └── lib/
│       └── combat.nova            small shared helpers (threat scoring) -- rarely needs edits
├── scripts/                       GDScript -- the game engine itself, not sandboxed
│   ├── daedalus_bridge.gd         loads the three files above into the game
│   ├── player.gd / enemy.gd / ... the parts of the guide below that touch GDScript point here
│   └── nova/                      the NovaLang interpreter itself
└── MODDING_DAEDALUS.md            this file
```

Three `.nova` files, one composition relationship between them:
`daedalus_rules.nova` **imports** the other two
(`import "daedalus_ai.nova" as ai` and
`import "daedalus_weapons.nova" as weapons`), so a ship's damage
against a hostile, or a weapon's falloff curve, is only ever declared
once and reused everywhere it's needed. You will spend most of your
time in `daedalus_rules.nova` (ships, sectors) and
`daedalus_ai.nova` (enemy behavior); `daedalus_weapons.nova` is smaller
and mostly about numbers, not reactions.

---

## How mods load

There is no mod manager or load order. `daedalus_bridge.gd` is loaded
once, automatically, the instant the game starts (it's what Godot calls
an "autoload" — it exists before the title screen even appears), and it
reads all three `.nova` files from disk at that moment:

1. Edit a file in `scripts_nova/`.
2. Save it.
3. Launch (or relaunch) the game.

If a file has a syntax error, or is missing a value the game requires
(see [Safety and limitations](#safety-and-limitations) below on the
self-check), the game does not silently run broken numbers — it prints
a clear error to Godot's output console and refuses to start the run.
Fix the error it names and try again.

**A note specific to Daedalus:** because `daedalus_bridge.gd` loads
once at boot and then stays alive for the entire session (including
trips back to the title screen, mid-run pauses, and "Resume"), you do
need to fully **restart the game** — not just return to the title
screen — for an edited `.nova` file to be re-read. Quit to your desktop
and relaunch.

---

## Safety and limitations

NovaLang is **sandboxed by design**: numbers, strings, lists, dicts,
`if`/`while`, functions, and a fixed set of about 30 built-in functions
(the complete list is in
[`../docs/NOVALANG.md`](../docs/NOVALANG.md)). There is:

- **no file system access** — a `.nova` file can't read or write
  anything on your computer;
- **no network access** — no sockets, no HTTP;
- **no way to call the operating system**;
- **no way to affect anything outside the game.** The only things a
  `.nova` file can do are call NovaLang functions declared in these
  same three files, or the builtins — Daedalus doesn't register any
  host functions at all beyond what the advisor rule engine uses
  internally (`log`/`alarm`, mirroring Reactor Sim's own pattern).

Two guards keep a broken mod from hanging the game: a **500,000-step
budget** per interpreter call, and a **128-frame call-depth** limit for
recursion. Both turn a runaway mistake into an error, not a freeze.

**Daedalus also self-checks its own cache at load time.** Every number
`daedalus_bridge.gd` reads out of your `.nova` files gets cross-checked
against a fresh call into the interpreter the moment the game starts
(`DaedalusBridge._self_check()`), and it fails loudly — a clear error in
Godot's output console — if anything doesn't match or is missing. In
practice, this means: **if you add a new ship, it must have every one
of the eight required stats** (see
[How to add a new ship](#how-to-add-a-new-ship)) **or the game refuses
to start**, rather than silently treating a missing stat as zero. This
is a feature, not a bug — a fighter that silently has 0 hull because you
forgot a field is a much worse experience than an error telling you
exactly what's missing.

**Bottom line: the worst a bad Daedalus mod can do is fail to load, or
make the game unbalanced.** It cannot touch anything outside the game
itself.

---

## Quick Start

1. **Open a file in `scripts_nova/` in any text editor.** Start with
   `daedalus_rules.nova` if you're not sure which one you need.
2. **Find the value you want to change.** Ship stats and sectors are in
   `daedalus_rules.nova`; enemy behavior is in `daedalus_ai.nova`;
   weapon numbers are in `daedalus_weapons.nova`.
3. **Change it and save.**
4. **Launch the game** — your mod is active from the moment the title
   screen appears. If something's wrong, the console will say so.

---

## Inside daedalus_rules.nova

This is the composition root: it owns the ship registry, the class
damage matrix, the power budget, the sector table, and it imports the
other two files to build the fully-resolved gameplay functions
(`fire_weapon`, `enemy_behavior`, and so on).

### SHIP_ORDER and SHIPS

```nova
let SHIP_ORDER = ["x302", "daedalus", "phoenix", "aurora", "destiny", "atlantis"]

let SHIPS = {
    x302: {
        name: "F-302 Fighter",
        class: "fighter",
        shield: 397,
        hull: 228,
        speed: 1142,
        turn: 348,
        gun_dmg: 4.7,
        rocket_dmg: 74.2,
        homing_dmg: 55.3,
        beam_dmg: 0,
        hardened: false,
    },
    # ... daedalus, phoenix, aurora, destiny, atlantis
}
```

Every ship needs exactly these nine fields — `name`, `class` (one of
`"fighter"`, `"battlecruiser"`, `"capital"`), `shield`, `hull`, `speed`
(u/s), `turn` (deg/s), `gun_dmg`, `rocket_dmg`, `homing_dmg`, `beam_dmg`
(`0` for a hull with no beam emitter), and `hardened` (`true` only for
Aurora and Atlantis — a distributed shield lattice with no single
saturation point; it changes how two of the six enemy archetypes react
to you, see [Inside daedalus_ai.nova](#inside-daedalus_ainova)). Miss
one and the self-check refuses to start the game, naming exactly which
ship and field.

### DAMAGE_SCALING

```nova
let DAMAGE_SCALING = {
    fighter:       { battlecruiser: 0.082, capital: 0.047 },
    battlecruiser: { fighter: 2.37,        capital: 0.74  },
    capital:       { fighter: 3.14,        battlecruiser: 1.12 },
}
```

Read as `DAMAGE_SCALING[attacker_class][defender_class]`. Any pair not
listed (including same-class fights) defaults to `1.0` — a
fighter-vs-fighter or capital-vs-capital fight needs no correction. This
is **the single matrix every weapon except the beam runs through** —
change a number here and it affects every ship and every weapon at
once, which is exactly why it's declared once, in this one place.

### POWER

```nova
let POWER = {
    max: 1047, recharge: 112, shield_draw: 143,
    thrust_drain: 48, cloak_drain: 27,
    primary_cost: 9.4, rocket_cost: 31.2, homing_cost: 22.7,
}
```

The reactor bus every ship shares. `recharge` is what you get back per
second; everything else is a drain while that system is active.
Notice `shield_draw` (143) is *higher* than `recharge` (112) — rebuilding
shields is never free, by design.

### DANGER and SECTORS

```nova
let DANGER = [
    { base: 0,  per_gen: 0 },     # index 0: safe, never spawns
    { base: 4,  per_gen: 0.8 },   # index 1
    { base: 9,  per_gen: 1.3 },   # index 2
    { base: 15, per_gen: 2.1 },   # index 3
]
```

`base` is ambient hostiles the instant you arrive; `per_gen` is more
hostiles added per minute survived (`gen`). A sector's `danger` field
indexes into this array. **You can add a fifth band (index 4) for an
extreme sector** — the game reads `danger_bands.size()` dynamically
rather than assuming exactly four exist, so this works with no other
changes. See [The Void](#new-sector-the-void) below for a worked
example.

```nova
let SECTORS = [
    { key: 1, name: "Terra Nova Orbit  //  HOME", danger: 0, spawns: false,
      capital_chance: 0.0, charge: 1.2, travel: 2.0,
      fighter_cd: [6.0, 11.0], mix: [] },
    # ... nine more, keys 0 and 2-9
]
```

`key` is the digit the player presses to jump there (0–9). `charge` and
`travel` are hyperdrive spool-up and transit time in seconds. `mix` is
an optional weighted list of hostile kinds for that sector's ambient
spawns (`[["fighter", 5], ["capital", 1]]` — a sector with an empty
`mix` uses the spawner's own default blend). `unique` (optional) names
one kind that gets an extra chance to appear regardless of the mix — the
Asuran Frontier's `unique: "replicator"` is why that sector always feels
like it has more replicators around than its `mix` alone would suggest.

### The composed functions

`daedalus_rules.nova` also declares the functions gameplay actually
calls, each one composing data from possibly more than one file:
`fire_weapon(weapon_type, attacker_key, target_class, distance, elapsed)`
resolves a shot; `enemy_behavior(kind, player_key)` resolves what a
hostile does against your specific ship; `damage_multiplier`,
`ship_stat`, `hostiles_for`, and a dozen smaller accessors sit
underneath both. You generally don't need to touch these — they're
where the *data* you edit elsewhere gets assembled — but reading
through them is the fastest way to understand how a number in `SHIPS`
ends up as damage on screen.

---

## Inside daedalus_ai.nova

Six hostile archetypes, each with a tuning table (`ENEMY`) and a
behavior-resolution function that reacts to what the player is flying.

### ENEMY and ENEMY_ORDER

```nova
export let ENEMY_ORDER = ["fighter", "capital", "dart", "hive", "replicator", "ori"]

export let ENEMY = {
    fighter: {
        name: "Hostile Fighter", class: "fighter", role: "Skirmisher",
        shield: 438.2, hull: 307.5, max_speed: 312.7, turn_rate: 204.8,
        gun_dmg: 6.2, score: 104,
        keep_dist: [286.0, 412.0], engage_range: [783.0, 912.0],
        fire_cd: [1.13, 1.67],
        strafe_interval: [2.7, 4.3], burst_min: 2.0, burst_max: 4.0,
    },
    # capital (Brawler), dart (Dive-Bomber), hive (Carrier),
    # replicator (Infestor), ori (Beam Satellite) -- each with its own
    # extra fields (dive_cd/ram_dmg_base for dart, spawn_cd/release_range/
    # max_stored for hive, flee_hull_frac/flee_speed for replicator,
    # charge_time/fire_time/beam_dps for ori)
}
```

Every archetype shares `name`, `class`, `role`, `shield`, `hull`,
`max_speed`, `turn_rate`, `gun_dmg`, `score`, `keep_dist` (the standoff
band it tries to hold), `engage_range`, and `fire_cd`. Beyond that, each
kind carries whatever extra fields its own behavior needs — a Dart has
`ram_dmg_base`, a Hive has `spawn_cd`/`max_stored`, and so on. `[min, max]`
pairs are ranges — the game rolls its own random value inside that band
per spawn, so the *tuning* stays deterministic even though individual
fights don't.

### Behavior functions — where reactions live

Each kind has a `_<kind>_behavior(...)` function that reads the raw
`ENEMY` table and reacts to the player. The Skirmisher (fighter) is the
simplest one to read:

```nova
func _fighter_behavior(player_class) {
    let b = _base_behavior("fighter")
    let kd = ENEMY.fighter.keep_dist
    let note = "holds its lane"
    if player_class == "capital" {
        kd = _scaled(kd, 0.88)
        note = "presses 12% closer -- your point defense needs time to track it"
    }
    if player_class == "fighter" {
        kd = _scaled(kd, 1.15)
        note = "opens the range 15% -- an even fight favors whoever fires first"
    }
    b.keep_dist = kd
    b.strafe_interval = ENEMY.fighter.strafe_interval
    b.burst_min = ENEMY.fighter.burst_min
    b.burst_max = ENEMY.fighter.burst_max
    b.tactical_role = "Skirmisher: " + note
    return b
}
```

This is the pattern every archetype follows: start from
`_base_behavior(kind)` (fills in the shared fields with safe zero
defaults for anything this kind doesn't use), read whatever
`ENEMY.<kind>` fields this behavior cares about, adjust them based on
`player_class` (and, for the Dart and Replicator, `player_hardened`),
and set `tactical_role` to a human-readable note (this string shows up
in the game's own tools and logs — keep it accurate to what you changed
if you edit the logic). `get_behavior(kind, player_class, player_hardened)`
at the bottom of the file is the single dispatch point that routes to
whichever `_<kind>_behavior()` matches.

**The `hardened` distinction matters here specifically:** the Dart
declines to dive on a hardened target (Aurora, Atlantis) and the
Replicator's infection bolts are blocked outright by one — both read
`player_hardened`, not `player_class`, because Destiny is capital-class
but *not* hardened, and both reactions are keyed to the shield lattice,
not the hull's size.

---

## Inside daedalus_weapons.nova

Six weapon systems (`primary`, `rocket`, `homing`, `beam`, `omni`,
`turret`), ballistics-only — no ship key or class knowledge lives here
at all (that composition happens in `daedalus_rules.nova`, which is why
this file can be edited for pure ballistics tuning with zero risk of
breaking which ship can fire what).

```nova
export let WEAPONS = {
    primary: {
        name: "Primary Guns", role: "Direct Fire",
        velocity: 1024.3, lifetime: 1.28, cooldown: 0.073,
        spread_deg: 1.9, energy_cost: 9.4, projectile_radius: 2.7,
    },
    rocket: {
        # ... velocity, lifetime, cooldown, energy_cost, projectile_radius,
        blast_radius: 97.4, blast_falloff: 0.37,
    },
    # homing, beam, omni, turret
}
```

Per-ship *damage* (`gun_dmg`, `rocket_dmg`, etc.) stays in `SHIPS`, not
here — this file only owns what doesn't vary by which ship is firing:
muzzle velocity, flight time (`lifetime`), cadence (`cooldown`), spread,
energy cost, and collision radius. Two shaping curves matter beyond raw
numbers:

**Blast/splash falloff** (rockets and homing missiles):

```nova
func falloff_damage(base_dmg, distance, radius, falloff) {
    if radius <= 0.0 { return base_dmg }
    if distance > radius { return 0.0 }
    let ratio = distance / radius
    return base_dmg * (1.0 - ratio * falloff)
}
```

A direct hit takes full damage; a hit at the very edge of `radius`
still takes `1.0 - falloff` of it (with the rocket's own `blast_falloff`
of `0.37`, that's 63%) — raise `blast_falloff` toward `1.0` to make the
edge of a blast nearly harmless, or lower it toward `0.0` to make the
whole radius almost as deadly as a direct hit.

**Beam ramp and its own class table** (the one weapon that does *not*
use `DAMAGE_SCALING`):

```nova
beam: {
    ramp_time: 1.42, max_range: 942.7, energy_drain: 26.4, min_energy: 5.2,
    class_multiplier: { fighter: 2.8, battlecruiser: 1.0, capital: 0.64 },
}
```

Output ramps from 60% to 100% of `base_dps` over `ramp_time` seconds of
continuous fire, then applies `class_multiplier` — a fighter can't shed
a coherent beam at all (2.8×), a capital's distributed lattice sheds
most of it (0.64×). This table is a deliberate, documented exception to
the general damage matrix; edit it directly if you want to rebalance
the beam specifically, and leave `DAMAGE_SCALING` in
`daedalus_rules.nova` alone if you do — they're intentionally separate.

---

## How to add a new ship

1. Open `daedalus_rules.nova`.
2. Add your ship's key to `SHIP_ORDER`.
3. Add a matching entry to `SHIPS` with all nine required fields (see
   [SHIP_ORDER and SHIPS](#ship_order-and-ships) above). Base the
   numbers on an existing ship of the class you want, then adjust.
4. Save and launch. Your ship is now selectable from the Ship Select
   screen and fully statted — damage scaling, power costs, and weapon
   resolution all pick it up automatically because they all read from
   `SHIPS` by key, never by a hardcoded list of names.

That's the complete, pure-NovaLang path. **Visual polish is optional and
lives in GDScript:** `scripts/player.gd` has a `HULL_COLORS` dictionary
keyed by ship key (falls back to white if your new key isn't in it) and
a `_hull_shape_for(class)` function that picks a silhouette by class
(fighter/capital/default). Adding a line to `HULL_COLORS` is still just
editing a text file and relaunching — no compiler — but it is GDScript,
not NovaLang, so a typo there can produce a real error rather than a
clean "missing field" message. If you skip this step entirely, your new
ship still works correctly, just in white.

---

## How to add a new enemy archetype

This is the one place in Daedalus modding where it matters a lot
**which** kind of "new" you mean, so read both cases before you start.

### Retuning an existing archetype (100% NovaLang, always safe)

If "new enemy" means "a different-feeling Skirmisher, Brawler, Dive-
Bomber, Carrier, Infestor, or Beam Satellite" — just edit its numbers in
`ENEMY` and, if you want to change *how* it reacts to player class or
hardened shields, edit its `_<kind>_behavior()` function directly. This
never touches GDScript and can't break anything beyond in-game balance.

### Adding a genuinely new, independently-named archetype

To add a **seventh** archetype — a new name, not a retuned existing one
— that actually fires and moves distinctly in-game, you need two
NovaLang additions and **one line of GDScript**, because the game's
firing/spawning logic (`scripts/enemy.gd`) dispatches on the kind name
too, and it only recognizes the original six:

1. **In `daedalus_ai.nova`:** add your kind to `ENEMY_ORDER` and `ENEMY`
   (same required fields as any archetype, plus whatever your behavior
   needs), copy the `_<kind>_behavior()` function closest to what you
   want (e.g. `_fighter_behavior` for a burst-firing skirmisher-style
   unit), rename it, point its `ENEMY.fighter` references at
   `ENEMY.<your_kind>` instead, and add a branch for it in
   `get_behavior()`:
   ```nova
   func get_behavior(kind, player_class, player_hardened) {
       let k = resolve_kind(kind)
       if k == "fighter"        { return _fighter_behavior(player_class) }
       if k == "your_new_kind"  { return _your_new_kind_behavior(player_class) }
       # ... the other five, unchanged
       return null
   }
   ```
2. **In `scripts/enemy.gd`:** find `_tick_timers()`'s `match kind:`
   block and add your kind's name to whichever case reuses the firing
   pattern you want (the handler functions read generically from the
   resolved behavior dictionary — they're not hardcoded to specific kind
   names — so this really is one line):
   ```gdscript
   match kind:
       "fighter", "your_new_kind":
           _handle_burst_fire(delta, target)
       "capital":
           _handle_burst_fire(delta, target)
           _handle_flak(delta, target)
       # ...
   ```

Skip step 2 and your new archetype spawns, has correct stats, and moves
(the orbit/standoff movement logic is fully generic and needs no
per-kind wiring) — it just never fires or does anything else, silently.
See [Troubleshooting](#troubleshooting) if that's what you're seeing.

---

## How to balance weapons

Everything is in `daedalus_weapons.nova`'s `WEAPONS` table, per weapon
type:

| Field | Meaning |
|---|---|
| `cooldown` | Seconds between shots. Lower = faster trigger. |
| `energy_cost` (or `energy_cost_per_bolt`, `energy_drain`) | Power spent per shot, or per second for the beam. |
| `velocity` / `lifetime` | Together set effective range (`velocity × lifetime`) for anything without an explicit `acquire_range`/`max_range`/`range`. |
| `projectile_radius` | Collision size — bigger is easier to hit with. |
| `spread_deg` | Muzzle inaccuracy, in degrees. |
| `blast_radius` / `blast_falloff`, `splash_radius` / `splash_falloff` | Area-damage shape; see [falloff](#inside-daedalus_weaponsnova) above. |

**Damage itself is not in this file** for the five per-ship weapons
(primary/rocket/homing/omni/turret draw from `SHIPS.<key>.gun_dmg` /
`.rocket_dmg` / `.homing_dmg`, or Atlantis's `gun_dmg` for omni) — to
change how hard a *specific ship's* gun hits, edit `SHIPS` in
`daedalus_rules.nova`, not `WEAPONS`. The one exception is
`turret.damage` (14.7, a fixed value — Destiny's automated point-defense
guns are a separate system from its own primary cannon, deliberately not
derived from any ship's stats) and the beam, whose `base_dps` comes from
`SHIPS.<key>.beam_dmg`.

**If you add a genuinely new field** to a weapon's table (not one of the
existing ones), you also need to add its name to `WEAPON_FIELDS` in
`scripts/daedalus_bridge.gd` — the self-check treats an unrecognized
field as an error on purpose, so a typo'd field name gets caught at
launch instead of silently doing nothing.

---

## Example mods

### New ship: "Wraith Cruiser" (an enemy hull, made playable)

Take the existing Brawler's stats from `daedalus_ai.nova`'s `ENEMY.capital`
entry and give the player a hull built from the same numbers:

```nova
# In daedalus_rules.nova:
let SHIP_ORDER = ["x302", "daedalus", "phoenix", "aurora", "destiny", "atlantis", "wraith_cruiser"]

let SHIPS = {
    # ... the original six, unchanged ...

    wraith_cruiser: {
        name: "Wraith Cruiser",
        class: "capital",
        shield: 1538.2,       # ENEMY.capital's shield, rounded
        hull: 3172.8,         # ENEMY.capital's hull
        speed: 300.0,         # faster than the AI's own 58.4 -- a player
                               # flying it needs to actually maneuver, an
                               # AI holding position at gunrange does not
        turn: 90.0,           # sluggish, matching the AI's 19.4 in spirit
                               # without being genuinely unplayable
        gun_dmg: 17.3,         # ENEMY.capital's own gun_dmg
        rocket_dmg: 160.0,     # no AI rocket stat to copy -- estimated
                               # in line with other capitals (134.8-186.5)
        homing_dmg: 0,         # the Brawler has no drone bay
        beam_dmg: 0,
        hardened: false,       # Wraith tech, not Ancient/Lantean lattice
    },
}
```

Note the two numbers changed from the AI's own values (`speed`, `turn`)
— an AI hostile that never needs to dodge can be nearly stationary, but
that's unplayable for a human. This is the general rule whenever you
"promote" a hostile stat block to a player ship: copy the combat stats
(shield, hull, gun_dmg) verbatim, but sanity-check the mobility stats
against what a human needs to actually fly.

### New enemy: "Replicator Carrier" (spawns infestation-flavored escorts)

A Hive-style carrier that launches Replicator-kind escorts instead of
Darts. This is the "seventh archetype" case from
[How to add a new enemy archetype](#how-to-add-a-new-enemy-archetype)
above, so it needs the one GDScript touch too.

**In `daedalus_ai.nova`:**

```nova
export let ENEMY_ORDER = ["fighter", "capital", "dart", "hive", "replicator", "ori", "replicator_carrier"]

export let ENEMY = {
    # ... the original six ...

    replicator_carrier: {
        name: "Replicator Carrier", class: "capital", role: "Carrier",
        shield: 2800.0, hull: 6000.0, max_speed: 40.0, turn_rate: 14.0,
        gun_dmg: 12.0, score: 7000,
        keep_dist: [650.0, 800.0], engage_range: [1200.0, 1400.0],
        fire_cd: [2.3, 3.0],
        spawn_cd: [6.0, 10.0], release_range: 320.0, max_stored: 6.0,
    },
}

func _replicator_carrier_behavior(player_class) {
    let b = _base_behavior("replicator_carrier")
    b.spawn_cd = ENEMY.replicator_carrier.spawn_cd
    b.release_range = ENEMY.replicator_carrier.release_range
    b.max_stored = ENEMY.replicator_carrier.max_stored
    b.prioritize_distance = true
    b.tactical_role = "Carrier: launches Replicator escorts instead of Darts"
    return b
}

# In get_behavior()'s dispatch, add:
#   if k == "replicator_carrier" { return _replicator_carrier_behavior(player_class) }
```

**In `scripts/enemy.gd`:** the Hive's own spawn handler
(`_handle_hive_spawn()`/`_spawn_dart()`) hardcodes `"kind": "dart"` for
what it launches. Generalize it to read the escort kind from the
behavior dictionary instead, defaulting to `"dart"` so the original Hive
is unaffected:

```gdscript
# In _spawn_dart(), change:
    "kind": "dart",
# to:
    "kind": String(behavior.get("spawn_kind", "dart")),
```

Then add `spawn_kind: "replicator"` to the Carrier's fields in both the
`_base_behavior()` neutral-defaults dict (as `spawn_kind: "dart"`, so
every other archetype is unaffected) and to
`_replicator_carrier_behavior()`'s return value (`b.spawn_kind =
"replicator"`), and add `"replicator_carrier"` to `enemy.gd`'s
`match kind:` under the `"hive"` case so it actually runs the spawn
logic:

```gdscript
match kind:
    "hive", "replicator_carrier":
        _handle_hive_spawn(delta, target)
```

This is the most GDScript-heavy example in this guide on purpose — it's
here to show exactly how far "just a text-file mod" extends, and
precisely where it stops.

### New sector: "The Void"

```nova
# In daedalus_rules.nova, extend DANGER with a fifth band:
let DANGER = [
    { base: 0,  per_gen: 0 },
    { base: 4,  per_gen: 0.8 },
    { base: 9,  per_gen: 1.3 },
    { base: 15, per_gen: 2.1 },
    { base: 24, per_gen: 3.0 },   # index 4: danger 4, worse than anything else
]

# Add to SECTORS (reuse an unused digit, or replace one you don't want):
{
    key: 4, name: "The Void  //  UNCHARTED",
    danger: 4, spawns: true, capital_chance: 0.6,
    charge: 3.5, travel: 7.0,
    fighter_cd: [1.0, 2.0], mix: [],
},
```

Danger band 4 (24 hostiles on arrival, 3 more per minute) is a pure data
addition — the game reads however many bands exist, so this works with
no other changes. **"All enemies spawn at double speed" is the one part
of this mod that needs a small GDScript touch**, because per-enemy
`max_speed` is a global stat in `ENEMY`, not something scoped to a
sector — doubling it in `daedalus_ai.nova` would double every hostile's
speed in *every* sector, not just this one. To scope it to The Void
specifically, add a one-line multiplier where hostiles are spawned, in
`scripts/game.gd`'s `_spawn_hostile()`:

```gdscript
func _spawn_hostile(kind: String) -> void:
    # ... existing setup ...
    e.setup({"kind": kind, "faction": "hostile", "player_key": player.ship_key, "position": pos})
    if sector_key == 4:   # The Void
        e.max_speed *= 2.0
```

Everything else about the sector — its danger scaling, its hyperdrive
cost, its capital-ship odds — is ordinary `.nova` data.

---

## Modding examples: beginner to advanced

**Beginner — double the Daedalus's shield strength:**

1. Open `daedalus_rules.nova`.
2. Find `daedalus: { ... shield: 1583, ... }` inside `SHIPS`.
3. Change `1583` to `3166`.
4. Save, relaunch. The Daedalus now has twice its original shield —
   nothing else needed to change, since every place shield is read
   (the HUD bar, `take_damage()`'s absorb-then-hull logic) just reads
   whatever number is in `SHIPS`.

**Intermediate — add a new enemy type (retuned, not a new name):**

Retuning is the far more common "new enemy" request in practice, and
it's just a numbers edit. Open `daedalus_ai.nova`, find the archetype
closest to what you want (say, a faster, glassier version of the
Skirmisher), and change its `ENEMY.fighter` numbers directly:

```nova
fighter: {
    # ...
    shield: 250.0,      # down from 438.2 -- glassier
    max_speed: 450.0,   # up from 312.7 -- faster
    # everything else unchanged
},
```

If you want it to coexist *alongside* the original Skirmisher as a
second, independently-spawnable kind rather than replacing it, that's
the "genuinely new archetype" path — see
[How to add a new enemy archetype](#how-to-add-a-new-enemy-archetype)
above, which needs the one line of GDScript.

**Advanced — writing custom AI behavior:**

The six existing `_<kind>_behavior()` functions are the complete
reference for what's possible: reading `player_class` and
`player_hardened`, scaling ranges (`_scaled()`), and returning a
`tactical_role` string. A genuinely novel *reaction* — not just new
numbers — is written the same way: an `if` on whatever inputs you want
to react to, setting fields on the behavior dictionary you return. For
example, a hostile that gets bolder specifically against a *cloaked*
player isn't currently possible, because `get_behavior()` only ever
receives `player_class` and `player_hardened` — extending it to also
receive a `player_cloaked` boolean would mean changing the function
signature in `daedalus_ai.nova` **and** the one call site in
`daedalus_rules.nova`'s `enemy_behavior()` **and** the GDScript call
site in `scripts/enemy.gd` that resolves behavior at spawn time — three
coordinated edits across two languages. This is the deep end of
Daedalus modding: still no engine rebuild, but no longer "just NovaLang"
either, and worth attempting only once the simpler patterns in this
guide feel comfortable.

---

## Troubleshooting

**The game refuses to start, with an error naming a ship, weapon, or
enemy kind.** This is the self-check catching a missing required field
— the error names exactly which key and which field. Go back to
[How to add a new ship](#how-to-add-a-new-ship) (or the enemy/weapon
equivalent) and make sure every required field is present.

**Syntax errors** (mismatched braces, missing commas, smart quotes from
a word processor) behave exactly as in Reactor Sim — see that game's
[`MODDING_REACTOR.md`](../MODDING_REACTOR.md#troubleshooting) for the
detailed walkthrough and the validator command; the same
`.nova` syntax and the same failure modes apply here.

**My new enemy archetype spawns but never fires or does anything
special.** You added a new kind name to `ENEMY_ORDER`/`ENEMY` and
`get_behavior()` but skipped the GDScript step in
[How to add a new enemy archetype](#how-to-add-a-new-enemy-archetype) —
`scripts/enemy.gd`'s `match kind:` doesn't recognize your new name, so
it falls through and does nothing beyond generic movement. Add your
kind's name to the appropriate case.

**Values out of range.** A few specific traps:

- `shield`/`hull` in the tens of thousands makes a ship or hostile
  functionally unkillable with the game's current weapon damage
  figures (all in the single or double digits per shot, low hundreds
  for rockets) — there's no hard cap, but balance breaks down well
  before five figures.
- `blast_falloff` or `splash_falloff` above `1.0` makes the *edge* of a
  blast radius deal *negative* damage, which `falloff_damage()` will
  compute but which then gets fed into `take_damage()` as a negative
  number — check `take_damage()`'s guard (`amount <= 0.0` is ignored)
  before assuming this "heals" anyone; in practice it's just wasted
  damage, not a healing exploit, but it's still not what you meant.
- `cooldown` of `0.0` fires every single physics frame — extremely high
  effective fire rate, not an error, but rarely the intended balance.
- A ship's `class` set to anything other than `"fighter"`,
  `"battlecruiser"`, or `"capital"` degrades to a neutral `1.0` damage
  multiplier in every matchup (see `DAMAGE_SCALING`'s own fallback) —
  not a crash, just quietly not what you meant.

**Reverting to the original files.**

- **With git:**
  ```bash
  git checkout -- daedalus_godot/scripts_nova/
  ```
- **Without git:** copy the whole `scripts_nova/` folder somewhere safe
  before you start modding. If something breaks, delete your edited
  copy and restore the backup. Only the exact filenames
  `daedalus_rules.nova`, `daedalus_ai.nova`, and `daedalus_weapons.nova`
  are ever loaded, so backup copies with any other name or extension
  sitting in the same folder are always safe and ignored by the game.

---

## Safety and ethics

- **NovaLang cannot access your file system or network** — see
  [Safety and limitations](#safety-and-limitations) above for exactly
  what it *can* do, which is a short, fixed list.
- **A mod can only affect the game it's loaded into.** The worst outcome
  of running someone else's `.nova` files is an unbalanced or broken
  *game* — not your computer or your other files. (The one caveat: if a
  shared mod also asks you to replace a `.gd` file, as the GDScript-
  touching examples in this guide do, treat that with the same caution
  you'd give any code from a stranger — read it before you run it.
  NovaLang's sandbox guarantee doesn't extend to GDScript.)
- **Share mods responsibly.** Say plainly what a mod changes, especially
  if it's a large balance shift — a "Wraith Cruiser" that's dramatically
  stronger than every original ship is a fair thing to build, but it's
  a "cheat ship," not a "new ship," if you don't say so. Crediting the
  original numbers and archetypes you built on top of is good community
  practice.

---

For every value not covered above, and for a side-by-side reference
with Reactor Sim's own moddable numbers, see
[`../MODDING_QUICKREF.md`](../MODDING_QUICKREF.md). For the full
language syntax, see [`../docs/NOVALANG.md`](../docs/NOVALANG.md). For
how the game's Godot side is put together (useful background for the
GDScript-touching examples above), see this project's own
[`README.md`](README.md).
