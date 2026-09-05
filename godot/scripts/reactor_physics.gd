class_name ReactorCore
extends RefCounted

## Six-group point kinetics + lumped thermal-hydraulics, fixed-step RK4.
##
## A line-for-line port of sim/reactor_physics.py. It runs the core on iOS
## and Web, where Godot cannot spawn the Python daemon. Every constant here
## is checked against the Python original by tools/check_parity.py, so the
## two can never silently drift apart.

# -- delayed neutron data (U-235 thermal, six groups) ----------------------
const BETA_I := [0.000215, 0.001424, 0.001274, 0.002568, 0.000748, 0.000273]
const LAMBDA_I := [0.0124, 0.0305, 0.111, 0.301, 1.14, 3.01]
const BETA_TOTAL := 0.006502

## The true prompt-neutron generation time is ~2e-5 s, which makes the
## kinetics equation far too stiff for explicit RK4 at a 0.05 s step.
## LAMBDA_STAR is deliberately lengthened so RK4 stays inside its stability
## region while keeping the six-group structure and the dynamics an
## operator actually feels.
const LAMBDA_STAR := 0.01

const PHYSICS_DT := 0.05
const PHYSICS_HZ := 20

# -- reactivity model ------------------------------------------------------
const ROD_W_MIN_PCM := -3000.0
const ROD_W_MAX_PCM := 6000.0
const ALPHA_FUEL_PCM_PER_C := -1.8
const ALPHA_MOD_PCM_PER_C := -6.0
const TF_REF_C := 300.0
const TM_REF_C := 290.0

# -- lumped thermal-hydraulics --------------------------------------------
const C_FUEL := 2.0
const C_MOD := 8.0
const HTC_FUEL_MOD := 1.6
const HTC_MOD_OUT := 1.2
const T_FEED_C := 270.0
const TAU_OUTLET := 3.0
const T_COLD_C := 270.0

const MIN_FLUX := 1e-12
const TEMP_FLOOR_C := -50.0
const TEMP_CEILING_C := 12000.0

const PRESSURE_BASE_MPA := 15.5
const PRESSURE_PER_C := 0.02
const PRESSURE_MIN_MPA := 0.1
const PRESSURE_MAX_MPA := 22.0

const MAX_ROD_RATE_PCT_S := 20.0

## State vector, 10 elements:
##   [0]     n        normalised neutron density, 1.0 == 100 % power
##   [1..6]  C1..C6   delayed neutron precursors
##   [7]     T_fuel   degC
##   [8]     T_mod    degC
##   [9]     T_out    degC, loop outlet (lags the moderator)
var y: PackedFloat64Array = PackedFloat64Array()
var reactivity_pcm := 0.0

# Boundary conditions for the step in progress, held constant across all
# four RK4 stages.
var _rod_a := 0.0
var _rod_b := 0.0
var _flow := 1.0
var _load := 1.0
var _xenon := 0.0
var _decay := 0.0

var _k1 := PackedFloat64Array()
var _k2 := PackedFloat64Array()
var _k3 := PackedFloat64Array()
var _k4 := PackedFloat64Array()
var _tmp := PackedFloat64Array()


func _init() -> void:
	y.resize(10)
	_k1.resize(10)
	_k2.resize(10)
	_k3.resize(10)
	_k4.resize(10)
	_tmp.resize(10)
	reset()


func reset() -> void:
	var n0 := 1.0e-6
	y[0] = n0
	for i in range(6):
		y[1 + i] = (float(BETA_I[i]) / (LAMBDA_STAR * float(LAMBDA_I[i]))) * n0
	y[7] = T_COLD_C
	y[8] = T_COLD_C
	y[9] = T_COLD_C
	reactivity_pcm = 0.0


# -- reactivity ------------------------------------------------------------

## Cubic rod worth: the last 10 % of withdrawal is worth far more than the
## first 10 %, which is what makes the top of the band twitchy.
static func bank_worth_pcm(position_percent: float) -> float:
	var x := clampf(position_percent, 0.0, 100.0) / 100.0
	return ROD_W_MIN_PCM + (ROD_W_MAX_PCM - ROD_W_MIN_PCM) * (x * x * x)


static func doppler_reactivity_pcm(fuel_temp_c: float) -> float:
	return ALPHA_FUEL_PCM_PER_C * (fuel_temp_c - TF_REF_C)


static func moderator_reactivity_pcm(mod_temp_c: float) -> float:
	return ALPHA_MOD_PCM_PER_C * (mod_temp_c - TM_REF_C)


static func total_reactivity_pcm(rod_a: float, rod_b: float, fuel_temp_c: float,
		mod_temp_c: float, xenon_pcm: float) -> float:
	return bank_worth_pcm(rod_a) + bank_worth_pcm(rod_b) \
		+ doppler_reactivity_pcm(fuel_temp_c) \
		+ moderator_reactivity_pcm(mod_temp_c) + xenon_pcm


