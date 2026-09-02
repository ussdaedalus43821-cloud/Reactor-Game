"""
Tests for the NovaLang reference implementation and the reactor it drives.

Run with:  python3 -m unittest discover -s reference/tests -t . -v

These test the *reference* (Python) implementation. The shipping GDScript
interpreter is held to the same behaviour by tools/gen_conformance.py,
which records the expected output of a corpus of programs from this
implementation, and parity_check.gd, which replays them in Godot.
"""

import json
import math
import os
import random
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import nova_evaluator as ev            # noqa: E402
import reactor_host as host            # noqa: E402
import reactor_physics as phys         # noqa: E402
from nova_lexer import NovaError, tokenize   # noqa: E402
from nova_parser import parse          # noqa: E402
from nova_vm import NovaVM             # noqa: E402


class Harness:
    """A VM plus the reactor host-function vocabulary, capturing everything
    the policy emits so tests can assert on it."""

    def __init__(self, source, seed=1, modules=None):
        self.events = []
        self.alarms = []
        self.calls = []
        self.modules = modules or {}
        self.vm = NovaVM(random.Random(seed),
                         module_reader=lambda p: self.modules.get(p))
        for name in host.HOST_FUNCTIONS:
            self.vm.register_function(name, self._make(name))
        self.ok = self.vm.eval(source)

    def _make(self, name):
        def fn(args):
            self.calls.append((name, list(args)))
            if name == "log":
                self.events.append(ev.text(args[0]) if args else "")
            elif name == "alarm":
                self.alarms.append((int(args[0]), ev.text(args[1])
                                    if len(args) > 1 else ""))
            elif name in ("scram", "meltdown", "victory"):
                self.events.append(ev.text(args[0]) if args else name.upper())
                if name == "scram":
                    self.vm.set_global("scram", True)
            return None
        return fn

    def tick(self, dt=0.05, faults=True, **inputs):
        self.events = []
        self.alarms = []
        self.calls = []
        ok = self.vm.tick(dt, inputs, faults)
        self.printed = self.vm.drain_output()
        return ok

    def g(self, name, fallback=None):
        return self.vm.get_global(name, fallback)


# ==========================================================================
# Lexer
# ==========================================================================

class TestLexer(unittest.TestCase):

    def kinds(self, src):
        return [(t.kind, t.value) for t in tokenize(src)][:-1]

    def test_numbers_strings_identifiers_and_operators(self):
        self.assertEqual(
            self.kinds('let x = 2.5e3 + "hi" != foo.bar[0]'),
            [("keyword", "let"), ("ident", "x"), ("op", "="),
             ("number", 2500.0), ("op", "+"), ("string", "hi"),
             ("op", "!="), ("ident", "foo"), ("op", "."), ("ident", "bar"),
             ("op", "["), ("number", 0.0), ("op", "]")])

    def test_both_comment_styles_are_stripped(self):
        self.assertEqual(self.kinds("1 # hash\n2 // slash\n3"),
                         [("number", 1.0), ("number", 2.0), ("number", 3.0)])

    def test_escape_sequences(self):
        self.assertEqual(tokenize(r'"a\nb\tc\"d\\e"')[0].value, 'a\nb\tc"d\\e')

    def test_two_char_operators_beat_one_char(self):
        self.assertEqual(self.kinds("a<=b>=c==d!=e"),
                         [("ident", "a"), ("op", "<="), ("ident", "b"),
                          ("op", ">="), ("ident", "c"), ("op", "=="),
                          ("ident", "d"), ("op", "!="), ("ident", "e")])

    def test_unterminated_string_reports_a_line(self):
        with self.assertRaises(NovaError) as ctx:
            tokenize('let a = 1\nlet b = "oops')
        self.assertIn("line 2", str(ctx.exception))

    def test_trailing_exponent_marker_is_not_swallowed(self):
        # "2e" is the number 2 followed by the identifier e, not an error.
        self.assertEqual(self.kinds("2e"), [("number", 2.0), ("ident", "e")])


# ==========================================================================
# Parser
# ==========================================================================

