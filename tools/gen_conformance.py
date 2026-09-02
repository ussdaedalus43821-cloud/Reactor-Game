#!/usr/bin/env python3
"""
gen_conformance.py -- record what NovaLang must do, from the reference.

Runs a corpus of NovaLang programs through the Python reference
implementation and writes godot/scripts/nova/conformance.json: for each
case, the exact lines print() emitted and the exact error text (if any).
It also records a deterministic reactor trace -- reactor_rules.nova driven
through a scripted rod program with the fault injector disabled -- so the
whole stack, not just the language, is pinned.

parity_check.gd replays that file inside Godot and diffs. That is how a
GDScript interpreter nobody can run from CI still gets verified: the
reference states the answer, the engine has to produce it.

Regenerate after any language change:
    python3 tools/gen_conformance.py
"""

from __future__ import annotations

import json
import os
import random
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "reference"))

import nova_evaluator as ev          # noqa: E402
import reactor_host as host          # noqa: E402
from nova_vm import NovaVM           # noqa: E402

OUT_PATH = os.path.join(ROOT, "godot", "scripts", "nova", "conformance.json")

MODULES = {
    "lib/m.nova": (
        'export func twice(x) { return x * 2 }\n'
        'export let NAME = "m"\n'
        'let secret = 41\n'
    ),
    "lib/n.nova": (
        'import "lib/m.nova" as m\n'
        'export func quad(x) { return m.twice(m.twice(x)) }\n'
    ),
}

