"""
reactor_physics.py -- the hot loop.

Six-group delayed-neutron point kinetics coupled to a lumped thermal-
hydraulic model, integrated with fixed-step classical RK4. NumPy is used
when it is importable (the six precursor groups and the whole 10-element
state vector become array arithmetic); otherwise an identical pure-Python
path runs, so the simulator still works against a stock macOS `python3`
with no site-packages.

This module is pure physics: no I/O, no control logic, no game rules.
Control logic lives in reactor_rules.nova and is executed by
nova_runtime.py. The two are joined by reactor_server.py.

IMPORTANT: every constant below is mirrored in
godot/scripts/sim_local.gd so the GDScript fallback used for the iOS and
Web exports behaves identically. tools/check_parity.py verifies that.
"""

from __future__ import annotations

import math

try:  # pragma: no cover - depends on the host interpreter
    import numpy as _np

    HAVE_NUMPY = True
except Exception:  # pragma: no cover
    _np = None
    HAVE_NUMPY = False


# --------------------------------------------------------------------------
# Delayed neutron data (U-235 thermal, six groups)
# --------------------------------------------------------------------------

BETA_I = [0.000215, 0.001424, 0.001274, 0.002568, 0.000748, 0.000273]
LAMBDA_I = [0.0124, 0.0305, 0.111, 0.301, 1.14, 3.01]
BETA_TOTAL = sum(BETA_I)

# The true prompt-neutron generation time of a thermal reactor is ~2e-5 s.
# At the 0.05 s fixed step this simulation runs on, that makes the kinetics
# equation far too stiff for explicit RK4 (stability needs |dt*eig| < 2.785,
# which 2e-5 s violates by ~100x for realistic reactivity swings).
# LAMBDA_STAR is deliberately lengthened so RK4 stays inside its stability
# region at dt = 0.05 s while preserving the six-group structure and the
# qualitative dynamics operators actually feel.
LAMBDA_STAR = 0.01

PHYSICS_DT = 0.05
PHYSICS_HZ = 20

# --------------------------------------------------------------------------
# Reactivity model
# --------------------------------------------------------------------------

ROD_W_MIN_PCM = -3000.0     # per-bank worth, fully inserted (0 % withdrawn)
ROD_W_MAX_PCM = 6000.0      # per-bank worth, fully withdrawn (100 %)

ALPHA_FUEL_PCM_PER_C = -1.8     # Doppler / fuel feedback
ALPHA_MOD_PCM_PER_C = -6.0      # moderator feedback
TF_REF_C = 300.0
TM_REF_C = 290.0

# --------------------------------------------------------------------------
# Lumped thermal-hydraulics
# --------------------------------------------------------------------------

C_FUEL = 2.0
C_MOD = 8.0
HTC_FUEL_MOD = 1.6
HTC_MOD_OUT = 1.2
T_FEED_C = 270.0
TAU_OUTLET = 3.0
T_COLD_C = 270.0            # cold, subcritical starting temperature

MIN_FLUX = 1e-12
TEMP_FLOOR_C = -50.0
TEMP_CEILING_C = 12000.0

PRESSURE_BASE_MPA = 15.5
PRESSURE_PER_C = 0.02
PRESSURE_MIN_MPA = 0.1
PRESSURE_MAX_MPA = 22.0

MAX_ROD_RATE_PCT_S = 20.0   # finite control-rod drive speed


def clamp(v: float, lo: float, hi: float) -> float:
    return lo if v < lo else (hi if v > hi else v)


def bank_worth_pcm(position_percent: float) -> float:
    """Cubic rod worth: the last 10 % of withdrawal is worth far more than
    the first 10 %, which is what makes the endgame twitchy."""
    x = clamp(position_percent, 0.0, 100.0) / 100.0
    return ROD_W_MIN_PCM + (ROD_W_MAX_PCM - ROD_W_MIN_PCM) * (x * x * x)


def doppler_reactivity_pcm(fuel_temp_c: float) -> float:
    return ALPHA_FUEL_PCM_PER_C * (fuel_temp_c - TF_REF_C)


def moderator_reactivity_pcm(mod_temp_c: float) -> float:
    return ALPHA_MOD_PCM_PER_C * (mod_temp_c - TM_REF_C)


def total_reactivity_pcm(rod_a, rod_b, fuel_temp_c, mod_temp_c, xenon_pcm):
    return (bank_worth_pcm(rod_a) + bank_worth_pcm(rod_b)
            + doppler_reactivity_pcm(fuel_temp_c)
            + moderator_reactivity_pcm(mod_temp_c)
            + xenon_pcm)


