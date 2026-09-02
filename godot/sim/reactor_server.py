#!/usr/bin/env python3
"""
reactor_server.py -- the bridge daemon Godot talks to.

Joins the RK4 core (reactor_physics.py) to the NovaLang policy
(reactor_rules.nova, run by nova_runtime.py) and exposes them over a
line-oriented JSON protocol.

Transports
----------
  stdio (default)  one JSON request per line on stdin, one JSON response
                   per line on stdout. This is what bridge.gd drives via
                   OS.execute_with_pipe(). stdout carries protocol only --
                   every diagnostic goes to stderr.

  --tcp PORT       the same protocol over a TCP socket, one client at a
                   time. Handy when you want the sim running in a terminal
                   where you can see it while Godot attaches.

  --once JSON      run a single stateless command and exit. Useful for
                   health checks from Godot (OS.execute) and from CI;
                   it is NOT a way to run the simulation, because each
                   call would start a fresh reactor.

Protocol
--------
  -> {"cmd":"hello"}
  <- {"ok":true,"proto":1,"backend":"numpy","title":"CHERNOBYL-1",...}

  -> {"cmd":"reset","seed":7}
  <- <state>

  -> {"cmd":"tick","steps":3,"rod_target_a":72.0,"rod_target_b":72.0,
      "scram":false,"faults":true}
  <- <state>            # steps * PHYSICS_DT seconds advanced

  -> {"cmd":"quit"}
  <- {"ok":true,"bye":true}

Every response carries "ok". On failure it carries "ok":false and "error",
and the daemon stays up -- a bad frame must never take the panel down.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nova_runtime as nova
import reactor_physics as phys

PROTO_VERSION = 1
DEFAULT_RULES = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "reactor_rules.nova")
MAX_STEPS_PER_TICK = 60         # 3 s of sim in one request; a guard against
                                # a stalled client asking for an hour of work

DECAY_HEAT_INITIAL_FRAC = 7.0   # % of pre-trip power, immediately post-trip
DECAY_HEAT_TAU_S = 130.0

GRID_N = 10


def log(*args):
    print(*args, file=sys.stderr, flush=True)


# ==========================================================================
# Simulation host
# ==========================================================================

class ReactorSim:
    """Owns the plant: physics, rods, the NovaLang machine and the run's
    bookkeeping. One instance per episode; reset() starts a new shift."""

    def __init__(self, rules_path: str = DEFAULT_RULES, seed: int | None = None):
        self.rules_path = rules_path
        with open(rules_path, "r", encoding="utf-8") as fh:
            self.program = nova.parse(fh.read())
        self.rng = random.Random(seed)
        self.machine = nova.NovaMachine(self.program, self.rng)
        self.physics = phys.ReactorPhysics()
        self.reset(seed)

    # -- lifecycle -------------------------------------------------------

    def reset(self, seed: int | None = None):
        if seed is not None:
            self.rng.seed(seed)
        self.physics.reset()
        self.machine.reset()

        self.t = 0.0
        self.rod_a = 0.0
        self.rod_b = 0.0
        self.rod_target_a = 0.0
        self.rod_target_b = 0.0

        self.scram = False
        self.scram_t = 0.0
        self.flux_at_scram = 0.0

        self.game_over = False
        self.victory = False
        self.state = "STARTUP"
        self.alarm_level = 0
        self.alarm_text = ""

        # Plant boundary conditions, owned by NovaLang from tick 2 onward.
        self.flow_frac = 1.0
        self.load_frac = 1.0
        self.xenon_pcm = 0.0
        self.stuck_bank = ""

        self.pending_events = ["SIMULATION RESET -- REACTOR SUBCRITICAL"]
        self.history: list[list[float]] = []
        self.step_count = 0
        return self.snapshot()

    def reload_rules(self):
        """Re-read the .nova file without restarting the process. Lets you
        tune setpoints with the game running."""
        with open(self.rules_path, "r", encoding="utf-8") as fh:
            self.program = nova.parse(fh.read())
        self.machine = nova.NovaMachine(self.program, self.rng)
        self.pending_events.append("CONTROL RULES RELOADED")

    # -- the hot loop ----------------------------------------------------

    def advance(self, steps: int, rod_target_a: float, rod_target_b: float,
                operator_scram: bool, faults_enabled: bool = True):
        steps = max(0, min(int(steps), MAX_STEPS_PER_TICK))
        dt = phys.PHYSICS_DT
        self.history = []

        if not self.game_over and not self.scram:
            self.rod_target_a = phys.clamp(float(rod_target_a), 0.0, 100.0)
            self.rod_target_b = phys.clamp(float(rod_target_b), 0.0, 100.0)

        for i in range(steps):
            # The button is an edge: it belongs to the first substep only.
            self._substep(dt, operator_scram and i == 0, faults_enabled)

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

        # 4. Hand the measurements to NovaLang. Its outputs are the plant's
        #    boundary conditions for the *next* substep -- one 50 ms lag,
        #    which is both physically honest and keeps the loop acyclic.
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
            "meltdown": self.machine.meltdown,
        }
        out = self.machine.tick(dt, inputs, faults_enabled)

        self.flow_frac = out["flow_frac"]
        self.load_frac = out["load_frac"]
        self.xenon_pcm = out["xenon_pcm"]
        self.stuck_bank = out["stuck_bank"]
        self.state = out["state"]
        self.alarm_level = out["alarm_level"]
        self.alarm_text = out["alarm_text"]

        # NovaLang may drive the rods itself (the optional autopilot rule).
        self.rod_target_a = out["rod_target_a"]
        self.rod_target_b = out["rod_target_b"]

        if out["scram_requested"] and not self.scram:
            self._latch_scram()
        elif out["trip_reset"] and self.scram:
            self.scram = False

        if out["meltdown"] and not self.game_over:
            self.game_over = True
        if out["victory"] and not self.game_over:
            self.game_over = True
            self.victory = True

        if out["events"]:
            self.pending_events.extend(out["events"])

        self.history.append([self.physics.flux_percent, self.physics.fuel_temp])

    def _latch_scram(self):
        """Rods slam in. This bypasses the drive rate limit on purpose --
        a real scram drops them under gravity, it does not drive them."""
        self.flux_at_scram = self.physics.flux_percent
        self.scram = True
        self.scram_t = self.t
        self.rod_a = 0.0
        self.rod_b = 0.0
        self.rod_target_a = 0.0
        self.rod_target_b = 0.0

    # -- reporting -------------------------------------------------------

    def _peaking(self):
        """Two scalars plus an amplitude are enough for the GPU to draw the
        whole 10x10 heat map, so the core map costs no per-frame bandwidth.
        Asymmetric rod insertion tilts the flux toward the withdrawn bank;
        losing flow pushes the hot spot toward the outlet."""
        tilt_x = phys.clamp((self.rod_a - self.rod_b) / 100.0, -1.0, 1.0)
        tilt_y = phys.clamp((1.0 - self.flow_frac) * 0.6, -1.0, 1.0)
        amp = 0.65
        return {"tilt_x": tilt_x, "tilt_y": tilt_y, "amp": amp, "n": GRID_N}

    def snapshot(self) -> dict:
        events = self.pending_events
        self.pending_events = []
        fault = None
        if self.machine.active_fault is not None:
            fault = {
                "name": self.machine.active_fault.name,
                "label": self.machine.active_fault.label,
                "elapsed": float(self.machine.vars.get("fault_elapsed", 0.0)),
                "duration": float(self.machine.vars.get("fault_duration", 0.0)),
            }
        snap = {
            "ok": True,
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
        }
        return snap


# ==========================================================================
# Command dispatch
# ==========================================================================

class Session:
    def __init__(self, rules_path=DEFAULT_RULES, seed=None):
        self.sim = ReactorSim(rules_path, seed)
        self.alive = True

    def handle(self, req: dict) -> dict:
        cmd = req.get("cmd", "")
        if cmd == "hello":
            return {
                "ok": True,
                "proto": PROTO_VERSION,
                "backend": phys.BACKEND,
                "engine": "nova",
                "title": self.sim.program.title,
                "rules_version": self.sim.program.version,
                "dt": phys.PHYSICS_DT,
                "hz": phys.PHYSICS_HZ,
                "grid": GRID_N,
                "pid": os.getpid(),
            }
        if cmd == "reset":
            return self.sim.reset(req.get("seed"))
        if cmd == "tick":
            return self.sim.advance(
                req.get("steps", 1),
                req.get("rod_target_a", self.sim.rod_target_a),
                req.get("rod_target_b", self.sim.rod_target_b),
                bool(req.get("scram", False)),
                bool(req.get("faults", True)),
            )
        if cmd == "state":
            return self.sim.snapshot()
        if cmd == "reload":
            self.sim.reload_rules()
            return self.sim.snapshot()
        if cmd == "quit":
            self.alive = False
            return {"ok": True, "bye": True}
        return {"ok": False, "error": f"unknown command {cmd!r}"}

    def handle_line(self, line: str) -> str | None:
        line = line.strip()
        if not line:
            return None
        try:
            req = json.loads(line)
            if not isinstance(req, dict):
                raise ValueError("request must be a JSON object")
            resp = self.handle(req)
        except Exception as exc:       # never let one bad frame kill the sim
            resp = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
        return json.dumps(resp, separators=(",", ":"))


# ==========================================================================
# Transports
# ==========================================================================

def serve_stdio(session: Session):
    log(f"[reactor] stdio bridge up, backend={phys.BACKEND}, pid={os.getpid()}")
    for line in sys.stdin:
        out = session.handle_line(line)
        if out is not None:
            sys.stdout.write(out + "\n")
            sys.stdout.flush()
        if not session.alive:
            break
    log("[reactor] stdio bridge closed")


def serve_tcp(session: Session, host: str, port: int):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(1)
    log(f"[reactor] tcp bridge listening on {host}:{port}, "
        f"backend={phys.BACKEND}")
    try:
        while True:
            conn, addr = srv.accept()
            log(f"[reactor] client connected from {addr[0]}:{addr[1]}")
            session.sim.reset()
            with conn, conn.makefile("rw", encoding="utf-8", newline="\n") as fh:
                for line in fh:
                    out = session.handle_line(line)
                    if out is not None:
                        fh.write(out + "\n")
                        fh.flush()
                    if not session.alive:
                        break
            log("[reactor] client disconnected")
            if not session.alive:
                break
    except KeyboardInterrupt:
        pass
    finally:
        srv.close()


# ==========================================================================
# Diagnostics
# ==========================================================================

def selftest(seconds: float = 60.0, seed: int = 7) -> dict:
    """Headless run: pull the rods to a critical band and hold. Exercises
    physics, rules and the fault injector with no Godot in the picture."""
    sim = ReactorSim(seed=seed)
    steps = int(seconds / phys.PHYSICS_DT)
    events = []
    snap = sim.snapshot()
    t0 = time.perf_counter()
    for i in range(steps):
        # Ramp the banks in over 60 s the way an operator would, rather than
        # yanking them out and tripping on flux inside four seconds.
        target = 72.0 * min(1.0, (i * phys.PHYSICS_DT) / 60.0)
        snap = sim.advance(1, target, target, False, True)
        events.extend(snap["events"])
    wall = time.perf_counter() - t0
    return {
        "ok": True,
        "sim_seconds": seconds,
        "wall_seconds": round(wall, 3),
        "realtime_factor": round(seconds / wall, 1) if wall > 0 else None,
        "us_per_step": round(wall / max(1, steps) * 1e6, 1),
        "backend": phys.BACKEND,
        "final": {k: snap[k] for k in ("t", "flux_pct", "fuel_temp_c",
                                       "pressure_mpa", "state", "scram",
                                       "game_over")},
        "events": events,
    }


def validate(rules_path: str) -> dict:
    try:
        with open(rules_path, "r", encoding="utf-8") as fh:
            prog = nova.parse(fh.read())
    except Exception as exc:
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
    return {
        "ok": True,
        "title": prog.title,
        "version": prog.version,
        "params": len(prog.params),
        "effects": len(prog.effects),
        "signals": len(prog.signals),
        "rules": [r.name for r in prog.rules],
        "faults": [f.name for f in prog.faults],
    }


# ==========================================================================
# Entry point
# ==========================================================================

def main(argv=None):
    ap = argparse.ArgumentParser(description="Reactor sim bridge daemon")
    ap.add_argument("--rules", default=DEFAULT_RULES,
                    help="path to the NovaLang policy file")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--tcp", metavar="[HOST:]PORT",
                    help="serve the protocol over TCP instead of stdio")
    ap.add_argument("--once", metavar="JSON",
                    help="handle one request, print the reply, exit")
    ap.add_argument("--selftest", action="store_true",
                    help="run a headless 60 s episode and report")
    ap.add_argument("--validate", action="store_true",
                    help="parse the .nova policy and report its contents")
    ap.add_argument("--seconds", type=float, default=60.0,
                    help="episode length for --selftest")
    args = ap.parse_args(argv)

    if args.validate:
        print(json.dumps(validate(args.rules), indent=2))
        return 0
    if args.selftest:
        print(json.dumps(selftest(args.seconds, args.seed or 7), indent=2))
        return 0

    session = Session(args.rules, args.seed)

    if args.once:
        print(session.handle_line(args.once))
        return 0
    if args.tcp:
        host, _, port = args.tcp.rpartition(":")
        serve_tcp(session, host or "127.0.0.1", int(port))
        return 0
    serve_stdio(session)
    return 0


if __name__ == "__main__":
    sys.exit(main())
