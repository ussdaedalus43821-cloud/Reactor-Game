class_name CoreGrid
extends Control

## The 10x10 fuel-channel map, rendered on the GPU.
##
## The map is a single ColorRect running shaders/core_heatmap.gdshader. All
## 100 channel temperatures are reconstructed in the fragment shader from
## four numbers the bridge already sends -- bulk fuel temperature plus a
## flux-peaking tilt and amplitude -- so the core map costs one draw call
## and zero per-frame bandwidth no matter how fast the sim runs.
##
## Everything drawn in _draw() on top (frame, channel ruling, hot-channel
## marker, legend) is CPU work that does not scale with grid size.

const GRID_N := 10
const SHADER_PATH := "res://shaders/core_heatmap.gdshader"

var fuel_temp := 270.0
var tilt := Vector2.ZERO
var amp := 0.65
var meltdown := 0.0
var alarm := 0.0

var _map: ColorRect = null
var _material: ShaderMaterial = null
var _inner := Rect2()


func _ready() -> void:
	_material = ShaderMaterial.new()
	var shader := load(SHADER_PATH)
	if shader is Shader:
		_material.shader = shader
	else:
		push_warning("[CoreGrid] %s missing; the core map will render flat"
				% SHADER_PATH)

	_map = ColorRect.new()
	_map.name = "HeatMap"
	_map.material = _material
	_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map.color = ReactorTheme.PANEL_DEEP
	add_child(_map)

	resized.connect(_layout)
	_layout()
	set_process(true)


func _layout() -> void:
	var pad := 10.0
	var top := 26.0
	var bottom := 22.0
	var side := minf(size.x - pad * 2.0, size.y - top - bottom)
	side = maxf(side, 16.0)
	_inner = Rect2(Vector2((size.x - side) * 0.5, top + (size.y - top - bottom - side) * 0.5),
			Vector2(side, side))
	if _map != null:
		_map.position = _inner.position
		_map.size = _inner.size
	queue_redraw()


## Push one frame of core state. `state` is the bridge's reply dictionary,
## so this works identically against Python and against the in-engine sim.
func apply_state(state: Dictionary) -> void:
	fuel_temp = float(state.get("fuel_temp_c", 270.0))
	var peak: Dictionary = state.get("peak", {})
	tilt = Vector2(float(peak.get("tilt_x", 0.0)), float(peak.get("tilt_y", 0.0)))
	amp = float(peak.get("amp", 0.65))
	meltdown = 1.0 if bool(state.get("game_over", false)) \
			and not bool(state.get("victory", false)) else 0.0
	alarm = clampf(float(state.get("alarm_level", 0)) / 3.0, 0.0, 1.0)


func _process(_delta: float) -> void:
	if _material == null or _material.shader == null:
		return
	_material.set_shader_parameter("fuel_temp_c", fuel_temp)
	_material.set_shader_parameter("tilt", tilt)
	_material.set_shader_parameter("amp", amp)
	_material.set_shader_parameter("grid_n", float(GRID_N))
	_material.set_shader_parameter("meltdown", meltdown)
	_material.set_shader_parameter("alarm", alarm)
	queue_redraw()


## Peak channel temperature. The centroid channel has peaking weight 1, so
## it sits at the bulk fuel temperature and every other channel is cooler.
func peak_temp() -> float:
	return fuel_temp


func _draw() -> void:
	var font := get_theme_default_font()

	draw_string(font, Vector2(10.0, 17.0), "CORE MAP  10 x 10 CHANNELS",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, ReactorTheme.TEXT_DIM)

	if _inner.size.x <= 0.0:
		return

	# Frame around the map, plus faint ruling every other channel so the
	# grid reads as fuel assemblies rather than as a gradient.
	draw_rect(_inner.grow(2.0), ReactorTheme.BEZEL, false, 2.0)
	var cell := _inner.size.x / float(GRID_N)
	for i in range(1, GRID_N):
		if i % 2 != 0:
			continue
		var x := _inner.position.x + cell * i
		var y := _inner.position.y + cell * i
		draw_line(Vector2(x, _inner.position.y), Vector2(x, _inner.end.y),
				Color(ReactorTheme.BG, 0.35), 1.0)
		draw_line(Vector2(_inner.position.x, y), Vector2(_inner.end.x, y),
				Color(ReactorTheme.BG, 0.35), 1.0)

	# Hot-channel marker: the shader's peak sits at the tilted centroid.
	var centroid := _inner.position + (Vector2(0.5, 0.5) + tilt * 0.5) * _inner.size
	centroid.x = clampf(centroid.x, _inner.position.x + 4.0, _inner.end.x - 4.0)
	centroid.y = clampf(centroid.y, _inner.position.y + 4.0, _inner.end.y - 4.0)
	var marker := Color(ReactorTheme.WHITE, 0.55)
	draw_arc(centroid, 9.0, 0.0, TAU, 20, marker, 1.5)
	draw_line(centroid - Vector2(13.0, 0.0), centroid - Vector2(5.0, 0.0), marker, 1.5)
	draw_line(centroid + Vector2(5.0, 0.0), centroid + Vector2(13.0, 0.0), marker, 1.5)

	# Temperature legend across the bottom.
	var legend := Rect2(Vector2(_inner.position.x, _inner.end.y + 6.0),
			Vector2(_inner.size.x, 7.0))
	var steps := 48
	for i in range(steps):
		var f := float(i) / float(steps - 1)
		var t := 270.0 + f * (2800.0 - 270.0)
		draw_rect(Rect2(legend.position + Vector2(legend.size.x * f, 0.0),
				Vector2(legend.size.x / float(steps) + 1.0, legend.size.y)),
				ReactorTheme.temp_color(t), true)
	draw_string(font, legend.position + Vector2(0.0, 18.0), "270 C",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, ReactorTheme.TEXT_FAINT)
	draw_string(font, legend.position + Vector2(legend.size.x - 46.0, 18.0),
			"2800 C", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, ReactorTheme.TEXT_FAINT)
