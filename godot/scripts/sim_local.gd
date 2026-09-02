class_name LocalSim
extends RefCounted

## The in-engine reactor host.
##
## Mirrors ReactorSim in sim/reactor_server.py: it drives the rods, runs the
## RK4 core (reactor_physics.gd) and executes the NovaLang policy
## (nova_vm.gd running res://sim/reactor_rules.nova), then emits exactly the
## same state Dictionary the Python daemon returns over the pipe.
##
## Because the shape of the reply is identical, bridge.gd can switch between
## Python and local execution at runtime and nothing upstream notices. This
## is what makes the iOS and Web exports work: they cannot spawn a process,
## so they run this instead.

const RULES_PATH := "res://sim/reactor_rules.nova"

const DECAY_HEAT_INITIAL_FRAC := 7.0    # % of pre-trip power, just after trip
const DECAY_HEAT_TAU_S := 130.0
const GRID_N := 10
const MAX_STEPS_PER_TICK := 60

var core := ReactorCore.new()
var vm: NovaVM = null
var ready := false
var error := ""

var t := 0.0
var step_count := 0

var rod_a := 0.0
var rod_b := 0.0
var rod_target_a := 0.0
var rod_target_b := 0.0

var scram := false
var scram_t := 0.0
var flux_at_scram := 0.0

var game_over := false
var victory := false
var state_name := "STARTUP"
var alarm_level := 0
var alarm_text := ""

var flow_frac := 1.0
var load_frac := 1.0
var xenon_pcm := 0.0
var stuck_bank := ""

var pending_events: Array[String] = []
var history: Array = []


func _init(rules_path: String = RULES_PATH) -> void:
	vm = NovaVM.from_file(rules_path)
	if vm.error != "":
		error = "NovaLang: " + vm.error
		push_error("[LocalSim] " + error)
		ready = false
	else:
		ready = true
	reset(0)


func reset(seed_value: int = 0) -> Dictionary:
	core.reset()
	if ready:
		vm.reset(seed_value)

	t = 0.0
	step_count = 0
	rod_a = 0.0
	rod_b = 0.0
	rod_target_a = 0.0
	rod_target_b = 0.0

	scram = false
	scram_t = 0.0
	flux_at_scram = 0.0

	game_over = false
	victory = false
	state_name = "STARTUP"
	alarm_level = 0
	alarm_text = ""

	flow_frac = 1.0
	load_frac = 1.0
	xenon_pcm = 0.0
	stuck_bank = ""

	pending_events.clear()
	pending_events.append("SIMULATION RESET -- REACTOR SUBCRITICAL")
	history.clear()
	return snapshot()


func hello() -> Dictionary:
	return {
		"ok": ready,
		"proto": 1,
		"backend": "gdscript",
		"engine": "nova",
		"title": vm.title if ready else "NO POLICY LOADED",
		"rules_version": vm.version if ready else 0,
		"dt": ReactorCore.PHYSICS_DT,
		"hz": ReactorCore.PHYSICS_HZ,
		"grid": GRID_N,
		"error": error,
	}


## Advance the plant. `steps` is counted in fixed PHYSICS_DT ticks; the
## operator's button press is an edge and belongs to the first step only.
func advance(steps: int, target_a: float, target_b: float,
		operator_scram: bool, faults_enabled: bool = true) -> Dictionary:
	steps = clampi(steps, 0, MAX_STEPS_PER_TICK)
	history.clear()

	if not game_over and not scram:
		rod_target_a = clampf(target_a, 0.0, 100.0)
		rod_target_b = clampf(target_b, 0.0, 100.0)

	for i in range(steps):
		_substep(ReactorCore.PHYSICS_DT, operator_scram and i == 0, faults_enabled)

	return snapshot()


