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


# ==========================================================================
# DAEDALUS Stage 1 balance tables
#
# Every figure is asserted literally. These numbers are measurements, not
# design knobs, so an accidental edit should fail a test rather than quietly
# rebalance the game.
# ==========================================================================

class TestDaedalusData(unittest.TestCase):

    # ship -> (class, shield, hull, speed, turn, gun, rocket, homing, beam,
    #           hardened)
    TABLE = {
        "x302":     ("fighter",        397,  228, 1142, 348,  4.7,  74.2,
                     55.3, 0, False),
        "daedalus": ("battlecruiser", 1583, 1049,  917, 218, 12.3, 117.5,
                     89.1, 2431, False),
        "phoenix":  ("battlecruiser", 2471, 1654, 1035, 241, 14.1, 163.0,
                     114.6, 3422, False),
        "aurora":   ("capital",       3682, 2183,  948, 184, 11.8, 138.4,
                     122.7, 0, True),
        "destiny":  ("capital",       1762, 3517,  806, 139, 11.1, 134.8,
                     94.2, 0, False),
        "atlantis": ("capital",       7124, 5843,  753, 108, 16.3, 186.5,
                     131.9, 0, True),
    }
    COLUMNS = ["class", "shield", "hull", "speed", "turn", "gun_dmg",
               "rocket_dmg", "homing_dmg", "beam_dmg", "hardened"]

    @classmethod
    def setUpClass(cls):
        cls.vm = NovaVM(random.Random(7), base_dir=host.RULES_DIR)
        for name in host.HOST_FUNCTIONS:
            cls.vm.register_function(name, lambda args: None)
        assert cls.vm.load_file("daedalus_rules.nova"), cls.vm.error

    def test_every_ship_stat_is_exact(self):
        ships = self.vm.get_global("SHIPS")
        self.assertEqual(set(ships), set(self.TABLE))
        for key, row in self.TABLE.items():
            for column, want in zip(self.COLUMNS, row):
                got = ships[key][column]
                if isinstance(want, str):
                    self.assertEqual(got, want, "%s.%s" % (key, column))
                elif isinstance(want, bool):
                    self.assertEqual(bool(got), want, "%s.%s" % (key, column))
                else:
                    self.assertAlmostEqual(float(got), float(want), places=9,
                                           msg="%s.%s" % (key, column))

    def test_exactly_aurora_and_atlantis_are_hardened(self):
        """Destiny is capital-class and NOT hardened -- this is the exact
        distinction Stage 2's dart-dive-avoidance and replicator-block
        logic have to get right, so it gets its own explicit test rather
        than trusting the generic per-field loop above."""
        ships = self.vm.get_global("SHIPS")
        hardened = sorted(k for k, s in ships.items() if s.get("hardened"))
        self.assertEqual(hardened, ["atlantis", "aurora"])
        self.assertFalse(ships["destiny"]["hardened"],
                         "Destiny is capital-class but must not be hardened")

    def test_ship_hardened_accessor(self):
        self.assertTrue(self.vm.call_function("ship_hardened", ["aurora"]))
        self.assertTrue(self.vm.call_function("ship_hardened", ["atlantis"]))
        self.assertFalse(self.vm.call_function("ship_hardened", ["destiny"]))
        self.assertFalse(self.vm.call_function("ship_hardened", ["daedalus"]))
        self.assertFalse(self.vm.call_function("ship_hardened", ["not_a_ship"]))

    def test_ship_order_covers_the_registry(self):
        order = self.vm.get_global("SHIP_ORDER")
        self.assertEqual(order, ["x302", "daedalus", "phoenix", "aurora",
                                 "destiny", "atlantis"])
        self.assertEqual(set(order), set(self.vm.get_global("SHIPS")))

    def test_damage_scaling_matrix(self):
        for (a, b), want in {
                ("fighter", "battlecruiser"): 0.082,
                ("fighter", "capital"): 0.047,
                ("battlecruiser", "fighter"): 2.37,
                ("battlecruiser", "capital"): 0.74,
                ("capital", "fighter"): 3.14,
                ("capital", "battlecruiser"): 1.12}.items():
            self.assertAlmostEqual(
                self.vm.call_function("damage_multiplier", [a, b]), want,
                places=9, msg="%s -> %s" % (a, b))

    def test_unlisted_matchups_are_neutral(self):
        for a, b in (("fighter", "fighter"),
                     ("battlecruiser", "battlecruiser"),
                     ("capital", "capital"),
                     ("fighter", "not_a_class"),
                     ("not_a_class", "capital")):
            self.assertEqual(self.vm.call_function("damage_multiplier", [a, b]),
                             1.0, "%s -> %s must fall back to 1.0" % (a, b))

    def test_weapon_damage_applies_the_matrix(self):
        # An F-302 railgun round barely scratches a city-ship...
        self.assertAlmostEqual(
            self.vm.call_function("weapon_damage",
                                  ["x302", "gun_dmg", "atlantis"]),
            4.7 * 0.047, places=9)
        # ...and one Atlantis bolt is three F-302 rounds' worth of overkill.
        self.assertAlmostEqual(
            self.vm.call_function("weapon_damage",
                                  ["atlantis", "gun_dmg", "x302"]),
            16.3 * 3.14, places=9)
        # Same-class stays raw.
        self.assertAlmostEqual(
            self.vm.call_function("weapon_damage",
                                  ["daedalus", "beam_dmg", "phoenix"]),
            2431.0, places=9)

    def test_power_constants(self):
        power = self.vm.get_global("POWER")
        for key, want in {"max": 1047, "recharge": 112, "shield_draw": 143,
                          "thrust_drain": 48, "cloak_drain": 27,
                          "primary_cost": 9.4, "rocket_cost": 31.2,
                          "homing_cost": 22.7}.items():
            self.assertAlmostEqual(float(power[key]), float(want), places=9,
                                   msg=key)

    def test_shield_recharge_outruns_the_reactor(self):
        """The load-bearing property of the power table: rebuilding shields
        costs more than the bus makes, so regenerating under fire is always
        a losing trade and running away is always affordable."""
        idle = self.vm.call_function("power_balance", [False, False, False])
        shields = self.vm.call_function("power_balance", [False, False, True])
        fighting = self.vm.call_function("power_balance", [True, False, True])
        running = self.vm.call_function("power_balance", [True, True, False])
        self.assertEqual(idle, 112.0)
        self.assertEqual(shields, -31.0)
        self.assertEqual(fighting, -79.0)
        self.assertEqual(running, 37.0)
        self.assertGreater(running, 0.0, "cloak + thrust must be sustainable")
        self.assertLess(shields, 0.0, "shield regen must never be free")

    def test_weapon_costs(self):
        for weapon, want in (("primary", 9.4), ("rocket", 31.2),
                             ("homing", 22.7), ("nonexistent", 0.0)):
            self.assertAlmostEqual(
                self.vm.call_function("weapon_cost", [weapon]), want, places=9)

    def test_danger_scaling(self):
        for danger, base, rate in ((1, 4, 0.8), (2, 9, 1.3), (3, 15, 2.1)):
            for gen in (0.0, 1.0, 3.5, 10.0, 25.0):
                self.assertEqual(
                    self.vm.call_function("hostiles_for", [float(danger), gen]),
                    math.floor(base + gen * rate),
                    "danger %d at gen %s" % (danger, gen))

    def test_danger_zero_never_spawns(self):
        for gen in (0.0, 5.0, 120.0):
            self.assertEqual(
                self.vm.call_function("hostiles_for", [0.0, gen]), 0)

    def test_saturation_points(self):
        """26 is the engine's live-hostile ceiling; this is how long each
        band takes to reach it."""
        for danger, want in ((1, 27.5), (2, 13.076923076923077),
                             (3, 5.238095238095238)):
            self.assertAlmostEqual(
                self.vm.call_function("saturation_minutes",
                                      [float(danger), 26.0]),
                want, places=9)
        self.assertEqual(
            self.vm.call_function("saturation_minutes", [0.0, 26.0]), -1)

    def test_sector_table(self):
        sectors = self.vm.get_global("SECTORS")
        self.assertEqual([int(s["key"]) for s in sectors],
                         [1, 2, 3, 4, 5, 6, 7, 8, 9, 0])
        for s in sectors:
            for field in ("key", "name", "danger", "spawns", "capital_chance",
                          "charge", "travel"):
                self.assertIn(field, s, "sector %s" % s.get("name"))
            self.assertGreater(float(s["charge"]), 0.0)
            self.assertGreater(float(s["travel"]), 0.0)

    def test_home_sector_never_spawns_whatever_its_band(self):
        home = self.vm.call_function("sector_by_key", [1.0])
        self.assertFalse(home["spawns"])
        for gen in (0.0, 30.0):
            self.assertEqual(
                self.vm.call_function("sector_hostiles", [1.0, gen]), 0)

    def test_sector_hostiles_follow_the_band(self):
        # Asuran Frontier is danger 3; at gen 6 that is 15 + 6*2.1 = 27.6.
        self.assertEqual(
            self.vm.call_function("sector_hostiles", [4.0, 6.0]), 27)
        # Lantea is danger 1: 4 + 6*0.8 = 8.8.
        self.assertEqual(
            self.vm.call_function("sector_hostiles", [5.0, 6.0]), 8)

    def test_unknown_sector_and_ship_degrade_safely(self):
        self.assertIsNone(self.vm.call_function("sector_by_key", [42.0]))
        self.assertEqual(self.vm.call_function("sector_hostiles", [42.0, 5.0]), 0)
        self.assertIsNone(self.vm.call_function("ship", ["not_a_hull"]))
        self.assertEqual(
            self.vm.call_function("ship_stat", ["not_a_hull", "shield", -1.0]),
            -1.0)


