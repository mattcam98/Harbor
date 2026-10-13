# First test on a real device

Everything so far has been tested against stand-ins for Apple and for the
device. This is the first run against the real things. Expect something to
fail; the point is to find out what.

## Blocked as of 13 October 2026

Since 12 October 2026 Apple's sign-in endpoint answers every third-party
sideloading tool with `-80045: This action cannot be completed at this time.`
It happens before the password is checked, and affects iloader, AltStore and
AltServer, SideStore, Sideloadly, xtool and PlumeImpactor alike (see
nab138/iloader#859, altstoreio/AltStore#1828, xtool-org/xtool#329). Signing in
through Xcode itself still works.

Harbor signs in the same way those tools do, through SideSign, so step 3
below is expected to fail the same way until the upstream projects find what
changed. Route A cannot be used at all meanwhile, because iloader has to sign
in to install Harbor. Route B still installs Harbor, which is enough to test
steps 1 and 2.

## What this build does

Signs in to an Apple ID, generates anisette data on the device, creates a
signing certificate, registers App IDs, signs an IPA and installs it through
the loopback VPN. It can then refresh that app's provisioning profiles.

What it does not do yet: revoke certificates, sync app capabilities or app
groups, run guest apps, refresh in the background, or anything with JIT.

## Which Apple ID

Your main Apple ID works. Harbor creates a development certificate, registers
App IDs and registers the device on it, as iloader and SideStore do, and this
build never revokes anything. A separate Apple ID is only extra caution for a
first run against Apple's servers.

## What you need

- An iPhone or iPad on iOS 17 or later, with Developer Mode on.
- LocalDevVPN installed on the device from the App Store.
- A free slot: a free Apple ID allows three sideloaded apps at once, and
  Harbor plus the test app need two of them.
- A small test IPA that is not encrypted (not one extracted from the App Store).

## Route A: install with iloader (Windows or Mac, no Xcode)

1. Get `Harbor.ipa`. Every CI run on `main` builds one as the artifact
   `Harbor-unsigned-ipa`, with its SHA-256 beside it:

   ```sh
   gh run download --repo mattcam98/Harbor --name Harbor-unsigned-ipa --dir dist
   ```

2. Connect the device by USB and open iloader. Sign in, select the device,
   choose to install a custom IPA and pick `Harbor.ipa`.
3. In iloader, export the pairing file for the device and save it somewhere
   the phone can read, such as iCloud Drive.
4. On the device, trust the developer certificate when iOS asks
   (Settings → General → VPN & Device Management).

The pairing file gives full access to the device's install services. Delete
the exported copy once Harbor has imported it.

## Route B: build with Xcode on a Mac

Needs Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
git clone --recurse-submodules git@github.com:mattcam98/Harbor.git
cd Harbor
bash scripts/generate-project.sh
open Harbor.xcodeproj
```

In Xcode, add your Apple ID under Settings → Accounts. Select the Harbor
target, open Signing & Capabilities and choose your name with "(Personal
Team)" in the Team menu. Change the bundle identifier if Xcode reports it is
taken. Select your device and run, then trust the developer certificate on
the device as in route A. You still need a pairing file made on a computer.

## Steps in the app

Do them in order and note where it stops.

1. Open LocalDevVPN and connect it.
2. In Harbor, **Import pairing file**. Expected: "Connected" and the last six
   characters of the device identifier.
3. **Sign in** with the secondary Apple ID. Expected: a verification code
   prompt, then "Signed in" with the address. The first sign-in downloads
   a few megabytes of provisioning libraries.
4. **Install an app** and pick the test IPA. Expected: the banner steps
   through unpacking, registering, certificate, profiles, signing and
   installing, and the app appears on the Home Screen and in the list with an
   expiry about seven days out.
5. Launch the installed app.
6. Swipe the app in the list and **Refresh**. Expected: the expiry moves.

## What to send back

For any step that fails: the step number, and the exact title and text of the
alert Harbor shows. If Xcode is attached, the console output around the
failure helps too. Do not send the pairing file, your password or any
screenshot that shows them.

## Known rough edges

- Installing Harbor with iloader or Xcode already puts one development
  certificate on the Apple ID. Harbor then asks Apple for its own. If Apple
  refuses with a certificate limit error, report it: this build never revokes
  certificates, and the screen that asks which one to revoke is not built yet.
- An app that relies on capabilities such as app groups or push will install
  but those features will not work.
- An encrypted (App Store) IPA signs and installs but will not launch.