class TestParser(unittest.TestCase):

    def test_precedence_climbs_correctly(self):
        node = parse("let x = 1 + 2 * 3 < 4 and not false").statements[0]["expr"]
        self.assertEqual(node["k"], "binary")
        self.assertEqual(node["op"], "and")

    def test_named_function_desugars_to_a_let(self):
        stmt = parse("func f(a) { return a }").statements[0]
        self.assertEqual(stmt["k"], "let")
        self.assertEqual(stmt["name"], "f")
        self.assertEqual(stmt["expr"]["k"], "func")

    def test_brace_in_statement_position_is_a_block(self):
        stmt = parse("{ let a = 1 }").statements[0]
        self.assertEqual(stmt["k"], "block")

    def test_dict_and_list_literals(self):
        prog = parse('let d = { a: 1, "b": 2, [1+1]: 3 }  let l = [1, 2, 3,]')
        self.assertEqual(len(prog.statements[0]["expr"]["pairs"]), 3)
        self.assertEqual(len(prog.statements[1]["expr"]["items"]), 3)

    def test_postfix_chains(self):
        node = parse("let x = a.b[0](1).c").statements[0]["expr"]
        self.assertEqual(node["k"], "member")
        self.assertEqual(node["obj"]["k"], "call")

    def test_else_if_chains(self):
        stmt = parse("if a { } else if b { } else { }").statements[0]
        self.assertEqual(stmt["else"]["body"][0]["k"], "if")

    def test_the_shipped_policy_still_parses(self):
        with open(os.path.join(host.RULES_DIR, "reactor_rules.nova"),
                  encoding="utf-8") as fh:
            prog = parse(fh.read(), "reactor_rules.nova")
        self.assertEqual(prog.title, "CHERNOBYL-1")
        self.assertEqual(len(prog.rules), 25)
        self.assertEqual({f["name"] for f in prog.faults},
                         {"turbine_trip", "feedwater_failure", "rod_stuck",
                          "xenon_poisoning"})

    def test_syntax_errors_report_a_line(self):
        with self.assertRaises(NovaError) as ctx:
            parse('reactor "t"\nrule r { when true then set = 3 }')
        self.assertIn("line 2", str(ctx.exception))


# ==========================================================================
# Evaluator: the imperative core
# ==========================================================================

