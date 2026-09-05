extends Control

## Control room -- the conductor.
##
## Owns the NovaLang bridge, drives it at the simulation's fixed rate
## regardless of render frame rate, and fans the resulting state out to the
## instruments. It contains no physics and no policy: the core is
## integrated by reactor_physics.gd, and every trip, alarm and fault
## decision comes from reactor_rules.nova, interpreted in-engine. This
## script is the panel and nothing more.
##
## project.godot's own header comment gets clobbered by Godot's editor
## every time it resaves the file, so the layout rationale lives here
## instead: base resolution is a fixed 1440x1580 design space, letterboxed
## on any other aspect ("keep" stretch). Every panel is laid out in that
## space, so the same scene is pixel-correct on a Mac window, an iPhone
## and a browser canvas with no per-platform layout code. The 460px below
## the original 900-tall control room is the plant schematic band -- see
## plant_schematic.gd -- and the 190px below that is the manual-override
## band: the two ThrottleSlider valves plus a key legend, see
## _setup_key_legend() and force_fault().

const BG_SHADER_PATH := "res://shaders/control_room_bg.gdshader"
const MAX_STEPS_PER_FRAME := 12     # 0.6 s of catch-up; beyond that we drop
                                    # simulated time rather than spiral

## Keyboard rod control: Q/A drive Bank A's target out/in, W/S drive
## Bank B's the same way (Q above A, W above S -- the same up/down sense
## as the two banks sitting side by side on the panel). Each press nudges
## the target by one small fixed step rather than a continuous held
## rate -- a 40 %/s continuous rate turned out to blow straight past the
## fine adjustments rod worth's cubic curve actually needs (see
## ReactorCore.bank_worth_pcm()'s own comment: the last 10 % of
## withdrawal is worth far more than the rest). Holding the key doesn't
## auto-repeat the nudge; _pressed()'s is_action_pressed() call defaults
## to allow_echo=false, so each physical press is exactly one step.
const ROD_KEY_STEP_PCT := 0.1

## Coolant flow and turbine load have no physical drive rate to respect --
## a valve just is wherever you put it -- so their keyboard nudge can be a
## much coarser step than the rods' and still feel controllable.
const THROTTLE_KEY_STEP_PCT := 5.0

@onready var background: ColorRect = $Background
@onready var header: HeaderBar = $Header
@onready var banner: FaultBanner = $Banner
@onready var flux_dial: AnalogDial = $FluxDial
@onready var temp_dial: AnalogDial = $TempDial
@onready var pressure_dial: AnalogDial = $PressureDial
@onready var core_grid: CoreGrid = $CoreGrid
@onready var graph: ScrollingGraph = $Graph
@onready var rod_a: RodSlider = $RodA
@onready var rod_b: RodSlider = $RodB
@onready var flow_slider: ThrottleSlider = $FlowSlider
@onready var load_slider: ThrottleSlider = $LoadSlider
@onready var key_legend: ReadoutPanel = $KeyLegend
@onready var readouts: ReadoutPanel = $Readouts
@onready var scram_button: ScramButton = $ScramButton
@onready var event_log: EventLog = $Log
@onready var schematic: PlantSchematic = $Schematic
@onready var overlay: GameOverlay = $Overlay

var bridge: NovaBridge = null

var _accum := 0.0
var _dt := 0.05
var _scram_pressed := false
var _target_a := 0.0
var _target_b := 0.0
var _last_state: Dictionary = {}
var _bg_material: ShaderMaterial = null


func _ready() -> void:
	_setup_background()
	_setup_dials()
	_setup_key_legend()

	rod_a.target_changed.connect(_on_rod_a_changed)
	rod_b.target_changed.connect(_on_rod_b_changed)
	scram_button.pressed.connect(_on_scram_pressed)

	bridge = NovaBridge.new()
	bridge.name = "NovaBridge"
	bridge.engine_ready.connect(_on_engine_ready)
	bridge.engine_error.connect(_on_engine_error)
	add_child(bridge)
	bridge.start()

	_dt = bridge.fixed_dt()
	_apply_state(bridge.reset(0))
	set_process(true)


