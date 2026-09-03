class_name GameState
extends Node

## Settings and run-in-progress state shared between the title screen, ship
## select, settings panel and a live run. An autoload (see project.godot's
## [autoload] section, name "GameState") so it survives every scene change
## the same way Daedalus does -- that is what makes "Resume" on the title
## screen possible: main.tscn does not have to still be alive, it just has
## to be told, next time it loads, "start from this snapshot" instead of
## "start fresh."
##
## Not part of the file list the Stage 4 brief named -- it is the glue
## every scene needs to agree on a selected ship, a difficulty and a
## resume point without a hard reference to whichever scene set them.

signal settings_changed

const DIFFICULTIES := ["Casual", "Normal", "Hard", "Brutal"]

## Multiplies damage the player takes. Hostile density is read straight
## from daedalus_rules.nova's own DANGER table -- only how hard an
## individual hit lands changes with difficulty, not the NovaLang data.
const DAMAGE_TAKEN_MULT := {
	"Casual": 0.6,
	"Normal": 1.0,
	"Hard": 1.4,
	"Brutal": 1.9,
}

const SPAWN_DENSITY_MULT := {
	"Casual": 0.7,
	"Normal": 1.0,
	"Hard": 1.25,
	"Brutal": 1.6,
}

var selected_ship := "daedalus"
var difficulty := "Normal"
var starting_sector := 1
var starting_wingmen := 0
var god_mode := false
var infinite_ammo := false
var cloak_available := true
var minimap_enabled := true

var game_in_progress := false
var resume_snapshot: Dictionary = {}


func difficulty_multiplier() -> float:
	return float(DAMAGE_TAKEN_MULT.get(difficulty, 1.0))


func spawn_density_multiplier() -> float:
	return float(SPAWN_DENSITY_MULT.get(difficulty, 1.0))


## Called by game.gd every few seconds while a run is live, so a trip to
## the pause menu (or even the title screen, without ending the run) can
## resume from roughly where it left off.
func save_snapshot(snapshot: Dictionary) -> void:
	resume_snapshot = snapshot.duplicate(true)
	game_in_progress = true


func clear_snapshot() -> void:
	resume_snapshot = {}
	game_in_progress = false


func has_resume() -> bool:
	return game_in_progress and not resume_snapshot.is_empty()
