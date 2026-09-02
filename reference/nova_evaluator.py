"""
nova_evaluator.py -- NovaLang tree-walking evaluator (reference).

Owns everything about *running* a parsed program: scope chains, closures,
the value model, the builtin library, and the registry through which host
code (GDScript in the real thing, Python here) exposes its own functions to
NovaLang.

Deliberate design notes, both of which exist so the GDScript port can be a
line-for-line mirror:

  * GDScript has no exceptions, so control flow does not use them here
    either. A statement returns None for "fell off the end", or a small
    dict {"flow": "return"|"break"|"continue", "value": ...}. Errors are
    reported through `self.error` and unwind by the same mechanism.
  * Numbers are always floats, `==` on them is exact (never approximate),
    and text formatting is defined character-for-character below. Anything
    fuzzier drifts between the two runtimes.

Two guards keep a bad policy file from taking a game down: a step budget
(a `while true {}` fails the tick instead of hanging the render thread) and
a call-depth limit (runaway recursion is an error, not a stack overflow).
"""

from __future__ import annotations

import math

from nova_lexer import NovaError, number_text

MAX_CALL_DEPTH = 128
MAX_STEPS = 500000

FLOW_RETURN = "return"
FLOW_BREAK = "break"
FLOW_CONTINUE = "continue"

# The builtin vocabulary. tools/check_parity.py asserts the GDScript
# evaluator implements exactly this set, with exactly these arities.
BUILTIN_ARITY = {
    # numeric
    "abs": 1, "min": 1, "max": 1, "clamp": 3, "exp": 1, "sqrt": 1,
    "floor": 1, "round": 1, "pow": 2, "ramp": 1, "lerp": 3,
    "pick": 1, "rand": 2, "held": 2,
    # types and conversion
    "type": 1, "str": 1, "num": 1, "bool": 1, "int": 1,
    # collections and strings
    "len": 1, "keys": 1, "has": 2, "get": 3, "append": 2, "remove_at": 2,
    "slice": 3, "range": 1, "join": 2, "split": 2, "contains": 2,
    "upper": 1, "lower": 1,
    # output
    "print": 0,
}


class NovaFunction:
    """A user-defined function plus the environment it closed over."""

    __slots__ = ("name", "params", "body", "closure")

    def __init__(self, name, params, body, closure):
        self.name = name
        self.params = params
        self.body = body
        self.closure = closure

    def __repr__(self):  # pragma: no cover
        return "<func %s>" % (self.name or "anonymous")


class Env:
    """One lexical scope. `parent` is None only for a module's global scope."""

    __slots__ = ("values", "parent")

    def __init__(self, parent=None):
        self.values = {}
        self.parent = parent

    def has(self, name: str) -> bool:
        env = self
        while env is not None:
            if name in env.values:
                return True
            env = env.parent
        return False

    def get(self, name: str):
        env = self
        while env is not None:
            if name in env.values:
                return env.values[name]
            env = env.parent
        return None

    def declare(self, name: str, value) -> None:
        """`let` -- always creates a binding in *this* scope."""
        self.values[name] = value

    def assign(self, name: str, value) -> bool:
        """`set` / bare `=` -- rebinds the nearest existing binding, or
        creates a global one if there is none. The fallback is what keeps
        v1 policies working, where rules `set` variables no one declared."""
        env = self
        while env is not None:
            if name in env.values:
                env.values[name] = value
                return True
            env = env.parent
        root = self
        while root.parent is not None:
            root = root.parent
        root.values[name] = value
        return False

    def root(self):
        env = self
        while env.parent is not None:
            env = env.parent
        return env


# ===========================================================================
# Value model -- identical rules on both sides
# ===========================================================================

def type_name(v) -> str:
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, (int, float)):
        return "number"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "list"
    if isinstance(v, dict):
        return "dict"
    if isinstance(v, NovaFunction):
        return "func"
    return "unknown"


def truthy(v) -> bool:
    if v is None:
        return False
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return v != 0.0
    if isinstance(v, str):
        return len(v) > 0
    if isinstance(v, (list, dict)):
        return len(v) > 0
    return True