static func pressure_from_mod_temp(mod_temp_c: float) -> float:
	return clampf(PRESSURE_BASE_MPA + PRESSURE_PER_C * (mod_temp_c - TM_REF_C),
			PRESSURE_MIN_MPA, PRESSURE_MAX_MPA)


# -- integration -----------------------------------------------------------

func _derivs(state: PackedFloat64Array, out: PackedFloat64Array) -> void:
	var n := state[0]
	var t_fuel := state[7]
	var t_mod := state[8]
	var t_out := state[9]

	var rho_pcm := total_reactivity_pcm(_rod_a, _rod_b, t_fuel, t_mod, _xenon)
	var rho := rho_pcm / 1.0e5

	var dn := ((rho - BETA_TOTAL) / LAMBDA_STAR) * n
	for i in range(6):
		dn += float(LAMBDA_I[i]) * state[1 + i]
	out[0] = dn

	for i in range(6):
		out[1 + i] = (float(BETA_I[i]) / LAMBDA_STAR) * n \
			- float(LAMBDA_I[i]) * state[1 + i]

	var p_percent := n * 100.0 + _decay
	out[7] = (p_percent - HTC_FUEL_MOD * _flow * (t_fuel - t_mod)) / C_FUEL
	out[8] = (HTC_FUEL_MOD * _flow * (t_fuel - t_mod) \
		- HTC_MOD_OUT * _load * _flow * (t_mod - T_FEED_C)) / C_MOD
	out[9] = (t_mod - t_out) / TAU_OUTLET


func _stage(base: PackedFloat64Array, k: PackedFloat64Array, scale: float) -> void:
	for i in range(10):
		_tmp[i] = base[i] + scale * k[i]


## Classic 4th-order Runge-Kutta over the whole state vector at once.
## Euler appears nowhere in this simulation.
func step(dt: float, rod_a: float, rod_b: float, flow_frac: float,
		load_frac: float, xenon_pcm: float, decay_pct: float) -> float:
	_rod_a = rod_a
	_rod_b = rod_b
	_flow = flow_frac
	_load = load_frac
	_xenon = xenon_pcm
	_decay = decay_pct

	_derivs(y, _k1)
	_stage(y, _k1, dt * 0.5)
	_derivs(_tmp, _k2)
	_stage(y, _k2, dt * 0.5)
	_derivs(_tmp, _k3)
	_stage(y, _k3, dt)
	_derivs(_tmp, _k4)

	var sixth := dt / 6.0
	for i in range(10):
		y[i] = y[i] + sixth * (_k1[i] + 2.0 * _k2[i] + 2.0 * _k3[i] + _k4[i])

	_sanitise()
	reactivity_pcm = total_reactivity_pcm(rod_a, rod_b, y[7], y[8], xenon_pcm)
	return reactivity_pcm


## Keep the integrator inside physical bounds. A diverging transient must
## read as a meltdown on the panel, never as a NaN that takes the UI down.
func _sanitise() -> void:
	if is_nan(y[0]) or y[0] < MIN_FLUX:
		y[0] = MIN_FLUX
	for i in range(1, 7):
		if is_nan(y[i]) or y[i] < 0.0:
			y[i] = 0.0
	for i in range(7, 10):
		if is_nan(y[i]):
			y[i] = TEMP_CEILING_C
		y[i] = clampf(y[i], TEMP_FLOOR_C, TEMP_CEILING_C)


# -- accessors -------------------------------------------------------------

func flux_percent() -> float:
	return y[0] * 100.0

func fuel_temp() -> float:
	return y[7]

func mod_temp() -> float:
	return y[8]

func out_temp() -> float:
	return y[9]

func pressure() -> float:
	return pressure_from_mod_temp(y[8])


# -- helpers shared with the host ------------------------------------------

## Move one rod bank toward its target at the finite drive rate.
static func drive_rod(position: float, target: float, dt: float,
		stuck: bool) -> float:
	if stuck:
		return position
	var diff := target - position
	var max_delta := MAX_ROD_RATE_PCT_S * dt
	if absf(diff) <= max_delta:
		return clampf(target, 0.0, 100.0)
	return clampf(position + (max_delta if diff > 0.0 else -max_delta),
			0.0, 100.0)


## Fission products keep making heat after the rods are in: ~7 % of pre-trip
## power immediately, decaying exponentially from there.
static func decay_heat_pct(flux_pct_at_scram: float, seconds_since_scram: float,
		initial_frac: float, tau_s: float) -> float:
	var frac := maxf(0.0, flux_pct_at_scram / 100.0)
	return initial_frac * frac * exp(-seconds_since_scram / tau_s)
