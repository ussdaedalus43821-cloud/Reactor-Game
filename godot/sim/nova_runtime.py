"""
nova_runtime.py -- a small interpreter for NovaLang.

NovaLang is the declarative rule language the reactor's *policy* is written
in (see reactor_rules.nova): trip setpoints, alarm tiers, fault injection
and the state machine. It deliberately knows nothing about how the core is
integrated -- reactor_physics.py owns that -- and nothing about pixels.
Editing reactor_rules.nova changes the reactor's behaviour with no Python
and no Godot rebuild.

Language summary
----------------

    reactor "NAME" version 1

    params  { name = <expr> ... }          # constants, readable everywhere
    effects { name = <expr> [persistent] } # vars faults write; reset each
                                           # tick unless marked persistent
    signals { name = <expr> ... }          # derived values, recomputed each
                                           # tick before any rule runs

    rule NAME [priority N] [once] [edge] {
        when <expr>
        then <action> <action> ...
    }

    fault NAME [weight W] [duration S] [label "TEXT"] {
        <action> ...                       # applied every tick while active
    }

Expressions: or / and / not, comparisons, + - * / %, parentheses, numbers,
strings, true / false, identifiers and calls. Builtins: abs min max clamp
exp sqrt floor ramp lerp pick rand, plus the temporal predicate
held(<cond>, <seconds>) which is true once <cond> has been continuously
true for that long.

Actions: set NAME = <expr>, log(<expr>), alarm(<level>, <expr>),
scram(<expr>), reset_trip(), meltdown(<expr>), victory(<expr>),
inject_fault(<name>), clear_fault().

`and` / `or` short-circuit, so a held() in a skipped branch does not
accumulate -- which is the behaviour you want for guarded trips.
"""

from __future__ import annotations

import math
import random
import re


class NovaError(Exception):
    """Raised for any syntax or runtime problem in a .nova script."""


# ==========================================================================
# Tokenizer
# ==========================================================================

_KEYWORDS = {
    "reactor", "version", "params", "effects", "signals", "rule", "fault",
    "when", "then", "set", "priority", "once", "edge", "weight", "duration",
    "label", "persistent", "and", "or", "not", "true", "false",
}

_TOKEN_RE = re.compile(r"""
      (?P<ws>\s+)
    | (?P<comment>\#[^\n]*|//[^\n]*)
    | (?P<number>\d+\.\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?|\d+(?:[eE][+-]?\d+)?)
    | (?P<string>"(?:[^"\\]|\\.)*")
    | (?P<ident>[A-Za-z_][A-Za-z_0-9]*)
    | (?P<op><=|>=|==|!=|[-+*/%<>=(){},])
""", re.VERBOSE)


class Token:
    __slots__ = ("kind", "value", "line")

    def __init__(self, kind, value, line):
        self.kind = kind
        self.value = value
        self.line = line

    def __repr__(self):  # pragma: no cover - debugging aid
        return f"Token({self.kind}, {self.value!r}, line {self.line})"


def tokenize(src: str):
    tokens = []
    pos = 0
    line = 1
    n = len(src)
    while pos < n:
        m = _TOKEN_RE.match(src, pos)
        if not m:
            raise NovaError(f"line {line}: unexpected character {src[pos]!r}")
        kind = m.lastgroup
        text = m.group()
        pos = m.end()
        if kind in ("ws", "comment"):
            line += text.count("\n")
            continue
        if kind == "number":
            tokens.append(Token("number", float(text), line))
        elif kind == "string":
            tokens.append(Token("string", _unescape(text[1:-1]), line))
        elif kind == "ident":
            tokens.append(Token("keyword" if text in _KEYWORDS else "ident",
                                text, line))
        else:
            tokens.append(Token("op", text, line))
    tokens.append(Token("eof", None, line))
    return tokens


def _unescape(s: str) -> str:
    return (s.replace("\\n", "\n").replace("\\t", "\t")
             .replace('\\"', '"').replace("\\\\", "\\"))