class TestLanguage(unittest.TestCase):

    def run_src(self, src, seed=1, modules=None):
        h = Harness(src, seed, modules)
        self.assertTrue(h.ok, h.vm.error)
        return h

    def out(self, src, **kw):
        return self.run_src(src, **kw).vm.drain_output()

    def test_arithmetic_and_precedence(self):
        self.assertEqual(self.out("print(2 + 3 * 4, (2 + 3) * 4, 7 % 4, -2 + 1)"),
                         ["14 20 3 -1"])

    def test_comparison_and_short_circuit(self):
        self.assertEqual(
            self.out('print(1 < 2 and not (3 > 4), false and boom(), true or boom())'),
            ["true false true"])   # boom() is never evaluated either time

    def test_recursion(self):
        self.assertEqual(
            self.out("func fib(n) { if n < 2 { return n } "
                     "return fib(n-1) + fib(n-2) }  print(fib(20))"),
            ["6765"])

    def test_closures_capture_their_defining_scope(self):
        self.assertEqual(
            self.out("func counter() { let n = 0  "
                     "return func() { n = n + 1  return n } }  "
                     "let a = counter()  let b = counter()  "
                     "a() a() print(a(), b())"),
            ["3 1"])

    def test_while_break_continue(self):
        self.assertEqual(
            self.out("let s = 0  let i = 0  "
                     "while true { i = i + 1  if i > 10 { break } "
                     "if i % 2 == 0 { continue }  s = s + i }  print(s, i)"),
            ["25 11"])

    def test_lists(self):
        self.assertEqual(
            self.out('let l = [3, 1, 2]  append(l, 9)  l[0] = 7  '
                     'print(l, len(l), l[-1], slice(l, 1, 3))'),
            ["[7, 1, 2, 9] 4 9 [1, 2]"])

    def test_dicts(self):
        self.assertEqual(
            self.out('let d = { a: 1 }  d.b = 2  d["c"] = 3  '
                     'print(d, len(d), d.a, has(d, "z"), get(d, "z", 0))'),
            ['{a: 1, b: 2, c: 3} 3 1 false 0'])

    def test_nested_structures_print_with_quoted_strings(self):
        self.assertEqual(self.out('print([1, "two", [true, null]], {k: "v"})'),
                         ['[1, "two", [true, null]] {k: "v"}'])

    def test_types_and_conversion(self):
        # Only user-defined functions are first-class values; builtins and
        # host functions exist in call position only.
        self.assertEqual(
            self.out('func f() { }  print(type(1), type("s"), type([]), '
                     'type({}), type(null), type(f))'),
            ["number string list dict null func"])
        self.assertEqual(self.out('print(num("2.5"), int(2.9), str(3), bool(""))'),
                         ["2.5 2 3 false"])

    def test_string_builtins(self):
        self.assertEqual(
            self.out('print(upper("ab"), split("a,b", ","), '
                     'join(["a","b"], "-"), contains("abc", "b"))'),
            ["AB [\"a\", \"b\"] a-b true"])

    def test_number_formatting_is_exact(self):
        self.assertEqual(self.out("print(1, 1.5, 1/3, -0.25, 1000000)"),
                         ["1 1.5 0.333333 -0.25 1000000"])

    def test_deep_equality(self):
        self.assertEqual(
            self.out('print([1,[2]] == [1,[2]], {a:1} == {a:1}, '
                     '[1] == [1,2], 1 == "1")'),
            ["true true false false"])

    def test_division_by_zero_is_survivable(self):
        self.assertEqual(self.out("print(1 / 0, 1 % 0)"), ["0 0"])

    def test_unknown_identifier_is_an_error(self):
        h = Harness("print(nope)")
        self.assertFalse(h.ok)
        self.assertIn("unknown identifier", h.vm.error)

    def test_builtin_arity_is_checked(self):
        h = Harness("print(clamp(1))")
        self.assertFalse(h.ok)
        self.assertIn("clamp() needs 3", h.vm.error)

    def test_user_function_arity_is_checked(self):
        h = Harness("func f(a, b) { return a }  f(1)")
        self.assertFalse(h.ok)
        self.assertIn("takes 2 argument", h.vm.error)

    def test_runaway_recursion_is_an_error_not_a_crash(self):
        h = Harness("func f(n) { return f(n + 1) }  f(0)")
        self.assertFalse(h.ok)
        self.assertIn("call depth", h.vm.error)

    def test_infinite_loop_hits_the_step_budget(self):
        h = Harness("while true { }")
        self.assertFalse(h.ok)
        self.assertIn("step budget", h.vm.error)

    def test_index_out_of_range_is_an_error(self):
        h = Harness("let l = [1]  print(l[5])")
        self.assertFalse(h.ok)
        self.assertIn("out of range", h.vm.error)

    def test_calling_a_non_function_is_an_error(self):
        h = Harness("let x = 1  x()")
        self.assertFalse(h.ok)
        self.assertIn("cannot call a number", h.vm.error)

    def test_a_non_callable_binding_does_not_hide_a_host_function(self):
        """The reactor policy has both a `scram` latch variable and a
        `scram()` host function; call position must find the function."""
        h = Harness('let scram = false  scram("TRIP")')
        self.assertTrue(h.ok, h.vm.error)
        self.assertIn(("scram", ["TRIP"]), h.calls)

    def test_host_functions_are_callable_from_nova(self):
        h = Harness('log("hello")  alarm(2, "warn")')
        self.assertTrue(h.ok, h.vm.error)
        self.assertEqual(h.events, ["hello"])
        self.assertEqual(h.alarms, [(2, "warn")])

    def test_register_function_takes_arbitrary_host_callbacks(self):
        vm = NovaVM(random.Random(0))
        vm.register_function("core_temp", lambda args: 812.5)
        vm.register_function("shout", lambda args: ev.text(args[0]).upper())
        self.assertTrue(vm.eval('print(core_temp() + 1, shout("ok"))'), vm.error)
        self.assertEqual(vm.drain_output(), ["813.5 OK"])

    def test_gdscript_can_call_nova_functions(self):
        vm = NovaVM(random.Random(0))
        self.assertTrue(vm.eval("func add(a, b) { return a + b }"), vm.error)
        self.assertEqual(vm.call_function("add", [2.0, 40.0]), 42.0)
        self.assertIsNone(vm.call_function("missing", []))
        self.assertIn("no such function", vm.error)


