"""Tests for the physics core, the NovaLang interpreter and the bridge
protocol. Run with:  python3 -m unittest discover -s sim/tests -v"""

import json
import math
import os
import random
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import nova_runtime as nova            # noqa: E402
import reactor_physics as phys         # noqa: E402
import reactor_server as server        # noqa: E402


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
        self.assertAlmostEqual(phys.bank_worth_pcm(0.0), phys.ROD_W_MIN_PCM)
        self.assertAlmostEqual(phys.bank_worth_pcm(100.0), phys.ROD_W_MAX_PCM)
        # Cubic worth: the top decile is worth much more than the bottom one.
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
        for _ in range(8000):           # 400 s
            r.step(0.05, 72.0, 72.0, 1.0, 1.0, 0.0, 0.0)
        flux_a, temp_a = r.flux_percent, r.fuel_temp
        for _ in range(2000):           # another 100 s
            r.step(0.05, 72.0, 72.0, 1.0, 1.0, 0.0, 0.0)
        self.assertLess(abs(r.flux_percent - flux_a), 0.5)
        self.assertLess(abs(r.fuel_temp - temp_a), 1.0)
        self.assertGreater(r.flux_percent, 50.0)
        # Negative feedback must hold the equilibrium near zero reactivity.
        self.assertLess(abs(r.reactivity_pcm), 20.0)

    def test_negative_temperature_feedback(self):
        """Hotter fuel and moderator must subtract reactivity. Without this
        the core has no self-regulation and every run is a prompt
        excursion."""
        self.assertLess(phys.doppler_reactivity_pcm(1000.0), 0.0)
        self.assertLess(phys.moderator_reactivity_pcm(1000.0), 0.0)

    def test_rk4_is_fourth_order(self):
        """Halving the step must cut the error by ~16x. This is the check
        that the integrator really is RK4 and not a dressed-up Euler."""
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
        a = phys.decay_heat_pct(100.0, 0.0, 7.0, 130.0)
        b = phys.decay_heat_pct(100.0, 130.0, 7.0, 130.0)
        self.assertAlmostEqual(a, 7.0)
        self.assertAlmostEqual(b, 7.0 / math.e, places=6)
        self.assertLess(phys.decay_heat_pct(100.0, 600.0, 7.0, 130.0), 0.07)


# ==========================================================================
# NovaLang
# ==========================================================================