# ==========================================================================
# AST
# ==========================================================================

class Node:
    __slots__ = ()


class Num(Node):
    __slots__ = ("value",)

    def __init__(self, value):
        self.value = value


class Str(Node):
    __slots__ = ("value",)

    def __init__(self, value):
        self.value = value


class Bool(Node):
    __slots__ = ("value",)

    def __init__(self, value):
        self.value = value


class Var(Node):
    __slots__ = ("name", "line")

    def __init__(self, name, line):
        self.name = name
        self.line = line


class Unary(Node):
    __slots__ = ("op", "operand")

    def __init__(self, op, operand):
        self.op = op
        self.operand = operand


class Binary(Node):
    __slots__ = ("op", "left", "right")

    def __init__(self, op, left, right):
        self.op = op
        self.left = left
        self.right = right


class Call(Node):
    __slots__ = ("name", "args", "slot", "line")

    def __init__(self, name, args, slot, line):
        self.name = name
        self.args = args
        self.slot = slot          # stable id for stateful builtins (held)
        self.line = line


class SetAction(Node):
    __slots__ = ("target", "expr", "line")

    def __init__(self, target, expr, line):
        self.target = target
        self.expr = expr
        self.line = line


class CallAction(Node):
    __slots__ = ("name", "args", "line")

    def __init__(self, name, args, line):
        self.name = name
        self.args = args
        self.line = line


class Rule:
    __slots__ = ("name", "priority", "once", "edge", "condition", "actions",
                 "fired", "was_true", "line")

    def __init__(self, name, priority, once, edge, condition, actions, line):
        self.name = name
        self.priority = priority
        self.once = once
        self.edge = edge
        self.condition = condition
        self.actions = actions
        self.fired = False
        self.was_true = False
        self.line = line


class Fault:
    __slots__ = ("name", "weight", "duration", "label", "actions", "line")

    def __init__(self, name, weight, duration, label, actions, line):
        self.name = name
        self.weight = weight
        self.duration = duration
        self.label = label
        self.actions = actions
        self.line = line


class Program:
    def __init__(self):
        self.title = "UNNAMED REACTOR"
        self.version = 1
        self.params = []        # [(name, expr)] -- ordered, may reference
        self.effects = []       # [(name, expr, persistent)]
        self.signals = []       # [(name, expr)]
        self.rules = []
        self.faults = []
        self.held_slots = 0


# ==========================================================================
# Parser
# ==========================================================================