# ==========================================================================
# Modules
# ==========================================================================

class TestModules(unittest.TestCase):

    MODULES = {
        "lib/util.nova": (
            'export func double(x) { return x * 2 }\n'
            'export let VERSION = 3\n'
            'let hidden = 99\n'),
        "lib/chain.nova": (
            'import "lib/util.nova" as u\n'
            'export func quad(x) { return u.double(u.double(x)) }\n'),
        "lib/loop_a.nova": 'import "lib/loop_b.nova"\nexport let a = 1\n',
        "lib/loop_b.nova": 'import "lib/loop_a.nova"\nexport let b = 2\n',
    }

    def vm(self):
        return NovaVM(random.Random(0), module_reader=self.MODULES.get)

    def test_aliased_import(self):
        vm = self.vm()
        self.assertTrue(vm.eval('import "lib/util.nova" as u\n'
                                'print(u.double(21), u.VERSION)'), vm.error)
        self.assertEqual(vm.drain_output(), ["42 3"])

    def test_bare_import_merges_exports(self):
        vm = self.vm()
        self.assertTrue(vm.eval('import "lib/util.nova"\nprint(double(4))'),
                        vm.error)
        self.assertEqual(vm.drain_output(), ["8"])

    def test_unexported_names_stay_private(self):
        vm = self.vm()
        self.assertFalse(vm.eval('import "lib/util.nova"\nprint(hidden)'))
        self.assertIn("unknown identifier", vm.error)

    def test_modules_may_import_modules(self):
        vm = self.vm()
        self.assertTrue(vm.eval('import "lib/chain.nova" as c\nprint(c.quad(3))'),
                        vm.error)
        self.assertEqual(vm.drain_output(), ["12"])

    def test_a_module_is_evaluated_once_and_cached(self):
        seen = []

        def reader(path):
            seen.append(path)
            return self.MODULES.get(path)

        vm = NovaVM(random.Random(0), module_reader=reader)
        self.assertTrue(vm.eval('import "lib/util.nova" as a\n'
                                'import "lib/util.nova" as b\n'
                                'print(a.VERSION + b.VERSION)'), vm.error)
        self.assertEqual(seen.count("lib/util.nova"), 1)

    def test_circular_imports_are_reported(self):
        vm = self.vm()
        self.assertFalse(vm.eval('import "lib/loop_a.nova"'))
        self.assertIn("circular import", vm.error)

    def test_a_missing_module_is_reported(self):
        vm = self.vm()
        self.assertFalse(vm.eval('import "nope.nova"'))
        self.assertIn("cannot read module", vm.error)


# ==========================================================================
# The reactor DSL layer
# ==========================================================================

