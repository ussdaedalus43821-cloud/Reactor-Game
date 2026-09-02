class_name EventLog
extends Control

## Scrolling operator log.
##
## Every line NovaLang emits -- trips, alarms, faults appearing and
## clearing -- lands here stamped with plant time. New lines slide up from
## the bottom and fade in; old ones dim with age so the eye is drawn to
## what just happened rather than to the wall of text above it.

const MAX_LINES := 64
const LINE_HEIGHT := 18.0
const SLIDE_TIME := 0.22

class Entry:
	var text: String
	var stamp: String
	var color: Color
	var age: float = 0.0
	var slide: float = 1.0     # 1 -> just arrived, 0 -> settled

	func _init(t: String, s: String, c: Color) -> void:
		text = t
		stamp = s
		color = c

var _entries: Array = []


func _ready() -> void:
	set_process(true)


func clear_log() -> void:
	_entries.clear()
	queue_redraw()


## Colour is inferred from the text so reactor_rules.nova stays free of
## presentation concerns: the policy says what happened, the panel decides
## how alarming it should look.
func add_line(text: String, plant_time: float) -> void:
	var upper := text.to_upper()
	var color := ReactorTheme.TEXT
	if upper.contains("MELTDOWN") or upper.contains("DISASSEMBLY"):
		color = ReactorTheme.RED
	elif upper.contains("SCRAM") or upper.contains("TRIP"):
		color = ReactorTheme.YELLOW
	elif upper.begins_with("ALARM"):
		color = ReactorTheme.AMBER
	elif upper.contains("CAUTION"):
		color = ReactorTheme.AMBER.darkened(0.15)
	elif upper.contains("CLEARED") or upper.contains("COMPLETE") \
			or upper.contains("RESTORED"):
		color = ReactorTheme.GREEN
	elif upper.contains("SURVIVED") or upper.contains("VETERAN"):
		color = ReactorTheme.GREEN

	var stamp := "T+%02d:%02d" % [int(plant_time) / 60, int(plant_time) % 60]
	_entries.append(Entry.new(text, stamp, color))
	while _entries.size() > MAX_LINES:
		_entries.remove_at(0)
	queue_redraw()


func _process(delta: float) -> void:
	var animating := false
	for item in _entries:
		var entry: Entry = item
		entry.age += delta
		if entry.slide > 0.0:
			entry.slide = maxf(0.0, entry.slide - delta / SLIDE_TIME)
			animating = true
	if animating:
		queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	var rect := Rect2(Vector2.ZERO, size)
	ReactorTheme.draw_bay(self, rect)

	draw_string(font, Vector2(10.0, 17.0), "EVENT LOG",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, ReactorTheme.TEXT_DIM)
	draw_line(Vector2(8.0, 24.0), Vector2(size.x - 8.0, 24.0),
			ReactorTheme.BEZEL, 1.0)

	var top := 30.0
	var visible_lines := int(floor((size.y - top - 6.0) / LINE_HEIGHT))
	if visible_lines <= 0:
		return

	var first := maxi(0, _entries.size() - visible_lines)
	var row := 0
	for i in range(first, _entries.size()):
		var entry: Entry = _entries[i]
		var y := top + row * LINE_HEIGHT + LINE_HEIGHT - 5.0
		y += entry.slide * LINE_HEIGHT      # slide up into place

		# Newest line is full strength; older ones fade toward the bezel.
		var recency := float(row + 1) / float(visible_lines)
		var alpha := (0.32 + 0.68 * recency) * (1.0 - entry.slide * 0.6)

		draw_string(font, Vector2(10.0, y), entry.stamp,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				Color(ReactorTheme.TEXT_FAINT, alpha))
		draw_string(font, Vector2(66.0, y), entry.text,
				HORIZONTAL_ALIGNMENT_LEFT, int(size.x - 74.0), 12,
				Color(entry.color, alpha))
		row += 1
