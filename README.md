# Harbor

One iOS app for installing, signing, refreshing and running sideloaded apps
with a personal Apple ID.

Harbor combines the roles of SideStore (on-device signing and refresh),
LiveContainer (running apps inside one container) and iloader (first install
and pairing from a computer). See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
for what iOS allows, the decisions taken, and the phase plan.

## Status

Phase 2 of 7 has started. The app is an empty shell; it cannot sign or
install anything yet.

| Area | State |
| --- | --- |
| `HarborCore`: artifact verification, signed manifests, secret policy, pairing validation, deep-link policy, refresh planning, account limits, source catalogue | Built and unit-tested |
| `HarborPlatform`: keychain secret store | Written; tested in the app's test bundle on the iOS Simulator in CI |
| `HarborSigning`: signing identity storage, certificate provisioning, App ID and profile provisioning with limit checks | Unit-tested against a fake developer portal; not yet run against Apple |
| App shell and Xcode project (`project.yml`) | Placeholder screen only |
| Apple ID sign-in, anisette, bundle signing, device transport, container engine, UI, automation, setup tool | Not started |

## Build and test

The core runs anywhere with a Swift 6 toolchain (macOS, Linux, Windows):

```sh
cd Packages/HarborCore
swift test
```

The app needs macOS with Xcode 16 and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
git submodule update --init
xcodegen generate
open Harbor.xcodeproj
```

## Licence

AGPL-3.0. Harbor builds on SideStore, minimuxer and LiveContainer, which are
AGPL-3.0.
