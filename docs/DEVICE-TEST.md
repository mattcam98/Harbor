# First test on a real device

Everything so far has been tested against stand-ins for Apple and for the
device. This is the first run against the real things. Expect something to
fail; the point is to find out what.

## What this build does

Signs in to an Apple ID, generates anisette data on the device, creates a
signing certificate, registers App IDs, signs an IPA and installs it through
the loopback VPN. It can then refresh that app's provisioning profiles.

What it does not do yet: revoke certificates, sync app capabilities or app
groups, run guest apps, refresh in the background, or anything with JIT.

## Use a secondary Apple ID

Use an Apple ID you do not depend on. This build creates a development
certificate and App IDs on it, and it is talking to Apple's developer
services for the first time.

## What you need

- A Mac with Xcode 16 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- An iPhone or iPad on iOS 17 or later, with Developer Mode on.
- LocalDevVPN installed on the device from the App Store.
- A pairing file for the device, made on a computer (iloader can export
  one), saved somewhere the Files app can reach.
- A small test IPA that is not encrypted (not one extracted from the App Store).

## Build and install Harbor

```sh
git clone --recurse-submodules git@github.com:mattcam98/Harbor.git
cd Harbor
bash scripts/generate-project.sh
```

Edit `CodeSigning.xcconfig`: set `DEVELOPMENT_TEAM` to your team identifier,
and change `HARBOR_BUNDLE_ID` if Xcode reports it is taken. Then:

```sh
bash scripts/generate-project.sh
open Harbor.xcodeproj
```

Select your device and run. Trust the developer certificate on the device
when iOS asks (Settings → General → VPN & Device Management).

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

- If the Apple ID already has iOS development certificates from another tool,
  the certificate step may fail with a limit error. This build never revokes
  certificates; that needs its own confirmation screen.
- An app that relies on capabilities such as app groups or push will install
  but those features will not work.
- An encrypted (App Store) IPA signs and installs but will not launch.