func _setup_background() -> void:
	var shader := load(BG_SHADER_PATH)
	if shader is Shader:
		_bg_material = ShaderMaterial.new()
		_bg_material.shader = shader
		background.material = _bg_material
		# The backdrop's bays and rivets are sized in pixels, so it needs to
		# be told the viewport size -- and told again whenever it changes.
		_update_bg_resolution()
		resized.connect(_update_bg_resolution)
	else:
		push_warning("[ControlRoom] %s missing; using a flat backdrop"
				% BG_SHADER_PATH)
		background.color = ReactorTheme.BG


func _update_bg_resolution() -> void:
	if _bg_material != null:
		_bg_material.set_shader_parameter("resolution", size)


func _setup_dials() -> void:
	flux_dial.label_text = "NEUTRON FLUX"
	flux_dial.unit_text = "%"
	flux_dial.min_value = 0.0
	flux_dial.max_value = 200.0
	flux_dial.dial_color = ReactorTheme.CYAN
	# Bands mirror the setpoints in reactor_rules.nova: caution at 115 %,
	# automatic trip at 150 %.
	flux_dial.set_zones([
		[0.0, 105.0, Color(ReactorTheme.GREEN, 0.55)],
		[105.0, 115.0, Color(ReactorTheme.YELLOW, 0.55)],
		[115.0, 150.0, Color(ReactorTheme.AMBER, 0.6)],
		[150.0, 200.0, Color(ReactorTheme.RED, 0.7)],
	])

	temp_dial.label_text = "FUEL TEMP"
	temp_dial.unit_text = "C"
	temp_dial.min_value = 0.0
	# 550/650/800/1500 (warn/overheat/trip/dial max) mirror
	# reactor_rules.nova's own rescaled setpoints -- see that file's
	# comment on why 1200/1500/1800/3000 sat far hotter than this plant's
	# heat-transfer constants let it actually reach.
	temp_dial.max_value = 1500.0
	temp_dial.decimals = 0
	temp_dial.major_ticks = 6
	temp_dial.dial_color = ReactorTheme.AMBER
	temp_dial.set_zones([
		[0.0, 550.0, Color(ReactorTheme.GREEN, 0.55)],
		[550.0, 650.0, Color(ReactorTheme.YELLOW, 0.55)],
		[650.0, 800.0, Color(ReactorTheme.AMBER, 0.6)],
		[800.0, 1500.0, Color(ReactorTheme.RED, 0.7)],
	])

	pressure_dial.label_text = "PRIMARY PRESSURE"
	pressure_dial.unit_text = "MPa"
	pressure_dial.min_value = 10.0
	pressure_dial.max_value = 22.0
	pressure_dial.decimals = 2
	pressure_dial.major_ticks = 6
	pressure_dial.dial_color = ReactorTheme.GREEN
	pressure_dial.set_zones([
		[10.0, 17.5, Color(ReactorTheme.GREEN, 0.55)],
		[17.5, 18.5, Color(ReactorTheme.AMBER, 0.6)],
		[18.5, 22.0, Color(ReactorTheme.RED, 0.7)],
	])


## Static reference card for the debug/sandbox keys -- what force_fault()
## and the throttle sliders answer to. Set once; nothing here changes at
## runtime.
func _setup_key_legend() -> void:
	key_legend.title_text = "MANUAL OVERRIDES"
	key_legend.set_rows([
		["1", "ROD BANK STUCK", ReactorTheme.MAGENTA],
		["2", "TURBINE TRIP", ReactorTheme.AMBER],
		["3", "FEEDWATER FAILURE", ReactorTheme.CYAN],
		["4", "XENON POISONING", ReactorTheme.CYAN],
		["0", "CLEAR ACTIVE FAULT", ReactorTheme.GREEN],
		["E / D", "COOLANT FLOW +/-", ReactorTheme.BLUE],
		["T / G", "TURBINE LOAD +/-", ReactorTheme.MAGENTA],
	])