class TestNovaLang(unittest.TestCase):

    def machine(self, src, seed=1):
        return nova.NovaMachine(nova.parse(src), random.Random(seed))

    def test_arithmetic_and_precedence(self):
        m = self.machine('reactor "t"\nrule r { when true then set x = 2 + 3 * 4 }')
        m.tick(0.05, {"t": 0.0})
        self.assertEqual(m.vars["x"], 14.0)

    def test_comparison_and_boolean_short_circuit(self):
        m = self.machine('reactor "t"\n'
                         'rule r { when 1 < 2 and not (3 > 4) then set hit = 1 }')
        m.tick(0.05, {"t": 0.0})
        self.assertEqual(m.vars["hit"], 1.0)

    def test_params_may_reference_earlier_params(self):
        m = self.machine('reactor "t"\nparams { a = 2.0  b = a * 3.0 }\n'
                         'rule r { when true then set x = b }')
        m.tick(0.05, {"t": 0.0})
        self.assertEqual(m.vars["x"], 6.0)

    def test_effects_reset_each_tick_unless_persistent(self):
        m = self.machine('reactor "t"\n'
                         'effects { a = 1.0  b = 1.0 persistent }\n'
                         'rule r once { when true then set a = 9.0 set b = 9.0 }')
        m.tick(0.05, {"t": 0.0})
        self.assertEqual(m.vars["a"], 9.0)
        m.tick(0.05, {"t": 0.05})
        self.assertEqual(m.vars["a"], 1.0)      # reset
        self.assertEqual(m.vars["b"], 9.0)      # persisted

    def test_held_requires_continuous_truth(self):
        m = self.machine('reactor "t"\n'
                         'rule r { when held(hot, 0.2) then log("TRIPPED") }')
        for _ in range(3):
            out = m.tick(0.1, {"t": 0.0, "hot": True})
        self.assertEqual(out["events"], ["TRIPPED"])
        # One false tick resets the timer.
        m.tick(0.1, {"t": 0.0, "hot": False})
        out = m.tick(0.1, {"t": 0.0, "hot": True})
        self.assertEqual(out["events"], [])

    def test_edge_rules_fire_once_per_rising_edge(self):
        m = self.machine('reactor "t"\nrule r edge { when x > 0 then log("UP") }')
        self.assertEqual(m.tick(0.05, {"t": 0.0, "x": 1.0})["events"], ["UP"])
        self.assertEqual(m.tick(0.05, {"t": 0.0, "x": 1.0})["events"], [])
        m.tick(0.05, {"t": 0.0, "x": 0.0})
        self.assertEqual(m.tick(0.05, {"t": 0.0, "x": 1.0})["events"], ["UP"])

    def test_once_rules_never_fire_twice(self):
        m = self.machine('reactor "t"\nrule r once { when true then log("HI") }')
        self.assertEqual(m.tick(0.05, {"t": 0.0})["events"], ["HI"])
        self.assertEqual(m.tick(0.05, {"t": 0.0})["events"], [])

    def test_priority_orders_rule_execution(self):
        m = self.machine('reactor "t"\n'
                         'rule low priority 1 { when true then set x = "low" }\n'
                         'rule high priority 9 { when true then set x = "high" }')
        m.tick(0.05, {"t": 0.0})
        self.assertEqual(m.vars["x"], "low")   # highest priority runs first

    def test_string_concatenation(self):
        m = self.machine('reactor "t"\nrule r { when true then log("BANK " + b) }')
        self.assertEqual(m.tick(0.05, {"t": 0.0, "b": "A"})["events"], ["BANK A"])

    def test_division_by_zero_is_survivable(self):
        m = self.machine('reactor "t"\nrule r { when true then set x = 1 / 0 }')
        m.tick(0.05, {"t": 0.0})
        self.assertEqual(m.vars["x"], 0.0)

    def test_syntax_errors_report_a_line(self):
        with self.assertRaises(nova.NovaError) as ctx:
            nova.parse('reactor "t"\nrule r { when true then set = 3 }')
        self.assertIn("line 2", str(ctx.exception))

    def test_unknown_identifier_is_an_error(self):
        m = self.machine('reactor "t"\nrule r { when nope > 1 then log("x") }')
        with self.assertRaises(nova.NovaError):
            m.tick(0.05, {"t": 0.0})

    def test_fault_activates_applies_effects_and_clears(self):
        m = self.machine('reactor "t"\n'
                         'params { fault_first_min_s = 1.0  fault_first_max_s = 1.0\n'
                         '         fault_gap_min_s = 99.0  fault_gap_max_s = 99.0 }\n'
                         'effects { load_frac = 1.0 }\n'
                         'fault trip weight 1 duration 0.5 label "TRIP" {\n'
                         '    set load_frac = 0.0\n}')
        t = 0.0
        seen = []
        for _ in range(40):
            t += 0.1
            out = m.tick(0.1, {"t": t})
            seen.extend(out["events"])
            if abs(t - 1.2) < 1e-9:
                self.assertEqual(out["load_frac"], 0.0)
            if abs(t - 2.0) < 1e-9:
                self.assertEqual(out["load_frac"], 1.0)   # auto-restored
        self.assertIn("ALARM: TRIP", seen)
        self.assertIn("TRIP CLEARED", seen)

    def test_builtin_arity_is_checked(self):
        """A typo in the policy must report a line, not raise IndexError
        somewhere in the middle of a shift."""
        m = self.machine('reactor "t"\nrule r { when true then set x = clamp(1) }')
        with self.assertRaises(nova.NovaError) as ctx:
            m.tick(0.05, {"t": 0.0})
        self.assertIn("clamp() needs 3", str(ctx.exception))

    def test_reset_trip_clears_the_latch_within_the_tick(self):
        m = self.machine('reactor "t"\n'
                         'rule clear priority 9 { when scram and t > 1.0 '
                         'then reset_trip() log("RESTORED") }\n'
                         'rule report priority 1 { when scram then set s = "on" }')
        out = m.tick(0.05, {"t": 2.0, "scram": True})
        self.assertTrue(out["trip_reset"])
        self.assertIn("RESTORED", out["events"])
        # The lower-priority rule ran after the reset, so it must not have
        # seen a scrammed plant.
        self.assertNotIn("s", m.vars)

    def test_the_shipped_policy_parses(self):
        with open(server.DEFAULT_RULES, encoding="utf-8") as fh:
            prog = nova.parse(fh.read())
        self.assertEqual(prog.title, "CHERNOBYL-1")
        names = {r.name for r in prog.rules}
        self.assertIn("operator_scram", names)
        self.assertIn("core_disassembly", names)
        self.assertEqual({f.name for f in prog.faults},
                         {"turbine_trip", "feedwater_failure", "rod_stuck",
                          "xenon_poisoning"})


