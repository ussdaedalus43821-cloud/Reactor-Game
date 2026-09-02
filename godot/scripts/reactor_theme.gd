class_name ReactorTheme
extends RefCounted

## Shared palette and small drawing helpers. Every widget pulls its colours
## from here so the panel reads as one instrument rack rather than eight
## separately-styled boxes.

const BG          := Color("0a0c11")
const PANEL       := Color("141821")
const PANEL_DEEP  := Color("0d1017")
const BEZEL       := Color("2b3242")
const BEZEL_LIT   := Color("3e4759")
const GRID_LINE   := Color("1e2431")

const TEXT        := Color("dfe6f0")
const TEXT_DIM    := Color("7c8699")
const TEXT_FAINT  := Color("4a5364")

const GREEN       := Color("3fd18a")
const CYAN        := Color("46d3dc")
const BLUE        := Color("4b96eb")
const AMBER       := Color("f0a63c")
const YELLOW      := Color("e8c828")
const RED         := Color("e34747")
const MAGENTA     := Color("e05ac8")
const WHITE       := Color("f2f5fa")

## Operating states, in the order the plant walks through them.
const STATE_COLORS := {
	"STARTUP": BLUE,
	"POWER ASCENSION": CYAN,
	"STEADY": GREEN,
	"OVERHEAT": AMBER,
	"SCRAM": YELLOW,
	"MELTDOWN": RED,
	"SECURED": GREEN,
}

## Alarm tiers raised by reactor_rules.nova: 0 clear, 1 advisory,
## 2 caution, 3 emergency.
const ALARM_COLORS := [TEXT_DIM, CYAN, AMBER, RED]


static func state_color(state: String) -> Color:
	return STATE_COLORS.get(state, TEXT)


static func alarm_color(level: int) -> Color:
	return ALARM_COLORS[clampi(level, 0, ALARM_COLORS.size() - 1)]


## Core temperature -> colour. Same stops as temp_to_color() in the
## heatmap shader and in the Python reference implementation.
static func temp_color(t: float) -> Color:
	if t <= 300.0:
		return Color(0.059, 0.118, 0.549) * (0.25 + 0.75 * clampf(t / 300.0, 0.0, 1.0))
	if t < 800.0:
		return Color(0.059, 0.118, 0.549).lerp(Color(1.0, 0.843, 0.157),
				(t - 300.0) / 500.0)
	if t < 1800.0:
		return Color(1.0, 0.843, 0.157).lerp(Color.WHITE, (t - 800.0) / 1000.0)
	return Color.WHITE.lerp(Color(1.0, 0.098, 0.098),
			clampf((t - 1800.0) / 1000.0, 0.0, 1.0))


## A sunken instrument bay: dark well, lit top-left bevel, dark bottom-right.
static func draw_bay(ci: CanvasItem, rect: Rect2, fill: Color = PANEL_DEEP) -> void:
	ci.draw_rect(rect, fill, true)
	ci.draw_rect(rect, BEZEL, false, 2.0)
	ci.draw_line(rect.position + Vector2(1, 1),
			rect.position + Vector2(rect.size.x - 1, 1), BEZEL_LIT, 1.0)
	ci.draw_line(rect.position + Vector2(1, 1),
			rect.position + Vector2(1, rect.size.y - 1), BEZEL_LIT, 1.0)


## Panel caption, drawn in the bezel above a bay.
static func draw_caption(ci: CanvasItem, font: Font, pos: Vector2, text: String,
		size: int = 13, color: Color = TEXT_DIM) -> void:
	ci.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
