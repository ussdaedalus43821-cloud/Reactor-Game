#!/usr/bin/env python3
"""
reactor_host.py -- the reference reactor, driven by NovaLang.

This is the oracle, not the game. It embeds the reference NovaLang VM,
registers the reactor's vocabulary as host functions, and runs the same
RK4 core the shipping GDScript uses -- so tests and
tools/gen_conformance.py can assert what the Godot build must reproduce.
Nothing here is shipped or executed by the game; see docs/ARCHITECTURE.md.

The host-function list below is the contract nova_bridge.gd implements on
the Godot side, and tools/check_parity.py fails the build if the two
registries ever disagree:

    log(text)            append a line to the operator event log
    alarm(level, text)   raise the alarm tier; highest in a tick wins
    scram(reason)        trip the plant, latching immediately
    reset_trip()         clear the latch, restore the rod drives
    meltdown(text)       end the run badly
    victory(text)        end the run well
    inject_fault(name)   force a named fault now
    clear_fault()        end the active fault early

Command interface (Session.handle_line) is a line-oriented JSON protocol
kept from the old bridge daemon. It is no longer a transport -- Godot never
speaks to this process -- but it is a convenient, testable way to drive a
whole episode from the outside, and the conformance generator uses it.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import reactor_physics as phys
from nova_vm import NovaVM

PROTO_VERSION = 2
RULES_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         "godot", "scripts")
DEFAULT_RULES = "reactor_rules.nova"

MAX_STEPS_PER_TICK = 60
DECAY_HEAT_INITIAL_FRAC = 7.0
DECAY_HEAT_TAU_S = 130.0
GRID_N = 10

# Exactly the names nova_bridge.gd registers. Order is irrelevant; membership
# is not -- check_parity.py compares this set against the GDScript one.
HOST_FUNCTIONS = [
    "log", "alarm", "scram", "reset_trip", "meltdown", "victory",
    "inject_fault", "clear_fault",
]


class ReactorHost:
    """Owns the plant: physics, rods, the NovaLang VM and the run's
    bookkeeping. One instance per episode."""

    def __init__(self, rules: str = DEFAULT_RULES, seed=None, rules_dir=RULES_DIR):
        self.rules = rules
        self.rng = random.Random(seed)
        self.vm = NovaVM(self.rng, base_dir=rules_dir)
        self._register_host_functions()

        self.physics = phys.ReactorPhysics()
        self.error = ""
        if not self.vm.load_file(rules):
            self.error = self.vm.error
        self.reset(seed)

    # -- host functions ----------------------------------------------------

    def _register_host_functions(self):
        vm = self.vm
        vm.register_function("log", self._fn_log)
        vm.register_function("alarm", self._fn_alarm)
        vm.register_function("scram", self._fn_scram)
        vm.register_function("reset_trip", self._fn_reset_trip)
        vm.register_function("meltdown", self._fn_meltdown)
        vm.register_function("victory", self._fn_victory)
        vm.register_function("inject_fault", self._fn_inject_fault)
        vm.register_function("clear_fault", self._fn_clear_fault)

    @staticmethod
    def _text(args, index, fallback=""):
        from nova_evaluator import text
        return text(args[index]) if len(args) > index else fallback

    def _fn_log(self, args):
        self.pending_events.append(self._text(args, 0))
        return None

    def _fn_alarm(self, args):
        if not args:
            return None
        level = int(float(args[0])) if isinstance(args[0], (int, float)) else 0
        if level > self.alarm_level:
            self.alarm_level = level
            self.alarm_text = self._text(args, 1)
        return None

    def _fn_scram(self, args):
        # Latching in the VM's globals too means the lower-priority rules
        # later in this same tick already see a scrammed plant, so the state
        # machine never lags the trip.
        if self.scram:
            return None
        reason = self._text(args, 0, "SCRAM")
        self.scram_requested = True
        self.scram_reason = reason
        self.vm.set_global("scram", True)
        self.pending_events.append(reason)
        return None

    def _fn_reset_trip(self, args):
        self.trip_reset = True
        self.vm.set_global("scram", False)
        return None

    def _fn_meltdown(self, args):
        if self.meltdown:
            return None
        self.meltdown = True
        self._end_run()
        self.pending_events.append(self._text(args, 0, "MELTDOWN"))
        return None

    def _fn_victory(self, args):
        if self.victory:
            return None
        self.victory = True
        self._end_run()
        self.pending_events.append(self._text(args, 0, "VICTORY"))
        return None

    def _end_run(self):
        """`running` is an ordinary signal computed before the rules, so
        without this the state machine would see the run finish one tick
        late."""
        self.game_over = True
        self.vm.set_global("game_over", True)
        self.vm.set_global("meltdown", self.meltdown)
        self.vm.set_global("victory", self.victory)
        self.vm.set_global("running", False)

    def _fn_inject_fault(self, args):
        if args:
            self.vm.inject_fault(self._text(args, 0))
        return None

    def _fn_clear_fault(self, args):
        self.vm.clear_fault()
        return None

    # -- lifecycle ---------------------------------------------------------

    def reset(self, seed=None) -> dict:
        if seed is not None:
            self.rng.seed(seed)
        self.physics.reset()

        self.t = 0.0
        self.step_count = 0
        self.rod_a = 0.0
        self.rod_b = 0.0
        self.rod_target_a = 0.0
        self.rod_target_b = 0.0

        self.scram = False
        self.scram_t = 0.0
        self.flux_at_scram = 0.0

        self.game_over = False
        self.victory = False
        self.meltdown = False
        self.state = "STARTUP"
        self.alarm_level = 0
        self.alarm_text = ""

        self.scram_requested = False
        self.scram_reason = ""
        self.trip_reset = False

        self.flow_frac = 1.0
        self.load_frac = 1.0
        self.xenon_pcm = 0.0
        self.stuck_bank = ""

        self.pending_events = ["SIMULATION RESET -- REACTOR SUBCRITICAL"]
        self.history = []

        self.vm.reset(seed if seed is not None else 0)
        if self.vm.error:
            self.error = self.vm.error
        return self.snapshot()

    # -- the loop ----------------------------------------------------------

    def advance(self, steps: int, rod_target_a: float, rod_target_b: float,
                operator_scram: bool, faults_enabled: bool = True) -> dict:
        steps = max(0, min(int(steps), MAX_STEPS_PER_TICK))
        self.history = []
        if not self.game_over and not self.scram:
            self.rod_target_a = phys.clamp(float(rod_target_a), 0.0, 100.0)
            self.rod_target_b = phys.clamp(float(rod_target_b), 0.0, 100.0)
        for i in range(steps):
            self._substep(phys.PHYSICS_DT, operator_scram and i == 0,
                          faults_enabled)
        return self.snapshot()

    def _substep(self, dt, operator_scram, faults_enabled):
        self.t += dt
        self.step_count += 1

        # 1. Rod drives -- finite speed, and a seized bank does not move.
        self.rod_a = phys.drive_rod(self.rod_a, self.rod_target_a, dt,
                                    self.stuck_bank == "A")
        self.rod_b = phys.drive_rod(self.rod_b, self.rod_target_b, dt,
                                    self.stuck_bank == "B")

        # 2. Decay heat keeps the core warm long after the rods are in.
        decay = 0.0
        if self.scram:
            decay = phys.decay_heat_pct(self.flux_at_scram, self.t - self.scram_t,
                                        DECAY_HEAT_INITIAL_FRAC, DECAY_HEAT_TAU_S)

        # 3. Integrate the core.
        self.physics.step(dt, self.rod_a, self.rod_b, self.flow_frac,
                          self.load_frac, self.xenon_pcm, decay)

        # 4. Run the policy. Its outputs are the plant's boundary conditions
        #    for the *next* substep -- one 50 ms lag, which keeps the loop
        #    acyclic and is mirrored exactly by nova_bridge.gd.
        self.scram_requested = False
        self.scram_reason = ""
        self.trip_reset = False
        self.alarm_level = 0
        self.alarm_text = ""

        inputs = {
            "t": self.t,
            "flux_pct": self.physics.flux_percent,
            "fuel_temp_c": self.physics.fuel_temp,
            "mod_temp_c": self.physics.mod_temp,
            "out_temp_c": self.physics.out_temp,
            "pressure_mpa": self.physics.pressure,
            "reactivity_pcm": self.physics.reactivity_pcm,
            "decay_heat_pct": decay,
            "rod_a": self.rod_a,
            "rod_b": self.rod_b,
            "rod_target_a": self.rod_target_a,
            "rod_target_b": self.rod_target_b,
            "scram": self.scram,
            "scram_elapsed": (self.t - self.scram_t) if self.scram else 0.0,
            "operator_scram": bool(operator_scram),
            "game_over": self.game_over,
            "victory": self.victory,
            "meltdown": self.meltdown,
        }
        if not self.vm.tick(dt, inputs, faults_enabled):
            self.error = self.vm.error
            self.pending_events.append("CONTROL LOGIC FAULT -- " + self.vm.error)
            return

        g = self.vm.get_global
        self.flow_frac = float(g("flow_frac", 1.0))
        self.load_frac = float(g("load_frac", 1.0))
        self.xenon_pcm = float(g("xenon_pcm", 0.0))
        self.stuck_bank = str(g("stuck_bank", ""))
        self.state = str(g("state", "STARTUP"))
        # NovaLang may drive the rods itself (the optional autopilot rule).
        self.rod_target_a = float(g("rod_target_a", self.rod_target_a))
        self.rod_target_b = float(g("rod_target_b", self.rod_target_b))

        if self.scram_requested and not self.scram:
            self._latch_scram()
        elif self.trip_reset and self.scram:
            self.scram = False

        for line in self.vm.drain_output():
            self.pending_events.append(line)

        self.history.append([self.physics.flux_percent, self.physics.fuel_temp])

    def _latch_scram(self):
        """Rods slam in -- a real scram drops them under gravity, it does
        not drive them, so this bypasses the rate limit on purpose."""
        self.flux_at_scram = self.physics.flux_percent
        self.scram = True
        self.scram_t = self.t
        self.rod_a = 0.0
        self.rod_b = 0.0
        self.rod_target_a = 0.0
        self.rod_target_b = 0.0

    # -- reporting ---------------------------------------------------------

    def _peaking(self):
        return {
            "tilt_x": phys.clamp((self.rod_a - self.rod_b) / 100.0, -1.0, 1.0),
            "tilt_y": phys.clamp((1.0 - self.flow_frac) * 0.6, -1.0, 1.0),
            "amp": 0.65,
            "n": GRID_N,
        }

    def snapshot(self) -> dict:
        events = self.pending_events
        self.pending_events = []
        fault = None
        if self.vm.active_fault is not None:
            fault = {
                "name": self.vm.active_fault["name"],
                "label": self.vm.active_fault["label"],
                "elapsed": float(self.vm.get_global("fault_elapsed", 0.0)),
                "duration": float(self.vm.get_global("fault_duration", 0.0)),
            }
        return {
            "ok": self.error == "",
            "t": self.t,
            "steps": self.step_count,
            "flux_pct": self.physics.flux_percent,
            "fuel_temp_c": self.physics.fuel_temp,
            "mod_temp_c": self.physics.mod_temp,
            "out_temp_c": self.physics.out_temp,
            "pressure_mpa": self.physics.pressure,
            "reactivity_pcm": self.physics.reactivity_pcm,
            "rod_a": self.rod_a,
            "rod_b": self.rod_b,
            "rod_target_a": self.rod_target_a,
            "rod_target_b": self.rod_target_b,
            "flow_frac": self.flow_frac,
            "load_frac": self.load_frac,
            "xenon_pcm": self.xenon_pcm,
            "stuck_bank": self.stuck_bank,
            "scram": self.scram,
            "scram_elapsed": (self.t - self.scram_t) if self.scram else 0.0,
            "state": self.state,
            "alarm_level": self.alarm_level,
            "alarm_text": self.alarm_text,
            "fault": fault,
            "peak": self._peaking(),
            "game_over": self.game_over,
            "victory": self.victory,
            "events": events,
            "history": self.history,
            "backend": phys.BACKEND,
            "error": self.error,
        }


# ==========================================================================
# Command interface
# ==========================================================================

class Session:
    def __init__(self, rules=DEFAULT_RULES, seed=None):
        self.sim = ReactorHost(rules, seed)
        self.alive = True

    def handle(self, req: dict) -> dict:
        cmd = req.get("cmd", "")
        if cmd == "hello":
            d = self.sim.vm.describe()
            return {"ok": True, "proto": PROTO_VERSION, "backend": phys.BACKEND,
                    "engine": "nova", "title": d["title"],
                    "rules_version": d["version"], "dt": phys.PHYSICS_DT,
                    "hz": phys.PHYSICS_HZ, "grid": GRID_N}
        if cmd == "reset":
            return self.sim.reset(req.get("seed"))
        if cmd == "tick":
            return self.sim.advance(
                req.get("steps", 1),
                req.get("rod_target_a", self.sim.rod_target_a),
                req.get("rod_target_b", self.sim.rod_target_b),
                bool(req.get("scram", False)),
                bool(req.get("faults", True)))
        if cmd == "state":
            return self.sim.snapshot()
        if cmd == "quit":
            self.alive = False
            return {"ok": True, "bye": True}
        return {"ok": False, "error": "unknown command %r" % cmd}

    def handle_line(self, line: str):
        line = line.strip()
        if not line:
            return None
        try:
            req = json.loads(line)
            if not isinstance(req, dict):
                raise ValueError("request must be a JSON object")
            resp = self.handle(req)
        except Exception as exc:
            resp = {"ok": False, "error": "%s: %s" % (type(exc).__name__, exc)}
        return json.dumps(resp, separators=(",", ":"))


def selftest(seconds: float = 60.0, seed: int = 7) -> dict:
    sim = ReactorHost(seed=seed)
    steps = int(seconds / phys.PHYSICS_DT)
    events = []
    snap = sim.snapshot()
    t0 = time.perf_counter()
    for i in range(steps):
        target = 72.0 * min(1.0, (i * phys.PHYSICS_DT) / 60.0)
        snap = sim.advance(1, target, target, False, True)
        events.extend(snap["events"])
    wall = time.perf_counter() - t0
    return {
        "ok": True, "sim_seconds": seconds, "wall_seconds": round(wall, 3),
        "realtime_factor": round(seconds / wall, 1) if wall > 0 else None,
        "us_per_step": round(wall / max(1, steps) * 1e6, 1),
        "backend": phys.BACKEND,
        "final": {k: snap[k] for k in ("t", "flux_pct", "fuel_temp_c",
                                       "pressure_mpa", "state", "scram",
                                       "game_over")},
        "events": events,
    }


def validate(rules: str) -> dict:
    vm = NovaVM(random.Random(0), base_dir=RULES_DIR)
    for name in HOST_FUNCTIONS:
        vm.register_function(name, lambda args: None)
    if not vm.load_file(rules):
        return {"ok": False, "error": vm.error}
    out = {"ok": True}
    out.update(vm.describe())
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description="NovaLang reactor reference host")
    ap.add_argument("--rules", default=DEFAULT_RULES)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--validate", action="store_true")
    ap.add_argument("--seconds", type=float, default=60.0)
    ap.add_argument("--once", metavar="JSON")
    args = ap.parse_args(argv)

    if args.validate:
        print(json.dumps(validate(args.rules), indent=2))
        return 0
    if args.selftest:
        print(json.dumps(selftest(args.seconds, args.seed or 7), indent=2))
        return 0
    if args.once:
        print(Session(args.rules, args.seed).handle_line(args.once))
        return 0
    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