class Parser:
    def __init__(self, tokens, program):
        self.toks = tokens
        self.i = 0
        self.prog = program

    # -- token helpers ---------------------------------------------------

    @property
    def cur(self):
        return self.toks[self.i]

    def at(self, kind, value=None):
        t = self.cur
        return t.kind == kind and (value is None or t.value == value)

    def accept(self, kind, value=None):
        if self.at(kind, value):
            t = self.cur
            self.i += 1
            return t
        return None

    def expect(self, kind, value=None):
        t = self.accept(kind, value)
        if t is None:
            want = value if value is not None else kind
            raise NovaError(f"line {self.cur.line}: expected {want!r}, "
                            f"got {self.cur.value!r}")
        return t

    def name_token(self):
        """Rule and fault names may collide with keywords; accept both."""
        t = self.cur
        if t.kind in ("ident", "keyword"):
            self.i += 1
            return t
        raise NovaError(f"line {t.line}: expected a name, got {t.value!r}")

    # -- top level -------------------------------------------------------

    def parse(self):
        while not self.at("eof"):
            if self.accept("keyword", "reactor"):
                self.prog.title = self.expect("string").value
                if self.accept("keyword", "version"):
                    self.prog.version = int(self.expect("number").value)
            elif self.accept("keyword", "params"):
                self.prog.params.extend(self._assign_block())
            elif self.accept("keyword", "signals"):
                self.prog.signals.extend(self._assign_block())
            elif self.accept("keyword", "effects"):
                self.prog.effects.extend(self._effect_block())
            elif self.accept("keyword", "rule"):
                self.prog.rules.append(self._rule())
            elif self.accept("keyword", "fault"):
                self.prog.faults.append(self._fault())
            else:
                raise NovaError(f"line {self.cur.line}: unexpected "
                                f"{self.cur.value!r} at top level")
        self.prog.rules.sort(key=lambda r: -r.priority)
        return self.prog

    def _assign_block(self):
        self.expect("op", "{")
        out = []
        while not self.accept("op", "}"):
            name = self.expect("ident").value
            self.expect("op", "=")
            out.append((name, self.expr()))
        return out

    def _effect_block(self):
        self.expect("op", "{")
        out = []
        while not self.accept("op", "}"):
            name = self.expect("ident").value
            self.expect("op", "=")
            value = self.expr()
            persistent = self.accept("keyword", "persistent") is not None
            out.append((name, value, persistent))
        return out

    def _rule(self):
        line = self.cur.line
        name = self.name_token().value
        priority = 0.0
        once = False
        edge = False
        while True:
            if self.accept("keyword", "priority"):
                priority = self.expect("number").value
            elif self.accept("keyword", "once"):
                once = True
            elif self.accept("keyword", "edge"):
                edge = True
            else:
                break
        self.expect("op", "{")
        self.expect("keyword", "when")
        cond = self.expr()
        self.expect("keyword", "then")
        actions = self._actions_until_brace()
        return Rule(name, priority, once, edge, cond, actions, line)

    def _fault(self):
        line = self.cur.line
        name = self.name_token().value
        weight = 1.0
        duration = Num(30.0)
        label = name.replace("_", " ").upper()
        while True:
            if self.accept("keyword", "weight"):
                weight = self.expect("number").value
            elif self.accept("keyword", "duration"):
                duration = self.expr()
            elif self.accept("keyword", "label"):
                label = self.expect("string").value
            else:
                break
        self.expect("op", "{")
        actions = self._actions_until_brace()
        return Fault(name, weight, duration, label, actions, line)

    def _actions_until_brace(self):
        actions = []
        while not self.accept("op", "}"):
            actions.append(self._action())
        return actions

    def _action(self):
        line = self.cur.line
        if self.accept("keyword", "set"):
            target = self.expect("ident").value
            self.expect("op", "=")
            return SetAction(target, self.expr(), line)
        name = self.expect("ident").value
        self.expect("op", "(")
        args = []
        if not self.at("op", ")"):
            args.append(self.expr())
            while self.accept("op", ","):
                args.append(self.expr())
        self.expect("op", ")")
        return CallAction(name, args, line)

    # -- expressions -----------------------------------------------------

    def expr(self):
        return self._or()

    def _or(self):
        node = self._and()
        while self.accept("keyword", "or"):
            node = Binary("or", node, self._and())
        return node

    def _and(self):
        node = self._not()
        while self.accept("keyword", "and"):
            node = Binary("and", node, self._not())
        return node

    def _not(self):
        if self.accept("keyword", "not"):
            return Unary("not", self._not())
        return self._comparison()

    def _comparison(self):
        node = self._additive()
        while self.cur.kind == "op" and self.cur.value in ("<", ">", "<=",
                                                           ">=", "==", "!="):
            op = self.cur.value
            self.i += 1
            node = Binary(op, node, self._additive())
        return node

    def _additive(self):
        node = self._multiplicative()
        while self.cur.kind == "op" and self.cur.value in ("+", "-"):
            op = self.cur.value
            self.i += 1
            node = Binary(op, node, self._multiplicative())
        return node

    def _multiplicative(self):
        node = self._unary()
        while self.cur.kind == "op" and self.cur.value in ("*", "/", "%"):
            op = self.cur.value
            self.i += 1
            node = Binary(op, node, self._unary())
        return node

    def _unary(self):
        if self.accept("op", "-"):
            return Unary("-", self._unary())
        if self.accept("op", "+"):
            return self._unary()
        return self._primary()

    def _primary(self):
        t = self.cur
        if t.kind == "number":
            self.i += 1
            return Num(t.value)
        if t.kind == "string":
            self.i += 1
            return Str(t.value)
        if self.accept("keyword", "true"):
            return Bool(True)
        if self.accept("keyword", "false"):
            return Bool(False)
        if self.accept("op", "("):
            node = self.expr()
            self.expect("op", ")")
            return node
        if t.kind == "ident":
            self.i += 1
            if self.accept("op", "("):
                args = []
                if not self.at("op", ")"):
                    args.append(self.expr())
                    while self.accept("op", ","):
                        args.append(self.expr())
                self.expect("op", ")")
                slot = -1
                if t.value == "held":
                    slot = self.prog.held_slots
                    self.prog.held_slots += 1
                return Call(t.value, args, slot, t.line)
            return Var(t.value, t.line)
        raise NovaError(f"line {t.line}: unexpected {t.value!r} in expression")