def text(v) -> str:
    """Display form: what print() shows and what `+` concatenates."""
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return number_text(float(v))
    if isinstance(v, str):
        return v
    if isinstance(v, list):
        return "[" + ", ".join(inner_text(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join("%s: %s" % (k, inner_text(v[k])) for k in v) + "}"
    if isinstance(v, NovaFunction):
        return "<func %s>" % (v.name or "anonymous")
    return "<unknown>"


def inner_text(v) -> str:
    """Inside a list or dict, strings are quoted so nesting stays readable."""
    if isinstance(v, str):
        return '"' + v + '"'
    return text(v)


def deep_equal(a, b) -> bool:
    ta, tb = type_name(a), type_name(b)
    if ta != tb:
        return False
    if ta == "null":
        return True
    if ta == "number":
        return float(a) == float(b)          # exact, never approximate
    if ta in ("bool", "string"):
        return a == b
    if ta == "list":
        if len(a) != len(b):
            return False
        return all(deep_equal(a[i], b[i]) for i in range(len(a)))
    if ta == "dict":
        if len(a) != len(b):
            return False
        for k in a:
            if k not in b or not deep_equal(a[k], b[k]):
                return False
        return True
    return a is b


# ===========================================================================
# Evaluator
# ===========================================================================

class Evaluator:
    def __init__(self, rng, vm=None):
        self.rng = rng
        self.vm = vm                     # for `import`; may be None
        self.globals = Env()
        self.host_functions = {}         # name -> callable(args) -> value
        self.held_timers = []
        self.output = []                 # everything print() has emitted
        self.error = ""
        self.dt = 0.0
        self._steps = 0
        self._depth = 0

    # -- host integration ---------------------------------------------------

    def register_function(self, name: str, fn) -> None:
        """Expose a host function to NovaLang. Called as a plain function
        from .nova source; receives the evaluated argument list."""
        self.host_functions[name] = fn

    def fail(self, line: int, msg: str):
        if not self.error:
            self.error = "line %d: %s" % (line, msg) if line else msg
        return {"flow": FLOW_RETURN, "value": None}

    def _tick_budget(self, line: int) -> bool:
        self._steps += 1
        if self._steps > MAX_STEPS:
            self.fail(line, "step budget exhausted (%d) -- runaway loop?"
                      % MAX_STEPS)
            return False
        return True

    def begin_run(self) -> None:
        """Reset the per-entry guards. Called once per tick / per public
        call, not per statement."""
        self._steps = 0
        self._depth = 0
        self.error = ""

    # -- statements ---------------------------------------------------------

    def exec_block(self, stmts, env: Env):
        for stmt in stmts:
            signal = self.exec_stmt(stmt, env)
            if self.error:
                return {"flow": FLOW_RETURN, "value": None}
            if signal is not None:
                return signal
        return None

    def exec_stmt(self, node, env: Env):
        kind = node["k"]
        line = node.get("line", 0)
        if not self._tick_budget(line):
            return {"flow": FLOW_RETURN, "value": None}

        if kind == "exprstmt":
            self.eval(node["expr"], env)
            return None

        if kind == "let":
            value = self.eval(node["expr"], env)
            if isinstance(value, NovaFunction) and not value.name:
                value.name = node["name"]
            env.declare(node["name"], value)
            return None

        if kind == "assign":
            return self._assign(node, env)

        if kind == "block":
            return self.exec_block(node["body"], Env(env))

        if kind == "if":
            if truthy(self.eval(node["cond"], env)):
                return self.exec_block(node["then"]["body"], Env(env))
            if node["else"] is not None:
                return self.exec_block(node["else"]["body"], Env(env))
            return None

        if kind == "while":
            while True:
                if not self._tick_budget(line):
                    return {"flow": FLOW_RETURN, "value": None}
                if not truthy(self.eval(node["cond"], env)):
                    return None
                if self.error:
                    return {"flow": FLOW_RETURN, "value": None}
                signal = self.exec_block(node["body"]["body"], Env(env))
                if signal is None:
                    continue
                if signal["flow"] == FLOW_BREAK:
                    return None
                if signal["flow"] == FLOW_CONTINUE:
                    continue
                return signal

        if kind == "return":
            value = self.eval(node["expr"], env) if node["expr"] else None
            return {"flow": FLOW_RETURN, "value": value}

        if kind == "break":
            return {"flow": FLOW_BREAK, "value": None}

        if kind == "continue":
            return {"flow": FLOW_CONTINUE, "value": None}

        if kind == "import":
            return self._import(node, env)

        return self.fail(line, "cannot execute a %r statement" % kind)

    def _assign(self, node, env: Env):
        target = node["target"]
        value = self.eval(node["expr"], env)
        if self.error:
            return {"flow": FLOW_RETURN, "value": None}
        line = node.get("line", 0)

        if target["k"] == "var":
            env.assign(target["name"], value)
            return None

        if target["k"] == "index":
            obj = self.eval(target["obj"], env)
            idx = self.eval(target["idx"], env)
            return self._set_element(obj, idx, value, line)

        if target["k"] == "member":
            obj = self.eval(target["obj"], env)
            return self._set_element(obj, target["name"], value, line)

        return self.fail(line, "cannot assign to a %r" % target["k"])

    def _set_element(self, obj, key, value, line):
        if isinstance(obj, dict):
            obj[text(key) if not isinstance(key, str) else key] = value
            return None
        if isinstance(obj, list):
            if type_name(key) != "number":
                return self.fail(line, "list index must be a number")
            i = int(key)
            if i < 0:
                i += len(obj)
            if i < 0 or i >= len(obj):
                return self.fail(line, "list index %d out of range (size %d)"
                                 % (int(key), len(obj)))
            obj[i] = value
            return None
        return self.fail(line, "cannot assign into a %s" % type_name(obj))

    def _import(self, node, env: Env):
        line = node.get("line", 0)
        if self.vm is None:
            return self.fail(line, "import is not available here")
        exports = self.vm.load_module(node["path"])
        if self.vm.error:
            return self.fail(line, self.vm.error)
        if node["alias"]:
            env.declare(node["alias"], exports)
        else:
            for name in exports:
                env.declare(name, exports[name])
        return None

    # -- expressions --------------------------------------------------------

    def eval(self, node, env: Env):
        kind = node["k"]

        if kind == "num" or kind == "str" or kind == "bool":
            return node["v"]
        if kind == "null":
            return None

        if not self._tick_budget(node.get("line", 0)):
            return None

        if kind == "var":
            name = node["name"]
            if env.has(name):
                return env.get(name)
            self.fail(node.get("line", 0), "unknown identifier %r" % name)
            return None

        if kind == "list":
            return [self.eval(item, env) for item in node["items"]]

        if kind == "dict":
            out = {}
            for key_node, val_node in node["pairs"]:
                key = self.eval(key_node, env)
                out[key if isinstance(key, str) else text(key)] = \
                    self.eval(val_node, env)
            return out

        if kind == "func":
            return NovaFunction(node["name"], node["params"], node["body"], env)

        if kind == "unary":
            if node["op"] == "not":
                return not truthy(self.eval(node["a"], env))
            return -self._num(self.eval(node["a"], env), node.get("line", 0))

        if kind == "binary":
            return self._eval_binary(node, env)

        if kind == "call":
            return self._eval_call(node, env)

        if kind == "index":
            obj = self.eval(node["obj"], env)
            return self._get_element(obj, self.eval(node["idx"], env),
                                     node.get("line", 0))

        if kind == "member":
            obj = self.eval(node["obj"], env)
            return self._get_element(obj, node["name"], node.get("line", 0))

        self.fail(node.get("line", 0), "cannot evaluate a %r node" % kind)
        return None

    def _num(self, v, line: int) -> float:
        if isinstance(v, bool):
            return 1.0 if v else 0.0
        if isinstance(v, (int, float)):
            return float(v)
        self.fail(line, "expected a number, got %s" % type_name(v))
        return 0.0

    def _get_element(self, obj, key, line):
        if isinstance(obj, dict):
            k = key if isinstance(key, str) else text(key)
            if k not in obj:
                self.fail(line, "dict has no key %r" % k)
                return None
            return obj[k]
        if isinstance(obj, list):
            if type_name(key) != "number":
                self.fail(line, "list index must be a number")
                return None
            i = int(key)
            if i < 0:
                i += len(obj)
            if i < 0 or i >= len(obj):
                self.fail(line, "list index %d out of range (size %d)"
                          % (int(key), len(obj)))
                return None
            return obj[i]
        if isinstance(obj, str):
            if type_name(key) != "number":
                self.fail(line, "string index must be a number")
                return None
            i = int(key)
            if i < 0:
                i += len(obj)
            if i < 0 or i >= len(obj):
                self.fail(line, "string index %d out of range (length %d)"
                          % (int(key), len(obj)))
                return None
            return obj[i]
        self.fail(line, "cannot index a %s" % type_name(obj))
        return None

    def _eval_binary(self, node, env: Env):
        op = node["op"]
        line = node.get("line", 0)

        if op == "and":
            if not truthy(self.eval(node["a"], env)):
                return False
            return truthy(self.eval(node["b"], env))
        if op == "or":
            if truthy(self.eval(node["a"], env)):
                return True
            return truthy(self.eval(node["b"], env))

        a = self.eval(node["a"], env)
        b = self.eval(node["b"], env)
        if self.error:
            return None

        if op == "==":
            return deep_equal(a, b)
        if op == "!=":
            return not deep_equal(a, b)

        # `+` doubles as string concatenation and list concatenation.
        if op == "+":
            if isinstance(a, str) or isinstance(b, str):
                return text(a) + text(b)
            if isinstance(a, list) and isinstance(b, list):
                return a + b

        x = self._num(a, line)
        y = self._num(b, line)
        if op == "<":
            return x < y
        if op == ">":
            return x > y
        if op == "<=":
            return x <= y
        if op == ">=":
            return x >= y
        if op == "+":
            return x + y
        if op == "-":
            return x - y
        if op == "*":
            return x * y
        if op == "/":
            return x / y if y != 0.0 else 0.0
        if op == "%":
            return math.fmod(x, y) if y != 0.0 else 0.0
        self.fail(line, "unknown operator %r" % op)
        return None

    # -- calls --------------------------------------------------------------

    def _eval_call(self, node, env: Env):
        callee = node["callee"]
        line = node.get("line", 0)

        if callee["k"] == "var":
            # Resolution order for a bare name in call position: a user
            # function bound to it, then a builtin, then a host function.
            # A *non-callable* binding is skipped rather than being an
            # error, which is what lets the reactor policy have both a
            # `scram` variable (the trip latch) and a `scram()` host
            # function without either shadowing the other.
            name = callee["name"]
            bound = env.get(name) if env.has(name) else None
            if not isinstance(bound, NovaFunction):
                # held() is a special form: its condition must stay
                # unevaluated so the timer only advances on ticks where the
                # surrounding guard actually reached this call site.
                if name == "held":
                    return self._eval_held(node, env)
                if name in BUILTIN_ARITY:
                    args = self._eval_args(node["args"], env)
                    if self.error:
                        return None      # an argument failed; do not call
                    return self.call_builtin(name, args, line)
                if name in self.host_functions:
                    args = self._eval_args(node["args"], env)
                    if self.error:
                        return None
                    return self.host_functions[name](args)
                if bound is not None:
                    self.fail(line, "cannot call a %s" % type_name(bound))
                else:
                    self.fail(line, "unknown function %r" % name)
                return None

        fn = self.eval(callee, env)
        if self.error:
            return None
        if not isinstance(fn, NovaFunction):
            self.fail(line, "cannot call a %s" % type_name(fn))
            return None
        args = self._eval_args(node["args"], env)
        if self.error:
            return None
        return self.call_function(fn, args, line)

    def _eval_args(self, arg_nodes, env: Env):
        return [self.eval(a, env) for a in arg_nodes]

    def call_function(self, fn: NovaFunction, args, line: int = 0):
        if len(args) != len(fn.params):
            self.fail(line, "%s() takes %d argument(s), got %d"
                      % (fn.name or "anonymous", len(fn.params), len(args)))
            return None
        if self._depth >= MAX_CALL_DEPTH:
            self.fail(line, "call depth limit (%d) exceeded -- infinite "
                            "recursion?" % MAX_CALL_DEPTH)
            return None

        scope = Env(fn.closure)
        for i, param in enumerate(fn.params):
            scope.declare(param, args[i])

        self._depth += 1
        signal = self.exec_block(fn.body["body"], scope)
        self._depth -= 1

        if signal is not None and signal["flow"] == FLOW_RETURN:
            return signal["value"]
        return None

    def _eval_held(self, node, env: Env):
        line = node.get("line", 0)
        if len(node["args"]) != 2:
            self.fail(line, "held(cond, seconds) takes 2 argument(s), got %d"
                      % len(node["args"]))
            return False
        cond = truthy(self.eval(node["args"][0], env))
        secs = self._num(self.eval(node["args"][1], env), line)
        slot = node["slot"]
        if slot < 0 or slot >= len(self.held_timers):
            return False
        if cond:
            self.held_timers[slot] += self.dt
        else:
            self.held_timers[slot] = 0.0
        return self.held_timers[slot] >= secs

    # -- builtins -----------------------------------------------------------

    def call_builtin(self, name: str, args, line: int):
        need = BUILTIN_ARITY[name]
        if len(args) < need:
            self.fail(line, "%s() needs %d argument(s), got %d"
                      % (name, need, len(args)))
            return None

        if name == "print":
            self.output.append(" ".join(text(a) for a in args))
            return None

        if name == "abs":
            return abs(self._num(args[0], line))
        if name == "min":
            return min(self._num(a, line) for a in args)
        if name == "max":
            return max(self._num(a, line) for a in args)
        if name == "clamp":
            v, lo, hi = (self._num(a, line) for a in args[:3])
            return lo if v < lo else (hi if v > hi else v)
        if name == "exp":
            return math.exp(max(-700.0, min(700.0, self._num(args[0], line))))
        if name == "sqrt":
            return math.sqrt(max(0.0, self._num(args[0], line)))
        if name == "floor":
            return math.floor(self._num(args[0], line))
        if name == "round":
            v = self._num(args[0], line)
            return math.floor(v + 0.5) if v >= 0 else -math.floor(-v + 0.5)
        if name == "pow":
            base = self._num(args[0], line)
            expo = self._num(args[1], line)
            try:
                return float(base ** expo)
            except OverflowError:
                # GDScript's pow() saturates to infinity rather than
                # raising; match it so the two runtimes agree.
                return float("inf") if base > 0 else float("-inf")
            except ValueError:
                return float("nan")
        if name == "ramp":
            v = self._num(args[0], line)
            return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)
        if name == "lerp":
            a, b, t = (self._num(x, line) for x in args[:3])
            t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
            return a + (b - a) * t
        if name == "pick":
            return args[self.rng.randrange(len(args))]
        if name == "rand":
            return self.rng.uniform(self._num(args[0], line),
                                    self._num(args[1], line))

        if name == "type":
            return type_name(args[0])
        if name == "str":
            return text(args[0])
        if name == "num":
            v = args[0]
            if isinstance(v, str):
                try:
                    return float(v)
                except ValueError:
                    return 0.0
            return self._num(v, line)
        if name == "bool":
            return truthy(args[0])
        if name == "int":
            return float(int(self._num(args[0], line)))

        if name == "len":
            v = args[0]
            if isinstance(v, (list, dict, str)):
                return float(len(v))
            self.fail(line, "len() needs a list, dict or string")
            return 0.0
        if name == "keys":
            if not isinstance(args[0], dict):
                self.fail(line, "keys() needs a dict")
                return []
            return list(args[0].keys())
        if name == "has":
            container, key = args[0], args[1]
            if isinstance(container, dict):
                return (key if isinstance(key, str) else text(key)) in container
            if isinstance(container, list):
                return any(deep_equal(x, key) for x in container)
            self.fail(line, "has() needs a dict or list")
            return False
        if name == "get":
            container, key, fallback = args[0], args[1], args[2]
            if isinstance(container, dict):
                k = key if isinstance(key, str) else text(key)
                return container.get(k, fallback)
            self.fail(line, "get() needs a dict")
            return fallback
        if name == "append":
            if not isinstance(args[0], list):
                self.fail(line, "append() needs a list")
                return None
            args[0].append(args[1])
            return args[0]
        if name == "remove_at":
            if not isinstance(args[0], list):
                self.fail(line, "remove_at() needs a list")
                return None
            i = int(self._num(args[1], line))
            if i < 0 or i >= len(args[0]):
                self.fail(line, "remove_at() index %d out of range (size %d)"
                          % (i, len(args[0])))
                return None
            return args[0].pop(i)
        if name == "slice":
            seq = args[0]
            start = int(self._num(args[1], line))
            end = int(self._num(args[2], line))
            if isinstance(seq, (list, str)):
                return seq[max(0, start):max(0, end)]
            self.fail(line, "slice() needs a list or string")
            return None
        if name == "range":
            count = int(self._num(args[0], line))
            start = int(self._num(args[1], line)) if len(args) > 1 else 0
            if len(args) > 1:
                return [float(x) for x in range(count, start)]
            return [float(x) for x in range(count)]
        if name == "join":
            if not isinstance(args[0], list):
                self.fail(line, "join() needs a list")
                return ""
            sep = args[1] if isinstance(args[1], str) else text(args[1])
            return sep.join(text(x) for x in args[0])
        if name == "split":
            s = args[0] if isinstance(args[0], str) else text(args[0])
            sep = args[1] if isinstance(args[1], str) else text(args[1])
            if sep == "":
                return [ch for ch in s]
            return s.split(sep)
        if name == "contains":
            hay = args[0] if isinstance(args[0], str) else text(args[0])
            needle = args[1] if isinstance(args[1], str) else text(args[1])
            return needle in hay
        if name == "upper":
            return text(args[0]).upper()
        if name == "lower":
            return text(args[0]).lower()

        self.fail(line, "unknown builtin %r" % name)
        return None
