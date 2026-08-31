"""
Project Chernobyl - Nuclear Reactor Control Room Simulator

A standalone pygame simulation of a PWR-style reactor core: six-group
point kinetics integrated with fixed-step RK4, lumped thermal-hydraulics,
a random fault injector, and a full control-room dashboard.

Controls:
  Mouse   - drag the Bank A / Bank B rod sliders, click the SCRAM button
  SPACE   - emergency SCRAM
  R       - reset after MELTDOWN or a VETERAN OPERATOR win
"""

import sys
import math
import random
import array
from collections import deque

import pygame

# --------------------------------------------------------------------------
# Window / timing
# --------------------------------------------------------------------------

WIDTH, HEIGHT = 1440, 900
RENDER_FPS = 60
PHYSICS_DT = 0.05          # fixed physics timestep (20 Hz), required for RK4 stability
PHYSICS_HZ = 20

HISTORY_MAXLEN = 1200      # 60s * 20Hz, per spec

# --------------------------------------------------------------------------
# Colors
# --------------------------------------------------------------------------

BG_COLOR = (16, 18, 24)
PANEL_BG = (26, 29, 36)
PANEL_BORDER = (58, 63, 74)
TEXT_COLOR = (225, 230, 235)
DIM_TEXT = (145, 150, 162)
GREEN = (60, 200, 110)
YELLOW = (232, 200, 40)
RED = (225, 55, 55)
ORANGE = (240, 145, 30)
BLUE = (70, 150, 235)
CYAN = (70, 210, 220)
WHITE = (245, 245, 250)
BLACK = (0, 0, 0)


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def lerp_color(c0, c1, f):
    f = clamp(f, 0.0, 1.0)
    return tuple(int(c0[i] + (c1[i] - c0[i]) * f) for i in range(3))


# ==========================================================================
# CORE PHYSICS: six-group delayed-neutron point kinetics + thermal-hydraulics
# ==========================================================================

# U-235 thermal six-group delayed neutron data (beta_i, lambda_i[1/s])
BETA_I = [0.000215, 0.001424, 0.001274, 0.002568, 0.000748, 0.000273]
LAMBDA_I = [0.0124, 0.0305, 0.111, 0.301, 1.14, 3.01]
BETA_TOTAL = sum(BETA_I)

# The physical prompt-neutron generation time for a thermal reactor is
# ~2e-5s. At dt=0.05s that makes the kinetics equation unconditionally
# stiff for explicit RK4 (the stability boundary requires |dt*eigenvalue|
# < ~2.785, and 2e-5s blows past it by ~100x for realistic reactivity
# swings). LAMBDA_STAR is deliberately lengthened so RK4 stays inside its
# stability region at the required fixed 0.05s step while keeping the
# same six-group structure and qualitative dynamics.
LAMBDA_STAR = 0.01

# Control rod worth: cubic (non-linear) per bank, in pcm.
# 90%->100% withdrawal therefore adds far more reactivity than 0%->10%.
ROD_W_MIN_PCM = -3000.0   # per-bank worth fully inserted (0%)
ROD_W_MAX_PCM = 6000.0    # per-bank worth fully withdrawn (100%)

# Temperature feedback coefficients (both negative -> self-regulating core)
ALPHA_FUEL_PCM_PER_C = -1.8    # Doppler (fuel) feedback
ALPHA_MOD_PCM_PER_C = -6.0     # Moderator feedback
TF_REF_C = 300.0
TM_REF_C = 290.0

# Lumped thermal-hydraulic constants
C_FUEL = 2.0
C_MOD = 8.0
HTC_FUEL_MOD = 1.6
HTC_MOD_OUT = 1.2
T_FEED_C = 270.0
TAU_OUTLET = 3.0

MIN_FLUX = 1e-12

# Decay heat: instantly drops to ~7% of the pre-SCRAM power fraction, then
# decays exponentially (tau chosen so it is negligible by ~600s).
DECAY_HEAT_INITIAL_FRAC = 7.0
DECAY_HEAT_TAU_S = 130.0
SCRAM_COOLDOWN_S = 600.0

XENON_MAX_PCM = 400.0
XENON_RAMP_S = 60.0

MELTDOWN_TEMP_C = 2800.0
MELTDOWN_SUSTAIN_S = 5.0
OVERHEAT_TEMP_C = 1500.0
STARTUP_FLUX_PCT = 3.0
WIN_TIME_S = 900.0

MAX_ROD_RATE_PCT_S = 20.0   # finite rod-drive speed


def bank_worth_pcm(position_percent):
    x = clamp(position_percent, 0.0, 100.0) / 100.0
    return ROD_W_MIN_PCM + (ROD_W_MAX_PCM - ROD_W_MIN_PCM) * (x ** 3)


def doppler_reactivity_pcm(fuel_temp_c):
    return ALPHA_FUEL_PCM_PER_C * (fuel_temp_c - TF_REF_C)


