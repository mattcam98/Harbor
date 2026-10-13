#!/usr/bin/env bash
# Prints the identifier of the newest available iPhone simulator.
set -euo pipefail

xcrun simctl list devices available -j | python3 -c '
import json, sys
runtimes = json.load(sys.stdin)["devices"]
phones = [d for name in sorted(runtimes) if "iOS" in name
          for d in runtimes[name] if d["name"].startswith("iPhone")]
if not phones:
    sys.exit("No iPhone simulator is installed. Add one in Xcode > Settings > Components.")
print(phones[-1]["udid"])'
