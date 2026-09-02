#!/usr/bin/env bash
# Everything that can be verified without opening Godot.
#
#   unit tests        the NovaLang reference: lexer, parser, evaluator,
#                     modules, the reactor DSL, the physics, the host
#   check_parity.py   the shipping GDScript and the reference describe the
#                     same language, and the conformance goldens are fresh
#   check_project.py  the Godot project is structurally sound, Python-free,
#                     and every .nova policy parses
#   --selftest        a headless five-minute reactor run
#
# The one thing this cannot do is run GDScript. For that:
#   godot --headless --path godot --script res://scripts/nova/parity_check.gd
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== reference unit tests ===================================="
python3 -m unittest discover -s reference/tests -t . -q

echo
echo "== reference <-> gdscript parity ==========================="
python3 tools/check_parity.py

echo
echo "== godot project structure ================================="
python3 tools/check_project.py

echo
echo "== novalang policies ======================================="
python3 reference/reactor_host.py --validate --rules reactor_rules.nova \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  reactor_rules.nova:", d["title"], "--", len(d["rules"]), "rules,", len(d["faults"]), "faults")'
python3 reference/reactor_host.py --validate --rules daedalus_rules.nova \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  daedalus_rules.nova:", d["title"], "--", len(d["rules"]), "rules,", len(d["faults"]), "faults")'

echo
echo "== daedalus stage 1 data ==================================="
python3 - <<'PY'
import random, sys
sys.path.insert(0, "reference")
from nova_vm import NovaVM
import reactor_host as host
vm = NovaVM(random.Random(7), base_dir=host.RULES_DIR)
for n in host.HOST_FUNCTIONS:
    vm.register_function(n, lambda a: None)
assert vm.load_file("daedalus_rules.nova"), vm.error
ships = vm.get_global("SHIPS")
print("  %d hulls, %d sectors, %d danger bands"
      % (len(ships), len(vm.get_global("SECTORS")),
         len(vm.get_global("DANGER"))))
for key in vm.get_global("SHIP_ORDER"):
    s = ships[key]
    print("    %-9s %-14s shield %6.0f  hull %6.0f  spd %5.0f  turn %4.0f"
          % (key, s["class"], s["shield"], s["hull"], s["speed"], s["turn"]))
print("  power: %.0f cap, %+.0f/s idle, %+.0f/s shields+thrust, %+.0f/s cloak+thrust"
      % (vm.get_global("POWER")["max"],
         vm.call_function("power_balance", [False, False, False]),
         vm.call_function("power_balance", [True, False, True]),
         vm.call_function("power_balance", [True, True, False])))
PY

echo
echo "== headless reactor run ===================================="
python3 reference/reactor_host.py --selftest --seconds 300 \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  %.0fx realtime, %s us/step, final state %s" % (d["realtime_factor"], d["us_per_step"], d["final"]["state"])); [print("   ", e) for e in d["events"]]'

echo
echo "all checks passed"
