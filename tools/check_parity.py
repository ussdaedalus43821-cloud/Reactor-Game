#!/usr/bin/env python3
"""
check_parity.py -- keep the shipping interpreter and the reference honest.

NovaLang exists twice on purpose:

  * godot/scripts/nova/*.gd  -- the implementation that ships. Pure
    GDScript, runs on macOS, iOS and Web, no Python anywhere near it.
  * reference/*.py           -- the oracle. Never shipped, never executed
    by the game; it exists so the language has a runnable specification
    that CI can test, and so the conformance goldens have an author.

If those two drift, the same .nova file means two different things and only
the platform you test least finds out. This script diffs the surfaces that
must match, mechanically:

  * every physics constant (the RK4 core is also written twice)
  * the lexer's keyword set and operator table
  * the parser's AST node vocabulary
  * the evaluator's builtin set, with arities, and its runtime limits
  * the reactor host-function registry
  * the conformance goldens -- rebuilt from the reference and compared to
    the committed file, so a stale conformance.json fails the build

Behavioural equivalence is checked separately, and more strongly, by
parity_check.gd replaying those goldens inside Godot.

Run from the repository root:  python3 tools/check_parity.py
"""

from __future__ import annotations

import ast
import json
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REF = ROOT / "reference"
GD = ROOT / "godot" / "scripts"

sys.path.insert(0, str(REF))
sys.path.insert(0, str(ROOT / "tools"))

problems: list[str] = []
notes: list[str] = []

TOLERANCE = 1e-12

# Constants that exist in only one runtime for a good reason.
PHYSICS_EXEMPT = {
    "HAVE_NUMPY", "BACKEND",           # python-only: backend selection
    "BETA_I", "LAMBDA_I",              # arrays, compared separately
    "BETA_TOTAL",                      # summed in python, literal in
                                       # gdscript; cross-checked below
}


def read(path: pathlib.Path) -> str:
    if not path.exists():
        problems.append("missing file: %s" % path.relative_to(ROOT))
        return ""
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


def _numbers(text: str, pattern: re.Pattern) -> dict:
    return {m.group(1): float(m.group(2)) for m in pattern.finditer(text)}


def _array_const(text: str, name: str):
    m = re.search(r"%s\s*:?=\s*\[([^\]]*)\]" % name, text)
    if not m:
        return None
    return [float(x) for x in m.group(1).replace("\n", " ").split(",")
            if x.strip()]


def check_physics() -> None:
    py_text = read(REF / "reactor_physics.py")
    gd_text = read(GD / "reactor_physics.gd")
    if not py_text or not gd_text:
        return
    py = _numbers(py_text, _PY_CONST)
    gd = _numbers(gd_text, _GD_CONST)

    shared = (set(py) | set(gd)) - PHYSICS_EXEMPT
    for name in sorted(shared):
        if name not in py:
            problems.append("physics: %s is in GDScript but not the reference"
                            % name)
        elif name not in gd:
            problems.append("physics: %s is in the reference but not GDScript"
                            % name)
        elif abs(py[name] - gd[name]) > TOLERANCE * max(1.0, abs(py[name])):
            problems.append("physics: %s differs -- reference %r vs gdscript %r"
                            % (name, py[name], gd[name]))

    for name in ("BETA_I", "LAMBDA_I"):
        a = _array_const(py_text, name)
        b = _array_const(gd_text, name)
        if a is None or b is None:
            problems.append("physics: %s not found in both cores" % name)
        elif a != b:
            problems.append("physics: %s differs\n      reference %s\n"
                            "      gdscript  %s" % (name, a, b))

    beta = _array_const(py_text, "BETA_I")
    if beta is not None and "BETA_TOTAL" in gd:
        if abs(sum(beta) - gd["BETA_TOTAL"]) > 1e-9:
            problems.append("physics: BETA_TOTAL is %r in GDScript but "
                            "sum(BETA_I) is %r" % (gd["BETA_TOTAL"], sum(beta)))
    notes.append("physics: %d shared constants compared" % len(shared))


# --------------------------------------------------------------------------
# Extracting literals from each language
# --------------------------------------------------------------------------

def py_literal(path: pathlib.Path, name: str):
    """Evaluate a module-level literal assignment from the reference."""
    text = read(path)
    if not text:
        return None
    tree = ast.parse(text, str(path))
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == name:
                    try:
                        return ast.literal_eval(node.value)
                    except ValueError:
                        return None
    return None


def gd_block(path: pathlib.Path, name: str) -> str:
    """The text of a `const NAME := { ... }` or `[ ... ]` declaration."""
    text = read(path)
    if not text:
        return ""
    m = re.search(r"const\s+%s\s*:=\s*([\{\[])" % name, text)
    if not m:
        return ""
    opener = m.group(1)
    closer = "}" if opener == "{" else "]"
    depth = 0
    start = m.end() - 1
    for i in range(start, len(text)):
        if text[i] == opener:
            depth += 1
        elif text[i] == closer:
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return ""


def gd_string_set(path: pathlib.Path, name: str) -> set:
    """Every "quoted" entry in a GDScript const collection."""
    return set(re.findall(r'"((?:[^"\\]|\\.)*)"', gd_block(path, name)))


def gd_string_list(path: pathlib.Path, name: str) -> list:
    return [s for s in re.findall(r'"((?:[^"\\]|\\.)*)"', gd_block(path, name))]