class TestReactorDSL(unittest.TestCase):

    def test_params_may_reference_earlier_params(self):
        h = Harness('reactor "t"\nparams { a = 2.0  b = a * 3.0 }\n'
                    'rule r { when true then set x = b }')
        h.tick(t=0.0)
        self.assertEqual(h.g("x"), 6.0)

    def test_effects_reset_each_tick_unless_persistent(self):
        h = Harness('reactor "t"\n'
                    'effects { a = 1.0  b = 1.0 persistent }\n'
                    'rule r once { when true then set a = 9.0 set b = 9.0 }')
        h.tick(t=0.0)
        self.assertEqual(h.g("a"), 9.0)
        h.tick(t=0.05)
        self.assertEqual(h.g("a"), 1.0)     # reset
        self.assertEqual(h.g("b"), 9.0)     # persisted

    def test_held_requires_continuous_truth(self):
        h = Harness('reactor "t"\n'
                    'rule r { when held(hot, 0.2) then log("TRIPPED") }')
        for _ in range(3):
            h.tick(dt=0.1, t=0.0, hot=True)
        self.assertEqual(h.events, ["TRIPPED"])
        h.tick(dt=0.1, t=0.0, hot=False)
        h.tick(dt=0.1, t=0.0, hot=True)
        self.assertEqual(h.events, [])

    def test_edge_rules_fire_once_per_rising_edge(self):
        h = Harness('reactor "t"\nrule r edge { when x > 0 then log("UP") }')
        h.tick(t=0.0, x=1.0)
        self.assertEqual(h.events, ["UP"])
        h.tick(t=0.0, x=1.0)
        self.assertEqual(h.events, [])
        h.tick(t=0.0, x=0.0)
        h.tick(t=0.0, x=1.0)
        self.assertEqual(h.events, ["UP"])

    def test_once_rules_never_fire_twice(self):
        h = Harness('reactor "t"\nrule r once { when true then log("HI") }')
        h.tick(t=0.0)
        self.assertEqual(h.events, ["HI"])
        h.tick(t=0.0)
        self.assertEqual(h.events, [])

    def test_priority_orders_rule_execution(self):
        h = Harness('reactor "t"\n'
                    'rule low priority 1 { when true then set x = "low" }\n'
                    'rule high priority 9 { when true then set x = "high" }')
        h.tick(t=0.0)
        self.assertEqual(h.g("x"), "low")   # highest priority runs first

    def test_rule_bodies_accept_full_statements(self):
        h = Harness('reactor "t"\n'
                    'rule r { when true then '
                    '  let total = 0 '
                    '  let i = 0 '
                    '  while i < 4 { total = total + i  i = i + 1 } '
                    '  if total > 3 { log("SUM " + total) } }')
        h.tick(t=0.0)
        self.assertEqual(h.events, ["SUM 6"])

    def test_string_concatenation(self):
        h = Harness('reactor "t"\nrule r { when true then log("BANK " + b) }')
        h.tick(t=0.0, b="A")
        self.assertEqual(h.events, ["BANK A"])

    def test_fault_activates_applies_effects_and_clears(self):
        h = Harness('reactor "t"\n'
                    'params { fault_first_min_s = 1.0  fault_first_max_s = 1.0\n'
                    '         fault_gap_min_s = 99.0  fault_gap_max_s = 99.0 }\n'
                    'effects { load_frac = 1.0 }\n'
                    'fault trip weight 1 duration 0.5 label "TRIP" {\n'
                    '    set load_frac = 0.0\n}')
        t = 0.0
        seen = []
        for _ in range(40):
            t += 0.1
            h.tick(dt=0.1, t=t)
            seen.extend(h.events)
            if abs(t - 1.2) < 1e-9:
                self.assertEqual(h.g("load_frac"), 0.0)
            if abs(t - 2.0) < 1e-9:
                self.assertEqual(h.g("load_frac"), 1.0)   # auto-restored
        self.assertIn("ALARM: TRIP", seen)
        self.assertIn("TRIP CLEARED", seen)

    def test_runtime_errors_in_a_rule_name_the_rule(self):
        h = Harness('reactor "t"\nrule bad { when true then set x = nope }')
        self.assertFalse(h.tick(t=0.0))
        self.assertIn("rule 'bad'", h.vm.error)


# ==========================================================================
# Physics
# ==========================================================================

