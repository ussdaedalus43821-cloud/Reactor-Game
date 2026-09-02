class_name NovaBridge
extends Node

## Connects NovaLang to Godot's physics and UI.
##
## This is the whole simulation host, and it is entirely in-engine: it owns
## the RK4 core (reactor_physics.gd), embeds the NovaLang VM
## (scripts/nova/), registers the reactor's vocabulary as host functions,
## and hands the panel one state Dictionary per frame.
##
## There is no Python here, no OS.execute, no socket and no fallback path.
## That is the point of the rewrite: the same code runs on macOS, iOS and
## Web, because it is only GDScript and a text file.
##
## Division of labour:
##   * physics  -- reactor_physics.gd, GDScript, the hot loop
##   * policy   -- res://scripts/reactor_rules.nova, interpreted
##   * panel    -- control_room.gd and scripts/widgets/
##
## The host functions registered below are the contract the policy is
## written against; reference/reactor_host.py registers exactly the same
## set, and tools/check_parity.py fails the build if they diverge.

signal engine_ready(label: String, info: Dictionary)
signal engine_error(message: String)

const RULES_PATH := "reactor_rules.nova"      # relative to res://scripts/

const DECAY_HEAT_INITIAL_FRAC := 7.0    # % of pre-trip power, just post-trip
const DECAY_HEAT_TAU_S := 130.0
const GRID_N := 10
const MAX_STEPS_PER_TICK := 60

## Exactly the names reference/reactor_host.py registers.
const HOST_FUNCTIONS := [
	"log", "alarm", "scram", "reset_trip", "meltdown", "victory",
	"inject_fault", "clear_fault",
]

var core := ReactorCore.new()
var vm: NovaVM = null
var ready := false
var error := ""
var backend_label := "GODOT / NovaLang"

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
var meltdown := false
var state_name := "STARTUP"
var alarm_level := 0
var alarm_text := ""

var flow_frac := 1.0
var load_frac := 1.0
var xenon_pcm := 0.0
var stuck_bank := ""

var scram_requested := false
var scram_reason := ""
var trip_reset := false

var pending_events: Array = []
var history: Array = []

var _rules_path := RULES_PATH


# ==========================================================================
# Lifecycle
# ==========================================================================

func start(rules_path: String = RULES_PATH) -> void:
	_rules_path = rules_path
	vm = NovaVM.new()
	_register_host_functions()

	if not vm.load_file(rules_path):
		error = "NovaLang: " + vm.error
		ready = false
		push_error("[NovaBridge] " + error)
		engine_error.emit(error)
	else:
		error = ""
		ready = true

	reset(0)
	engine_ready.emit(backend_label, hello())


func hello() -> Dictionary:
	var info := {
		"ok": ready,
		"engine": "nova",
		"backend": "gdscript",
		"dt": ReactorCore.PHYSICS_DT,
		"hz": ReactorCore.PHYSICS_HZ,
		"grid": GRID_N,
		"error": error,
	}
	if ready:
		var d := vm.describe()
		info["title"] = d["title"]
		info["rules_version"] = d["version"]
		info["rules"] = d["rules"].size()
		info["faults"] = d["faults"].size()
	else:
		info["title"] = "NO POLICY LOADED"
		info["rules_version"] = 0
	return info


func is_ready() -> bool:
	return ready


func fixed_dt() -> float:
	return ReactorCore.PHYSICS_DT


## Re-read the .nova policy without restarting the game. Only useful in the
## editor, where res:// is a real directory and edits land immediately.
func reload_rules() -> Dictionary:
	start(_rules_path)
	return snapshot()


# ==========================================================================
# Host functions -- the vocabulary reactor_rules.nova is written against
# ==========================================================================

func _register_host_functions() -> void:
	vm.register_function("log", _fn_log)
	vm.register_function("alarm", _fn_alarm)
	vm.register_function("scram", _fn_scram)
	vm.register_function("reset_trip", _fn_reset_trip)
	vm.register_function("meltdown", _fn_meltdown)
	vm.register_function("victory", _fn_victory)
	vm.register_function("inject_fault", _fn_inject_fault)
	vm.register_function("clear_fault", _fn_clear_fault)


## Games embedding this bridge can add their own vocabulary on top -- this
## is the seam daedalus_rules.nova uses.
func register_function(name: String, fn: Callable) -> void:
	if vm != null:
		vm.register_function(name, fn)


static func _arg_text(args: Array, index: int, fallback: String = "") -> String:
	return NovaEvaluator.text(args[index]) if args.size() > index else fallback


func _fn_log(args: Array):
	pending_events.append(_arg_text(args, 0))
	return null


func _fn_alarm(args: Array):
	if args.is_empty():
		return null
	var level := int(NovaEvaluator.to_number(args[0]))
	if level > alarm_level:
		alarm_level = level
		alarm_text = _arg_text(args, 1)
	return null


func _fn_scram(args: Array):
	# Latching in the VM's globals too means the lower-priority rules later
	# in this same tick already see a scrammed plant, so the state machine
	# never lags the trip.
	if scram:
		return null
	scram_requested = true
	scram_reason = _arg_text(args, 0, "SCRAM")
	vm.set_global("scram", true)
	pending_events.append(scram_reason)
	return null