# ==========================================================================
# Main loop
# ==========================================================================

func _process(delta: float) -> void:
	if bridge == null or not bridge.is_ready():
		return

	# Fixed-step accumulator: the reactor always advances in exact 0.05 s
	# ticks no matter what the display is doing, so a dropped frame or a
	# 120 Hz monitor never changes the physics.
	_accum += minf(delta, 0.25)
	var steps := int(_accum / _dt)
	if steps <= 0:
		return
	_accum -= steps * _dt
	if steps > MAX_STEPS_PER_FRAME:
		steps = MAX_STEPS_PER_FRAME
		_accum = 0.0

	# The sliders are the single source of truth for whether the operator
	# is holding the valve -- AUTO hands the value straight back to
	# reactor_rules.nova's fault injector, see ThrottleSlider.is_auto().
	bridge.manual_flow_override = -1.0 if flow_slider.is_auto() else flow_slider.value / 100.0
	bridge.manual_load_override = -1.0 if load_slider.is_auto() else load_slider.value / 100.0

	var state := bridge.tick(steps, _target_a, _target_b, _scram_pressed)
	_scram_pressed = false
	if state.is_empty():
		return
	_apply_state(state)


func _apply_state(state: Dictionary) -> void:
	if state.is_empty():
		return
	_last_state = state

	var plant_time := float(state.get("t", 0.0))
	var flux := float(state.get("flux_pct", 0.0))
	var fuel := float(state.get("fuel_temp_c", 0.0))
	var scram := bool(state.get("scram", false))
	var game_over := bool(state.get("game_over", false))
	var victory := bool(state.get("victory", false))
	var alarm_level := int(state.get("alarm_level", 0))
	var state_name := str(state.get("state", "STARTUP"))

	header.state_name = state_name
	header.plant_time = plant_time
	header.reactivity_pcm = float(state.get("reactivity_pcm", 0.0))
	header.power_pct = flux
	header.alarm_level = alarm_level

	flux_dial.value = flux
	temp_dial.value = fuel
	pressure_dial.value = float(state.get("pressure_mpa", 15.5))

	core_grid.apply_state(state)
	readouts.apply_state(state)
	schematic.apply_state(state)

	# Every physics substep the bridge advanced comes back in `history`, so
	# the strip chart stays continuous even though we only poll once a frame.
	var history: Array = state.get("history", [])
	for entry in history:
		var sample: Array = entry
		if sample.size() >= 2:
			graph.push_sample(float(sample[0]), float(sample[1]))

	# The rods move at their own rate; the sliders show command vs actual.
	rod_a.actual = float(state.get("rod_a", 0.0))
	rod_b.actual = float(state.get("rod_b", 0.0))
	var stuck := str(state.get("stuck_bank", ""))
	rod_a.stuck = stuck == "A"
	rod_b.stuck = stuck == "B"
	var drives_live := not scram and not game_over
	rod_a.enabled = drives_live
	rod_b.enabled = drives_live

	# Coolant flow and turbine load stay live through a SCRAM on purpose --
	# choking flow into decay heat is a real, deliberate way to keep
	# pushing the plant even after the rods are in. Only the end of the
	# run itself takes the valves away.
	flow_slider.enabled = not game_over
	load_slider.enabled = not game_over
	flow_slider.follow_auto(float(state.get("flow_frac", 1.0)) * 100.0)
	load_slider.follow_auto(float(state.get("load_frac", 1.0)) * 100.0)
	if scram or game_over:
		# A trip drops the rods and zeroes the commands; follow them so the
		# slider does not sit somewhere the plant is no longer trying to go.
		_target_a = float(state.get("rod_target_a", 0.0))
		_target_b = float(state.get("rod_target_b", 0.0))
		rod_a.target = _target_a
		rod_b.target = _target_b

	scram_button.latched = scram
	scram_button.enabled = not game_over
	scram_button.alarm_level = alarm_level

	for line in state.get("events", []):
		event_log.add_line(str(line), plant_time)

	_update_banner(state, alarm_level)

	if _bg_material != null:
		_bg_material.set_shader_parameter("alarm",
				clampf(float(alarm_level) / 3.0, 0.0, 1.0))

	if game_over:
		if victory:
			overlay.show_result("SHIFT COMPLETE",
					"15 minutes on watch, core intact. Veteran operator.",
					ReactorTheme.GREEN)
		else:
			overlay.show_result("MELTDOWN",
					"Core disassembly at T+%02d:%02d. Fuel temperature %.0f C."
					% [int(plant_time) / 60, int(plant_time) % 60, fuel],
					ReactorTheme.RED)
	else:
		overlay.hide_result()


