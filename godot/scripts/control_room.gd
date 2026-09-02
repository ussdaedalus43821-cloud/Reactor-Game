extends Control

## Control room -- the conductor.
##
## Owns the NovaLang bridge, drives it at the simulation's fixed rate
## regardless of render frame rate, and fans the resulting state out to the
## instruments. It contains no physics and no policy: the core is
## integrated by reactor_physics.gd, and every trip, alarm and fault
## decision comes from reactor_rules.nova, interpreted in-engine. This
## script is the panel and nothing more.

const BG_SHADER_PATH := "res://shaders/control_room_bg.gdshader"
const MAX_STEPS_PER_FRAME := 12     # 0.6 s of catch-up; beyond that we drop
                                    # simulated time rather than spiral

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
@onready var readouts: ReadoutPanel = $Readouts
@onready var scram_button: ScramButton = $ScramButton
@onready var event_log: EventLog = $Log
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
	temp_dial.max_value = 3000.0
	temp_dial.decimals = 0
	temp_dial.major_ticks = 6
	temp_dial.dial_color = ReactorTheme.AMBER
	temp_dial.set_zones([
		[0.0, 1200.0, Color(ReactorTheme.GREEN, 0.55)],
		[1200.0, 1500.0, Color(ReactorTheme.YELLOW, 0.55)],
		[1500.0, 1800.0, Color(ReactorTheme.AMBER, 0.6)],
		[1800.0, 3000.0, Color(ReactorTheme.RED, 0.7)],
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
	elif event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			if OS.get_name() != "Web" and OS.get_name() != "iOS":
				get_tree().quit()


## Prefer the remappable InputMap action, but fall back to the raw key so
## the panel still works if the input map is missing.
func _pressed(event: InputEvent, action: String, fallback_key: Key) -> bool:
	if InputMap.has_action(action):
		return event.is_action_pressed(action)
	if event is InputEventKey:
		var key := event as InputEventKey
		return key.pressed and not key.echo and key.keycode == fallback_key
	return false


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
