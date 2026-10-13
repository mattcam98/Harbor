# Harbor

One iOS app for installing, signing, refreshing and running sideloaded apps
with a personal Apple ID.

Harbor combines the roles of SideStore (on-device signing and refresh),
LiveContainer (running apps inside one container) and iloader (first install
and pairing from a computer). See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
for what iOS allows, the decisions taken, and the phase plan.

## Status

Phase 2 of 7 is code-complete and tested against stand-ins; it has not yet
run against Apple, whose sign-in is blocked for tools like this one. The
container runtime of phase 3 runs on a real iPhone. Both device tests are
described in [docs/DEVICE-TEST.md](docs/DEVICE-TEST.md).

| Area | State |
| --- | --- |
| `HarborCore`: artifact and archive checks, signed manifests, secret policy, pairing records, deep-link policy, refresh planning, account limits, source catalogue, installed-app library, device contract, Mach-O reader and guest executable patcher | Unit-tested on macOS, Linux and Windows. The patcher is compared byte for byte with LiveContainer's original in CI |
| `HarborPlatform`: keychain secret store | Tested inside the app on the iOS Simulator |
| `HarborSigning`: sign-in with two-factor, on-device anisette, signing identity, certificates, App IDs and profiles, capability and app-group sync, bundle signing, install and refresh pipeline | Unit-tested against a fake developer portal and device |
| `HarborDevice`: minimuxer transport | Unit-tested on the iOS Simulator against a fake minimuxer |
| App | A plain working screen for pairing, sign-in, certificate choices, install and refresh. Builds for the simulator and for devices (unsigned IPA from CI) |
| Container runtime | LiveContainer's engine is built into the app unmodified. A guest app can be added, signed and launched; on the iOS Simulator a test guest runs inside Harbor and sees itself as its own app (`scripts/check.sh guest`). On an iPhone 16 Pro with iOS 27.0 (13 October 2026) the test guest, signed with an imported development certificate, was accepted by iOS and ran, and so did one large real app with tweak libraries. That is two apps; compatibility more widely is unknown |
| Sources | Sources in the AltStore format can be added by address, browsed and searched, and an app added from one to the container. Parsing and the download rules are unit-tested; a large real source (821 apps) reads and displays on the simulator. On the iPhone, one app was downloaded from that source, signed and run |
| Running beside Harbor | A guest runs in its own process (LiveContainer's LiveProcess extension, unmodified) while Harbor stays open: a button at the screen edge returns to Harbor, several guests can be open at once, and the guest's process has neither Harbor's keychain group nor its files. Works on the iOS 27 simulator, two guests at once (`scripts/check.sh guest`). Not yet run on a device |
| Home Screen shortcuts | Each guest can be given its own Home Screen icon: a web-clip profile made on the device, served to Safari from the device itself. The link it opens launches the app in Harbor. Profile contents and the server are unit-tested; installing one has not been done on a device |
| Harbor Setup | `Setup/` (Rust, the part that talks to the iPhone; builds on Windows and macOS) lists devices, finds Harbor, makes a pairing file and delivers it and the signing certificate into Harbor, and installs a signed app. Tested on an iPhone 16 Pro with iOS 27.0 over a cable from a Mac: device listing, finding Harbor, pairing (lockdown and RemotePairing) and delivery. `harbor-setup-mac` (Swift) signs in with the Mac's own machine identity and signs with Harbor's pipeline. On 13 October 2026 `scripts/setup-mac.sh` signed in to a free Apple ID, registered the device, made a certificate, two App IDs and an app group, signed Harbor with its extension and installed it on the iPhone, with no part done by Xcode; Harbor then took its pairing file and certificate. Windows cannot sign in yet (no accepted machine identity there). No graphical interface yet |
| Designed UI, background automation | Not started |

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

To build and test everything on a Mac, as the CI workflow used to on every
push:

```sh
bash scripts/check.sh
```

It reports each stage, prints the errors of any that fail, and leaves an
unsigned `dist/Harbor.ipa`. The GitHub Actions workflow still exists but only
runs when started by hand.

## Licence

AGPL-3.0. Harbor builds on SideStore, minimuxer and LiveContainer, which are
AGPL-3.0.