# Each case: (name, source). A case that should fail names its expected
# error by simply producing one -- the generator records whatever the
# reference says, and Godot has to match it word for word.
CASES = [
    ("literals", 'print(1, 2.5, "s", true, false, null)'),
    ("arithmetic", "print(2 + 3 * 4, (2 + 3) * 4, 10 / 4, 7 % 4, -3 + 1)"),
    ("precedence", "print(1 + 2 < 4 and not false, 2 * 3 == 6 or 1 / 0 > 0)"),
    ("comparisons", "print(1 < 2, 2 <= 2, 3 > 4, 3 >= 3, 1 == 1, 1 != 2)"),
    ("short_circuit", "print(false and nope(), true or nope())"),
    ("string_concat", 'print("n=" + 42, "f=" + 1.5, "b=" + true, "x" + null)'),
    ("number_format", "print(1, 1.5, 1/3, -0.25, 1000000, 2/3 * 3)"),
    ("unary", "print(-(2 + 3), - -4, not 0, not \"\", not [])"),

    ("let_and_assign", "let a = 1  a = a + 1  let b = a * 2  print(a, b)"),
    ("blocks_scope", "let x = 1  { let x = 2  print(x) }  print(x)"),
    ("if_else_chain", "let r = []  let i = 0  while i < 4 { "
                      "if i == 0 { append(r, \"z\") } else if i < 3 "
                      "{ append(r, i) } else { append(r, \"big\") } "
                      "i = i + 1 }  print(r)"),
    ("while_break_continue", "let s = 0  let i = 0  while true { i = i + 1 "
                             "if i > 10 { break }  if i % 2 == 0 { continue } "
                             "s = s + i }  print(s, i)"),

    ("functions", "func add(a, b) { return a + b }  print(add(2, 3), add(-1, 1))"),
    ("recursion", "func fib(n) { if n < 2 { return n } "
                  "return fib(n-1) + fib(n-2) }  print(fib(18))"),
    ("mutual_recursion", "func even(n) { if n == 0 { return true } "
                         "return odd(n - 1) }  "
                         "func odd(n) { if n == 0 { return false } "
                         "return even(n - 1) }  print(even(10), odd(7))"),
    ("closures", "func counter() { let n = 0  return func() { n = n + 1 "
                 "return n } }  let a = counter()  let b = counter()  "
                 "a() a()  print(a(), b())"),
    ("closure_capture_loop", "let fns = []  let i = 0  "
                             "while i < 3 { let k = i  "
                             "append(fns, func() { return k * 10 })  "
                             "i = i + 1 }  print(fns[0](), fns[2]())"),
    ("higher_order", "func apply(f, v) { return f(v) }  "
                     "print(apply(func(x) { return x + 1 }, 41))"),
    ("implicit_null_return", "func f() { let a = 1 }  print(f())"),

    ("lists", "let l = [3, 1, 2]  append(l, 9)  l[0] = 7  "
              "print(l, len(l), l[-1], slice(l, 1, 3))"),
    ("list_ops", "print(remove_at([1,2,3], 1), has([1,2], 2), "
                 "range(4), range(2, 5))"),
    ("list_concat", "print([1,2] + [3], [] + [])"),
    ("dicts", 'let d = { a: 1 }  d.b = 2  d["c"] = 3  '
              'print(d, len(d), d.a, d["b"], has(d, "z"), get(d, "z", 0))'),
    ("dict_keys", 'let d = { b: 1, a: 2 }  print(keys(d))'),
    ("computed_keys", 'let k = "x"  let d = { [k + "1"]: 5 }  print(d)'),
    ("nesting", 'print([1, "two", [true, null], {a: [1]}])'),
    ("deep_equality", 'print([1,[2]] == [1,[2]], {a:1} == {a:1}, '
                      '[1] == [1,2], 1 == "1", null == null)'),

    ("builtins_math", "print(abs(-2), min(3,1,2), max(3,1,2), clamp(5,0,1), "
                      "floor(1.7), round(1.5), round(-1.5), pow(2,10))"),
    ("builtins_more", "print(exp(0), sqrt(9), ramp(1.5), ramp(-1), "
                      "lerp(0, 10, 0.25), lerp(0, 10, 2))"),
    ("builtins_types", 'func f() { }  print(type(1), type("s"), type([]), '
                       'type({}), type(null), type(f), type(true))'),
    ("builtins_convert", 'print(num("2.5"), num("bad"), int(2.9), int(-2.9), '
                         'str(3), str([1]), bool(""), bool(0), bool([1]))'),
    ("builtins_strings", 'print(upper("aB"), lower("aB"), split("a,b,c", ","), '
                         'split("ab", ""), join(["a","b"], "-"), '
                         'contains("abc", "bc"), len("abc"), "abc"[1])'),

    ("import_alias", 'import "lib/m.nova" as m\nprint(m.twice(21), m.NAME)'),
    ("import_bare", 'import "lib/m.nova"\nprint(twice(4), NAME)'),
    ("import_nested", 'import "lib/n.nova" as n\nprint(n.quad(3))'),
    ("import_cached", 'import "lib/m.nova" as a\nimport "lib/m.nova" as b\n'
                      'print(a.NAME + b.NAME)'),

    ("err_unknown_ident", "print(nope)"),
    ("err_unknown_func", "nope()"),
    ("err_call_number", "let x = 1  x()"),
    ("err_builtin_arity", "print(clamp(1))"),
    ("err_user_arity", "func f(a, b) { return a }  f(1)"),
    ("err_list_range", "let l = [1]  print(l[5])"),
    ("err_dict_key", "let d = {}  print(d.missing)"),
    ("err_type", 'print("a" - 1)'),
    ("err_depth", "func f(n) { return f(n + 1) }  f(0)"),
    ("err_steps", "while true { }"),
    ("err_parse", "let = 3"),
    ("err_lex", 'let s = "unterminated'),
    ("err_module_missing", 'import "nope.nova"'),
    ("err_private_export", 'import "lib/m.nova"\nprint(secret)'),

    ("non_callable_binding_falls_through",
     'let scram = false  scram("TRIP")  print("ok")'),
]


def run_case(name: str, source: str) -> dict:
    vm = NovaVM(random.Random(12345), module_reader=MODULES.get)
    calls = []
    for fn_name in host.HOST_FUNCTIONS:
        vm.register_function(
            fn_name,
            (lambda n: lambda args: calls.append(
                n + "(" + ", ".join(ev.text(a) for a in args) + ")"))(fn_name))
    ok = vm.eval(source, name)
    return {
        "name": name,
        "source": source,
        "ok": bool(ok),
        "error": vm.error,
        "output": vm.drain_output(),
        "host_calls": calls,
    }


def reactor_trace(steps: int = 900) -> dict:
    """A deterministic end-to-end run: fault injector off, so nothing
    depends on either language's RNG, and a scripted rod ramp that takes
    the plant from cold to a trip."""
    sim = host.ReactorHost(seed=1)
    frames = []
    program = []
    for i in range(steps):
        # ramp to 74 % over 40 s, hold, then yank to 100 % to force a trip
        t = i * 0.05
        if t < 40.0:
            target = 74.0 * (t / 40.0)
        elif t < 42.0:
            target = 74.0
        else:
            target = 100.0
        program.append(round(target, 6))
        snap = sim.advance(1, target, target, False, faults_enabled=False)
        if i % 25 == 0 or snap["events"]:
            frames.append({
                "i": i,
                "t": round(snap["t"], 9),
                "flux_pct": snap["flux_pct"],
                "fuel_temp_c": snap["fuel_temp_c"],
                "pressure_mpa": snap["pressure_mpa"],
                "reactivity_pcm": snap["reactivity_pcm"],
                "rod_a": snap["rod_a"],
                "state": snap["state"],
                "scram": snap["scram"],
                "alarm_level": snap["alarm_level"],
                "events": snap["events"],
            })
    return {"rules": "reactor_rules.nova", "steps": steps,
            "rod_program": program, "frames": frames}