func _substep(dt: float, operator_scram: bool, faults_enabled: bool) -> void:
	t += dt
	step_count += 1

	# 1. Rod drives -- finite speed, and a seized bank does not move.
	rod_a = ReactorCore.drive_rod(rod_a, rod_target_a, dt, stuck_bank == "A")
	rod_b = ReactorCore.drive_rod(rod_b, rod_target_b, dt, stuck_bank == "B")

	# 2. Decay heat keeps the core warm long after the rods are in.
	var decay := 0.0
	if scram:
		decay = ReactorCore.decay_heat_pct(flux_at_scram, t - scram_t,
				DECAY_HEAT_INITIAL_FRAC, DECAY_HEAT_TAU_S)

	# 3. Integrate the core.
	core.step(dt, rod_a, rod_b, flow_frac, load_frac, xenon_pcm, decay)

	if not ready:
		history.append([core.flux_percent(), core.fuel_temp()])
		return

	# 4. Hand the measurements to NovaLang. Its outputs are the plant's
	#    boundary conditions for the *next* substep -- one 50 ms lag, which
	#    keeps the loop acyclic and matches the Python host exactly.
	var inputs := {
		"t": t,
		"flux_pct": core.flux_percent(),
		"fuel_temp_c": core.fuel_temp(),
		"mod_temp_c": core.mod_temp(),
		"out_temp_c": core.out_temp(),
		"pressure_mpa": core.pressure(),
		"reactivity_pcm": core.reactivity_pcm,
		"decay_heat_pct": decay,
		"rod_a": rod_a,
		"rod_b": rod_b,
		"rod_target_a": rod_target_a,
		"rod_target_b": rod_target_b,
		"scram": scram,
		"scram_elapsed": (t - scram_t) if scram else 0.0,
		"operator_scram": operator_scram,
		"game_over": game_over,
		"victory": victory,
		"meltdown": vm.meltdown,
	}
	var out := vm.tick(dt, inputs, faults_enabled)

	if vm.runtime_error != "":
		error = "NovaLang: " + vm.runtime_error
		push_error("[LocalSim] " + error)
		ready = false
		pending_events.append("CONTROL LOGIC FAULT -- " + vm.runtime_error)
		return

	flow_frac = out["flow_frac"]
	load_frac = out["load_frac"]
	xenon_pcm = out["xenon_pcm"]
	stuck_bank = out["stuck_bank"]
	state_name = out["state"]
	alarm_level = out["alarm_level"]
	alarm_text = out["alarm_text"]

	# NovaLang may drive the rods itself (the optional autopilot rule).
	rod_target_a = out["rod_target_a"]
	rod_target_b = out["rod_target_b"]

	if out["scram_requested"] and not scram:
		_latch_scram()
	elif out["trip_reset"] and scram:
		scram = false

	if out["meltdown"] and not game_over:
		game_over = true
	if out["victory"] and not game_over:
		game_over = true
		victory = true

	var new_events: Array = out["events"]
	for e in new_events:
		pending_events.append(str(e))

	history.append([core.flux_percent(), core.fuel_temp()])


## Rods slam in. This bypasses the drive rate limit on purpose -- a real
## scram drops them under gravity, it does not drive them.
func _latch_scram() -> void:
	flux_at_scram = core.flux_percent()
	scram = true
	scram_t = t
	rod_a = 0.0
	rod_b = 0.0
	rod_target_a = 0.0
	rod_target_b = 0.0


## Two scalars and an amplitude are all the GPU needs to draw the whole
## 10x10 core map, so it costs no per-frame bandwidth. Asymmetric insertion
## tilts the flux toward the withdrawn bank; losing flow pushes the hot spot
## toward the outlet.
func _peaking() -> Dictionary:
	return {
		"tilt_x": clampf((rod_a - rod_b) / 100.0, -1.0, 1.0),
		"tilt_y": clampf((1.0 - flow_frac) * 0.6, -1.0, 1.0),
		"amp": 0.65,
		"n": GRID_N,
	}


func snapshot() -> Dictionary:
	var events := pending_events.duplicate()
	pending_events.clear()

	var fault = null
	if ready and not vm.active_fault.is_empty():
		fault = {
			"name": vm.active_fault["name"],
			"label": vm.active_fault["label"],
			"elapsed": float(vm.vars.get("fault_elapsed", 0.0)),
			"duration": float(vm.vars.get("fault_duration", 0.0)),
		}

	return {
		"ok": true,
		"t": t,
		"steps": step_count,
		"flux_pct": core.flux_percent(),
		"fuel_temp_c": core.fuel_temp(),
		"mod_temp_c": core.mod_temp(),
		"out_temp_c": core.out_temp(),
		"pressure_mpa": core.pressure(),
		"reactivity_pcm": core.reactivity_pcm,
		"rod_a": rod_a,
		"rod_b": rod_b,
		"rod_target_a": rod_target_a,
		"rod_target_b": rod_target_b,
		"flow_frac": flow_frac,
		"load_frac": load_frac,
		"xenon_pcm": xenon_pcm,
		"stuck_bank": stuck_bank,
		"scram": scram,
		"scram_elapsed": (t - scram_t) if scram else 0.0,
		"state": state_name,
		"alarm_level": alarm_level,
		"alarm_text": alarm_text,
		"fault": fault,
		"peak": _peaking(),
		"game_over": game_over,
		"victory": victory,
		"events": events,
		"history": history.duplicate(),
		"backend": "gdscript",
	}