def moderator_reactivity_pcm(mod_temp_c):
    return ALPHA_MOD_PCM_PER_C * (mod_temp_c - TM_REF_C)


def point_kinetics_derivatives(y, p):
    """y = [n, C1..C6, T_fuel, T_mod, T_out]. p holds this tick's boundary
    conditions (rod positions, flow/load fractions, xenon, decay heat),
    held constant across the four RK4 stages of a single 0.05s step."""
    n = y[0]
    c = y[1:7]
    t_fuel, t_mod, t_out = y[7], y[8], y[9]

    rho_pcm = (bank_worth_pcm(p['rod_a']) + bank_worth_pcm(p['rod_b'])
               + doppler_reactivity_pcm(t_fuel) + moderator_reactivity_pcm(t_mod)
               + p['xenon_pcm'])
    rho = rho_pcm / 1.0e5

    dn_dt = ((rho - BETA_TOTAL) / LAMBDA_STAR) * n + sum(LAMBDA_I[i] * c[i] for i in range(6))
    dc_dt = [(BETA_I[i] / LAMBDA_STAR) * n - LAMBDA_I[i] * c[i] for i in range(6)]

    flow = p['flow_frac']
    load = p['load_frac']
    p_percent = n * 100.0 + p['decay_heat_pct']

    dtf_dt = (p_percent - HTC_FUEL_MOD * flow * (t_fuel - t_mod)) / C_FUEL
    dtm_dt = (HTC_FUEL_MOD * flow * (t_fuel - t_mod)
              - HTC_MOD_OUT * load * flow * (t_mod - T_FEED_C)) / C_MOD
    dto_dt = (t_mod - t_out) / TAU_OUTLET

    return [dn_dt] + dc_dt + [dtf_dt, dtm_dt, dto_dt]


def rk4_step(y, dt, params):
    """Classic 4th-order Runge-Kutta, fixed dt, applied to the whole
    state vector (kinetics + thermal-hydraulics) at once. Euler is never
    used anywhere in this simulation."""
    k1 = point_kinetics_derivatives(y, params)
    y2 = [y[i] + dt / 2.0 * k1[i] for i in range(len(y))]
    k2 = point_kinetics_derivatives(y2, params)
    y3 = [y[i] + dt / 2.0 * k2[i] for i in range(len(y))]
    k3 = point_kinetics_derivatives(y3, params)
    y4 = [y[i] + dt * k3[i] for i in range(len(y))]
    k4 = point_kinetics_derivatives(y4, params)

    y_new = [y[i] + dt / 6.0 * (k1[i] + 2 * k2[i] + 2 * k3[i] + k4[i]) for i in range(len(y))]

    y_new[0] = max(y_new[0], MIN_FLUX)
    for i in range(1, 7):
        y_new[i] = max(y_new[i], 0.0)
    for i in (7, 8, 9):
        y_new[i] = clamp(y_new[i], -50.0, 12000.0)  # graceful cap, never crash
    return y_new


class ReactorPhysics:
    def __init__(self):
        self.reset()

    def reset(self):
        n0 = 1.0e-6
        c0 = [(BETA_I[i] / (LAMBDA_STAR * LAMBDA_I[i])) * n0 for i in range(6)]
        self.y = [n0] + c0 + [270.0, 270.0, 270.0]
        self.last_reactivity_pcm = 0.0

    def step(self, dt, rod_a_pos, rod_b_pos, flow_frac, load_frac, xenon_pcm, decay_heat_pct):
        params = dict(rod_a=rod_a_pos, rod_b=rod_b_pos, flow_frac=flow_frac,
                      load_frac=load_frac, xenon_pcm=xenon_pcm, decay_heat_pct=decay_heat_pct)
        self.y = rk4_step(self.y, dt, params)
        self.last_reactivity_pcm = (bank_worth_pcm(rod_a_pos) + bank_worth_pcm(rod_b_pos)
                                     + doppler_reactivity_pcm(self.y[7])
                                     + moderator_reactivity_pcm(self.y[8]) + xenon_pcm)

    @property
    def flux_percent(self):
        return self.y[0] * 100.0

    @property
    def fuel_temp(self):
        return self.y[7]

    @property
    def mod_temp(self):
        return self.y[8]

    @property
    def out_temp(self):
        return self.y[9]

    @property
    def pressure_mpa(self):
        return clamp(15.5 + 0.02 * (self.mod_temp - TM_REF_C), 0.1, 22.0)


# ==========================================================================
# CONTROL RODS
# ==========================================================================

class ControlRodBank:
    def __init__(self, name):
        self.name = name
        self.target = 0.0
        self.position = 0.0

    def set_target(self, value):
        self.target = clamp(value, 0.0, 100.0)

    def update(self, dt, stuck):
        if stuck:
            return
        diff = self.target - self.position
        max_delta = MAX_ROD_RATE_PCT_S * dt
        if abs(diff) <= max_delta:
            self.position = self.target
        else:
            self.position += max_delta if diff > 0 else -max_delta

    def scram(self):
        # "instantly drives all rods to 0% insertion" -- bypasses rate limit
        self.target = 0.0
        self.position = 0.0