func _update_banner(state: Dictionary, alarm_level: int) -> void:
	var fault = state.get("fault", null)
	if typeof(fault) == TYPE_DICTIONARY:
		var elapsed := float(fault.get("elapsed", 0.0))
		var duration := float(fault.get("duration", 0.0))
		banner.show_alert(str(fault.get("label", "FAULT")),
				"clearing in %ds" % maxi(0, int(ceil(duration - elapsed))),
				ReactorTheme.alarm_color(maxi(alarm_level, 1)),
				maxf(0.0, duration - elapsed), duration)
		return

	var alarm_text := str(state.get("alarm_text", ""))
	if alarm_level >= 2 and alarm_text != "":
		banner.show_alert(alarm_text, "", ReactorTheme.alarm_color(alarm_level))
		return

	banner.hide_alert()


# ==========================================================================
# Input
# ==========================================================================

func _unhandled_input(event: InputEvent) -> void:
	if _pressed(event, "scram", KEY_SPACE):
		scram_button.trigger()
		get_viewport().set_input_as_handled()
	elif _pressed(event, "restart", KEY_R):
		_restart()
		get_viewport().set_input_as_handled()
	elif _pressed(event, "rod_a_out", KEY_Q):
		_nudge_rod_a(ROD_KEY_STEP_PCT)
		get_viewport().set_input_as_handled()
	elif _pressed(event, "rod_a_in", KEY_A):
		_nudge_rod_a(-ROD_KEY_STEP_PCT)
		get_viewport().set_input_as_handled()
	elif _pressed(event, "rod_b_out", KEY_W):
		_nudge_rod_b(ROD_KEY_STEP_PCT)
		get_viewport().set_input_as_handled()
	elif _pressed(event, "rod_b_in", KEY_S):
		_nudge_rod_b(-ROD_KEY_STEP_PCT)
		get_viewport().set_input_as_handled()
	elif _pressed(event, "flow_up", KEY_E):
		flow_slider.nudge(THROTTLE_KEY_STEP_PCT)
		get_viewport().set_input_as_handled()
	elif _pressed(event, "flow_down", KEY_D):
		flow_slider.nudge(-THROTTLE_KEY_STEP_PCT)
		get_viewport().set_input_as_handled()
	elif _pressed(event, "load_up", KEY_T):
		load_slider.nudge(THROTTLE_KEY_STEP_PCT)
		get_viewport().set_input_as_handled()
	elif _pressed(event, "load_down", KEY_G):
		load_slider.nudge(-THROTTLE_KEY_STEP_PCT)
		get_viewport().set_input_as_handled()
	elif _pressed(event, "force_rod_stuck", KEY_1):
		_force_fault("rod_stuck")
		get_viewport().set_input_as_handled()
	elif _pressed(event, "force_turbine_trip", KEY_2):
		_force_fault("turbine_trip")
		get_viewport().set_input_as_handled()
	elif _pressed(event, "force_feedwater_failure", KEY_3):
		_force_fault("feedwater_failure")
		get_viewport().set_input_as_handled()
	elif _pressed(event, "force_xenon_poisoning", KEY_4):
		_force_fault("xenon_poisoning")
		get_viewport().set_input_as_handled()
	elif _pressed(event, "clear_fault", KEY_0):
		if bridge != null and not bridge.game_over:
			bridge.clear_active_fault()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			if OS.get_name() != "Web" and OS.get_name() != "iOS":
				get_tree().quit()


