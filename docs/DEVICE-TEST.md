# First test on a real device

Everything so far has been tested against stand-ins for Apple and for the
device. This is the first run against the real things. Expect something to
fail; the point is to find out what.

## Test 1: run an app inside Harbor

This does not need Harbor to sign in to Apple, so it works during the block
described below. On the iOS Simulator it already passes
(`bash scripts/check.sh guest`); a real iPhone adds the part the simulator
skips, which is iOS accepting the guest's signature.

On the Mac:

1. In Xcode, Settings → Accounts, add your Apple ID.
2. Connect the iPhone, unlock it and trust the Mac. Developer Mode must be on
   (Settings → Privacy & Security → Developer Mode).
3. Set `DEVELOPMENT_TEAM` in `CodeSigning.xcconfig` to your team identifier
   and run `bash scripts/generate-project.sh`. (Or, in Xcode, choose your
   "(Personal Team)" under Signing & Capabilities for each of the targets
   Harbor, LiveContainerShared, TweakLoader and HarborUI.)
4. Open `Harbor.xcodeproj`, select the iPhone as the destination and press
   Run. On the phone, trust the developer certificate (Settings → General →
   VPN & Device Management).
5. Export the certificate Xcode just created: Keychain Access → login → My
   Certificates → "Apple Development: …" → right-click → Export, as a `.p12`
   with a password of your choosing.
6. Build the test guest: `bash scripts/build-test-guest.sh`.
7. AirDrop the `.p12` and `dist/HarborTestGuest.ipa` to the iPhone and save
   both to Files.

On the iPhone, in Harbor:

1. **Import signing certificate**, pick the `.p12`, enter its password.
   Expected: "Signing certificate imported".
2. **Add an app to Harbor**, pick `HarborTestGuest.ipa`. Expected: "Smoke Test
   Guest" appears in the list.
3. Tap it. Expected: Harbor closes and reopens as a teal screen reading "Hello
   from the guest / com.example.harborguest".
4. Close it and open Harbor again from the Home Screen. Expected: Harbor's own
   screen, and no error alert.

If any step shows an alert, its exact text is what to send back. Delete the
`.p12` from Files and from the Mac once it is imported: it is your signing key.

## Test 2: sign in, install and refresh

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

What it does not do yet: run guest apps, refresh in the background, or
anything with JIT.

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

1. Get `Harbor.ipa`. On a Mac, `bash scripts/check.sh ipa` builds it as
   `dist/Harbor.ipa` with its SHA-256 beside it.

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
  certificate on the Apple ID. When Harbor needs its own it shows the existing
  ones and asks whether to revoke any. Keep them all unless Apple then refuses
  with a certificate limit error; note which choice you made.
- Capabilities a free Apple ID cannot have, such as push, are listed under the
  app after install; those features will not work.
- An app that uses app groups installs, but may not find its shared data.
- An encrypted (App Store) IPA is refused with "Encrypted app".
