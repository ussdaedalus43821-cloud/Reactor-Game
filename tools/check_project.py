#!/usr/bin/env python3
"""
check_project.py -- static checks on the Godot project.

Godot reports a malformed .tscn or a broken res:// path only when you open
the editor, and a typo in a node path only when the scene actually runs.
This catches the whole class of problem from the command line:

  * every res:// path mentioned in a script, scene or config file exists
  * every .tscn parses: unique ext_resource ids, no dangling
    ExtResource() reference, every node's parent path defined before use,
    load_steps consistent with the resources declared
  * every $NodePath in control_room.gd resolves against Main.tscn
  * .gd files: tabs-only indentation, balanced brackets, no duplicated
    function name in a file, no duplicated class_name across the project
  * the export presets actually ship reactor_rules.nova

Run from the repository root:  python3 tools/check_project.py
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT = ROOT / "godot"

problems: list[str] = []
notes: list[str] = []


def problem(msg: str) -> None:
    problems.append(msg)


def res_to_path(res: str) -> pathlib.Path:
    return PROJECT / res[len("res://"):]


# --------------------------------------------------------------------------
# res:// references
# --------------------------------------------------------------------------

RES_RE = re.compile(r'res://[A-Za-z0-9_./\-]+')


def check_res_paths() -> None:
    checked = 0
    for path in sorted(PROJECT.rglob("*")):
        if path.is_dir() or path.suffix not in (".gd", ".tscn", ".godot", ".cfg",
                                                ".gdshader"):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for ref in sorted(set(RES_RE.findall(text))):
            checked += 1
            if not res_to_path(ref).exists():
                problem("%s references %s, which does not exist"
                        % (path.relative_to(ROOT), ref))
    notes.append("%d res:// references resolved" % checked)


# --------------------------------------------------------------------------
# Scenes
# --------------------------------------------------------------------------

HEADER_RE = re.compile(r'^\[gd_scene([^\]]*)\]')
EXT_RE = re.compile(r'^\[ext_resource ([^\]]*)\]')
SUB_RE = re.compile(r'^\[sub_resource ([^\]]*)\]')
NODE_RE = re.compile(r'^\[node ([^\]]*)\]')
# Section attributes come both quoted (name="Foo") and bare (format=3,
# instance=ExtResource("id")), so accept either and unquote afterwards.
ATTR_RE = re.compile(r'(\w+)=("[^"]*"|[^\s\]]+)')
EXTREF_RE = re.compile(r'ExtResource\("([^"]+)"\)')
SUBREF_RE = re.compile(r'SubResource\("([^"]+)"\)')


def attrs_of(blob: str) -> dict[str, str]:
    return {k: v[1:-1] if v.startswith('"') else v
            for k, v in ATTR_RE.findall(blob)}


def check_scene(path: pathlib.Path) -> dict:
    text = path.read_text(encoding="utf-8")
    rel = path.relative_to(ROOT)
    lines = text.splitlines()

    if not lines or not HEADER_RE.match(lines[0]):
        problem("%s does not start with a [gd_scene] header" % rel)
        return {}

    header = attrs_of(HEADER_RE.match(lines[0]).group(1))
    if header.get("format") != "3":
        problem("%s is not format=3 (Godot 4)" % rel)

    ext_ids: dict[str, str] = {}
    sub_ids: set[str] = set()
    nodes: list[tuple[str, str]] = []      # (name, parent)
    node_paths: set[str] = {"."}
    root_name = ""

    for line in lines:
        m = EXT_RE.match(line)
        if m:
            attrs = attrs_of(m.group(1))
            rid = attrs.get("id", "")
            if rid in ext_ids:
                problem("%s declares ext_resource id %r twice" % (rel, rid))
            ext_ids[rid] = attrs.get("path", "")
            continue
        m = SUB_RE.match(line)
        if m:
            sub_ids.add(attrs_of(m.group(1)).get("id", ""))
            continue
        m = NODE_RE.match(line)
        if m:
            attrs = attrs_of(m.group(1))
            name = attrs.get("name", "")
            parent = attrs.get("parent")
            if parent is None:
                if root_name:
                    problem("%s declares a second root node %r" % (rel, name))
                root_name = name
            else:
                if parent not in node_paths:
                    problem("%s: node %r has parent %r, which is not defined "
                            "above it" % (rel, name, parent))
                nodes.append((name, parent))
                node_paths.add(name if parent == "." else "%s/%s" % (parent, name))
            if "instance" not in attrs and "type" not in attrs \
                    and "instance_placeholder" not in attrs:
                problem("%s: node %r has neither type= nor instance="
                        % (rel, name))

    for rid in sorted(set(EXTREF_RE.findall(text))):
        if rid not in ext_ids:
            problem("%s uses ExtResource(%r) with no matching declaration"
                    % (rel, rid))
    for rid in sorted(set(SUBREF_RE.findall(text))):
        if rid not in sub_ids:
            problem("%s uses SubResource(%r) with no matching declaration"
                    % (rel, rid))

    declared = int(header.get("load_steps", "1"))
    expected = len(ext_ids) + len(sub_ids) + 1
    if declared != expected:
        problem("%s says load_steps=%d but declares %d resources (expected %d)"
                % (rel, declared, expected - 1, expected))

    return {"root": root_name, "children": {n for n, _ in nodes},
            "paths": node_paths}


def check_scenes() -> dict[str, dict]:
    scenes = {}
    for path in sorted(PROJECT.rglob("*.tscn")):
        scenes[str(path.relative_to(PROJECT))] = check_scene(path)
    notes.append("%d scenes parsed" % len(scenes))
    return scenes


# --------------------------------------------------------------------------
# $NodePath references from the main script
# --------------------------------------------------------------------------

DOLLAR_RE = re.compile(r'\$([A-Za-z_][A-Za-z0-9_/]*)')


def check_node_paths(scenes: dict[str, dict]) -> None:
    main = scenes.get("scenes/Main.tscn")
    if not main:
        problem("scenes/Main.tscn is missing")
        return
    script = PROJECT / "scripts" / "control_room.gd"
    text = script.read_text(encoding="utf-8")
    refs = sorted(set(DOLLAR_RE.findall(text)))
    for ref in refs:
        if ref not in main["paths"]:
            problem("control_room.gd uses $%s but Main.tscn has no such node"
                    % ref)
    notes.append("%d $NodePath references resolved against Main.tscn" % len(refs))


# --------------------------------------------------------------------------
# GDScript hygiene
# --------------------------------------------------------------------------

FUNC_RE = re.compile(r'^(\t*)func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(')
CLASSNAME_RE = re.compile(r'^class_name\s+([A-Za-z_][A-Za-z0-9_]*)', re.M)


def check_gdscript() -> None:
    class_names: dict[str, str] = {}
    count = 0
    for path in sorted(PROJECT.rglob("*.gd")):
        count += 1
        rel = path.relative_to(ROOT)
        text = path.read_text(encoding="utf-8")

        for i, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if line.startswith(" ") and stripped and not stripped.startswith("#"):
                problem("%s:%d indents with spaces; GDScript here uses tabs"
                        % (rel, i))
                break

        depth = {"(": 0, "[": 0, "{": 0}
        pairs = {")": "(", "]": "[", "}": "{"}
        for line in text.splitlines():
            in_string = ""
            for ch in line:
                if in_string:
                    if ch == in_string:
                        in_string = ""
                    continue
                if ch in "\"'":
                    in_string = ch
                elif ch == "#":
                    break                      # comment: prose, not code
                elif ch in depth:
                    depth[ch] += 1
                elif ch in pairs:
                    depth[pairs[ch]] -= 1
        for opener, n in depth.items():
            if n != 0:
                problem("%s has unbalanced '%s' (%+d)" % (rel, opener, n))

        seen: dict[str, int] = {}
        for i, line in enumerate(text.splitlines(), 1):
            m = FUNC_RE.match(line)
            if m and m.group(1) == "":          # top-level funcs only
                name = m.group(2)
                if name in seen:
                    problem("%s defines func %s() twice (lines %d and %d)"
                            % (rel, name, seen[name], i))
                seen[name] = i

        for m in CLASSNAME_RE.finditer(text):
            name = m.group(1)
            if name in class_names:
                problem("class_name %s declared in both %s and %s"
                        % (name, class_names[name], rel))
            class_names[name] = str(rel)

    notes.append("%d GDScript files checked, %d class_names declared"
                 % (count, len(class_names)))


# --------------------------------------------------------------------------
# Project + export configuration
# --------------------------------------------------------------------------

def check_config() -> None:
    project_file = PROJECT / "project.godot"
    text = project_file.read_text(encoding="utf-8")
    m = re.search(r'run/main_scene="([^"]+)"', text)
    if not m:
        problem("project.godot has no run/main_scene")
    elif not res_to_path(m.group(1)).exists():
        problem("project.godot main_scene %s does not exist" % m.group(1))

    presets = PROJECT / "export_presets.cfg"
    if not presets.exists():
        problem("export_presets.cfg is missing")
        return
    ptext = presets.read_text(encoding="utf-8")
    names = re.findall(r'^name="([^"]+)"', ptext, re.M)
    for required in ("macOS", "iOS", "Web"):
        if required not in names:
            problem("export_presets.cfg has no %s preset" % required)

    # Every preset must ship the NovaLang policy, or the exported build has
    # no control logic at all.
    filters = re.findall(r'^include_filter="([^"]*)"', ptext, re.M)
    if len(filters) != len(names):
        problem("export_presets.cfg: %d presets but %d include_filter lines"
                % (len(names), len(filters)))
    for name, flt in zip(names, filters):
        if "*.nova" not in flt:
            problem("the %s preset does not include *.nova, so the exported "
                    "build would have no control policy" % name)
    notes.append("%d export presets checked: %s" % (len(names), ", ".join(names)))


def main() -> int:
    if not PROJECT.exists():
        print("no godot/ project directory found")
        return 2
    check_res_paths()
    scenes = check_scenes()
    check_node_paths(scenes)
    check_gdscript()
    check_config()

    for note in notes:
        print("  " + note)
    if problems:
        print("\n%d problem(s):" % len(problems))
        for p in problems:
            print("  FAIL  " + p)
        return 1
    print("\nproject structure OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
