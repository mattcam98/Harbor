# Harbor

One iOS app for installing, signing, refreshing and running sideloaded apps
with a personal Apple ID.

Harbor combines the roles of SideStore (on-device signing and refresh),
LiveContainer (running apps inside one container) and iloader (first install
and pairing from a computer). See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
for what iOS allows, the decisions taken, and the phase plan.

## Status

Phase 1 of 7. The platform-independent core exists and is tested. There is no
installable app yet.

| Area | State |
| --- | --- |
| `HarborCore`: artifact verification, signed manifests, secret policy, pairing validation, deep-link policy, refresh planning, account limits, source catalogue | Built and unit-tested |
| Keychain, signing, device transport, container engine, UI, automation, setup tool | Not started |

## Build and test the core

```sh
cd Packages/HarborCore
swift test
```

Works on macOS, Linux and Windows with a Swift 6 toolchain.

## Licence

AGPL-3.0. Harbor builds on SideStore, minimuxer and LiveContainer, which are
AGPL-3.0.
