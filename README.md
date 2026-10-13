# Harbor

One iOS app for installing, signing, refreshing and running sideloaded apps
with a personal Apple ID.

Harbor combines the roles of SideStore (on-device signing and refresh),
LiveContainer (running apps inside one container) and iloader (first install
and pairing from a computer). See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
for what iOS allows, the decisions taken, and the phase plan.

## Status

Phase 2 of 7 is code-complete and passing in CI. It has not yet run against
Apple or a real device: that first run is described in
[docs/DEVICE-TEST.md](docs/DEVICE-TEST.md).

| Area | State |
| --- | --- |
| `HarborCore`: artifact and archive checks, signed manifests, secret policy, pairing records, deep-link policy, refresh planning, account limits, source catalogue, installed-app library, device contract, Mach-O reader and guest executable patcher | Unit-tested on macOS, Linux and Windows. The patcher is compared byte for byte with LiveContainer's original in CI |
| `HarborPlatform`: keychain secret store | Tested inside the app on the iOS Simulator |
| `HarborSigning`: sign-in with two-factor, on-device anisette, signing identity, certificates, App IDs and profiles, capability and app-group sync, bundle signing, install and refresh pipeline | Unit-tested against a fake developer portal and device |
| `HarborDevice`: minimuxer transport | Unit-tested on the iOS Simulator against a fake minimuxer |
| App | A plain working screen for pairing, sign-in, certificate choices, install and refresh. Builds for the simulator and for devices (unsigned IPA from CI) |
| Container runtime (loading and running guests), designed UI, background automation, setup tool | Not started |

## Build and test

The core runs anywhere with a Swift 6 toolchain (macOS, Linux, Windows):

```sh
cd Packages/HarborCore
swift test
```

The app needs macOS with Xcode 16 and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
bash scripts/generate-project.sh
open Harbor.xcodeproj
```

The script fetches the submodules, creates `CodeSigning.xcconfig` from the
sample, generates the project and installs the dependency lockfile.

## Licence

AGPL-3.0. Harbor builds on SideStore, minimuxer and LiveContainer, which are
AGPL-3.0.