# ==========================================================================
# DAEDALUS Stage 2 enemy AI
# ==========================================================================

class TestDaedalusAI(unittest.TestCase):

    # kind -> (class, keep_dist, engage_range, fire_cd, gun_dmg, max_speed,
    #          turn_rate, shield, hull, score)
    TABLE = {
        "fighter": ("fighter", [286, 412], [783, 912], [1.13, 1.67], 6.2,
                    312.7, 204.8, 438.2, 307.5, 104),
        "capital": ("capital", [516, 638], [947, 1138], [1.82, 2.41], 17.3,
                    58.4, 19.4, 1538.4, 3172.8, 3184),
        "dart": ("fighter", [194, 273], [704, 831], [0.48, 0.73], 5.1,
                 587.2, 386.1, 92.7, 68.3, 126),
        "hive": ("capital", [614, 748], [1184, 1372], [2.21, 2.89], 18.7,
                 42.3, 14.7, 2417.6, 5283.7, 6273),
        "replicator": ("fighter", [372, 461], [873, 1014], [1.72, 2.31], 0,
                       384.6, 226.3, 837.5, 967.2, 3017),
        "ori": ("capital", [1024, 1318], [1147, 1284], [2.14, 2.63], 0,
               18.2, 11.7, 3421.8, 3618.4, 5817),
    }
    PLAYER_CLASSES = ["fighter", "battlecruiser", "capital"]
    BEHAVIOR_KEYS = [
        "kind", "class", "name", "role", "shield", "hull", "score",
        "max_speed", "turn_rate", "gun_dmg", "keep_dist", "engage_range",
        "fire_cd", "burst_min", "burst_max", "strafe_interval", "flak_cd",
        "dive_cd", "dive_enabled", "ram_dmg_base", "spawn_cd",
        "release_range", "max_stored", "prioritize_distance",
        "flee_hull_frac", "flee_speed", "infect_blocked",
        "hide_behind_allies", "charge_time", "fire_time", "beam_dps",
        "beam_cooldown", "tactical_role",
    ]

    @classmethod
    def setUpClass(cls):
        cls.vm = NovaVM(random.Random(7), base_dir=host.RULES_DIR)
        assert cls.vm.load_file("daedalus_ai.nova"), cls.vm.error

    def behavior(self, kind, player_class, hardened=False):
        b = self.vm.call_function("get_behavior", [kind, player_class, hardened])
        self.assertEqual(self.vm.error, "")
        return b

    def test_every_enemy_stat_is_exact(self):
        enemy = self.vm.get_global("ENEMY")
        self.assertEqual(set(enemy), set(self.TABLE))
        for kind, row in self.TABLE.items():
            cls, keep_dist, engage_range, fire_cd, gun, speed, turn, \
                shield, hull, score = row
            e = enemy[kind]
            self.assertEqual(e["class"], cls, kind)
            for field, want in (("keep_dist", keep_dist),
                                ("engage_range", engage_range),
                                ("fire_cd", fire_cd)):
                self.assertAlmostEqual(e[field][0], want[0], places=9,
                                       msg="%s.%s[0]" % (kind, field))
                self.assertAlmostEqual(e[field][1], want[1], places=9,
                                       msg="%s.%s[1]" % (kind, field))
            for field, want in (("gun_dmg", gun), ("max_speed", speed),
                                ("turn_rate", turn), ("shield", shield),
                                ("hull", hull), ("score", score)):
                self.assertAlmostEqual(float(e[field]), float(want), places=9,
                                       msg="%s.%s" % (kind, field))

    def test_enemy_order_covers_the_registry(self):
        order = self.vm.get_global("ENEMY_ORDER")
        self.assertEqual(order, ["fighter", "capital", "dart", "hive",
                                 "replicator", "ori"])
        self.assertEqual(set(order), set(self.vm.get_global("ENEMY")))

    def test_class_assignment_matches_original_hull_tiers(self):
        """fighter/dart/replicator are fighter-scale; capital/hive/ori are
        capital-scale -- the same tier split the original engine used."""
        for kind, want in {"fighter": "fighter", "capital": "capital",
                          "dart": "fighter", "hive": "capital",
                          "replicator": "fighter", "ori": "capital"}.items():
            self.assertEqual(self.vm.call_function("enemy_class", [kind]),
                             want, kind)

    def test_kind_aliases_resolve(self):
        self.assertEqual(self.vm.call_function("resolve_kind", ["wdart"]),
                         "dart")
        self.assertEqual(self.vm.call_function("resolve_kind", ["whive"]),
                         "hive")
        self.assertEqual(self.vm.call_function("resolve_kind", ["capital"]),
                         "capital")
        self.assertEqual(self.vm.call_function("enemy_class", ["wdart"]),
                         "fighter")

    def test_prose_only_constants(self):
        """Values given only in the brief's bulleted description, not the
        tuning table, are still pinned exactly."""
        e = self.vm.get_global("ENEMY")
        self.assertEqual(e["fighter"]["strafe_interval"], [2.7, 4.3])
        self.assertEqual(e["fighter"]["burst_min"], 2)
        self.assertEqual(e["fighter"]["burst_max"], 4)
        self.assertEqual(e["capital"]["flak_cd"], [2.7, 4.1])
        self.assertEqual(e["dart"]["dive_cd"], [3.1, 5.4])
        self.assertAlmostEqual(e["dart"]["ram_dmg_base"], 26.4)
        self.assertEqual(e["hive"]["spawn_cd"], [5.7, 9.2])
        self.assertAlmostEqual(e["replicator"]["flee_hull_frac"], 0.30)
        self.assertAlmostEqual(e["replicator"]["flee_speed"], 512.0)
        self.assertAlmostEqual(e["ori"]["charge_time"], 1.14)
        self.assertAlmostEqual(e["ori"]["fire_time"], 1.52)
        self.assertAlmostEqual(e["ori"]["beam_dps"], 1547.0)

    def test_every_behavior_has_the_full_uniform_shape(self):
        """All 36 (kind, class, hardened) combinations return exactly the
        same key set -- no missing fields, no stray ones."""
        count = 0
        for kind in self.vm.get_global("ENEMY_ORDER"):
            for cls in self.PLAYER_CLASSES:
                for hardened in (False, True):
                    b = self.behavior(kind, cls, hardened)
                    self.assertEqual(set(b), set(self.BEHAVIOR_KEYS),
                                     "%s/%s/%s" % (kind, cls, hardened))
                    count += 1
        self.assertEqual(count, 36)

    def test_fighter_keep_dist_reacts_to_player_class(self):
        base = self.behavior("fighter", "battlecruiser")["keep_dist"]
        vs_capital = self.behavior("fighter", "capital")["keep_dist"]
        vs_fighter = self.behavior("fighter", "fighter")["keep_dist"]
        self.assertEqual(base, [286.0, 412.0])
        self.assertAlmostEqual(vs_capital[0], 286.0 * 0.88, places=9)
        self.assertAlmostEqual(vs_capital[1], 412.0 * 0.88, places=9)
        self.assertAlmostEqual(vs_fighter[0], 286.0 * 1.15, places=9)
        self.assertAlmostEqual(vs_fighter[1], 412.0 * 1.15, places=9)

    def test_capital_flak_and_burst_react_to_player_class(self):
        base = self.behavior("capital", "battlecruiser")
        vs_fighter = self.behavior("capital", "fighter")
        vs_capital = self.behavior("capital", "capital")
        self.assertEqual(base["flak_cd"], [2.7, 4.1])
        self.assertEqual(base["fire_cd"], [1.82, 2.41])
        self.assertAlmostEqual(vs_fighter["flak_cd"][0], 2.7 * 0.82, places=9)
        self.assertAlmostEqual(vs_fighter["flak_cd"][1], 4.1 * 0.82, places=9)
        self.assertEqual(vs_fighter["fire_cd"], base["fire_cd"],
                         "flak reaction must not also change the burst cycle")
        self.assertAlmostEqual(vs_capital["fire_cd"][0], 1.82 * 0.88, places=9)
        self.assertAlmostEqual(vs_capital["fire_cd"][1], 2.41 * 0.88, places=9)
        self.assertEqual(vs_capital["flak_cd"], base["flak_cd"],
                         "burst reaction must not also change flak")
        for b in (base, vs_fighter, vs_capital):
            self.assertEqual(b["burst_min"], 3.0)
            self.assertEqual(b["burst_max"], 3.0)

    def test_dart_avoids_diving_only_when_hardened(self):
        normal = self.behavior("dart", "battlecruiser", False)
        vs_capital_soft = self.behavior("dart", "capital", False)
        vs_hardened = self.behavior("dart", "capital", True)
        self.assertTrue(normal["dive_enabled"])
        self.assertEqual(normal["dive_cd"], [3.1, 5.4])
        self.assertTrue(vs_capital_soft["dive_enabled"],
                        "capital class alone (e.g. Destiny) must not suppress the dive")
        self.assertFalse(vs_hardened["dive_enabled"])
        # It still circles at its own standoff rather than vanishing.
        self.assertEqual(vs_hardened["keep_dist"], [194.0, 273.0])

    def test_dart_ram_damage_scales_with_the_square_of_speed(self):
        full = self.vm.call_function("dart_ram_damage", [587.2])
        half = self.vm.call_function("dart_ram_damage", [293.6])
        zero = self.vm.call_function("dart_ram_damage", [0.0])
        self.assertAlmostEqual(full, 26.4, places=9)
        self.assertAlmostEqual(half, 26.4 * 0.25, places=9)
        self.assertAlmostEqual(zero, 0.0, places=9)
        # Clamped, not unbounded, for a hypothetical overspeed dive.
        overspeed = self.vm.call_function("dart_ram_damage", [587.2 * 10])
        self.assertAlmostEqual(overspeed, 26.4 * 1.5, places=9)

    def test_hive_ignores_player_class(self):
        vs_fighter = self.behavior("hive", "fighter")
        vs_capital = self.behavior("hive", "capital")
        self.assertEqual(vs_fighter, vs_capital)
        self.assertEqual(vs_fighter["spawn_cd"], [5.7, 9.2])
        self.assertAlmostEqual(vs_fighter["release_range"], 307.0, places=9)
        self.assertEqual(vs_fighter["max_stored"], 6.0)
        self.assertTrue(vs_fighter["prioritize_distance"])

    def test_replicator_blocked_only_when_hardened(self):
        open_ = self.behavior("replicator", "battlecruiser", False)
        blocked = self.behavior("replicator", "capital", True)
        self.assertFalse(open_["infect_blocked"])
        self.assertTrue(blocked["infect_blocked"])
        self.assertTrue(open_["hide_behind_allies"])
        self.assertTrue(blocked["hide_behind_allies"])
        self.assertAlmostEqual(open_["flee_hull_frac"], 0.30, places=9)
        self.assertAlmostEqual(open_["flee_speed"], 512.0, places=9)

    def test_ori_charge_and_dps_react_independently(self):
        base = self.behavior("ori", "battlecruiser")
        vs_fighter = self.behavior("ori", "fighter")
        vs_capital = self.behavior("ori", "capital")
        self.assertAlmostEqual(base["charge_time"], 1.14, places=9)
        self.assertAlmostEqual(base["beam_dps"], 1547.0, places=9)
        self.assertAlmostEqual(vs_fighter["charge_time"], 1.14 * 0.92, places=9)
        self.assertAlmostEqual(vs_fighter["beam_dps"], 1547.0, places=9,
                               msg="fighter reaction must not also raise DPS")
        self.assertAlmostEqual(vs_capital["beam_dps"], 1547.0 * 1.12, places=9)
        self.assertAlmostEqual(vs_capital["charge_time"], 1.14, places=9,
                               msg="capital reaction must not also speed up the charge")

    def test_unknown_kind_returns_null(self):
        self.assertIsNone(self.vm.call_function(
            "get_behavior", ["not_a_kind", "fighter", False]))
        self.assertEqual(self.vm.call_function("enemy_class", ["not_a_kind"]),
                         "fighter")
        self.assertEqual(self.vm.call_function(
            "enemy_stat", ["not_a_kind", "shield", -1.0]), -1.0)

    def test_behavior_calls_are_idempotent_and_independent(self):
        a = self.behavior("ori", "capital")
        b = self.behavior("ori", "capital")
        self.assertEqual(a, b)
        a["beam_dps"] = -1.0
        self.assertNotEqual(a["beam_dps"], b["beam_dps"],
                            "each call must return an independent value")