def build_doc() -> dict:
    """The whole golden document. check_parity.py rebuilds this and diffs it
    against the committed file, so a reference change that nobody
    regenerated is caught rather than silently trusted."""
    return {
        "_comment": "GENERATED by tools/gen_conformance.py from the Python "
                    "reference in reference/. Do not hand-edit. "
                    "parity_check.gd replays this inside Godot.",
        "version": 2,
        "modules": MODULES,
        "cases": [run_case(name, src) for name, src in CASES],
        "reactor_trace": reactor_trace(),
        "daedalus_data": daedalus_data(),
    }


DAEDALUS_DAMAGE_PAIRS = [
    ["fighter", "battlecruiser"], ["fighter", "capital"],
    ["battlecruiser", "fighter"], ["battlecruiser", "capital"],
    ["capital", "fighter"], ["capital", "battlecruiser"],
    ["fighter", "fighter"], ["battlecruiser", "battlecruiser"],
    ["capital", "capital"], ["fighter", "no_such_class"],
]
DAEDALUS_DANGER_SAMPLES = [[0, 40.0], [1, 0.0], [1, 12.5], [2, 0.0],
                           [2, 7.25], [3, 0.0], [3, 3.75], [3, 20.0]]


def daedalus_data() -> dict:
    """Pin the Stage 1 balance tables. parity_check.gd loads the same
    daedalus_rules.nova through the GDScript interpreter and diffs, so a
    number that reads differently in the two runtimes fails the build."""
    vm = NovaVM(random.Random(7),
                module_reader=lambda p: _read_script(p))
    for fn_name in host.HOST_FUNCTIONS:
        vm.register_function(fn_name, lambda args: None)
    if not vm.load_file("daedalus_rules.nova"):
        raise SystemExit("daedalus_rules.nova failed to load: %s" % vm.error)

    ships = {}
    for key, entry in vm.get_global("SHIPS").items():
        ships[key] = {k: entry[k] for k in
                      ("name", "class", "shield", "hull", "speed", "turn",
                       "gun_dmg", "rocket_dmg", "homing_dmg", "beam_dmg")}

    return {
        "ship_order": vm.get_global("SHIP_ORDER"),
        "ships": ships,
        "damage_pairs": [
            {"a": a, "b": b,
             "mult": vm.call_function("damage_multiplier", [a, b])}
            for a, b in DAEDALUS_DAMAGE_PAIRS],
        "power": dict(vm.get_global("POWER")),
        "danger_samples": [
            {"danger": d, "gen": g,
             "hostiles": vm.call_function("hostiles_for", [float(d), g])}
            for d, g in DAEDALUS_DANGER_SAMPLES],
        "sector_keys": [int(s["key"]) for s in vm.get_global("SECTORS")],
        "sector_hostiles": [
            {"key": k, "gen": 6.0,
             "hostiles": vm.call_function("sector_hostiles", [float(k), 6.0])}
            for k in (1, 4, 5, 9)],
        "power_balance": [
            {"thrust": t, "cloak": c, "shields": sh,
             "net": vm.call_function("power_balance", [t, c, sh])}
            for t, c, sh in ((False, False, False), (True, False, True),
                             (True, True, False), (True, True, True))],
    }


def _read_script(path: str):
    full = os.path.join(ROOT, "godot", "scripts", path)
    if not os.path.exists(full):
        return None
    with open(full, "r", encoding="utf-8") as fh:
        return fh.read()


def main() -> int:
    doc = build_doc()
    cases = doc["cases"]
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1, sort_keys=False)
        fh.write("\n")

    failures = sum(1 for c in cases if not c["ok"])
    print("wrote %s" % os.path.relpath(OUT_PATH, ROOT))
    print("  %d cases (%d expected-error), %d reactor frames, "
          "%d daedalus hulls"
          % (len(cases), failures, len(doc["reactor_trace"]["frames"]),
             len(doc["daedalus_data"]["ships"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