## Prefer the remappable InputMap action, but fall back to the raw key so
## the panel still works if the input map is missing. is_action_pressed()
## defaults to allow_echo=false, so a held key does not repeat-fire this
## -- exactly what a "nudge by one step" control wants.
func _pressed(event: InputEvent, action: String, fallback_key: Key) -> bool:
	if InputMap.has_action(action):
		return event.is_action_pressed(action)
	if event is InputEventKey:
		var key := event as InputEventKey
		return key.pressed and not key.echo and key.keycode == fallback_key
	return false


## Q/A nudge Bank A's commanded target out/in; W/S do the same for Bank B.
## Mirrors exactly what dragging that bank's slider already does -- moves
## _target_a/_target_b (what _process() feeds the bridge every tick) and
## the slider's own .target (so the handle the operator sees moves too),
## and is gated by the same rod_a.enabled/rod_b.enabled a SCRAM or
## game-over already sets false.
func _nudge_rod_a(step: float) -> void:
	if not rod_a.enabled:
		return
	_target_a = clampf(_target_a + step, 0.0, 100.0)
	rod_a.target = _target_a


func _nudge_rod_b(step: float) -> void:
	if not rod_b.enabled:
		return
	_target_b = clampf(_target_b + step, 0.0, 100.0)
	rod_b.target = _target_b


## The four fault keys (1/2/3/4) each hand the fault injector's own
## machinery to the operator -- same activation reactor_rules.nova's
## random scheduler uses, just triggered on demand instead of by the
## weighted roll. Refused after the run has ended, same as every other
## control.
func _force_fault(name: String) -> void:
	if bridge != null and not bridge.game_over:
		bridge.force_fault(name)


func _on_rod_a_changed(value: float) -> void:
	_target_a = value


func _on_rod_b_changed(value: float) -> void:
	_target_b = value


func _on_scram_pressed() -> void:
	_scram_pressed = true


func _restart() -> void:
	_target_a = 0.0
	_target_b = 0.0
	_scram_pressed = false
	_accum = 0.0
	rod_a.target = 0.0
	rod_b.target = 0.0
	# Not release_to_auto() -- that no-ops while the slider is disabled
	# (e.g. restarting right after a meltdown), and a restart must clear
	# manual overrides unconditionally.
	flow_slider.value = 100.0
	load_slider.value = 100.0
	graph.clear_history()
	event_log.clear_log()
	overlay.hide_result()
	_apply_state(bridge.reset(0))


# ==========================================================================
# Engine status
# ==========================================================================

func _on_engine_ready(label: String, info: Dictionary) -> void:
	header.backend_label = label
	header.backend_ok = bool(info.get("ok", true))
	_dt = float(info.get("dt", _dt))
	var title := str(info.get("title", ""))
	if title != "":
		event_log.add_line("POLICY LOADED: %s v%d  (%d rules, %d faults)"
				% [title, int(info.get("rules_version", 1)),
				   int(info.get("rules", 0)), int(info.get("faults", 0))], 0.0)


## A .nova error stops the policy dead; the physics keeps integrating so the
## panel stays live, but the operator needs to see why nothing is tripping.
func _on_engine_error(message: String) -> void:
	header.backend_ok = false
	header.backend_label = "NovaLang ERROR"
	event_log.add_line("CONTROL LOGIC ERROR: " + message, header.plant_time)
