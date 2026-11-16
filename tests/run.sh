#!/usr/bin/env bash
# Runs the Going Once scenario tests on forever_sim, the headless Forever client from cjber/forever-core.
#
#   tests/run.sh                 # every scenario
#   tests/run.sh "trade good"    # scenarios whose name contains the text
#
# Needs luajit, python3 and git. tests/sim.sh fetches the sim at the commit pinned in tests/forever_sim.txt, with
# the Blizzard UI source and client data it runs against, into ~/.cache/goingonce-sim (GOINGONCE_CACHE moves it).
# FOREVER_SIM runs the tests on another forever_sim folder, such as a forever-core checkout's.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sim_env=$("$here/sim.sh")
while IFS='=' read -r name value; do
	export "$name=$value"
done <<<"$sim_env"

cd "$here"
exec luajit goingonce_test.lua "$@"
