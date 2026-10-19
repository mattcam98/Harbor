# Harbor

Install and run your own apps on iPhone with a free Apple ID. Harbor signs
them on the phone, runs them inside itself so they don't count toward
Apple's three-app limit, and renews everything before the seven days a free
Apple ID allows run out.

Harbor brings together what SideStore (signing and renewal on the device),
LiveContainer (running apps inside one container) and iloader (first install
from a computer) each do. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
explains what iOS allows and how Harbor is built.

## What you need

- An iPhone or iPad on iOS 17 or later, with Developer Mode on.
- An Apple ID. A free one works.
- LocalDevVPN, free on the App Store. Harbor reaches the iPhone's own
  install service through it.
- For the first install, a Mac with Apple silicon and a cable.

## Install

1. Build Harbor Setup (see below) or download it from a release of this
   repository, connect the iPhone and run `install-harbor`. It signs Harbor
   with your Apple ID, installs it, and hands Harbor this iPhone's pairing
   record and its signing certificate. Your password goes only to Apple.
2. On the iPhone, trust your Apple ID in Settings › General › VPN & Device
   Management, then turn on LocalDevVPN.
3. Open Harbor and follow **Get Started**.

On iOS 27 and later Harbor can pair with the iPhone by itself (Settings ›
Pair This iPhone), so a lost pairing record doesn't need the Mac.

## Renewing

A free Apple ID signs apps for seven days. Harbor renews itself and the apps
it installed from the phone:

- **By hand**: tap **Renew** on the Apps tab.
- **Automatically**: Settings › Automatic Renewal sets up a daily Shortcuts
  automation in about a minute. See [docs/SHORTCUTS.md](docs/SHORTCUTS.md).
- **Reminders**: optional notifications a day and three hours before Harbor
  expires.

Times are always shown in the iPhone's own time zone. A profile lasts exactly
seven days, so when the clocks change during that week the expiry time moves
by an hour on the clock, not in fact.

## Build from source

The core runs anywhere with a Swift 6 toolchain:

```sh
cd Packages/HarborCore
swift test
```

The app needs macOS with Xcode 16 or later and
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
git clone --recurse-submodules <this repository>
cd Harbor
bash scripts/generate-project.sh
open Harbor.xcodeproj
```

`generate-project.sh` fetches the submodules, creates `CodeSigning.xcconfig`
from [CodeSigning.xcconfig.sample](CodeSigning.xcconfig.sample) and generates
the project. Put your team identifier in `CodeSigning.xcconfig` to build for a
device. That file is ignored by Git; never commit it, or any certificate,
profile or pairing record.

To build and test everything:

```sh
bash scripts/check.sh
```

It reports each stage and leaves an unsigned `dist/Harbor.ipa`.
[docs/RELEASING.md](docs/RELEASING.md) covers publishing Harbor Setup and the
download page, and [docs/TESTING.md](docs/TESTING.md) testing on a device.

## Privacy

Harbor has no server and collects nothing. Your Apple ID password goes only
to Apple, and is kept only if you turn on Remember Password. The session,
pairing record and signing key stay in the iPhone's keychain, never synced.
Signing in uses a public anisette server, which provides a machine identity
for Apple and never sees your Apple ID.

## Licence

AGPL-3.0. Harbor builds on SideStore, minimuxer and LiveContainer, which are
AGPL-3.0.
