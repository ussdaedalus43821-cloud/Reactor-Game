"""
nova_vm.py -- the NovaLang façade (reference).

Ties the lexer, parser and evaluator together and adds the two things a
host actually needs: a public API (load_file / eval / call_function /
register_function) and the reactor rule engine that drives `rule`, `fault`,
`effects` and `signals` declarations once per tick.

Note what is *not* here any more: scram(), log(), alarm() and the rest used
to be hard-coded actions inside the interpreter. They are now ordinary host
functions, registered by whoever embeds the VM -- reactor_host.py here,
nova_bridge.gd in Godot. The language no longer knows what a reactor is.
"""

from __future__ import annotations

import os
import random

from nova_lexer import NovaError
from nova_parser import Program, parse
from nova_evaluator import Env, Evaluator, NovaFunction, text, truthy


class NovaVM:
    def __init__(self, rng=None, module_reader=None, base_dir: str = ""):
        self.rng = rng or random.Random()
        self.base_dir = base_dir
        self.module_reader = module_reader or self._read_from_disk
        self.program = Program()
        self.evaluator = Evaluator(self.rng, self)
        self.error = ""
        self.name = "<empty>"

        self._modules = {}          # resolved path -> exports dict
        self._loading = []          # cycle detection

        # rule-engine state
        self.effect_defaults = {}
        self.persistent_effects = {}
        self.active_fault = None
        self.fault_started_at = 0.0
        self.next_fault_at = 0.0

    # -- module loading -----------------------------------------------------

    def _read_from_disk(self, path: str):
        full = os.path.join(self.base_dir, path) if self.base_dir else path
        if not os.path.exists(full):
            return None
        with open(full, "r", encoding="utf-8") as fh:
            return fh.read()

    def load_module(self, path: str) -> dict:
        """`import "x.nova"` -- parse and run a module once, then hand back
        its exported bindings. Results are cached, so importing the same
        module from three places runs it once."""
        if path in self._modules:
            return self._modules[path]
        if path in self._loading:
            self.error = "circular import of %r" % path
            return {}

        source = self.module_reader(path)
        if source is None:
            self.error = "cannot read module %r" % path
            return {}

        self._loading.append(path)
        try:
            module_prog = parse(source, path)
        except NovaError as exc:
            self.error = "%s: %s" % (path, exc)
            self._loading.pop()
            return {}

        # A module gets its own global scope: it can see the builtins and the
        # host functions, never the importer's variables.
        module_env = Env()
        saved_held = self.evaluator.held_timers
        self.evaluator.held_timers = [0.0] * module_prog.held_slots
        self.evaluator.exec_block(module_prog.statements, module_env)
        self.evaluator.held_timers = saved_held
        self._loading.pop()

        if self.evaluator.error:
            self.error = "%s: %s" % (path, self.evaluator.error)
            return {}

        exports = {}
        for name in module_prog.exports:
            if module_env.has(name):
                exports[name] = module_env.get(name)
        self._modules[path] = exports
        return exports

    # -- public API ---------------------------------------------------------

    def register_function(self, name: str, fn) -> None:
        """Expose a host function to NovaLang source."""
        self.evaluator.register_function(name, fn)

    def load_file(self, path: str) -> bool:
        source = self.module_reader(path)
        if source is None:
            self.error = "cannot read %r" % path
            return False
        return self.eval(source, path)

    def eval(self, source: str, name: str = "<source>") -> bool:
        """Parse `source` as the main program and initialise it. Returns
        False and sets `error` on any lexer, parser or runtime failure."""
        self.error = ""
        self.name = name
        try:
            self.program = parse(source, name)
        except NovaError as exc:
            self.error = str(exc)
            return False
        return self.reset(0)

    def call_function(self, name: str, args=None):
        """Call a NovaLang function from host code.

        Named call_function() rather than call() because every Godot Object
        already has a call() method and shadowing it is a hard error there;
        the two implementations keep the same name so the docs match.
        """
        args = args or []
        if not self.globals.has(name):
            self.error = "no such function %r" % name
            return None
        fn = self.globals.get(name)
        if not isinstance(fn, NovaFunction):
            self.error = "%r is not a function" % name
            return None
        self.evaluator.begin_run()
        result = self.evaluator.call_function(fn, args, 0)
        if self.evaluator.error:
            self.error = self.evaluator.error
        return result

    def get_global(self, name: str, fallback=None):
        if self.globals.has(name):
            return self.globals.get(name)
        return fallback

    def set_global(self, name: str, value) -> None:
        self.globals.declare(name, value)

    @property
    def globals(self) -> Env:
        return self.evaluator.globals

    @property
    def output(self):
        """Everything print() has emitted since the last drain."""
        return self.evaluator.output

    def drain_output(self):
        lines = list(self.evaluator.output)
        self.evaluator.output = []
        return lines

    # -- lifecycle ----------------------------------------------------------

    def reset(self, seed: int = 0) -> bool:
        """Re-initialise: fresh globals, top-level statements re-run, params
        and effect defaults re-evaluated, every latch cleared."""
        if seed:
            self.rng.seed(seed)
        ev = self.evaluator
        ev.globals = Env()
        ev.held_timers = [0.0] * self.program.held_slots
        ev.output = []
        ev.begin_run()

        ev.exec_block(self.program.statements, ev.globals)
        if ev.error:
            self.error = ev.error
            return False

        for name, expr in self.program.params:
            ev.globals.declare(name, ev.eval(expr, ev.globals))

        self.effect_defaults = {}
        self.persistent_effects = {}
        for name, expr, persistent in self.program.effects:
            value = ev.eval(expr, ev.globals)
            self.effect_defaults[name] = value
            ev.globals.declare(name, value)
            if persistent:
                self.persistent_effects[name] = True

        for rule in self.program.rules:
            rule["fired"] = False
            rule["was_true"] = False

        self.active_fault = None
        self.fault_started_at = 0.0
        self.next_fault_at = self.rng.uniform(
            float(self.get_global("fault_first_min_s", 45.0)),
            float(self.get_global("fault_first_max_s", 90.0)))

        if ev.error:
            self.error = ev.error
            return False
        return True

    # -- the reactor rule engine -------------------------------------------

    def _host_log(self, message: str) -> None:
        """The scheduler's own announcements go through the host's log()
        like any other, so a host that renders logs differently gets fault
        messages for free."""
        fn = self.evaluator.host_functions.get("log")
        if fn is not None:
            fn([message])

    def _fault_by_name(self, name: str):
        for f in self.program.faults:
            if f["name"] == name:
                return f
        return None

    def _activate_fault(self, fault) -> None:
        if self.active_fault is not None:
            return
        ev = self.evaluator
        self.active_fault = fault
        self.fault_started_at = float(self.get_global("t", 0.0))
        ev.globals.declare("active_fault", fault["name"])
        ev.globals.declare("fault_label", fault["label"])
        ev.globals.declare("fault_elapsed", 0.0)
        ev.globals.declare("fault_duration",
                           float(ev.eval(fault["duration"], ev.globals)))
        self._host_log("ALARM: " + fault["label"])

    def _clear_fault(self) -> None:
        if self.active_fault is None:
            return
        ev = self.evaluator
        self._host_log(self.active_fault["label"] + " CLEARED")
        self.active_fault = None
        ev.globals.declare("active_fault", "")
        ev.globals.declare("fault_label", "")
        ev.globals.declare("fault_elapsed", 0.0)
        ev.globals.declare("fault_duration", 0.0)
        now = float(self.get_global("t", 0.0))
        self.next_fault_at = now + self.rng.uniform(
            float(self.get_global("fault_gap_min_s", 45.0)),
            float(self.get_global("fault_gap_max_s", 90.0)))

    def _pick_weighted_fault(self):
        total = sum(f["weight"] for f in self.program.faults if f["weight"] > 0)
        if total <= 0.0:
            return None
        r = self.rng.uniform(0.0, total)
        acc = 0.0
        for f in self.program.faults:
            if f["weight"] <= 0.0:
                continue
            acc += f["weight"]
            if r <= acc:
                return f
        return None

    def inject_fault(self, name: str) -> bool:
        fault = self._fault_by_name(name)
        if fault is None:
            self.error = "no such fault %r" % name
            return False
        self._activate_fault(fault)
        return True

    def clear_fault(self) -> None:
        self._clear_fault()

    def _update_faults(self, now: float, enabled: bool) -> None:
        ev = self.evaluator
        if self.active_fault is None:
            if enabled and now >= self.next_fault_at:
                fault = self._pick_weighted_fault()
                if fault is not None:
                    self._activate_fault(fault)
        else:
            elapsed = now - self.fault_started_at
            ev.globals.declare("fault_elapsed", elapsed)
            if elapsed >= float(self.get_global("fault_duration", 30.0)):
                self._clear_fault()

        if self.active_fault is not None:
            ev.exec_block(self.active_fault["body"], Env(ev.globals))

    def tick(self, dt: float, inputs: dict, faults_enabled: bool = True) -> bool:
        """One control cycle: reset transient effects, take the host's
        measurements, run the fault scheduler, recompute signals, then fire
        every rule in priority order. The host reads results back with
        get_global() and through the functions it registered."""
        ev = self.evaluator
        ev.begin_run()
        ev.dt = dt

        for name, value in self.effect_defaults.items():
            if name not in self.persistent_effects:
                ev.globals.declare(name, value)

        ev.globals.declare("dt", dt)
        for key in inputs:
            ev.globals.declare(key, inputs[key])
        for key, default in (("active_fault", ""), ("fault_label", ""),
                             ("fault_elapsed", 0.0), ("fault_duration", 0.0)):
            if not ev.globals.has(key):
                ev.globals.declare(key, default)

        self._update_faults(float(self.get_global("t", 0.0)), faults_enabled)
        if ev.error:
            self.error = ev.error
            return False

        for name, expr in self.program.signal_defs:
            ev.globals.declare(name, ev.eval(expr, ev.globals))

        for rule in self.program.rules:
            if rule["once"] and rule["fired"]:
                rule["was_true"] = False
                continue
            cond = truthy(ev.eval(rule["cond"], ev.globals))
            if ev.error:
                self.error = "rule %r: %s" % (rule["name"], ev.error)
                return False
            should_fire = cond and (not rule["edge"] or not rule["was_true"])
            rule["was_true"] = cond
            if should_fire:
                rule["fired"] = True
                ev.exec_block(rule["body"], Env(ev.globals))
                if ev.error:
                    self.error = "rule %r: %s" % (rule["name"], ev.error)
                    return False
        return True

    # -- introspection, used by --validate and the conformance generator ---

    def describe(self) -> dict:
        return {
            "title": self.program.title,
            "version": self.program.version,
            "params": [n for n, _ in self.program.params],
            "effects": [n for n, _, _ in self.program.effects],
            "signals": [n for n, _ in self.program.signal_defs],
            "rules": [r["name"] for r in self.program.rules],
            "faults": [f["name"] for f in self.program.faults],
            "statements": len(self.program.statements),
            "exports": list(self.program.exports),
            "held_slots": self.program.held_slots,
        }