def pressure_mpa(mod_temp_c: float) -> float:
    return clamp(PRESSURE_BASE_MPA + PRESSURE_PER_C * (mod_temp_c - TM_REF_C),
                 PRESSURE_MIN_MPA, PRESSURE_MAX_MPA)


# --------------------------------------------------------------------------
# Derivatives + RK4, pure-Python path
# --------------------------------------------------------------------------
#
# State vector y (10 elements):
#   y[0]      n           normalised neutron density (1.0 == 100 % power)
#   y[1..6]   C1..C6      delayed neutron precursor concentrations
#   y[7]      T_fuel      degC
#   y[8]      T_mod       degC
#   y[9]      T_out       degC (loop outlet, lags the moderator)
#
# `p` carries this tick's boundary conditions -- rod positions, coolant flow
# and turbine load fractions, xenon worth and decay heat. They are held
# constant across the four RK4 stages of one step, which is what makes the
# step deterministic and reproducible between the Python and GDScript
# implementations.


def _derivs_py(y, p):
    n = y[0]
    t_fuel, t_mod, t_out = y[7], y[8], y[9]

    rho_pcm = total_reactivity_pcm(p["rod_a"], p["rod_b"], t_fuel, t_mod,
                                   p["xenon_pcm"])
    rho = rho_pcm / 1.0e5

    dn = ((rho - BETA_TOTAL) / LAMBDA_STAR) * n
    for i in range(6):
        dn += LAMBDA_I[i] * y[1 + i]

    out = [dn, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    for i in range(6):
        out[1 + i] = (BETA_I[i] / LAMBDA_STAR) * n - LAMBDA_I[i] * y[1 + i]

    flow = p["flow_frac"]
    load = p["load_frac"]
    p_percent = n * 100.0 + p["decay_heat_pct"]

    out[7] = (p_percent - HTC_FUEL_MOD * flow * (t_fuel - t_mod)) / C_FUEL
    out[8] = (HTC_FUEL_MOD * flow * (t_fuel - t_mod)
              - HTC_MOD_OUT * load * flow * (t_mod - T_FEED_C)) / C_MOD
    out[9] = (t_mod - t_out) / TAU_OUTLET
    return out


def _rk4_py(y, dt, p):
    k1 = _derivs_py(y, p)
    y2 = [y[i] + 0.5 * dt * k1[i] for i in range(10)]
    k2 = _derivs_py(y2, p)
    y3 = [y[i] + 0.5 * dt * k2[i] for i in range(10)]
    k3 = _derivs_py(y3, p)
    y4 = [y[i] + dt * k3[i] for i in range(10)]
    k4 = _derivs_py(y4, p)

    out = [y[i] + (dt / 6.0) * (k1[i] + 2.0 * k2[i] + 2.0 * k3[i] + k4[i])
           for i in range(10)]
    return _sanitise_py(out)


def _sanitise_py(y):
    """Keep the integrator inside physical bounds. A diverging transient
    should read as a meltdown, never as a NaN that takes the UI with it."""
    if not (y[0] == y[0]) or y[0] < MIN_FLUX:   # NaN-safe
        y[0] = MIN_FLUX
    for i in range(1, 7):
        if not (y[i] == y[i]) or y[i] < 0.0:
            y[i] = 0.0
    for i in (7, 8, 9):
        v = y[i]
        if not (v == v):
            v = TEMP_CEILING_C
        y[i] = clamp(v, TEMP_FLOOR_C, TEMP_CEILING_C)
    return y


# --------------------------------------------------------------------------
# Derivatives + RK4, NumPy path
# --------------------------------------------------------------------------

if HAVE_NUMPY:  # pragma: no cover - exercised only where numpy exists
    _BETA_ARR = _np.array(BETA_I, dtype=_np.float64)
    _LAM_ARR = _np.array(LAMBDA_I, dtype=_np.float64)

    def _derivs_np(y, p):
        n = y[0]
        c = y[1:7]
        t_fuel, t_mod, t_out = y[7], y[8], y[9]

        rho_pcm = total_reactivity_pcm(p["rod_a"], p["rod_b"], t_fuel, t_mod,
                                       p["xenon_pcm"])
        rho = rho_pcm / 1.0e5

        out = _np.empty(10, dtype=_np.float64)
        out[0] = ((rho - BETA_TOTAL) / LAMBDA_STAR) * n + float(_LAM_ARR @ c)
        out[1:7] = (_BETA_ARR / LAMBDA_STAR) * n - _LAM_ARR * c

        flow = p["flow_frac"]
        load = p["load_frac"]
        p_percent = n * 100.0 + p["decay_heat_pct"]

        out[7] = (p_percent - HTC_FUEL_MOD * flow * (t_fuel - t_mod)) / C_FUEL
        out[8] = (HTC_FUEL_MOD * flow * (t_fuel - t_mod)
                  - HTC_MOD_OUT * load * flow * (t_mod - T_FEED_C)) / C_MOD
        out[9] = (t_mod - t_out) / TAU_OUTLET
        return out

    def _rk4_np(y, dt, p):
        k1 = _derivs_np(y, p)
        k2 = _derivs_np(y + 0.5 * dt * k1, p)
        k3 = _derivs_np(y + 0.5 * dt * k2, p)
        k4 = _derivs_np(y + dt * k3, p)
        out = y + (dt / 6.0) * (k1 + 2.0 * k2 + 2.0 * k3 + k4)
        return _sanitise_np(out)

    def _sanitise_np(y):
        y = _np.nan_to_num(y, nan=0.0, posinf=TEMP_CEILING_C,
                           neginf=TEMP_FLOOR_C)
        y[0] = max(float(y[0]), MIN_FLUX)
        y[1:7] = _np.maximum(y[1:7], 0.0)
        y[7:10] = _np.clip(y[7:10], TEMP_FLOOR_C, TEMP_CEILING_C)
        return y


BACKEND = "numpy" if HAVE_NUMPY else "python"


# --------------------------------------------------------------------------
# Core object
# --------------------------------------------------------------------------

class ReactorPhysics:
    """Integrates the core. Owns no policy -- rods are handed to it as
    positions, faults as flow/load/xenon multipliers."""

    def __init__(self):
        self.reset()

    def reset(self):
        n0 = 1.0e-6
        c0 = [(BETA_I[i] / (LAMBDA_STAR * LAMBDA_I[i])) * n0 for i in range(6)]
        y = [n0] + c0 + [T_COLD_C, T_COLD_C, T_COLD_C]
        self.y = _np.array(y, dtype=_np.float64) if HAVE_NUMPY else y
        self.reactivity_pcm = 0.0

    # -- accessors -------------------------------------------------------

    @property
    def flux_percent(self) -> float:
        return float(self.y[0]) * 100.0

    @property
    def fuel_temp(self) -> float:
        return float(self.y[7])

    @property
    def mod_temp(self) -> float:
        return float(self.y[8])

    @property
    def out_temp(self) -> float:
        return float(self.y[9])

    @property
    def pressure(self) -> float:
        return pressure_mpa(self.mod_temp)

    # -- integration -----------------------------------------------------

    def step(self, dt, rod_a, rod_b, flow_frac, load_frac, xenon_pcm,
             decay_heat_pct):
        p = {
            "rod_a": rod_a,
            "rod_b": rod_b,
            "flow_frac": flow_frac,
            "load_frac": load_frac,
            "xenon_pcm": xenon_pcm,
            "decay_heat_pct": decay_heat_pct,
        }
        self.y = _rk4_np(self.y, dt, p) if HAVE_NUMPY else _rk4_py(self.y, dt, p)
        self.reactivity_pcm = total_reactivity_pcm(
            rod_a, rod_b, self.fuel_temp, self.mod_temp, xenon_pcm)
        return self.reactivity_pcm

    def snapshot(self) -> dict:
        return {
            "flux_pct": self.flux_percent,
            "fuel_temp_c": self.fuel_temp,
            "mod_temp_c": self.mod_temp,
            "out_temp_c": self.out_temp,
            "pressure_mpa": self.pressure,
            "reactivity_pcm": self.reactivity_pcm,
        }


def drive_rod(position: float, target: float, dt: float, stuck: bool) -> float:
    """Move one rod bank toward its target at the finite drive rate."""
    if stuck:
        return position
    diff = target - position
    max_delta = MAX_ROD_RATE_PCT_S * dt
    if abs(diff) <= max_delta:
        return clamp(target, 0.0, 100.0)
    return clamp(position + (max_delta if diff > 0.0 else -max_delta),
                 0.0, 100.0)


def decay_heat_pct(flux_pct_at_scram: float, seconds_since_scram: float,
                   initial_frac: float, tau_s: float) -> float:
    """Fission products keep making heat after the rods are in. Drops to
    ~7 % of pre-trip power immediately, then decays exponentially."""
    frac = max(0.0, flux_pct_at_scram / 100.0)
    return initial_frac * frac * math.exp(-seconds_since_scram / tau_s)