# ==========================================================================
# FAULT INJECTOR
# ==========================================================================

FAULT_TURBINE_TRIP = "TURBINE TRIP"
FAULT_ROD_STUCK = "CONTROL ROD STUCK"
FAULT_FEEDWATER = "FEEDWATER PUMP FAILURE"
FAULT_XENON = "XENON POISONING"
FAULT_TYPES = [FAULT_TURBINE_TRIP, FAULT_ROD_STUCK, FAULT_FEEDWATER, FAULT_XENON]

FAULT_DURATIONS = {
    FAULT_TURBINE_TRIP: 40.0,
    FAULT_ROD_STUCK: 35.0,
    FAULT_FEEDWATER: 45.0,
    FAULT_XENON: XENON_RAMP_S,
}

FAULT_COLORS = {
    FAULT_TURBINE_TRIP: ORANGE,
    FAULT_ROD_STUCK: (230, 90, 200),
    FAULT_FEEDWATER: RED,
    FAULT_XENON: CYAN,
}


class FaultManager:
    def __init__(self, log_callback):
        self.log = log_callback
        self.reset()

    def reset(self):
        self.active_type = None
        self.active_start = 0.0
        self.stuck_bank = None
        self.xenon_phase = 'idle'
        self.xenon_value = 0.0
        self.xenon_recover_start = 0.0
        self.xenon_value_at_recover = 0.0
        self.next_fault_at = random.uniform(45.0, 90.0)

    def update(self, elapsed, dt):
        if self.active_type is None:
            if elapsed >= self.next_fault_at:
                self._trigger(elapsed)
        else:
            t_in = elapsed - self.active_start
            if t_in >= FAULT_DURATIONS[self.active_type]:
                self._clear(elapsed)

        if self.active_type == FAULT_XENON:
            t_in = elapsed - self.active_start
            self.xenon_value = -XENON_MAX_PCM * min(1.0, t_in / XENON_RAMP_S)
        elif self.xenon_phase == 'recovering':
            t_rec = elapsed - self.xenon_recover_start
            frac = max(0.0, 1.0 - t_rec / XENON_RAMP_S)
            self.xenon_value = self.xenon_value_at_recover * frac
            if frac <= 0.0:
                self.xenon_phase = 'idle'
                self.xenon_value = 0.0

    def _trigger(self, elapsed):
        ftype = random.choice(FAULT_TYPES)
        self.active_type = ftype
        self.active_start = elapsed
        if ftype == FAULT_ROD_STUCK:
            self.stuck_bank = random.choice(['A', 'B'])
            self.log(f"ALARM: {ftype} - BANK {self.stuck_bank}")
        else:
            self.log(f"ALARM: {ftype}")
        if ftype == FAULT_XENON:
            self.xenon_phase = 'ramping'

    def _clear(self, elapsed):
        self.log(f"{self.active_type} CLEARED")
        if self.active_type == FAULT_XENON:
            self.xenon_phase = 'recovering'
            self.xenon_recover_start = elapsed
            self.xenon_value_at_recover = self.xenon_value
        if self.active_type == FAULT_ROD_STUCK:
            self.stuck_bank = None
        self.active_type = None
        self.next_fault_at = elapsed + random.uniform(45.0, 90.0)

    @property
    def flow_frac(self):
        return 0.3 if self.active_type == FAULT_FEEDWATER else 1.0

    @property
    def load_frac(self):
        return 0.0 if self.active_type == FAULT_TURBINE_TRIP else 1.0

    @property
    def xenon_pcm(self):
        return self.xenon_value

    def is_stuck(self, bank_name):
        return self.active_type == FAULT_ROD_STUCK and self.stuck_bank == bank_name


# ==========================================================================
# CORE GRID (10x10 localized power distribution)
# ==========================================================================

GRID_N = 10


def _compute_grid_weights():
    weights = [[0.0] * GRID_N for _ in range(GRID_N)]
    c = (GRID_N - 1) / 2.0
    max_r = math.hypot(c, c)
    for i in range(GRID_N):
        for j in range(GRID_N):
            r = min(math.hypot(i - c, j - c) / max_r, 1.0)
            weights[i][j] = math.cos(r * math.pi / 2.0)
    return weights


GRID_WEIGHTS = _compute_grid_weights()

TEMP_COLOR_STOPS = [
    (TF_REF_C, (15, 30, 140)),
    (800.0, (255, 215, 40)),
    (1800.0, (255, 255, 255)),
    (2800.0, (255, 25, 25)),
]