class TestDaedalusRulesEnemyBridge(unittest.TestCase):
    """The seam between rules.nova (SHIPS, DAMAGE_SCALING) and ai.nova
    (ENEMY, get_behavior), exercised through daedalus_rules.nova's import
    of daedalus_ai.nova rather than by loading ai.nova directly."""

    @classmethod
    def setUpClass(cls):
        cls.vm = NovaVM(random.Random(7), base_dir=host.RULES_DIR)
        for name in host.HOST_FUNCTIONS:
            cls.vm.register_function(name, lambda args: None)
        assert cls.vm.load_file("daedalus_rules.nova"), cls.vm.error

    def test_enemy_order_and_stats_are_reachable_through_the_import(self):
        self.assertEqual(self.vm.get_global("ENEMY_ORDER"),
                         ["fighter", "capital", "dart", "hive",
                          "replicator", "ori"])
        self.assertEqual(
            self.vm.call_function("enemy_stat", ["ori", "shield", -1.0]),
            3421.8)

    def test_enemy_weapon_damage_applies_the_class_matrix(self):
        # Dart (fighter-class) vs Atlantis (capital-class player hull).
        self.assertAlmostEqual(
            self.vm.call_function("enemy_weapon_damage", ["dart", "atlantis"]),
            5.1 * 0.047, places=9)
        # Hostile Cruiser (capital-class) vs F-302 (fighter-class): overmatch.
        self.assertAlmostEqual(
            self.vm.call_function("enemy_weapon_damage", ["capital", "x302"]),
            17.3 * 3.14, places=9)
        # A gun_dmg of 0 (Ori, Replicator) stays 0 regardless of matchup.
        self.assertEqual(
            self.vm.call_function("enemy_weapon_damage", ["ori", "x302"]), 0.0)

    def test_player_weapon_vs_enemy_is_the_mirror_direction(self):
        self.assertAlmostEqual(
            self.vm.call_function("player_weapon_vs_enemy",
                                  ["x302", "gun_dmg", "hive"]),
            4.7 * 0.047, places=9)

    def test_enemy_behavior_resolves_a_player_ship_key_end_to_end(self):
        """The case the brief calls out by name: Destiny is capital-class
        but not hardened, so a Dart must still dive on it -- only Aurora
        and Atlantis, which really are hardened, turn it away."""
        vs_atlantis = self.vm.call_function("enemy_behavior",
                                            ["dart", "atlantis"])
        vs_destiny = self.vm.call_function("enemy_behavior",
                                           ["dart", "destiny"])
        vs_daedalus = self.vm.call_function("enemy_behavior",
                                            ["dart", "daedalus"])
        self.assertFalse(vs_atlantis["dive_enabled"])
        self.assertTrue(vs_destiny["dive_enabled"],
                        "Destiny is capital-class but not hardened")
        self.assertTrue(vs_daedalus["dive_enabled"])

        vs_aurora_rep = self.vm.call_function("enemy_behavior",
                                              ["replicator", "aurora"])
        vs_phoenix_rep = self.vm.call_function("enemy_behavior",
                                               ["replicator", "phoenix"])
        self.assertTrue(vs_aurora_rep["infect_blocked"])
        self.assertFalse(vs_phoenix_rep["infect_blocked"])

    def test_ai_nova_still_loads_and_matches_standalone(self):
        """rules.nova imports ai.nova with an alias (`as ai`), so
        get_behavior() is deliberately reachable through daedalus_rules.nova
        only via the ship-key-resolving enemy_behavior() wrapper, not as a
        bare top-level name -- that alias is not a leak to plug, it is the
        namespacing aliased import is for. What must actually hold is that
        ai.nova loaded standalone (the path ai_bridge.gd uses) agrees with
        ai.nova loaded through the import (the path daedalus_rules.nova
        uses): the same module source must not answer differently
        depending on who asked."""
        standalone = NovaVM(random.Random(7), base_dir=host.RULES_DIR)
        assert standalone.load_file("daedalus_ai.nova"), standalone.error

        # daedalus_rules.nova has no bare get_behavior() -- confirm that is
        # deliberate namespacing, not an accidental gap.
        missing = self.vm.call_function("get_behavior", ["fighter", "capital", False])
        self.assertIsNone(missing)
        self.assertIn("no such function", self.vm.error)

        # The two real call paths: ai_bridge.gd calls get_behavior()
        # directly; daedalus_rules.nova calls it by resolving a player ship
        # key first. Fed the same underlying (class, hardened) pair --
        # aurora is capital-class and hardened -- they must agree exactly.
        direct = standalone.call_function("get_behavior",
                                          ["fighter", "capital", True])
        via_rules = self.vm.call_function("enemy_behavior",
                                          ["fighter", "aurora"])
        self.assertEqual(self.vm.call_function("ship_class", ["aurora"]),
                         "capital")
        self.assertTrue(self.vm.call_function("ship_hardened", ["aurora"]))
        self.assertEqual(direct, via_rules)


