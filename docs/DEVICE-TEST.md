# First test on a real device

Everything so far has been tested against stand-ins for Apple and for the
device. This is the first run against the real things. Expect something to
fail; the point is to find out what.

## Test 1: run an app inside Harbor

This does not need Harbor to sign in to Apple, so it works during the block
described below. On the iOS Simulator it passes
(`bash scripts/check.sh guest`); a real iPhone adds the part the simulator
skips, which is iOS accepting the guest's signature.

**Passed on 13 October 2026** on an iPhone 16 Pro with iOS 27.0, at commit
`86cef15`: the test guest showed its teal screen. Two things failed on the
way and are fixed: the guest has to be signed file by file under Harbor's
own identifier, with a certificate from the profile Harbor was installed
with, and the engine needs `Documents/Tweaks` to exist. Not checked in that
run: what `NSHomeDirectory()` returns in a guest on a device, and any real
app.

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
   with a password of your choosing. If two entries share that name, check
   the "Expires" column and take the one that has not expired: iOS only loads
   apps signed with a certificate this copy of Harbor was installed with, and
   an old one from an earlier Xcode sign-in is not that.
6. Build the test guest: `bash scripts/build-test-guest.sh`.
7. AirDrop the `.p12` and `dist/HarborTestGuest.ipa` to the iPhone and save
   both to Files.

On the iPhone, in Harbor:

1. **Import signing certificate**, pick the `.p12`, enter its password.
   Expected: "Signing certificate imported", with the certificate's name,
   expiry date and the end of its serial number underneath. An expired
   certificate, or one Harbor was not installed with, is refused here with an
   alert naming the ones that would work. **Replace signing certificate**
   swaps in a different file later.
2. **Add an app to Harbor**, pick `HarborTestGuest.ipa`. Expected: "Smoke Test
   Guest" appears in the list.
3. Tap it. Expected: Harbor closes and reopens as a teal screen reading "Hello
   from the guest / com.example.harborguest".
4. Close it and open Harbor again from the Home Screen. Expected: Harbor's own
   screen, and no error alert.

If any step shows an alert, its exact text is what to send back. "iOS rejected
the signature" ends with what iOS itself said and the error number, which is
the part that matters. Delete the
`.p12` from Files and from the Mac once it is imported: it is your signing key.

## Test 3: several apps, the way back, and Home Screen icons

This needs no Apple sign-in either. It does need a new build from Xcode,
because Harbor gained an extension and an app group: the first Run after
updating may take longer while Xcode registers them. If Xcode reports a
signing error for the target LiveProcess, open the project's Signing &
Capabilities tab for that target once and let it repair the profile.

On the iPhone, in Harbor, with at least two apps under "Run inside Harbor":

1. Tap an app. Expected: it opens full screen, with a small round button at
   the right edge.
2. Tap the button. Expected: Harbor's list, with the app under "Open now".
3. Tap a second app, then touch and hold the button. Expected: a menu with
   Harbor, the first app under "Switch to", and Close. Switch to the first
   app: it is where you left it, not restarted.
4. Drag the button somewhere else. Expected: it stays there next time.
5. In Harbor, touch and hold an app and choose **Add to Home Screen**, then
   follow the three steps shown. Expected: after installing the profile in
   Settings, the app's icon is on the Home Screen with its own name.
6. Close Harbor from the app switcher and tap the new icon. Expected: Harbor
   opens straight into that app.

What to send back if something fails: the alert text, or just say what
happened. Crash reports can be read off the phone from the Mac. If an app
that worked before does not open this way, touch and hold it and choose
**Open as the whole app**, which is the previous behaviour, and say which
app it was.

## Test 2: sign in, install and refresh

## Blocked as of 13 October 2026

Since 12 October 2026 Apple's sign-in endpoint answers every third-party
sideloading tool with `-80045: This action cannot be completed at this time.`
It happens before the password is checked, and affects iloader, AltStore and
AltServer, SideStore, Sideloadly, xtool and PlumeImpactor alike (see
nab138/iloader#859, altstoreio/AltStore#1828, xtool-org/xtool#329). Signing in
through Xcode itself still works.

The cause, measured on 13 October 2026 (see `docs/ARCHITECTURE.md`, section
8): Apple refuses the made-up machine identities those tools sign in with,
and Harbor's on-device sign-in uses the same kind. A real Mac's own identity
is still accepted. So signing in inside Harbor on the phone (step 3 below)
fails with a message saying so, Route A (iloader) cannot be used, and the
way to install without Xcode is Harbor Setup on a Mac, Test 4.

## Test 4: install with Harbor Setup from a Mac

This replaces pressing Run in Xcode. It signs in with your Apple ID using the
Mac's own identity, signs Harbor with Harbor's own signing code, installs it
over the cable, and gives Harbor a pairing file and its signing certificate.
It is the first time Harbor's signing code runs against Apple for real, so
expect something to need fixing.

In Terminal on the Mac, with the iPhone connected and unlocked:

    cd ~/Harbor
    bash scripts/setup-mac.sh --apple-id you@example.com

It asks for the password on the keyboard (not shown, not stored) and for the
six-digit code Apple sends. If the Apple ID already has certificates it asks
whether to keep or revoke them: keep is the safe answer while the copy
installed from Xcode is still in use.

Expected: the steps are printed one by one, ending with "Done". On the
phone, trust the developer in Settings > General > VPN & Device Management,
then open the new Harbor. It should show the pairing file as stored and the
signing certificate as imported without you doing anything.

Two things to know. It installs as a separate app from the copy Xcode
installed, with its own data: free Apple IDs get three apps and ten new app
identifiers a week, and this uses two identifiers. And to check Apple still
accepts the Mac without signing in at all:

    Packages/HarborSigning/.build/release/harbor-setup-mac check

What to send back: everything it printed from the first line that does not
look like the expected step, with the Apple ID removed.

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
