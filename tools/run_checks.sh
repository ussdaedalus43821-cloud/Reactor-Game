#!/usr/bin/env bash
# Everything that can be verified without opening Godot.
#
#   python3 unit tests   physics, NovaLang interpreter, bridge protocol
#   check_parity.py      the Python and GDScript runtimes agree
#   check_project.py     the Godot project is structurally sound
#   --selftest           a headless 5-minute reactor run
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== unit tests =============================================="
python3 -m unittest discover -s godot/sim/tests -t . -q

echo
echo "== python <-> gdscript parity =============================="
python3 tools/check_parity.py

echo
echo "== godot project structure ================================="
python3 tools/check_project.py

echo
echo "== novalang policy ========================================="
python3 godot/sim/reactor_server.py --validate

echo
echo "== headless reactor run ===================================="
python3 godot/sim/reactor_server.py --selftest --seconds 300

echo
echo "all checks passed"