func _fn_reset_trip(_args: Array):
	trip_reset = true
	vm.set_global("scram", false)
	return null


func _fn_meltdown(args: Array):
	if meltdown:
		return null
	meltdown = true
	_end_run()
	pending_events.append(_arg_text(args, 0, "MELTDOWN"))
	return null


func _fn_victory(args: Array):
	if victory:
		return null
	victory = true
	_end_run()
	pending_events.append(_arg_text(args, 0, "VICTORY"))
	return null


## `running` is an ordinary signal computed before the rules, so without
## this the state machine would see the run finish one tick late.
func _end_run() -> void:
	game_over = true
	vm.set_global("game_over", true)
	vm.set_global("meltdown", meltdown)
	vm.set_global("victory", victory)
	vm.set_global("running", false)


func _fn_inject_fault(args: Array):
	if not args.is_empty():
		vm.inject_fault(_arg_text(args, 0))
	return null


func _fn_clear_fault(_args: Array):
	vm.clear_fault()
	return null


# ==========================================================================
# Simulation
# ==========================================================================

func reset(seed_value: int = 0) -> Dictionary:
	core.reset()
	if vm != null:
		vm.reset(seed_value)
		if vm.error != "":
			error = "NovaLang: " + vm.error
			ready = false

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
	meltdown = false
	state_name = "STARTUP"
	alarm_level = 0
	alarm_text = ""

	scram_requested = false
	scram_reason = ""
	trip_reset = false

	flow_frac = 1.0
	load_frac = 1.0
	xenon_pcm = 0.0
	stuck_bank = ""

	pending_events.clear()
	pending_events.append("SIMULATION RESET -- REACTOR SUBCRITICAL")
	history.clear()
	return snapshot()


## Advance the plant by `steps` fixed PHYSICS_DT ticks. The operator's
## button press is an edge and belongs to the first step only.
func tick(steps: int, target_a: float, target_b: float,
		operator_scram: bool, faults_enabled: bool = true) -> Dictionary:
	steps = clampi(steps, 0, MAX_STEPS_PER_TICK)
	history.clear()

	if not game_over and not scram:
		rod_target_a = clampf(target_a, 0.0, 100.0)
		rod_target_b = clampf(target_b, 0.0, 100.0)

	for i in range(steps):
		_substep(ReactorCore.PHYSICS_DT, operator_scram and i == 0,
				faults_enabled)

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

	# 4. Run the policy. Its outputs are the plant's boundary conditions for
	#    the *next* substep -- one 50 ms lag, which keeps the loop acyclic
	#    and is mirrored exactly by the Python reference.
	scram_requested = false
	scram_reason = ""
	trip_reset = false
	alarm_level = 0
	alarm_text = ""

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
		"meltdown": meltdown,
	}

	if not vm.tick(dt, inputs, faults_enabled):
		error = "NovaLang: " + vm.error
		push_error("[NovaBridge] " + error)
		ready = false
		pending_events.append("CONTROL LOGIC FAULT -- " + vm.error)
		engine_error.emit(error)
		return

	flow_frac = float(vm.get_global("flow_frac", 1.0))
	load_frac = float(vm.get_global("load_frac", 1.0))
	xenon_pcm = float(vm.get_global("xenon_pcm", 0.0))
	stuck_bank = String(vm.get_global("stuck_bank", ""))
	state_name = String(vm.get_global("state", "STARTUP"))
	# NovaLang may drive the rods itself (the optional autopilot rule).
	rod_target_a = float(vm.get_global("rod_target_a", rod_target_a))
	rod_target_b = float(vm.get_global("rod_target_b", rod_target_b))

	if scram_requested and not scram:
		_latch_scram()
	elif trip_reset and scram:
		scram = false

	for line in vm.drain_output():
		pending_events.append(String(line))

	history.append([core.flux_percent(), core.fuel_temp()])


## Rods slam in -- a real scram drops them under gravity, it does not drive
## them, so this bypasses the rate limit on purpose.
func _latch_scram() -> void:
	flux_at_scram = core.flux_percent()
	scram = true
	scram_t = t
	rod_a = 0.0
	rod_b = 0.0
	rod_target_a = 0.0
	rod_target_b = 0.0


## Two scalars and an amplitude are all the GPU needs to draw the whole
## 10x10 core map. Asymmetric insertion tilts the flux toward the withdrawn
## bank; losing flow pushes the hot spot toward the outlet.
func _peaking() -> Dictionary:
	return {
		"tilt_x": clampf((rod_a - rod_b) / 100.0, -1.0, 1.0),
		"tilt_y": clampf((1.0 - flow_frac) * 0.6, -1.0, 1.0),
		"amp": 0.65,
		"n": GRID_N,
	}


func snapshot() -> Dictionary:
	var events: Array = pending_events.duplicate()
	pending_events.clear()

	var fault = null
	if ready and vm.active_fault != null:
		var f: Dictionary = vm.active_fault
		fault = {
			"name": f["name"],
			"label": f["label"],
			"elapsed": float(vm.get_global("fault_elapsed", 0.0)),
			"duration": float(vm.get_global("fault_duration", 0.0)),
		}

	return {
		"ok": error == "",
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
		"error": error,
	}