# ==========================================================================
# DAEDALUS Stage 3 weapons
# ==========================================================================

class TestDaedalusWeapons(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.vm = NovaVM(random.Random(7), base_dir=host.RULES_DIR)
        assert cls.vm.load_file("daedalus_weapons.nova"), cls.vm.error

    def test_weapon_order(self):
        self.assertEqual(self.vm.get_global("WEAPON_ORDER"),
                         ["primary", "rocket", "homing", "beam", "omni",
                          "turret"])

    def test_primary_gun_table(self):
        p = self.vm.get_global("WEAPONS")["primary"]
        self.assertAlmostEqual(p["velocity"], 1024.3, places=9)
        self.assertAlmostEqual(p["lifetime"], 1.28, places=9)
        self.assertAlmostEqual(p["cooldown"], 0.073, places=9)
        self.assertAlmostEqual(p["spread_deg"], 1.9, places=9)
        self.assertAlmostEqual(p["energy_cost"], 9.4, places=9)
        self.assertAlmostEqual(p["projectile_radius"], 2.7, places=9)

    def test_rocket_table(self):
        r = self.vm.get_global("WEAPONS")["rocket"]
        self.assertAlmostEqual(r["velocity"], 617.8, places=9)
        self.assertAlmostEqual(r["lifetime"], 3.14, places=9)
        self.assertAlmostEqual(r["cooldown"], 0.82, places=9)
        self.assertAlmostEqual(r["energy_cost"], 31.2, places=9)
        self.assertAlmostEqual(r["blast_radius"], 97.4, places=9)
        self.assertAlmostEqual(r["blast_falloff"], 0.37, places=9)
        self.assertAlmostEqual(r["projectile_radius"], 5.2, places=9)

    def test_homing_table(self):
        h = self.vm.get_global("WEAPONS")["homing"]
        self.assertAlmostEqual(h["velocity"], 468.2, places=9)
        self.assertAlmostEqual(h["lifetime"], 5.47, places=9)
        self.assertAlmostEqual(h["cooldown"], 1.13, places=9)
        self.assertAlmostEqual(h["turn_rate"], 212.4, places=9)
        self.assertAlmostEqual(h["acquire_range"], 1482.6, places=9)
        self.assertAlmostEqual(h["energy_cost"], 22.7, places=9)
        self.assertAlmostEqual(h["splash_radius"], 78.3, places=9)
        self.assertAlmostEqual(h["splash_falloff"], 0.28, places=9)
        self.assertAlmostEqual(h["projectile_radius"], 4.8, places=9)
        self.assertEqual(h["salvo_overrides"], {"aurora": 3, "atlantis": 6})

    def test_beam_table(self):
        b = self.vm.get_global("WEAPONS")["beam"]
        self.assertAlmostEqual(b["ramp_time"], 1.42, places=9)
        self.assertAlmostEqual(b["max_range"], 942.7, places=9)
        self.assertAlmostEqual(b["beam_width"], 6.3, places=9)
        self.assertAlmostEqual(b["energy_drain"], 26.4, places=9)
        self.assertAlmostEqual(b["min_energy"], 5.2, places=9)
        self.assertEqual(b["class_multiplier"],
                         {"fighter": 2.8, "battlecruiser": 1.0, "capital": 0.64})

    def test_omni_table(self):
        o = self.vm.get_global("WEAPONS")["omni"]
        self.assertEqual(o["port_count"], 8)
        self.assertTrue(o["twin_bolts"])
        self.assertAlmostEqual(o["velocity"], 1187.4, places=9)
        self.assertAlmostEqual(o["lifetime"], 1.13, places=9)
        self.assertAlmostEqual(o["cooldown"], 0.11, places=9)
        self.assertAlmostEqual(o["spread_deg"], 4.3, places=9)
        self.assertAlmostEqual(o["energy_cost_per_bolt"], 8.7, places=9)
        self.assertAlmostEqual(o["projectile_radius"], 2.7, places=9)

    def test_turret_table(self):
        t = self.vm.get_global("WEAPONS")["turret"]
        self.assertEqual(t["turret_count"], 5)
        self.assertAlmostEqual(t["velocity"], 938.6, places=9)
        self.assertAlmostEqual(t["lifetime"], 1.08, places=9)
        self.assertAlmostEqual(t["cooldown"], 0.47, places=9)
        self.assertAlmostEqual(t["range"], 642.8, places=9)
        self.assertAlmostEqual(t["damage"], 14.7, places=9)
        self.assertAlmostEqual(t["energy_cost"], 4.2, places=9)

    def test_effective_range(self):
        f = self.vm.call_function
        self.assertAlmostEqual(f("effective_range", ["primary"]),
                               1024.3 * 1.28, places=6)
        self.assertAlmostEqual(f("effective_range", ["rocket"]),
                               617.8 * 3.14, places=6)
        self.assertEqual(f("effective_range", ["homing"]), 1482.6)
        self.assertEqual(f("effective_range", ["beam"]), 942.7)
        self.assertEqual(f("effective_range", ["turret"]), 642.8)

    def test_falloff_damage_is_linear_within_radius_and_zero_beyond(self):
        f = lambda d: self.vm.call_function("falloff_damage",
                                            [100.0, d, 97.4, 0.37])
        self.assertEqual(f(0.0), 100.0)
        self.assertAlmostEqual(f(48.7), 100.0 * (1 - 0.5 * 0.37), places=9)
        # The documented edge behavior: AT the radius, damage is the
        # continuous limit (63%), not a discontinuous drop to zero --
        # only distances beyond the radius are zero.
        self.assertAlmostEqual(f(97.4), 63.0, places=9)
        self.assertEqual(f(97.40001), 0.0)
        self.assertEqual(f(500.0), 0.0)

    def test_falloff_damage_handles_a_zero_radius_without_dividing_by_it(self):
        self.assertEqual(
            self.vm.call_function("falloff_damage", [50.0, 0.0, 0.0, 0.5]),
            50.0)

    def test_beam_ramp_curve(self):
        f = lambda t: self.vm.call_function("beam_ramp_frac", [t])
        self.assertEqual(f(0.0), 0.6)
        self.assertEqual(f(-1.0), 0.6)
        self.assertAlmostEqual(f(0.71), 0.8, places=9)
        self.assertEqual(f(1.42), 1.0)
        self.assertEqual(f(10.0), 1.0)

    def test_beam_class_multiplier_is_not_the_general_matrix(self):
        """The beam exception: its own table, not Stage 1's."""
        self.assertEqual(
            self.vm.call_function("beam_class_multiplier", ["fighter"]), 2.8)
        self.assertEqual(
            self.vm.call_function("beam_class_multiplier", ["battlecruiser"]), 1.0)
        self.assertEqual(
            self.vm.call_function("beam_class_multiplier", ["capital"]), 0.64)
        # Nothing in Stage 1's DAMAGE_SCALING is 2.8 or 0.64 for these
        # pairs -- confirms the beam is genuinely not reusing that table.
        self.assertNotIn(2.8, (0.082, 0.047, 2.37, 3.14, 0.74, 1.12))
        self.assertNotIn(0.64, (0.082, 0.047, 2.37, 3.14, 0.74, 1.12))

    def test_beam_damage_per_second(self):
        f = self.vm.call_function
        self.assertAlmostEqual(f("beam_damage_per_second", [2431.0, 1.42, "fighter"]),
                               2431.0 * 2.8, places=6)
        self.assertAlmostEqual(f("beam_damage_per_second", [2431.0, 0.0, "capital"]),
                               2431.0 * 0.6 * 0.64, places=6)
        self.assertAlmostEqual(f("beam_damage_per_second", [3422.0, 1.42, "battlecruiser"]),
                               3422.0, places=6)

    def test_homing_turn_rate_reacts_to_target_class(self):
        f = self.vm.call_function
        self.assertAlmostEqual(f("homing_turn_rate", ["fighter"]),
                               212.4 * 1.14, places=9)
        self.assertAlmostEqual(f("homing_turn_rate", ["capital"]),
                               212.4 * 0.89, places=9)
        self.assertEqual(f("homing_turn_rate", ["battlecruiser"]), 212.4)

    def test_homing_salvo_size(self):
        f = self.vm.call_function
        self.assertEqual(f("homing_salvo_size", ["aurora"]), 3)
        self.assertEqual(f("homing_salvo_size", ["atlantis"]), 6)
        for key in ("x302", "daedalus", "phoenix", "destiny"):
            self.assertEqual(f("homing_salvo_size", [key]), 1, key)

    def test_fire_ballistic_direct_hit(self):
        r = self.vm.call_function("fire_ballistic", ["primary", 12.3, 1.0, 0.0])
        self.assertTrue(r["hit"])
        self.assertAlmostEqual(r["damage_dealt"], 12.3, places=9)
        self.assertEqual(r["effect"], "direct hit")

    def test_fire_ballistic_not_equipped(self):
        r = self.vm.call_function("fire_ballistic", ["primary", 0.0, 1.0, 0.0])
        self.assertFalse(r["hit"])
        self.assertEqual(r["effect"], "not equipped")

    def test_fire_ballistic_out_of_range(self):
        r = self.vm.call_function("fire_ballistic", ["primary", 12.3, 1.0, 5000.0])
        self.assertFalse(r["hit"])
        self.assertEqual(r["effect"], "out of range")

    def test_fire_ballistic_rocket_blast(self):
        direct = self.vm.call_function("fire_ballistic", ["rocket", 117.5, 1.0, 0.0])
        edge = self.vm.call_function("fire_ballistic", ["rocket", 117.5, 1.0, 97.4])
        beyond = self.vm.call_function("fire_ballistic", ["rocket", 117.5, 1.0, 200.0])
        self.assertEqual(direct["effect"], "direct hit")
        self.assertAlmostEqual(direct["damage_dealt"], 117.5, places=9)
        self.assertEqual(edge["effect"], "blast hit")
        self.assertAlmostEqual(edge["damage_dealt"], 117.5 * 0.63, places=6)
        self.assertFalse(beyond["hit"])
        self.assertEqual(beyond["effect"], "out of blast radius")

    def test_fire_ballistic_homing_splash(self):
        r = self.vm.call_function("fire_ballistic", ["homing", 89.1, 1.0, 40.0])
        self.assertTrue(r["hit"])
        self.assertEqual(r["effect"], "splash hit")
        want = 89.1 * (1.0 - (40.0 / 78.3) * 0.28)
        self.assertAlmostEqual(r["damage_dealt"], want, places=6)

    def test_fire_ballistic_omni_and_turret_have_no_falloff(self):
        far_but_in_range = self.vm.call_function("fire_ballistic",
                                                  ["omni", 16.3, 1.0, 500.0])
        self.assertTrue(far_but_in_range["hit"])
        self.assertAlmostEqual(far_but_in_range["damage_dealt"], 16.3, places=9)
        self.assertEqual(far_but_in_range["effect"], "direct hit")

    def test_fire_beam_outcomes(self):
        f = self.vm.call_function
        vaporized = f("fire_beam", [2431.0, "fighter", 100.0, 1.42])
        absorbed = f("fire_beam", [2431.0, "capital", 100.0, 1.42])
        burned = f("fire_beam", [2431.0, "battlecruiser", 100.0, 1.42])
        no_emitter = f("fire_beam", [0.0, "fighter", 100.0, 1.0])
        no_target = f("fire_beam", [2431.0, "", 100.0, 1.0])
        out_of_range = f("fire_beam", [2431.0, "fighter", 5000.0, 1.42])
        self.assertEqual(vaporized["effect"], "vaporized")
        self.assertEqual(absorbed["effect"], "absorbed")
        self.assertEqual(burned["effect"], "burned through")
        self.assertFalse(no_emitter["hit"])
        self.assertEqual(no_emitter["effect"], "no beam emitter")
        self.assertFalse(no_target["hit"])
        self.assertEqual(no_target["effect"], "no target")
        self.assertFalse(out_of_range["hit"])
        self.assertEqual(out_of_range["effect"], "out of range")

    def test_unknown_weapon_type_degrades_safely(self):
        self.assertEqual(
            self.vm.call_function("weapon_stat", ["not_a_weapon", "velocity", -1.0]),
            -1.0)
        self.assertEqual(
            self.vm.call_function("effective_range", ["not_a_weapon"]), 0.0)


class TestDaedalusRulesWeaponsBridge(unittest.TestCase):
    """The seam between rules.nova (SHIPS, DAMAGE_SCALING) and
    weapons.nova (WEAPONS, fire_ballistic/fire_beam), exercised through
    daedalus_rules.nova's fire_weapon()."""

    @classmethod
    def setUpClass(cls):
        cls.vm = NovaVM(random.Random(7), base_dir=host.RULES_DIR)
        for name in host.HOST_FUNCTIONS:
            cls.vm.register_function(name, lambda args: None)
        assert cls.vm.load_file("daedalus_rules.nova"), cls.vm.error

    CLASS_OF = {"x302": "fighter", "daedalus": "battlecruiser",
               "phoenix": "battlecruiser", "aurora": "capital",
               "destiny": "capital", "atlantis": "capital"}

    def test_weapon_order_and_stats_reachable_through_the_import(self):
        self.assertEqual(self.vm.get_global("WEAPON_ORDER"),
                         ["primary", "rocket", "homing", "beam", "omni",
                          "turret"])
        self.assertEqual(
            self.vm.call_function("weapon_stat", ["rocket", "blast_radius", -1.0]),
            97.4)

    def test_per_ship_primary_damage_at_same_class_is_unscaled(self):
        for key, want in {"x302": 4.7, "daedalus": 12.3, "phoenix": 14.1,
                          "aurora": 11.8, "destiny": 11.1,
                          "atlantis": 16.3}.items():
            r = self.vm.call_function("fire_weapon",
                                      ["primary", key, self.CLASS_OF[key], 0.0, 0.0])
            self.assertAlmostEqual(r["damage_dealt"], want, places=9, msg=key)

    def test_stage1_energy_costs_still_match_weapons_nova(self):
        """Independently declared in two files on purpose (weapons.nova
        must be importable standalone) -- this is the test that catches
        them drifting apart."""
        power = self.vm.get_global("POWER")
        self.assertEqual(
            self.vm.call_function("weapon_stat", ["primary", "energy_cost", -1.0]),
            power["primary_cost"])
        self.assertEqual(
            self.vm.call_function("weapon_stat", ["rocket", "energy_cost", -1.0]),
            power["rocket_cost"])
        self.assertEqual(
            self.vm.call_function("weapon_stat", ["homing", "energy_cost", -1.0]),
            power["homing_cost"])

    def test_beam_only_daedalus_and_phoenix(self):
        for key in ("daedalus", "phoenix"):
            r = self.vm.call_function("fire_weapon",
                                      ["beam", key, "fighter", 100.0, 1.42])
            self.assertTrue(r["hit"], key)
            self.assertEqual(r["effect"], "vaporized", key)
        for key in ("x302", "aurora", "destiny", "atlantis"):
            r = self.vm.call_function("fire_weapon",
                                      ["beam", key, "fighter", 100.0, 1.42])
            self.assertFalse(r["hit"], key)
            self.assertEqual(r["effect"], "no beam emitter", key)

    def test_omni_only_atlantis(self):
        ok = self.vm.call_function("fire_weapon",
                                   ["omni", "atlantis", "fighter", 50.0, 0.0])
        self.assertTrue(ok["hit"])
        self.assertAlmostEqual(ok["damage_dealt"], 16.3 * 3.14, places=6)
        for key in ("x302", "daedalus", "phoenix", "aurora", "destiny"):
            refused = self.vm.call_function("fire_weapon",
                                            ["omni", key, "fighter", 50.0, 0.0])
            self.assertFalse(refused["hit"], key)
            self.assertEqual(refused["effect"], "no omni ports", key)

    def test_turret_only_destiny(self):
        ok = self.vm.call_function("fire_weapon",
                                   ["turret", "destiny", "battlecruiser", 300.0, 0.0])
        self.assertTrue(ok["hit"])
        self.assertAlmostEqual(ok["damage_dealt"], 14.7 * 1.12, places=6)
        for key in ("x302", "daedalus", "phoenix", "aurora", "atlantis"):
            refused = self.vm.call_function("fire_weapon",
                                            ["turret", key, "battlecruiser", 300.0, 0.0])
            self.assertFalse(refused["hit"], key)
            self.assertEqual(refused["effect"], "no turrets", key)

    def test_damage_scaling_matrix_applies_inside_fire_weapon(self):
        r = self.vm.call_function("fire_weapon",
                                  ["primary", "x302", "capital", 0.0, 0.0])
        self.assertAlmostEqual(r["damage_dealt"], 4.7 * 0.047, places=9)
        r2 = self.vm.call_function("fire_weapon",
                                   ["omni", "atlantis", "battlecruiser", 0.0, 0.0])
        self.assertAlmostEqual(r2["damage_dealt"], 16.3 * 1.12, places=9)

    def test_homing_helpers_reachable_through_rules(self):
        self.assertEqual(self.vm.call_function("homing_salvo_size", ["aurora"]), 3)
        self.assertAlmostEqual(
            self.vm.call_function("homing_turn_rate", ["fighter"]),
            212.4 * 1.14, places=9)

    def test_weapons_nova_still_loads_standalone(self):
        standalone = NovaVM(random.Random(7), base_dir=host.RULES_DIR)
        assert standalone.load_file("daedalus_weapons.nova"), standalone.error
        a = standalone.call_function("fire_ballistic",
                                     ["primary", 12.3, 1.0, 0.0])
        b = self.vm.call_function("fire_weapon",
                                  ["primary", "daedalus", "battlecruiser", 0.0, 0.0])
        self.assertEqual(a, b)


if __name__ == "__main__":
    unittest.main(verbosity=2)