# ==========================================================================
# Bridge protocol
# ==========================================================================

class TestBridgeProtocol(unittest.TestCase):

    def session(self, seed=5):
        return server.Session(server.DEFAULT_RULES, seed)

    def reply(self, sess, obj):
        return json.loads(sess.handle_line(json.dumps(obj)))

    def test_hello_advertises_the_contract(self):
        r = self.reply(self.session(), {"cmd": "hello"})
        self.assertTrue(r["ok"])
        self.assertEqual(r["proto"], server.PROTO_VERSION)
        self.assertEqual(r["dt"], phys.PHYSICS_DT)
        self.assertEqual(r["grid"], server.GRID_N)

    def test_tick_advances_time_and_returns_history(self):
        s = self.session()
        r = self.reply(s, {"cmd": "tick", "steps": 10, "rod_target_a": 50,
                           "rod_target_b": 50})
        self.assertAlmostEqual(r["t"], 10 * phys.PHYSICS_DT)
        self.assertEqual(len(r["history"]), 10)
        self.assertEqual(len(r["history"][0]), 2)
        self.assertIn("peak", r)
        self.assertEqual(r["peak"]["n"], server.GRID_N)

    def test_malformed_frames_do_not_kill_the_session(self):
        s = self.session()
        self.assertFalse(json.loads(s.handle_line("{{{"))["ok"])
        self.assertFalse(json.loads(s.handle_line("[1,2,3]"))["ok"])
        self.assertFalse(self.reply(s, {"cmd": "nope"})["ok"])
        self.assertTrue(self.reply(s, {"cmd": "hello"})["ok"])
        self.assertIsNone(s.handle_line("   "))

    def test_steps_are_clamped(self):
        s = self.session()
        r = self.reply(s, {"cmd": "tick", "steps": 100000})
        self.assertEqual(len(r["history"]), server.MAX_STEPS_PER_TICK)

    def test_operator_scram_latches_and_slams_the_rods_in(self):
        s = self.session()
        self.reply(s, {"cmd": "tick", "steps": 60, "rod_target_a": 70,
                       "rod_target_b": 70})
        r = self.reply(s, {"cmd": "tick", "steps": 1, "rod_target_a": 70,
                           "rod_target_b": 70, "scram": True})
        self.assertTrue(r["scram"])
        self.assertEqual(r["rod_a"], 0.0)
        self.assertEqual(r["rod_b"], 0.0)
        self.assertEqual(r["state"], "SCRAM")
        self.assertIn("MANUAL SCRAM INITIATED", r["events"])
        # Sliders are dead while tripped.
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
        self.assertTrue(any("AUTO SCRAM" in e for e in r["events"])
                        or r["state"] == "SCRAM")

    def test_same_seed_gives_the_same_run(self):
        def run(seed):
            s = self.session(seed)
            out = []
            for _ in range(120):
                r = self.reply(s, {"cmd": "tick", "steps": 20,
                                   "rod_target_a": 60, "rod_target_b": 60})
                out.extend(r["events"])
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

    def test_rod_drives_come_back_after_the_cooldown(self):
        """A trip locks the sliders out; reactor_rules.nova hands them back
        once decay heat has died away."""
        s = self.session()
        self.reply(s, {"cmd": "tick", "steps": 40, "rod_target_a": 60,
                       "rod_target_b": 60})
        r = self.reply(s, {"cmd": "tick", "steps": 1, "scram": True})
        self.assertTrue(r["scram"])
        cooldown = int(600.0 / phys.PHYSICS_DT / server.MAX_STEPS_PER_TICK) + 2
        for _ in range(cooldown):
            r = self.reply(s, {"cmd": "tick", "steps": server.MAX_STEPS_PER_TICK,
                               "faults": False})
            if not r["scram"]:
                break
        self.assertFalse(r["scram"], "the trip should clear after cooldown")

    def test_quit_stops_the_session(self):
        s = self.session()
        self.assertTrue(self.reply(s, {"cmd": "quit"})["bye"])
        self.assertFalse(s.alive)

    def test_selftest_entry_point_runs(self):
        result = server.selftest(seconds=20.0, seed=3)
        self.assertTrue(result["ok"])
        self.assertGreater(result["realtime_factor"], 1.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
