class_name ReadoutPanel
extends Control

## Secondary instrumentation: the numbers that explain *why* the dials are
## doing what they are doing.
##
## Coolant flow and turbine load show which fault is biting; xenon worth
## and decay heat explain reactivity the rods do not account for; the two
## rod positions show the drives actually catching up to their commands.

const ROW_HEIGHT := 22.0

var rows: Array = []        # [[label, text, Color], ...]


func set_rows(new_rows: Array) -> void:
	rows = new_rows
	queue_redraw()


## Build the standard set from a bridge state Dictionary.
func apply_state(state: Dictionary) -> void:
	var flow := float(state.get("flow_frac", 1.0))
	var load := float(state.get("load_frac", 1.0))
	var xenon := float(state.get("xenon_pcm", 0.0))
	set_rows([
		["MODERATOR", "%7.1f C" % float(state.get("mod_temp_c", 0.0)),
			ReactorTheme.temp_color(float(state.get("mod_temp_c", 0.0)))],
		["LOOP OUTLET", "%7.1f C" % float(state.get("out_temp_c", 0.0)),
			ReactorTheme.TEXT],
		["COOLANT FLOW", "%6.0f %%" % (flow * 100.0),
			ReactorTheme.GREEN if flow > 0.9 else ReactorTheme.RED],
		["TURBINE LOAD", "%6.0f %%" % (load * 100.0),
			ReactorTheme.GREEN if load > 0.9 else ReactorTheme.AMBER],
		["XENON WORTH", "%+7.1f pcm" % xenon,
			ReactorTheme.TEXT_DIM if xenon > -1.0 else ReactorTheme.CYAN],
		["BANK A", "%6.1f %% out" % float(state.get("rod_a", 0.0)),
			ReactorTheme.BLUE],
		["BANK B", "%6.1f %% out" % float(state.get("rod_b", 0.0)),
			ReactorTheme.MAGENTA],
	])


func _draw() -> void:
	var font := get_theme_default_font()
	ReactorTheme.draw_bay(self, Rect2(Vector2.ZERO, size))

	draw_string(font, Vector2(10.0, 17.0), "PLANT PARAMETERS",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, ReactorTheme.TEXT_DIM)
	draw_line(Vector2(8.0, 24.0), Vector2(size.x - 8.0, 24.0),
			ReactorTheme.BEZEL, 1.0)

	var y := 30.0
	for row in rows:
		if y + ROW_HEIGHT > size.y:
			break
		var baseline := y + ROW_HEIGHT - 6.0
		draw_string(font, Vector2(12.0, baseline), str(row[0]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, ReactorTheme.TEXT_DIM)
		var text := str(row[1])
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		draw_string(font, Vector2(size.x - 12.0 - w, baseline), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, row[2])
		# Hairline between rows keeps the column readable at a glance.
		draw_line(Vector2(10.0, y + ROW_HEIGHT - 1.0),
				Vector2(size.x - 10.0, y + ROW_HEIGHT - 1.0),
				Color(ReactorTheme.GRID_LINE, 0.7), 1.0)
		y += ROW_HEIGHT