class TestPhysics(unittest.TestCase):

    def test_rod_worth_is_monotonic_and_cubic(self):
        prev = -1e9
        for pct in range(0, 101):
            w = phys.bank_worth_pcm(pct)
            self.assertGreater(w, prev)
            prev = w
        bottom = phys.bank_worth_pcm(10.0) - phys.bank_worth_pcm(0.0)
        top = phys.bank_worth_pcm(100.0) - phys.bank_worth_pcm(90.0)
        self.assertGreater(top, 50.0 * bottom)

    def test_rods_in_means_shutdown(self):
        r = phys.ReactorPhysics()
        for _ in range(2000):
            r.step(0.05, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0)
        self.assertLess(r.flux_percent, 1e-3)
        self.assertLess(abs(r.fuel_temp - phys.T_COLD_C), 1.0)

    def test_reaches_a_stable_operating_point(self):
        r = phys.ReactorPhysics()
        for _ in range(8000):
            r.step(0.05, 72.0, 72.0, 1.0, 1.0, 0.0, 0.0)
        flux_a, temp_a = r.flux_percent, r.fuel_temp
        for _ in range(2000):
            r.step(0.05, 72.0, 72.0, 1.0, 1.0, 0.0, 0.0)
        self.assertLess(abs(r.flux_percent - flux_a), 0.5)
        self.assertLess(abs(r.fuel_temp - temp_a), 1.0)
        self.assertGreater(r.flux_percent, 50.0)
        self.assertLess(abs(r.reactivity_pcm), 20.0)

    def test_negative_temperature_feedback(self):
        self.assertLess(phys.doppler_reactivity_pcm(1000.0), 0.0)
        self.assertLess(phys.moderator_reactivity_pcm(1000.0), 0.0)

    def test_rk4_is_fourth_order(self):
        """Halving the step must cut the error by ~16x -- the check that the
        integrator really is RK4 and not a dressed-up Euler."""
        def run(dt, total=4.0):
            r = phys.ReactorPhysics()
            for _ in range(int(total / dt)):
                r.step(dt, 74.0, 74.0, 1.0, 1.0, 0.0, 0.0)
            return r.flux_percent

        ref = run(0.00125)
        e_coarse = abs(run(0.02) - ref)
        e_fine = abs(run(0.01) - ref)
        self.assertGreater(e_coarse, 0.0)
        self.assertGreater(e_coarse / max(e_fine, 1e-15), 8.0)

    def test_step_never_returns_nan_under_a_prompt_excursion(self):
        r = phys.ReactorPhysics()
        for _ in range(4000):
            r.step(0.05, 100.0, 100.0, 0.0, 0.0, 0.0, 0.0)
            self.assertFalse(math.isnan(r.flux_percent))
            self.assertFalse(math.isnan(r.fuel_temp))
        self.assertLessEqual(r.fuel_temp, phys.TEMP_CEILING_C)

    def test_rod_drive_is_rate_limited_and_stuck_rods_do_not_move(self):
        pos = phys.drive_rod(0.0, 100.0, 0.05, False)
        self.assertAlmostEqual(pos, phys.MAX_ROD_RATE_PCT_S * 0.05)
        self.assertEqual(phys.drive_rod(40.0, 100.0, 0.05, True), 40.0)
        self.assertAlmostEqual(phys.drive_rod(40.0, 40.2, 0.05, False), 40.2)

    def test_decay_heat_decays(self):
        self.assertAlmostEqual(phys.decay_heat_pct(100.0, 0.0, 7.0, 130.0), 7.0)
        self.assertAlmostEqual(phys.decay_heat_pct(100.0, 130.0, 7.0, 130.0),
                               7.0 / math.e, places=6)
        self.assertLess(phys.decay_heat_pct(100.0, 600.0, 7.0, 130.0), 0.07)


# ==========================================================================
# The reference reactor host
# ==========================================================================

