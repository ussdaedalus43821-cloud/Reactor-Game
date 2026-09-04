# Daedalus

A space-combat game whose ship stats, enemy AI and weapons logic are all
written in NovaLang — the same language and interpreter built for this
repository's Reactor Sim, embedded here as plain GDScript
(`scripts/nova/`) with no Python and no `OS.execute` anywhere. This is
Stage 4 of the conversion: the Godot scene and bridge that fly the six
hulls, six hostile archetypes and six weapon systems Stages 1-3 already
defined.

```
scripts_nova/daedalus_rules.nova     ships, damage scaling, power, sectors, the live advisor
     │  import "daedalus_ai.nova" as ai         import "daedalus_weapons.nova" as weapons
     ▼                                                    ▼
scripts/daedalus_bridge.gd -- ONE NovaVM, autoload "Daedalus", loaded once at boot
     │
     ├── scripts/player.gd     the six flyable hulls
     ├── scripts/enemy.gd      six hostile archetypes AND wingmen (same script, faction flag)
     ├── scripts/projectile.gd every shot's flight + damage resolution
     └── scripts/game.gd       spawner, sectors, hyperdrive, the advisor tick, score
```

## Running it

Open this folder in Godot 4.3+ (`daedalus_godot/`, not the repo root) and
press F5. There is nothing to install. The title screen
(`scenes/ui/menu.tscn`) is the entry point.

## Controls

| Key | Action |
|---|---|
| Mouse / A-D or arrows | Turn (mouse aims when no turn key is held) |
| W / Up | Thrust forward |
| S / Down | Thrust reverse |
| Space | Fire guns (Atlantis fires its omni-broadsides instead) |
| Shift | Fire a rocket |
| X | Fire a homing missile (needs a lock) |
| F (hold) | Fire the beam (Daedalus / Phoenix only) |
| Q | Toggle cloak |
| G | Spawn a wingman |
| Tab | Cycle ship (sandbox convenience — swaps hull instantly, keeping position) |
| M | Toggle the minimap |
| 0-9 | Hyperjump to that sector (matches `SECTORS[i].key`) |
| Esc | Pause / resume |

Destiny's five auto-turrets are never player-triggered — they fire
automatically at the nearest hostile in range, matching
`daedalus_weapons.nova`'s own "Point Defense (automated)" doctrine. On a
touchscreen (checked via `DisplayServer.is_touchscreen_available()`,
so this never appears on desktop or a non-touch web session) an on-screen
joystick and button row (`scripts/touch_controls.gd`) replace WASD/mouse
and the fire/cloak/wingman keys.

## Architecture notes

**One bridge, one NovaVM.** `daedalus_bridge.gd` is an autoload (singleton
name `Daedalus`) that loads `daedalus_rules.nova` exactly once and keeps
it alive for the life of the app — the title screen, ship select, a run
in progress and the pause menu all share it. Stages 1-3 shipped three
bridges (one NovaVM each) specifically to prove `daedalus_ai.nova` and
`daedalus_weapons.nova` are standalone, ship-registry-agnostic modules;
that property is unchanged here, this file just composes the same
already-proven view `daedalus_rules.nova` builds via
`import ... as ai` / `import ... as weapons`. Two lines were added to this
project's copy of `daedalus_rules.nova` (`let ENEMY = ai.ENEMY` and
`let WEAPONS = weapons.WEAPONS`, both no-op aliases of already-exported
dicts) so the bridge can cache the full raw tables from one
`vm.get_global()` each, plus three thin wrapper functions
(`effective_range`, `falloff_damage`, `beam_damage_per_second`,
`dart_ram_damage`) matching the pattern `weapon_stat`/`weapon_name`
already used — nothing about either module's design changed. The Stage
1-3 `godot/` project is untouched.

**Hot path / cold path** follows the exact split Stages 1-3 established:
`damage_multiplier`, `power_balance`, `hostiles_for`, blast/splash
falloff and the beam's ramp-and-class-scaling formula are cached
GDScript, cross-checked against a fresh NovaLang call at load time
(`DaedalusBridge._self_check()`); `fire_weapon`, `enemy_behavior` and
`dart_ram_damage` stay real interpreter calls, each bounded by a cooldown
or a single spawn/collision event, never a per-frame hot loop.

**The live advisor.** `daedalus_rules.nova`'s `params`/`effects`/
`signals`/`rule`/`fault` blocks are a tactical-advisor rule engine of
exactly the same shape as `reactor_rules.nova`'s reactor policy — Stages
1-3 only ever loaded it for its data tables, never drove it. This stage
does: `game.gd` calls `Daedalus.advisor_tick()` at a fixed 10 Hz with the
player's live hull/shield/cloak/infestation/contacts, and the HUD's alert
banner, alarms and the scripted "encounter director" faults (wraith
ambush, Ori satellite, replicator incursion, sensor ghosts) are that rule
engine actually running, not hardcoded HUD logic.

**Enemies and wingmen are the same script.** `enemy.gd` plays all six
hostile archetypes and the player's wingmen off of one `faction` flag —
a wingman is the "fighter" (Skirmisher) profile from
`daedalus_ai.nova`'s own table, redirected to hunt the opposing group
instead of the player. Nothing about the AI data changes for that.