def parse(src: str) -> Program:
    prog = Program()
    return Parser(tokenize(src), prog).parse()


# ==========================================================================
# Interpreter
# ==========================================================================

def _truthy(v):
    if isinstance(v, bool):
        return v
    if isinstance(v, str):
        return len(v) > 0
    return bool(v)


def _as_text(v) -> str:
    """Numbers interpolated into log messages should read like operator
    displays, not like float repr."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float):
        return str(int(v)) if v == int(v) else f"{v:.2f}"
    return str(v)


def _num(v, ctx=""):
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)):
        return float(v)
    raise NovaError(f"{ctx}expected a number, got {v!r}")


# Minimum argument count per builtin. Guarding here means a typo in the
# policy file surfaces as a readable error instead of an IndexError.
_MIN_ARITY = {
    "clamp": 3, "lerp": 3, "rand": 2,
    "abs": 1, "exp": 1, "sqrt": 1, "floor": 1, "ramp": 1,
    "min": 1, "max": 1, "pick": 1,
}


class NovaMachine:
    """Holds the parsed program plus all runtime state (variables, held()
    timers, rule latches, the fault scheduler). One machine == one
    reactor episode; call reset() to start a new run."""

    def __init__(self, program: Program, rng: random.Random | None = None):
        self.prog = program
        self.rng = rng or random.Random()
        self.vars: dict[str, object] = {}
        self.params: dict[str, object] = {}
        self.held_timers = [0.0] * program.held_slots
        self.events: list[str] = []
        self.reset()

    # -- lifecycle -------------------------------------------------------

    def reset(self):
        self.vars = {}
        self.params = {}
        self.held_timers = [0.0] * self.prog.held_slots
        self.events = []
        self._dt = 0.0

        # Params first: later params may reference earlier ones.
        for name, expr in self.prog.params:
            self.params[name] = self.eval(expr)

        self.effect_defaults = {}
        self.persistent_effects = set()
        for name, expr, persistent in self.prog.effects:
            value = self.eval(expr)
            self.effect_defaults[name] = value
            self.vars[name] = value
            if persistent:
                self.persistent_effects.add(name)

        for rule in self.prog.rules:
            rule.fired = False
            rule.was_true = False

        # Fault scheduler
        self.active_fault: Fault | None = None
        self.fault_started_at = 0.0
        self.next_fault_at = self._roll_next_fault_delay(0.0)

        # Per-tick sink, refreshed by tick()
        self.scram_requested = False
        self.scram_reason = ""
        self.trip_reset = False
        self.meltdown = False
        self.victory = False
        self.alarm_level = 0
        self.alarm_text = ""

    def _roll_next_fault_delay(self, now):
        lo = _num(self.lookup("fault_first_min_s", 45.0))
        hi = _num(self.lookup("fault_first_max_s", 90.0))
        return now + self.rng.uniform(lo, hi)

    # -- variable access -------------------------------------------------

    def lookup(self, name, default=None):
        if name in self.vars:
            return self.vars[name]
        if name in self.params:
            return self.params[name]
        if default is not None:
            return default
        raise NovaError(f"unknown identifier {name!r}")

    def set_inputs(self, mapping: dict):
        """Host pushes physics/operator state in before each tick."""
        self.vars.update(mapping)

    # -- expression evaluation -------------------------------------------

    def eval(self, node):
        cls = node.__class__
        if cls is Num or cls is Str or cls is Bool:
            return node.value
        if cls is Var:
            try:
                return self.lookup(node.name)
            except NovaError as exc:
                raise NovaError(f"line {node.line}: {exc}") from None
        if cls is Unary:
            if node.op == "not":
                return not _truthy(self.eval(node.operand))
            return -_num(self.eval(node.operand), "unary -: ")
        if cls is Binary:
            return self._eval_binary(node)
        if cls is Call:
            return self._eval_call(node)
        raise NovaError(f"cannot evaluate {cls.__name__}")

    def _eval_binary(self, node):
        op = node.op
        if op == "and":
            left = self.eval(node.left)
            return _truthy(left) and _truthy(self.eval(node.right))
        if op == "or":
            left = self.eval(node.left)
            return _truthy(left) or _truthy(self.eval(node.right))

        a = self.eval(node.left)
        b = self.eval(node.right)

        if op == "==":
            return a == b
        if op == "!=":
            return a != b

        # `+` doubles as string concatenation so rules can build messages.
        if op == "+" and (isinstance(a, str) or isinstance(b, str)):
            return _as_text(a) + _as_text(b)

        # Ordering comparisons on strings are not meaningful here.
        an, bn = _num(a, f"'{op}': "), _num(b, f"'{op}': ")
        if op == "<":
            return an < bn
        if op == ">":
            return an > bn
        if op == "<=":
            return an <= bn
        if op == ">=":
            return an >= bn
        if op == "+":
            return an + bn
        if op == "-":
            return an - bn
        if op == "*":
            return an * bn
        if op == "/":
            return an / bn if bn != 0.0 else 0.0
        if op == "%":
            return math.fmod(an, bn) if bn != 0.0 else 0.0
        raise NovaError(f"unknown operator {op!r}")

    def _eval_call(self, node):
        name = node.name

        # held() is special: it must see the *unevaluated* condition so the
        # timer only advances on ticks where the guard actually runs.
        if name == "held":
            if len(node.args) != 2:
                raise NovaError(f"line {node.line}: held(cond, seconds) "
                                f"takes 2 arguments")
            cond = _truthy(self.eval(node.args[0]))
            secs = _num(self.eval(node.args[1]), "held(): ")
            slot = node.slot
            if cond:
                self.held_timers[slot] += self._dt
            else:
                self.held_timers[slot] = 0.0
            return self.held_timers[slot] >= secs

        args = [self.eval(a) for a in node.args]

        need = _MIN_ARITY.get(name, 0)
        if len(args) < need:
            raise NovaError(f"line {node.line}: {name}() needs {need} "
                            f"argument(s), got {len(args)}")

        if name == "abs":
            return abs(_num(args[0]))
        if name == "min":
            return min(_num(a) for a in args)
        if name == "max":
            return max(_num(a) for a in args)
        if name == "clamp":
            v, lo, hi = (_num(a) for a in args[:3])
            return lo if v < lo else (hi if v > hi else v)
        if name == "exp":
            return math.exp(max(-700.0, min(700.0, _num(args[0]))))
        if name == "sqrt":
            return math.sqrt(max(0.0, _num(args[0])))
        if name == "floor":
            return math.floor(_num(args[0]))
        if name == "ramp":
            v = _num(args[0])
            return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)
        if name == "lerp":
            a, b, t = (_num(x) for x in args[:3])
            t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
            return a + (b - a) * t
        if name == "pick":
            return self.rng.choice(args)
        if name == "rand":
            return self.rng.uniform(_num(args[0]), _num(args[1]))
        raise NovaError(f"line {node.line}: unknown function {name!r}")

    # -- actions ---------------------------------------------------------

    def exec_action(self, action):
        if action.__class__ is SetAction:
            self.vars[action.target] = self.eval(action.expr)
            return

        name = action.name
        args = [self.eval(a) for a in action.args]

        if name == "log":
            self.emit(str(args[0]))
        elif name == "alarm":
            if not args:
                raise NovaError(f"line {action.line}: alarm() needs a level")
            level = int(_num(args[0], "alarm(): "))
            text = str(args[1]) if len(args) > 1 else ""
            if level > self.alarm_level:
                self.alarm_level = level
                self.alarm_text = text
        elif name == "scram":
            # Latching the trip in vars as well as in the sink means the
            # lower-priority rules later in *this same tick* already see a
            # scrammed plant, so the state machine never lags the trip.
            reason = str(args[0]) if args else "SCRAM"
            if not _truthy(self.lookup("scram", False)):
                self.scram_requested = True
                self.scram_reason = reason
                self.vars["scram"] = True
                self.emit(reason)
        elif name == "meltdown":
            if not self.meltdown:
                self.meltdown = True
                self._end_run()
                self.emit(str(args[0]) if args else "MELTDOWN")
        elif name == "victory":
            if not self.victory:
                self.victory = True
                self._end_run()
                self.emit(str(args[0]) if args else "VICTORY")
        elif name == "reset_trip":
            self.trip_reset = True
            self.vars["scram"] = False
        elif name == "inject_fault":
            if not args:
                raise NovaError(f"line {action.line}: inject_fault() needs a name")
            self._activate_fault_by_name(str(args[0]))
        elif name == "clear_fault":
            if self.active_fault is not None:
                self._clear_fault()
        else:
            raise NovaError(f"line {action.line}: unknown action {name!r}")

    def _end_run(self):
        """Make the end of the run visible to the rest of this tick.
        `running` is an ordinary signal computed before the rules, so
        without this the state machine and the alarms would see the run
        finish one tick late."""
        self.vars["game_over"] = True
        self.vars["meltdown"] = self.meltdown
        self.vars["victory"] = self.victory
        self.vars["running"] = False

    def emit(self, text: str):
        self.events.append(text)

    # -- fault scheduling ------------------------------------------------

    def _fault_by_name(self, name):
        for f in self.prog.faults:
            if f.name == name:
                return f
        return None

    def _activate_fault_by_name(self, name):
        fault = self._fault_by_name(name)
        if fault is None:
            raise NovaError(f"no such fault {name!r}")
        self._activate_fault(fault)

    def _activate_fault(self, fault: Fault):
        if self.active_fault is not None:
            return
        self.active_fault = fault
        self.fault_started_at = _num(self.lookup("t", 0.0))
        self.vars["active_fault"] = fault.name
        self.vars["fault_label"] = fault.label
        self.vars["fault_elapsed"] = 0.0
        self.vars["fault_duration"] = _num(self.eval(fault.duration))
        self.emit("ALARM: " + fault.label)

    def _clear_fault(self):
        if self.active_fault is None:
            return
        self.emit(self.active_fault.label + " CLEARED")
        self.active_fault = None
        self.vars["active_fault"] = ""
        self.vars["fault_label"] = ""
        self.vars["fault_elapsed"] = 0.0
        self.vars["fault_duration"] = 0.0
        now = _num(self.lookup("t", 0.0))
        lo = _num(self.lookup("fault_gap_min_s", 45.0))
        hi = _num(self.lookup("fault_gap_max_s", 90.0))
        self.next_fault_at = now + self.rng.uniform(lo, hi)

    def _pick_weighted_fault(self):
        faults = [f for f in self.prog.faults if f.weight > 0.0]
        if not faults:
            return None
        total = sum(f.weight for f in faults)
        r = self.rng.uniform(0.0, total)
        acc = 0.0
        for f in faults:
            acc += f.weight
            if r <= acc:
                return f
        return faults[-1]

    def _update_faults(self, now, dt, enabled):
        if self.active_fault is None:
            if enabled and now >= self.next_fault_at:
                fault = self._pick_weighted_fault()
                if fault is not None:
                    self._activate_fault(fault)
        else:
            elapsed = now - self.fault_started_at
            self.vars["fault_elapsed"] = elapsed
            if elapsed >= _num(self.vars.get("fault_duration", 30.0)):
                self._clear_fault()

        if self.active_fault is not None:
            for action in self.active_fault.actions:
                self.exec_action(action)

    # -- the tick --------------------------------------------------------

    def tick(self, dt: float, inputs: dict, faults_enabled: bool = True):
        """One control cycle. `inputs` is the physics + operator state the
        host measured this step; the returned dict is what the host should
        feed back into the physics and show on the panel."""
        self._dt = dt
        self.events = []
        self.scram_requested = False
        self.scram_reason = ""
        self.trip_reset = False
        self.alarm_level = 0
        self.alarm_text = ""

        # Non-persistent effect vars fall back to their declared defaults so
        # a cleared fault stops acting on the plant automatically.
        for name, value in self.effect_defaults.items():
            if name not in self.persistent_effects:
                self.vars[name] = value

        self.vars["dt"] = dt
        self.vars.update(inputs)
        self.vars.setdefault("active_fault", "")
        self.vars.setdefault("fault_label", "")
        self.vars.setdefault("fault_elapsed", 0.0)
        self.vars.setdefault("fault_duration", 0.0)

        now = _num(self.lookup("t", 0.0))
        self._update_faults(now, dt, faults_enabled)

        for name, expr in self.prog.signals:
            self.vars[name] = self.eval(expr)

        for rule in self.prog.rules:
            if rule.once and rule.fired:
                rule.was_true = False
                continue
            try:
                cond = _truthy(self.eval(rule.condition))
            except NovaError as exc:
                raise NovaError(f"rule {rule.name!r}: {exc}") from None
            should_fire = cond and (not rule.edge or not rule.was_true)
            rule.was_true = cond
            if should_fire:
                rule.fired = True
                for action in rule.actions:
                    try:
                        self.exec_action(action)
                    except NovaError as exc:
                        raise NovaError(f"rule {rule.name!r}: {exc}") from None

        return self.outputs()

    def outputs(self) -> dict:
        return {
            "flow_frac": _num(self.lookup("flow_frac", 1.0)),
            "load_frac": _num(self.lookup("load_frac", 1.0)),
            "xenon_pcm": _num(self.lookup("xenon_pcm", 0.0)),
            "stuck_bank": str(self.lookup("stuck_bank", "")),
            "rod_target_a": _num(self.lookup("rod_target_a", 0.0)),
            "rod_target_b": _num(self.lookup("rod_target_b", 0.0)),
            "state": str(self.lookup("state", "STARTUP")),
            "alarm_level": self.alarm_level,
            "alarm_text": self.alarm_text,
            "scram_requested": self.scram_requested,
            "scram_reason": self.scram_reason,
            "trip_reset": self.trip_reset,
            "meltdown": self.meltdown,
            "victory": self.victory,
            "active_fault": str(self.lookup("active_fault", "")),
            "fault_label": str(self.lookup("fault_label", "")),
            "fault_elapsed": _num(self.lookup("fault_elapsed", 0.0)),
            "fault_duration": _num(self.lookup("fault_duration", 0.0)),
            "events": list(self.events),
        }


def load(path: str, rng: random.Random | None = None) -> NovaMachine:
    with open(path, "r", encoding="utf-8") as fh:
        return NovaMachine(parse(fh.read()), rng)