def gd_arity_map(path: pathlib.Path, name: str) -> dict:
    out = {}
    for key, value in re.findall(r'"([a-z_]+)"\s*:\s*(-?\d+)',
                                 gd_block(path, name)):
        out[key] = int(value)
    return out


def gd_const_number(path: pathlib.Path, name: str):
    m = re.search(r"const\s+%s\s*:=\s*(-?\d+(?:\.\d+)?)" % name, read(path))
    return float(m.group(1)) if m else None


def compare_sets(label: str, reference: set, gdscript: set) -> None:
    if reference == gdscript:
        notes.append("%s: %d entries match" % (label, len(reference)))
        return
    problems.append("%s differs: reference-only %s, gdscript-only %s"
                    % (label, sorted(reference - gdscript),
                       sorted(gdscript - reference)))


# --------------------------------------------------------------------------
# NovaLang surface
# --------------------------------------------------------------------------

def check_lexer() -> None:
    ref = py_literal(REF / "nova_lexer.py", "KEYWORDS")
    gds = gd_string_set(GD / "nova" / "nova_lexer.gd", "KEYWORDS")
    if ref is None:
        problems.append("lexer: could not read the reference keyword set")
    else:
        compare_sets("lexer keywords", set(ref), gds)

    ref_ops = py_literal(REF / "nova_lexer.py", "OPERATORS")
    gd_ops = gd_string_list(GD / "nova" / "nova_lexer.gd", "OPERATORS")
    if ref_ops is None:
        problems.append("lexer: could not read the reference operator table")
    elif list(ref_ops) != gd_ops:
        # Order matters here: the table is scanned longest-first, so a
        # reordering silently changes how "<=" tokenises.
        problems.append("lexer operators differ (order is significant):\n"
                        "      reference %s\n      gdscript  %s"
                        % (ref_ops, gd_ops))
    else:
        notes.append("lexer operators: %d entries match, in order" % len(gd_ops))


def check_parser() -> None:
    ref = py_literal(REF / "nova_parser.py", "NODE_KINDS")
    gds = gd_string_list(GD / "nova" / "nova_parser.gd", "NODE_KINDS")
    if ref is None:
        problems.append("parser: could not read the reference node kinds")
    else:
        compare_sets("parser node kinds", set(ref), set(gds))


def check_evaluator() -> None:
    ref = py_literal(REF / "nova_evaluator.py", "BUILTIN_ARITY")
    gds = gd_arity_map(GD / "nova" / "nova_evaluator.gd", "BUILTIN_ARITY")
    if ref is None:
        problems.append("evaluator: could not read the reference builtin table")
    else:
        compare_sets("builtins", set(ref), set(gds))
        for name in sorted(set(ref) & set(gds)):
            if ref[name] != gds[name]:
                problems.append("builtin %s(): arity %d in the reference, "
                                "%d in GDScript" % (name, ref[name], gds[name]))

    for name in ("MAX_CALL_DEPTH", "MAX_STEPS"):
        ref_value = py_literal(REF / "nova_evaluator.py", name)
        gd_value = gd_const_number(GD / "nova" / "nova_evaluator.gd", name)
        if ref_value is None or gd_value is None:
            problems.append("evaluator: %s missing from one implementation"
                            % name)
        elif float(ref_value) != gd_value:
            problems.append("evaluator: %s is %s in the reference, %s in "
                            "GDScript" % (name, ref_value, gd_value))


def check_host_functions() -> None:
    ref = py_literal(REF / "reactor_host.py", "HOST_FUNCTIONS")
    gds = gd_string_list(GD / "nova_bridge.gd", "HOST_FUNCTIONS")
    if ref is None:
        problems.append("host: could not read the reference registry")
    else:
        compare_sets("reactor host functions", set(ref), set(gds))


# --------------------------------------------------------------------------
# Conformance goldens
# --------------------------------------------------------------------------

def check_conformance() -> None:
    path = GD / "nova" / "conformance.json"
    if not path.exists():
        problems.append("conformance.json is missing -- run "
                        "python3 tools/gen_conformance.py")
        return
    try:
        import gen_conformance
    except Exception as exc:
        problems.append("cannot import gen_conformance: %s" % exc)
        return

    committed = json.loads(path.read_text(encoding="utf-8"))
    rebuilt = gen_conformance.build_doc()
    if committed == rebuilt:
        notes.append("conformance: %d cases + %d reactor frames, up to date"
                     % (len(rebuilt["cases"]),
                        len(rebuilt["reactor_trace"]["frames"])))
        return

    problems.append("conformance.json is stale -- the reference no longer "
                    "produces it. Run: python3 tools/gen_conformance.py")
    old = {c["name"]: c for c in committed.get("cases", [])}
    new = {c["name"]: c for c in rebuilt["cases"]}
    for name in sorted(set(old) | set(new)):
        if old.get(name) != new.get(name):
            problems.append("  case %r changed" % name)


def main() -> int:
    print("checking NovaLang reference <-> GDScript parity")
    check_physics()
    check_lexer()
    check_parser()
    check_evaluator()
    check_host_functions()
    check_conformance()

    for note in notes:
        print("  " + note)
    if problems:
        print("\n%d parity problem(s):" % len(problems))
        for p in problems:
            print("  FAIL  " + p)
        return 1
    print("\nparity OK -- both implementations describe the same language")
    return 0


if __name__ == "__main__":
    sys.exit(main())