**Damage always goes through Daedalus.** A player shot resolves through
`fire_weapon()` (falloff + the class-scaling matrix, or the beam's own
table); a hostile or wingman shot resolves through
`effective_damage(enemy_stat(kind,"gun_dmg"), enemy_class(kind),
target_class)` — the same formula `enemy_weapon_damage()` uses, just
generalised so a wingman shooting a hostile works with no second formula.
Ram damage and infection are deliberately never scaled by class, matching
`daedalus_ai.nova`'s own documented exception. `projectile.gd` never
computes a damage number itself.

**No art or audio assets ship with this project.** Every ship, projectile
and particle is a procedural `Polygon2D`/generated dot texture
(`scripts/placeholder_gfx.gd`); every sound is a generated tone from
`scripts/audio_bus.gd` via `AudioStreamGenerator`. Each `assets/*/`
folder has a short note on exactly which function to point real assets
at. All UI (`hud.gd`, `minimap.gd`, `hyperdrive.gd`, `menu.gd`,
`ship_select.gd`, `settings_panel.gd`) is built in code in `_ready()`
rather than hand-authored in `.tscn` — the same reasoning as the
placeholder visuals: this environment cannot open the Godot editor to
check a hand-written layout, but a `Control` built by a line of GDScript
can be checked by reading it.

**Pause** is a `process_mode` split: `Main` (`game.gd`, `main.tscn`'s
root) runs `PROCESS_MODE_ALWAYS` so the HUD stays interactive and the
Esc handler keeps firing while `get_tree().paused` is true, while
`$World` is explicitly set back to `PROCESS_MODE_PAUSABLE` so it does not
inherit "always" from its parent — Player, Enemy and Projectile all
freeze correctly. `GameState` (autoload) holds the settings and a
periodic run snapshot, which is what makes "Resume" on the title screen
possible without `main.tscn` still being alive.

## Deviations from the requested file list

A few files exist beyond the ones named in the brief, each because
something on the list needed it to actually work:

- `scripts/nova/*.gd` (the interpreter itself — lexer/parser/evaluator/VM)
  and `scripts_nova/lib/combat.nova` — copied unchanged from the Stage
  1-3 `godot/` project. `daedalus_bridge.gd` cannot load
  `daedalus_rules.nova` without them.
- `scripts/game.gd`, the actual script on `scenes/main.tscn`'s root (the
  brief named the scene but not a script for it).
- `scripts/game_state.gd`, `scripts/ship_select.gd`,
  `scripts/settings_panel.gd`, `scripts/touch_controls.gd`,
  `scripts/audio_bus.gd`, `scripts/input_map_setup.gd`,
  `scripts/placeholder_gfx.gd` — glue and infrastructure explained above
  and in each file's own header comment.
- `export_presets.cfg` — macOS/iOS/Web presets mirroring the sibling
  Reactor Sim project's, with the same critical detail: `.nova` files are
  not Godot resources, so every preset's `include_filter` explicitly
  ships `scripts_nova/*.nova` or an exported build has no ship stats, no
  enemy AI and no weapons at all.

## Modding

Ship stats, enemy AI and weapon ballistics all live in three text files
under `scripts_nova/` — edit one in any text editor, save, and relaunch
to try your change. No compiler, no rebuild.

* **[MODDING_DAEDALUS.md](MODDING_DAEDALUS.md)** — the full guide: what's
  inside `daedalus_rules.nova`, `daedalus_ai.nova` and
  `daedalus_weapons.nova`, how to add a new ship or enemy archetype, how
  to balance weapons, worked example mods (a playable Wraith Cruiser, a
  Replicator Carrier, a new high-danger sector), and troubleshooting.
* **[../MODDING_QUICKREF.md](../MODDING_QUICKREF.md)** — a one-page
  cheat sheet of every moddable value in both this game and Reactor Sim.

NovaLang is sandboxed: a `.nova` file has no file system or network
access, so the worst a bad mod does is fail the boot-time self-check or
unbalance the game.

## Verifying

Every number `daedalus_bridge.gd` caches is cross-checked against a
fresh NovaLang call inside `_self_check()`, called from `_ready()` — a
build with a broken cache fails loudly (`push_error` + `load_failed`
signal) instead of quietly running the wrong numbers. That check, and
the `daedalus_rules.nova` changes it depends on, were verified against
this repository's Python reference interpreter (`reference/nova_vm.py`)
during development — every cached formula (`damage_multiplier`,
`hostiles_for`, `effective_range`, `homing_turn_rate`, `beam_dps`,
`falloff_damage`, `homing_salvo_size`, `power_balance`, `fire_weapon`,
`dart_ram_damage`) was matched against the reference for every ship,
weapon and class combination the game actually exercises.

**What that verification cannot cover:** this environment cannot open
the Godot editor or run the Godot engine, so nothing here has actually
been played. Every `.tscn` and every scene-graph assumption in the
GDScript (node names, `$Path` references, signal connections, physics
layers) was checked by hand against the files that build them, not by
pressing play. Before relying on this build, open it in Godot, watch the
console for `[DaedalusBridge]` / `[WeaponsBridge]`-style load errors on
launch, and fly it.