class TestReactorHost(unittest.TestCase):

    def session(self, seed=5):
        return host.Session(host.DEFAULT_RULES, seed)

    def reply(self, sess, obj):
        return json.loads(sess.handle_line(json.dumps(obj)))

    def test_the_shipped_policy_loads_without_error(self):
        sim = host.ReactorHost(seed=1)
        self.assertEqual(sim.error, "")
        self.assertEqual(sim.vm.describe()["title"], "CHERNOBYL-1")

    def test_hello_advertises_the_contract(self):
        r = self.reply(self.session(), {"cmd": "hello"})
        self.assertTrue(r["ok"])
        self.assertEqual(r["proto"], host.PROTO_VERSION)
        self.assertEqual(r["dt"], phys.PHYSICS_DT)
        self.assertEqual(r["grid"], host.GRID_N)

    def test_tick_advances_time_and_returns_history(self):
        s = self.session()
        r = self.reply(s, {"cmd": "tick", "steps": 10, "rod_target_a": 50,
                           "rod_target_b": 50})
        self.assertAlmostEqual(r["t"], 10 * phys.PHYSICS_DT)
        self.assertEqual(len(r["history"]), 10)
        self.assertEqual(r["peak"]["n"], host.GRID_N)

    def test_malformed_frames_do_not_kill_the_session(self):
        s = self.session()
        self.assertFalse(json.loads(s.handle_line("{{{"))["ok"])
        self.assertFalse(json.loads(s.handle_line("[1,2,3]"))["ok"])
        self.assertFalse(self.reply(s, {"cmd": "nope"})["ok"])
        self.assertTrue(self.reply(s, {"cmd": "hello"})["ok"])
        self.assertIsNone(s.handle_line("   "))

    def test_steps_are_clamped(self):
        r = self.reply(self.session(), {"cmd": "tick", "steps": 100000})
        self.assertEqual(len(r["history"]), host.MAX_STEPS_PER_TICK)

    def test_operator_scram_latches_and_slams_the_rods_in(self):
        s = self.session()
        self.reply(s, {"cmd": "tick", "steps": 60, "rod_target_a": 70,
                       "rod_target_b": 70})
        r = self.reply(s, {"cmd": "tick", "steps": 1, "rod_target_a": 70,
                           "rod_target_b": 70, "scram": True})
        self.assertTrue(r["scram"])
        self.assertEqual(r["rod_a"], 0.0)
        self.assertEqual(r["state"], "SCRAM")
        self.assertIn("MANUAL SCRAM INITIATED", r["events"])
        r = self.reply(s, {"cmd": "tick", "steps": 20, "rod_target_a": 90,
                           "rod_target_b": 90})
        self.assertEqual(r["rod_target_a"], 0.0)

    def test_flux_high_trip_fires_on_a_runaway_pull(self):
        s = self.session()
        r = {}
        for _ in range(60):
            r = self.reply(s, {"cmd": "tick", "steps": 10,
                               "rod_target_a": 100, "rod_target_b": 100})
            if r["scram"]:
                break
        self.assertTrue(r["scram"], "yanking both banks out must auto-trip")

    def test_rod_drives_come_back_after_the_cooldown(self):
        s = self.session()
        self.reply(s, {"cmd": "tick", "steps": 40, "rod_target_a": 60,
                       "rod_target_b": 60})
        r = self.reply(s, {"cmd": "tick", "steps": 1, "scram": True})
        self.assertTrue(r["scram"])
        cooldown = int(600.0 / phys.PHYSICS_DT / host.MAX_STEPS_PER_TICK) + 2
        for _ in range(cooldown):
            r = self.reply(s, {"cmd": "tick", "steps": host.MAX_STEPS_PER_TICK,
                               "faults": False})
            if not r["scram"]:
                break
        self.assertFalse(r["scram"], "the trip should clear after cooldown")

    def test_same_seed_gives_the_same_run(self):
        def run(seed):
            s = self.session(seed)
            out = []
            for _ in range(120):
                out.extend(self.reply(s, {"cmd": "tick", "steps": 20,
                                          "rod_target_a": 60,
                                          "rod_target_b": 60})["events"])
            return out
        self.assertEqual(run(11), run(11))

    def test_reset_returns_the_plant_to_cold_shutdown(self):
        s = self.session()
        self.reply(s, {"cmd": "tick", "steps": 60, "rod_target_a": 80,
                       "rod_target_b": 80})
        r = self.reply(s, {"cmd": "reset", "seed": 1})
        self.assertEqual(r["t"], 0.0)
        self.assertEqual(r["rod_a"], 0.0)
        self.assertFalse(r["scram"])
        self.assertAlmostEqual(r["fuel_temp_c"], phys.T_COLD_C)

    def test_quit_stops_the_session(self):
        s = self.session()
        self.assertTrue(self.reply(s, {"cmd": "quit"})["bye"])
        self.assertFalse(s.alive)

    def test_selftest_entry_point_runs(self):
        result = host.selftest(seconds=20.0, seed=3)
        self.assertTrue(result["ok"])
        self.assertGreater(result["realtime_factor"], 1.0)

    def test_validate_reports_the_policy(self):
        d = host.validate(host.DEFAULT_RULES)
        self.assertTrue(d["ok"])
        self.assertIn("operator_scram", d["rules"])

    def test_the_daedalus_policy_loads_too(self):
        sim = host.ReactorHost("daedalus_rules.nova", seed=2)
        self.assertEqual(sim.error, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
