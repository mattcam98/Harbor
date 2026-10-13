#!/usr/bin/env bash
# Exports SIM_UDID: the newest available iPhone simulator on this runner.
set -euo pipefail

udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
runtimes = json.load(sys.stdin)["devices"]
phones = [d for name in sorted(runtimes) if "iOS" in name
          for d in runtimes[name] if d["name"].startswith("iPhone")]
print(phones[-1]["udid"])')

echo "SIM_UDID=$udid" >> "$GITHUB_ENV"
echo "Using simulator $udid"
