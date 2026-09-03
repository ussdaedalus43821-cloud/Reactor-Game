class_name AudioBus
extends Node

## Procedural sound via AudioStreamGenerator -- no audio assets ship with
## this project (see assets/audio/README.txt). Three channels, each an
## AudioStreamGeneratorPlayback fed a plain sine wave every _process():
## a looping "thrust" channel, a looping "beam" channel, and a one-shot
## "sfx" channel for fire/explosion/hyperdrive blips (only one sfx tone
## plays at a time -- a second call simply replaces the first, which is
## enough for a placeholder and keeps this file small).
##
## An autoload (name "AudioBus" in project.godot), so any script can call
## AudioBus.play_fire("rocket") etc. without holding a reference to it.

const MIX_RATE := 22050.0
const BUFFER_LENGTH := 0.2

var _thrust_playback: AudioStreamGeneratorPlayback
var _beam_playback: AudioStreamGeneratorPlayback
var _sfx_playback: AudioStreamGeneratorPlayback

var _thrust_active := false
var _beam_active := false
var _thrust_phase := 0.0
var _beam_phase := 0.0

var _sfx_freq := 440.0
var _sfx_volume := 0.0
var _sfx_remaining := 0.0
var _sfx_phase := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_thrust_playback = _make_playback(-14.0)
	_beam_playback = _make_playback(-10.0)
	_sfx_playback = _make_playback(-6.0)


func _make_playback(volume_db: float) -> AudioStreamGeneratorPlayback:
	var player := AudioStreamPlayer.new()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MIX_RATE
	gen.buffer_length = BUFFER_LENGTH
	player.stream = gen
	player.volume_db = volume_db
	add_child(player)
	player.play()
	return player.get_stream_playback()


func _process(_delta: float) -> void:
	# Gameplay scripts stop processing while paused (see game.gd's
	# process_mode split), so whatever set_thrust()/set_beam() last said
	# would otherwise keep looping silently-not-silent for as long as the
	# pause menu is open -- mute both looping channels directly instead.
	var paused := get_tree().paused
	_fill(_thrust_playback, _thrust_active and not paused, 55.0, 0.5, "_thrust_phase")
	_fill(_beam_playback, _beam_active and not paused, 220.0, 0.4, "_beam_phase")
	_fill_sfx()


## `phase_field` names one of this script's own float fields to advance --
## GDScript has no by-reference float parameter, so the phase accumulator
## is written back through `set(phase_field, phase)` instead of a return
## value the caller would have to remember to store.
func _fill(playback: AudioStreamGeneratorPlayback, active: bool, freq: float,
		volume: float, phase_field: String) -> void:
	var phase: float = get(phase_field)
	var frames := playback.get_frames_available()
	for i in range(frames):
		var sample := 0.0
		if active:
			sample = sin(phase) * volume
			phase = fmod(phase + TAU * freq / MIX_RATE, TAU)
		playback.push_frame(Vector2(sample, sample))
	set(phase_field, phase)


func _fill_sfx() -> void:
	var frames := _sfx_playback.get_frames_available()
	var dt := 1.0 / MIX_RATE
	for i in range(frames):
		var sample := 0.0
		if _sfx_remaining > 0.0:
			var envelope := clampf(_sfx_remaining / 0.04, 0.0, 1.0)
			sample = sin(_sfx_phase) * _sfx_volume * envelope
			_sfx_phase = fmod(_sfx_phase + TAU * _sfx_freq / MIX_RATE, TAU)
			_sfx_remaining -= dt
		_sfx_playback.push_frame(Vector2(sample, sample))


# ==========================================================================
# Public API
# ==========================================================================

func set_thrust(active: bool) -> void:
	_thrust_active = active


func set_beam(active: bool) -> void:
	_beam_active = active


func play_tone(freq: float, duration: float, volume: float = 0.35) -> void:
	_sfx_freq = freq
	_sfx_remaining = duration
	_sfx_volume = volume


func play_fire(weapon_type: String) -> void:
	match weapon_type:
		"rocket":
			play_tone(220.0, 0.14, 0.4)
		"homing":
			play_tone(440.0, 0.12, 0.35)
		"beam":
			pass   # the beam is its own looping channel, see set_beam()
		_:
			play_tone(880.0, 0.05, 0.3)


func play_explosion() -> void:
	play_tone(90.0, 0.35, 0.5)


func play_hyperdrive_charge() -> void:
	play_tone(150.0, 0.6, 0.3)