def temp_to_color(t):
    if t <= TEMP_COLOR_STOPS[0][0]:
        return TEMP_COLOR_STOPS[0][1]
    if t >= TEMP_COLOR_STOPS[-1][0]:
        return TEMP_COLOR_STOPS[-1][1]
    for k in range(len(TEMP_COLOR_STOPS) - 1):
        t0, c0 = TEMP_COLOR_STOPS[k]
        t1, c1 = TEMP_COLOR_STOPS[k + 1]
        if t0 <= t <= t1:
            return lerp_color(c0, c1, (t - t0) / (t1 - t0))
    return TEMP_COLOR_STOPS[-1][1]


def cell_temp(i, j, fuel_temp):
    w = GRID_WEIGHTS[i][j]
    return TF_REF_C + (fuel_temp - TF_REF_C) * (0.35 + 0.65 * w)


# ==========================================================================
# AUDIO: generated square-wave beep, no external assets
# ==========================================================================

class Beeper:
    def __init__(self):
        self.enabled = True
        try:
            pygame.mixer.init(frequency=44100, size=-16, channels=1)
        except Exception:
            self.enabled = False
        self._cache = {}

    def _make_sound(self, freq_hz, duration_s=0.12, volume=0.35, sample_rate=44100):
        n_samples = max(1, int(sample_rate * duration_s))
        amp = int(32767 * volume)
        period = sample_rate / freq_hz
        buf = array.array('h')
        for i in range(n_samples):
            buf.append(amp if (i % period) < period / 2.0 else -amp)
        return pygame.mixer.Sound(buffer=buf.tobytes())

    def play(self, freq_hz, duration_s=0.12, volume=0.35):
        if not self.enabled:
            return
        try:
            key = (int(freq_hz), duration_s)
            snd = self._cache.get(key)
            if snd is None:
                snd = self._make_sound(freq_hz, duration_s, volume)
                self._cache[key] = snd
            snd.play()
        except Exception:
            self.enabled = False


# ==========================================================================
# GAME STATES
# ==========================================================================

STARTUP = "STARTUP"
POWER_ASCENSION = "POWER ASCENSION"
STEADY = "STEADY"
OVERHEAT = "OVERHEAT"
SCRAM = "SCRAM"
MELTDOWN = "MELTDOWN"

STATE_COLORS = {
    STARTUP: BLUE,
    POWER_ASCENSION: CYAN,
    STEADY: GREEN,
    OVERHEAT: ORANGE,
    SCRAM: YELLOW,
    MELTDOWN: RED,
}


# ==========================================================================
# DIAL / WIDGET DRAWING HELPERS
# ==========================================================================

def value_to_angle_deg(value, vmin, vmax):
    frac = clamp((value - vmin) / (vmax - vmin), 0.0, 1.0)
    return 225.0 - frac * 270.0


def polar_point(cx, cy, r, angle_deg):
    a = math.radians(angle_deg)
    return (cx + r * math.cos(a), cy - r * math.sin(a))


