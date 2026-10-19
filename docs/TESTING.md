# Testing on a device

`scripts/check.sh` covers everything the simulator can: unit tests, the app's
tests, and a guest app run inside Harbor (`bash scripts/check.sh guest`).
What the simulator skips is signing, pairing and talking to Apple. These are
the checks to run on a real iPhone before a release.

Use your own Apple ID and devices. Never share a pairing record, a `.p12`,
your password, or screenshots that show them.

## Before you start

- An iPhone on iOS 17 or later with Developer Mode on (Settings › Privacy &
  Security › Developer Mode).
- LocalDevVPN from the App Store.
- A free app slot: a free Apple ID allows three sideloaded apps, Harbor
  included, and ten new App IDs a week. Harbor uses two.
- An unencrypted test app. `bash scripts/build-test-guest.sh` makes
  `dist/HarborTestGuest.ipa`.

## 1. Install with Harbor Setup

On a Mac with Apple silicon, the iPhone connected and unlocked:

    bash scripts/setup-mac.sh --apple-id you@example.com

It asks for your password (not shown, not stored) and Apple's verification
code, signs Harbor and installs it. Trust your Apple ID on the iPhone in
Settings › General › VPN & Device Management, turn on LocalDevVPN and open
Harbor.

Expected: Get Started no longer lists pairing or the certificate, and
Settings › This iPhone says Connected.

## 2. Apps inside Harbor

1. Apps › + › Add from Files, pick the test app. Expected: it's listed.
2. Tap it. Expected: it opens with a small round button at the edge; tapping
   the button returns to Harbor, with the app under Open.
3. Open a second app, touch and hold the button. Expected: a menu to switch
   between them or close one. A switched-to app is where you left it.
4. Touch and hold an app › Add to Home Screen and follow the steps.
   Expected: its icon opens it in Harbor, even after Harbor is closed.

If an app won't open beside Harbor, try Open Full Screen and note the app.

## 3. Sign in, install and renew

1. Settings › Sign In. Expected: a verification code prompt, then your
   Apple ID under Signed In.
2. Apps › + › Install on Home Screen, pick the test app. Expected: the
   banner steps through signing and installing, and the app appears on the
   Home Screen and under On Home Screen.
3. Swipe it › Renew. Expected: its expiry moves forward.
4. Tap Renew next to Harbor's expiry. Expected: a new date about seven days
   out, kept after Harbor is closed and reopened.

## 4. Automatic renewal

1. Settings › Automatic Renewal › Add to Shortcuts, and follow the steps.
2. Create the Time of Day automation as shown.
3. Tap Run Now. Expected: Harbor opens, returns to Shortcuts, and the status
   in Harbor says Working with the time it ran.
4. Turn off LocalDevVPN and tap Run Now again. Expected: after two retries
   Shortcuts shows "Turn on LocalDevVPN".

## 5. Pair this iPhone (iOS 27 and later)

1. Connect to Wi-Fi and turn on LocalDevVPN.
2. Settings › Pair Again (or Pair This iPhone) › Start. Allow Local Network
   and notifications.
3. Go straight to Settings › Privacy & Security › Developer Mode and tap
   Pair with Harbor. Enter the code from Harbor's notification.
4. Back in Harbor. Expected: Paired, and This iPhone says Connected.
5. Restart the iPhone, turn on LocalDevVPN and open Harbor. Expected: still
   Connected.

If Pair with Harbor doesn't appear, check Settings › Privacy & Security ›
Local Network › Harbor is on, and that the iPhone is on Wi-Fi. Don't tap
Cancel on a Developer Mode prompt: the menu can then vanish until a restart.

## Reporting a failure

Say which step failed and copy the alert's title and text exactly. Remove
your Apple ID and anything that identifies your device.
