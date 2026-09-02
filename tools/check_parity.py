#!/usr/bin/env python3
"""
check_parity.py -- keep the two implementations honest.

The reactor exists twice: once in Python (sim/reactor_physics.py plus
sim/nova_runtime.py, used on desktop) and once in GDScript
(godot/scripts/reactor_physics.gd plus godot/scripts/nova_vm.gd, used on
iOS and Web). If those two drift, the same reactor_rules.nova produces
different reactors on different platforms -- the worst kind of bug,
because it only shows up on the target you test least.

This script diffs the things that must match:

  * every physics constant, by name and value
  * the NovaLang keyword set
  * the NovaLang builtin function set
  * the NovaLang action set

Run it from the repository root:  python3 tools/check_parity.py
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PY_PHYSICS = ROOT / "godot" / "sim" / "reactor_physics.py"
GD_PHYSICS = ROOT / "godot" / "scripts" / "reactor_physics.gd"
PY_NOVA = ROOT / "godot" / "sim" / "nova_runtime.py"
GD_NOVA = ROOT / "godot" / "scripts" / "nova_vm.gd"

# Constants that exist in only one runtime for a good reason.
PHYSICS_EXEMPT = {
    "HAVE_NUMPY", "BACKEND",           # python-only: backend selection
    "BETA_I", "LAMBDA_I",              # arrays, compared separately
    "BETA_TOTAL",                      # summed in python, literal in gdscript;
                                       # cross-checked against BETA_I below
}

TOLERANCE = 1e-12


def fail(msg: str) -> None:
    print("  FAIL  " + msg)


def read(path: pathlib.Path) -> str:
    if not path.exists():
        print("missing file: %s" % path)
        sys.exit(2)
    return path.read_text(encoding="utf-8")


# --------------------------------------------------------------------------
# Physics constants
# --------------------------------------------------------------------------

_PY_CONST = re.compile(
    r"^([A-Z][A-Z0-9_]*)\s*=\s*(-?\d+\.?\d*(?:[eE][+-]?\d+)?)\s*(?:#.*)?$",
    re.MULTILINE)
_GD_CONST = re.compile(
    r"^const\s+([A-Z][A-Z0-9_]*)\s*:=\s*(-?\d+\.?\d*(?:[eE][+-]?\d+)?)\s*(?:#.*)?$",
    re.MULTILINE)


def _numbers(text: str, pattern: re.Pattern) -> dict[str, float]:
    return {m.group(1): float(m.group(2)) for m in pattern.finditer(text)}


def _array_const(text: str, name: str) -> list[float] | None:
    m = re.search(r"%s\s*:?=\s*\[([^\]]*)\]" % name, text)
    if not m:
        return None
    return [float(x) for x in m.group(1).replace("\n", " ").split(",") if x.strip()]


def check_physics() -> list[str]:
    problems: list[str] = []
    py = _numbers(read(PY_PHYSICS), _PY_CONST)
    gd = _numbers(read(GD_PHYSICS), _GD_CONST)

    shared = (set(py) | set(gd)) - PHYSICS_EXEMPT
    for name in sorted(shared):
        if name not in py:
            problems.append("%s is in the GDScript core but not the Python one" % name)
            continue
        if name not in gd:
            problems.append("%s is in the Python core but not the GDScript one" % name)
            continue
        if abs(py[name] - gd[name]) > TOLERANCE * max(1.0, abs(py[name])):
            problems.append("%s differs: python %r vs gdscript %r"
                            % (name, py[name], gd[name]))

    for name in ("BETA_I", "LAMBDA_I"):
        a = _array_const(read(PY_PHYSICS), name)
        b = _array_const(read(GD_PHYSICS), name)
        if a is None or b is None:
            problems.append("%s not found in both cores" % name)
        elif a != b:
            problems.append("%s differs:\n      python   %s\n      gdscript %s"
                            % (name, a, b))

    # BETA_TOTAL is summed in Python and hard-coded in GDScript.
    beta = _array_const(read(PY_PHYSICS), "BETA_I")
    if beta is not None and "BETA_TOTAL" in gd:
        if abs(sum(beta) - gd["BETA_TOTAL"]) > 1e-9:
            problems.append("BETA_TOTAL in GDScript is %r but sum(BETA_I) is %r"
                            % (gd["BETA_TOTAL"], sum(beta)))

    print("  physics: %d shared constants compared" % len(shared))
    return problems


# --------------------------------------------------------------------------
# NovaLang surface
# --------------------------------------------------------------------------

def _py_keywords(text: str) -> set[str]:
    m = re.search(r"_KEYWORDS\s*=\s*\{(.*?)\}", text, re.S)
    return set(re.findall(r'"([a-z_]+)"', m.group(1))) if m else set()


def _gd_keywords(text: str) -> set[str]:
    m = re.search(r"const KEYWORDS\s*:=\s*\{(.*?)\n\}", text, re.S)
    return set(re.findall(r'"([a-z_]+)":', m.group(1))) if m else set()


def _py_names(text: str, func: str) -> set[str]:
    """Names compared against `name` inside one Python function."""
    m = re.search(r"def %s\(.*?\n(.*?)(?=\n    def |\n\nclass |\Z)" % func,
                  text, re.S)
    if not m:
        return set()
    return set(re.findall(r'name == "([a-z_]+)"', m.group(1)))


def _gd_match_arms(text: str, func: str) -> set[str]:
    """String arms of the `match name:` inside one GDScript function."""
    m = re.search(r"func %s\(.*?\n(.*?)(?=\nfunc |\Z)" % func, text, re.S)
    if not m:
        return set()
    body = m.group(1)
    names = set(re.findall(r'^\t\t"([a-z_]+)":', body, re.M))
    names |= set(re.findall(r'name == "([a-z_]+)"', body))
    return names


def check_nova() -> list[str]:
    problems: list[str] = []
    py = read(PY_NOVA)
    gd = read(GD_NOVA)

    py_kw, gd_kw = _py_keywords(py), _gd_keywords(gd)
    if not py_kw or not gd_kw:
        problems.append("could not extract the keyword sets")
    elif py_kw != gd_kw:
        problems.append("keywords differ: python-only %s, gdscript-only %s"
                        % (sorted(py_kw - gd_kw), sorted(gd_kw - py_kw)))
    else:
        print("  novalang: %d keywords match" % len(py_kw))

    py_fn = _py_names(py, "_eval_call")
    gd_fn = _gd_match_arms(gd, "_eval_call")
    if py_fn != gd_fn:
        problems.append("builtin functions differ: python-only %s, gdscript-only %s"
                        % (sorted(py_fn - gd_fn), sorted(gd_fn - py_fn)))
    else:
        print("  novalang: %d builtin functions match" % len(py_fn))

    py_act = _py_names(py, "exec_action")
    gd_act = _gd_match_arms(gd, "_exec_action")
    if py_act != gd_act:
        problems.append("actions differ: python-only %s, gdscript-only %s"
                        % (sorted(py_act - gd_act), sorted(gd_act - py_act)))
    else:
        print("  novalang: %d actions match" % len(py_act))

    return problems


def main() -> int:
    print("checking python <-> gdscript parity")
    problems = check_physics() + check_nova()
    if problems:
        print("\n%d parity problem(s):" % len(problems))
        for p in problems:
            fail(p)
        return 1
    print("\nparity OK -- both runtimes describe the same reactor")
    return 0


if __name__ == "__main__":
    sys.exit(main())