def draw_dial(surface, font, small_font, cx, cy, radius, value, vmin, vmax,
              label, unit, zones=None, value_fmt="{:.1f}"):
    pygame.draw.circle(surface, (34, 37, 45), (cx, cy), radius + 16)
    pygame.draw.circle(surface, (10, 11, 15), (cx, cy), radius + 16, 2)

    rect = pygame.Rect(cx - radius, cy - radius, radius * 2, radius * 2)
    pygame.draw.arc(surface, (66, 70, 80), rect, math.radians(-45), math.radians(225), 6)

    if zones:
        for (a, b, color) in zones:
            a0 = value_to_angle_deg(a, vmin, vmax)
            a1 = value_to_angle_deg(b, vmin, vmax)
            lo, hi = min(a0, a1), max(a0, a1)
            if hi - lo > 0.5:
                pygame.draw.arc(surface, color, rect, math.radians(lo), math.radians(hi), 6)

    for k in range(11):
        v = vmin + (vmax - vmin) * k / 10.0
        ang = value_to_angle_deg(v, vmin, vmax)
        p0 = polar_point(cx, cy, radius - 2, ang)
        p1 = polar_point(cx, cy, radius - 11, ang)
        pygame.draw.line(surface, (150, 155, 168), p0, p1, 2)

    ang = value_to_angle_deg(value, vmin, vmax)
    tip = polar_point(cx, cy, radius - 18, ang)
    pygame.draw.line(surface, (235, 70, 70), (cx, cy), tip, 3)
    pygame.draw.circle(surface, (235, 70, 70), (cx, cy), 6)
    pygame.draw.circle(surface, (15, 16, 20), (cx, cy), 6, 1)

    label_txt = small_font.render(label, True, DIM_TEXT)
    surface.blit(label_txt, (cx - label_txt.get_width() // 2, cy + radius - 4))
    vtxt = font.render(value_fmt.format(value) + unit, True, WHITE)
    surface.blit(vtxt, (cx - vtxt.get_width() // 2, cy + radius + 18))


def draw_panel_frame(surface, rect, title, small_font):
    pygame.draw.rect(surface, PANEL_BG, rect, border_radius=6)
    pygame.draw.rect(surface, PANEL_BORDER, rect, 2, border_radius=6)
    txt = small_font.render(title, True, DIM_TEXT)
    surface.blit(txt, (rect.x + 10, rect.y + 6))


def draw_grid_panel(surface, rect, physics, meltdown_active, t_ms):
    inner = rect.inflate(-20, -40)
    inner.top = rect.top + 30
    cw = inner.width / GRID_N
    ch = inner.height / GRID_N
    for i in range(GRID_N):
        for j in range(GRID_N):
            x = inner.x + i * cw
            y = inner.y + j * ch
            if meltdown_active:
                color = (5, 5, 5)
            else:
                jitter = math.sin((i * 13 + j * 7 + t_ms * 0.003)) * 6.0
                temp = cell_temp(i, j, physics.fuel_temp) + jitter
                color = temp_to_color(temp)
            pygame.draw.rect(surface, color, (x + 1, y + 1, cw - 2, ch - 2), border_radius=2)
    pygame.draw.rect(surface, PANEL_BORDER, inner, 1)


def draw_graph_panel(surface, rect, flux_hist, temp_hist, small_font):
    inner = rect.inflate(-20, -40)
    inner.top = rect.top + 30
    pygame.draw.rect(surface, (14, 15, 20), inner)
    pygame.draw.rect(surface, PANEL_BORDER, inner, 1)

    for gy in range(1, 4):
        y = inner.y + inner.height * gy / 4.0
        pygame.draw.line(surface, (32, 35, 42), (inner.x, y), (inner.right, y), 1)

    def plot(hist, vmax, color):
        n = len(hist)
        if n < 2:
            return
        pts = []
        for idx, v in enumerate(hist):
            x = inner.x + inner.width * idx / (HISTORY_MAXLEN - 1)
            f = clamp(v / vmax, 0.0, 1.0)
            y = inner.bottom - f * inner.height
            pts.append((x, y))
        if len(pts) >= 2:
            pygame.draw.lines(surface, color, False, pts, 2)

    flux_max = max(150.0, (max(flux_hist) if flux_hist else 100.0) * 1.15)
    temp_max = 3000.0
    plot(flux_hist, flux_max, CYAN)
    plot(temp_hist, temp_max, ORANGE)

    leg1 = small_font.render("-- Neutron Flux %", True, CYAN)
    leg2 = small_font.render("-- Fuel Temp C", True, ORANGE)
    surface.blit(leg1, (inner.x + 6, inner.y + 4))
    surface.blit(leg2, (inner.x + 6, inner.y + 20))


def draw_slider(surface, rect, value, label, stuck, font, small_font):
    track_color = (200, 90, 60) if stuck else (55, 59, 68)
    pygame.draw.rect(surface, track_color, rect, border_radius=8)
    pygame.draw.rect(surface, PANEL_BORDER, rect, 2, border_radius=8)
    fill_w = int(rect.width * clamp(value, 0, 100) / 100.0)
    fill_rect = pygame.Rect(rect.x, rect.y, fill_w, rect.height)
    fill_color = (150, 60, 60) if stuck else GREEN
    pygame.draw.rect(surface, fill_color, fill_rect, border_radius=8)
    handle_x = rect.x + fill_w
    pygame.draw.circle(surface, WHITE, (handle_x, rect.centery), rect.height // 2 + 4)
    pygame.draw.circle(surface, (20, 21, 26), (handle_x, rect.centery), rect.height // 2 + 4, 2)

    label_txt = font.render(f"{label}: {value:5.1f}%" + ("  [STUCK]" if stuck else ""), True, TEXT_COLOR)
    surface.blit(label_txt, (rect.x, rect.y - 24))


def draw_scram_button(surface, center, radius, t_ms, font):
    pulse = 1.0 + 0.06 * math.sin(t_ms * 0.006)
    r = int(radius * pulse)
    pygame.draw.circle(surface, (120, 15, 15), center, r + 8)
    pygame.draw.circle(surface, RED, center, r)
    pygame.draw.circle(surface, (255, 160, 160), center, r, 3)
    txt = font.render("SCRAM", True, WHITE)
    surface.blit(txt, (center[0] - txt.get_width() // 2, center[1] - txt.get_height() // 2))


def draw_event_log(surface, rect, log_deque, small_font):
    draw_panel_frame(surface, rect, "EVENT LOG", small_font)
    y = rect.y + 30
    for entry in list(log_deque)[-5:]:
        txt = small_font.render(entry, True, DIM_TEXT)
        surface.blit(txt, (rect.x + 10, y))
        y += 18


# ==========================================================================
# MAIN GAME
# ==========================================================================

class Game:
    def __init__(self):
        pygame.init()
        self.screen = pygame.display.set_mode((WIDTH, HEIGHT))
        pygame.display.set_caption("Project Chernobyl - Reactor Control Room")
        self.clock = pygame.time.Clock()

        self.font_big = pygame.font.SysFont("consolas,couriernew,monospace", 30, bold=True)
        self.font = pygame.font.SysFont("consolas,couriernew,monospace", 18)
        self.font_small = pygame.font.SysFont("consolas,couriernew,monospace", 14)

        self.beeper = Beeper()

        self.event_log = deque(maxlen=5)
        self.fault_mgr = FaultManager(self._log)

        self._layout()
        self._new_game()

    # ---- layout -----------------------------------------------------

    def _layout(self):
        self.banner_rect = pygame.Rect(0, 0, WIDTH, 44)
        self.bottom_rect = pygame.Rect(0, HEIGHT - 250, WIDTH, 250)
        main_top = 44
        main_bottom = HEIGHT - 250

        self.left_panel = pygame.Rect(10, main_top + 8, 300, main_bottom - main_top - 16)
        self.center_panel = pygame.Rect(320, main_top + 8, 560, main_bottom - main_top - 16)
        self.right_panel = pygame.Rect(890, main_top + 8, WIDTH - 900, main_bottom - main_top - 16)

        self.slider_a_rect = pygame.Rect(40, self.bottom_rect.y + 60, 480, 26)
        self.slider_b_rect = pygame.Rect(40, self.bottom_rect.y + 150, 480, 26)

        self.scram_center = (650, self.bottom_rect.y + 120)
        self.scram_radius = 55

        self.log_rect = pygame.Rect(780, self.bottom_rect.y + 10, WIDTH - 800, 230)

        # dial centers within left panel
        lp = self.left_panel
        self.dial_flux_pos = (lp.centerx, lp.y + 110)
        self.dial_temp_pos = (lp.centerx, lp.y + 300)
        self.dial_pres_pos = (lp.centerx, lp.y + 490)
        self.dial_radius = 78

    # ---- lifecycle ----------------------------------------------------

    def _new_game(self):
        self.physics = ReactorPhysics()
        self.bank_a = ControlRodBank('A')
        self.bank_b = ControlRodBank('B')
        self.fault_mgr.reset()
        self.event_log.clear()

        self.flux_hist = deque(maxlen=HISTORY_MAXLEN)
        self.temp_hist = deque(maxlen=HISTORY_MAXLEN)

        self.elapsed = 0.0
        self.melt_timer = 0.0
        self.scram_active = False
        self.scram_countdown = 0.0
        self.n_at_scram_pct = 0.0
        self.scram_time_ref = 0.0

        self.game_over = False
        self.victory = False
        self.state = STARTUP

        self.dragging = None
        self.accumulator = 0.0
        self.beep_timer = 0.0

        self._log("SIMULATION RESET - REACTOR SUBCRITICAL")

    def _log(self, msg):
        self.event_log.append(msg)

    # ---- physics tick ---------------------------------------------------

    def _trigger_scram(self):
        if self.game_over:
            return
        self.n_at_scram_pct = self.physics.flux_percent
        self.bank_a.scram()
        self.bank_b.scram()
        self.scram_active = True
        self.scram_countdown = SCRAM_COOLDOWN_S
        self.scram_time_ref = self.elapsed
        self.state = SCRAM
        self._log("MANUAL SCRAM INITIATED")

    def _trigger_meltdown(self):
        self.game_over = True
        self.state = MELTDOWN
        self._log("CORE DISASSEMBLY - MELTDOWN")
        self.beeper.play(90, duration_s=0.9, volume=0.6)

    def _trigger_victory(self):
        self.game_over = True
        self.victory = True
        self._log("15 MINUTES SURVIVED - VETERAN OPERATOR")

    def _decay_heat_pct(self):
        if not self.scram_active:
            return 0.0
        t = self.elapsed - self.scram_time_ref
        frac = max(0.0, self.n_at_scram_pct / 100.0)
        return DECAY_HEAT_INITIAL_FRAC * frac * math.exp(-t / DECAY_HEAT_TAU_S)

    def _update_state(self):
        if self.game_over:
            return
        if self.scram_active:
            self.state = SCRAM
            return
        tf = self.physics.fuel_temp
        flux = self.physics.flux_percent
        if tf > OVERHEAT_TEMP_C or self.melt_timer > 0.0:
            self.state = OVERHEAT
        elif flux < STARTUP_FLUX_PCT:
            self.state = STARTUP
        elif flux < 60.0:
            self.state = POWER_ASCENSION
        else:
            self.state = STEADY

    def _physics_tick(self):
        self.elapsed += PHYSICS_DT

        self.bank_a.update(PHYSICS_DT, self.fault_mgr.is_stuck('A'))
        self.bank_b.update(PHYSICS_DT, self.fault_mgr.is_stuck('B'))
        self.fault_mgr.update(self.elapsed, PHYSICS_DT)

        decay_pct = self._decay_heat_pct()
        self.physics.step(PHYSICS_DT, self.bank_a.position, self.bank_b.position,
                           self.fault_mgr.flow_frac, self.fault_mgr.load_frac,
                           self.fault_mgr.xenon_pcm, decay_pct)

        self.flux_hist.append(self.physics.flux_percent)
        self.temp_hist.append(self.physics.fuel_temp)

        if self.physics.fuel_temp > MELTDOWN_TEMP_C:
            self.melt_timer += PHYSICS_DT
        else:
            self.melt_timer = 0.0
        if self.melt_timer >= MELTDOWN_SUSTAIN_S:
            self._trigger_meltdown()
            return

        if self.scram_active:
            self.scram_countdown -= PHYSICS_DT
            if self.scram_countdown <= 0.0:
                self.scram_active = False
                self._log("REACTOR COOLDOWN COMPLETE")

        self._update_state()

        if not self.victory and self.elapsed >= WIN_TIME_S:
            self._trigger_victory()

        flux = self.physics.flux_percent
        if flux > 110.0 and not self.game_over:
            self.beep_timer -= PHYSICS_DT
            if self.beep_timer <= 0.0:
                freq = clamp(500.0 + (flux - 110.0) * 6.0, 500.0, 1600.0)
                self.beeper.play(freq, duration_s=0.09, volume=0.25)
                self.beep_timer = clamp(0.6 - (flux - 110.0) * 0.003, 0.08, 0.6)

    # ---- input ----------------------------------------------------------

    def _slider_value_from_mouse(self, rect, mx):
        f = clamp((mx - rect.x) / rect.width, 0.0, 1.0)
        return f * 100.0

    def handle_event(self, ev):
        if ev.type == pygame.QUIT:
            self._quit()
        elif ev.type == pygame.KEYDOWN:
            if ev.key == pygame.K_SPACE:
                self._trigger_scram()
            elif ev.key == pygame.K_r:
                if self.game_over:
                    self._new_game()
            elif ev.key == pygame.K_ESCAPE:
                self._quit()
        elif ev.type == pygame.MOUSEBUTTONDOWN and ev.button == 1:
            mx, my = ev.pos
            dx = mx - self.scram_center[0]
            dy = my - self.scram_center[1]
            if dx * dx + dy * dy <= (self.scram_radius + 10) ** 2:
                self._trigger_scram()
                return
            if not self.game_over:
                if self.slider_a_rect.inflate(0, 16).collidepoint(mx, my):
                    self.dragging = 'A'
                    self.bank_a.set_target(self._slider_value_from_mouse(self.slider_a_rect, mx))
                elif self.slider_b_rect.inflate(0, 16).collidepoint(mx, my):
                    self.dragging = 'B'
                    self.bank_b.set_target(self._slider_value_from_mouse(self.slider_b_rect, mx))
        elif ev.type == pygame.MOUSEBUTTONUP and ev.button == 1:
            self.dragging = None
        elif ev.type == pygame.MOUSEMOTION:
            if self.dragging == 'A':
                self.bank_a.set_target(self._slider_value_from_mouse(self.slider_a_rect, ev.pos[0]))
            elif self.dragging == 'B':
                self.bank_b.set_target(self._slider_value_from_mouse(self.slider_b_rect, ev.pos[0]))

    def _quit(self):
        pygame.quit()
        sys.exit(0)

    # ---- render -----------------------------------------------------------

    def _draw_banner(self):
        pygame.draw.rect(self.screen, (10, 11, 15), self.banner_rect)
        color = STATE_COLORS.get(self.state, TEXT_COLOR)
        state_txt = self.font_big.render(self.state, True, color)
        self.screen.blit(state_txt, (16, 4))

        mins = int(self.elapsed // 60)
        secs = int(self.elapsed % 60)
        timer_txt = self.font.render(f"T+{mins:02d}:{secs:02d}   goal 15:00", True, DIM_TEXT)
        self.screen.blit(timer_txt, (300, 12))

        rho_txt = self.font.render(f"reactivity {self.physics.last_reactivity_pcm:+7.1f} pcm", True, DIM_TEXT)
        self.screen.blit(rho_txt, (560, 12))

        if self.fault_mgr.active_type:
            blink = (pygame.time.get_ticks() // 400) % 2 == 0
            color = FAULT_COLORS.get(self.fault_mgr.active_type, RED)
            if blink:
                txt = self.font_big.render(f"! {self.fault_mgr.active_type} !", True, color)
                self.screen.blit(txt, (WIDTH - txt.get_width() - 20, 4))

    def _draw_left_panel(self):
        draw_panel_frame(self.screen, self.left_panel, "REACTOR PARAMETERS", self.font_small)
        flux = self.physics.flux_percent
        draw_dial(self.screen, self.font, self.font_small, *self.dial_flux_pos, self.dial_radius,
                  min(flux, 200.0), 0, 200, "NEUTRON FLUX", "%",
                  zones=[(0, 100, GREEN), (100, 150, YELLOW), (150, 200, RED)])
        draw_dial(self.screen, self.font, self.font_small, *self.dial_temp_pos, self.dial_radius,
                  min(self.physics.fuel_temp, 3000.0), 0, 3000, "FUEL TEMP", "C",
                  zones=[(0, 1500, GREEN), (1500, 2800, YELLOW), (2800, 3000, RED)], value_fmt="{:.0f}")
        draw_dial(self.screen, self.font, self.font_small, *self.dial_pres_pos, self.dial_radius,
                  self.physics.pressure_mpa, 0, 22, "COOLANT PRESSURE", "MPa",
                  zones=[(0, 17, GREEN), (17, 19.5, YELLOW), (19.5, 22, RED)])

    def _draw_center_panel(self):
        draw_panel_frame(self.screen, self.center_panel, "CORE - 10x10 LOCAL POWER MAP", self.font_small)
        draw_grid_panel(self.screen, self.center_panel, self.physics,
                         self.state == MELTDOWN, pygame.time.get_ticks())

    def _draw_right_panel(self):
        draw_panel_frame(self.screen, self.right_panel, "60s TREND", self.font_small)
        draw_graph_panel(self.screen, self.right_panel, self.flux_hist, self.temp_hist, self.font_small)

    def _draw_bottom_panel(self):
        pygame.draw.rect(self.screen, PANEL_BG, self.bottom_rect)
        pygame.draw.rect(self.screen, PANEL_BORDER, self.bottom_rect, 2)

        # slider shows the rod's actual physical position, not the raw mouse
        # target -- so a stuck bank visibly stops following the mouse
        draw_slider(self.screen, self.slider_a_rect, self.bank_a.position, "BANK A",
                    self.fault_mgr.is_stuck('A'), self.font, self.font_small)
        draw_slider(self.screen, self.slider_b_rect, self.bank_b.position, "BANK B",
                    self.fault_mgr.is_stuck('B'), self.font, self.font_small)

        draw_scram_button(self.screen, self.scram_center, self.scram_radius,
                           pygame.time.get_ticks(), self.font)

        if self.scram_active:
            cd_txt = self.font.render(f"DECAY COOLDOWN: {int(self.scram_countdown)}s", True, YELLOW)
            self.screen.blit(cd_txt, (self.scram_center[0] - cd_txt.get_width() // 2,
                                       self.scram_center[1] + self.scram_radius + 14))

        draw_event_log(self.screen, self.log_rect, self.event_log, self.font_small)

    def _draw_overlay_meltdown(self):
        flash = (pygame.time.get_ticks() // 120) % 2 == 0
        if flash:
            overlay = pygame.Surface((WIDTH, HEIGHT))
            overlay.set_alpha(90)
            overlay.fill(WHITE)
            self.screen.blit(overlay, (0, 0))
        dim = pygame.Surface((WIDTH, HEIGHT), pygame.SRCALPHA)
        dim.fill((0, 0, 0, 180))
        self.screen.blit(dim, (0, 0))
        title = self.font_big.render("GAME OVER - CORE DISASSEMBLY", True, RED)
        sub = self.font.render("Press R to reset", True, TEXT_COLOR)
        self.screen.blit(title, (WIDTH // 2 - title.get_width() // 2, HEIGHT // 2 - 40))
        self.screen.blit(sub, (WIDTH // 2 - sub.get_width() // 2, HEIGHT // 2 + 10))

    def _draw_overlay_victory(self):
        dim = pygame.Surface((WIDTH, HEIGHT), pygame.SRCALPHA)
        dim.fill((0, 0, 0, 170))
        self.screen.blit(dim, (0, 0))
        title = self.font_big.render("VETERAN OPERATOR", True, GREEN)
        sub = self.font.render("15 minutes survived without meltdown. Press R to reset.", True, TEXT_COLOR)
        self.screen.blit(title, (WIDTH // 2 - title.get_width() // 2, HEIGHT // 2 - 40))
        self.screen.blit(sub, (WIDTH // 2 - sub.get_width() // 2, HEIGHT // 2 + 10))

    def render(self):
        self.screen.fill(BG_COLOR)
        self._draw_banner()
        self._draw_left_panel()
        self._draw_center_panel()
        self._draw_right_panel()
        self._draw_bottom_panel()
        if self.game_over:
            if self.victory:
                self._draw_overlay_victory()
            else:
                self._draw_overlay_meltdown()
        pygame.display.flip()

    # ---- main loop --------------------------------------------------------

    def run(self):
        running = True
        while running:
            frame_dt = self.clock.tick(RENDER_FPS) / 1000.0

            for ev in pygame.event.get():
                if ev.type == pygame.QUIT:
                    running = False
                else:
                    self.handle_event(ev)

            if not self.game_over:
                self.accumulator += frame_dt
                # avoid a death spiral if a frame stalls badly
                self.accumulator = min(self.accumulator, PHYSICS_DT * 8)
                while self.accumulator >= PHYSICS_DT:
                    self._physics_tick()
                    self.accumulator -= PHYSICS_DT
                    if self.game_over:
                        break

            self.render()

        pygame.quit()


def main():
    Game().run()


if __name__ == "__main__":
    main()
