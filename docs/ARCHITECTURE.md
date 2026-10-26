# Harbor — architecture and plan

This document records what the platform is, what iOS allows it to do, the
decisions taken, and the order of work. Evidence for
claims about the three source projects is the reverse-engineering pass over
SideStore `0dd743f`, iloader `80142ff` and LiveContainer `4dbe0f9`.

## 1. What it is

One iOS app that installs, signs, refreshes and runs sideloaded apps with a
personal Apple ID, plus a small desktop tool that is needed once.

| Part | Role | Origin |
| --- | --- | --- |
| Harbor app (iOS 17+) | Store, signing, refresh, container, automation, UI | New shell around existing engines |
| Harbor Setup (desktop) | First install and pairing | New, small; same approach as iloader |
| LocalDevVPN (App Store) | Loopback tunnel so the app can reach the device's own services | Third party, unchanged |

Licence: AGPL-3.0. SideStore, minimuxer and LiveContainer are AGPL-3.0, so any
product that links them must be too. iloader's code is MIT; its name and logo
are reserved and are not used.

## 2. What iOS actually allows

These limits are not design choices. The plan works inside them.

| Capability | On device | Needs a computer once | Needs something else |
| --- | --- | --- | --- |
| Apple ID sign-in, 2FA | Yes | | Anisette data from a server that makes it on a real Mac (on-device ADI libraries are refused since October 2026; section 8) |
| Certificate, App ID, profile management | Yes | | |
| Re-signing an IPA | Yes | | |
| Installing / refreshing an app | Yes | | Pairing file, and the loopback VPN switched on |
| First install of Harbor itself | No | Yes | Or a paid developer account / an existing sideloading tool |
| Creating the pairing file | iOS 27: yes (Pair This iPhone) | iOS 17 to 26: yes | Open question Q1 below |
| Loopback VPN inside Harbor | No | | Network Extension entitlement is not available to free accounts, so the VPN stays a separate App Store app |
| Running a guest app in the container | Yes | | A signing certificate (JIT-less) or JIT |
| JIT | Partly | | Pairing + VPN + developer disk image; on iOS 26 the dyld bypass is disabled and a certificate is mandatory |
| Refresh on a schedule | Best effort | | iOS decides when background tasks run; no app can guarantee a time |

Free-account limits that the product must model, not hide:

- Profiles last 7 days.
- 3 active sideloaded apps per device.
- 10 new App IDs per rolling 7 days. Every app extension uses one.
- Guest apps run with Harbor's entitlements, not their own: no push, no
  iCloud, no extensions or widgets of their own.

## 3. Decisions

**D1. One process model, no "store as a guest".** LiveContainer today ships
SideStore as a converted framework downloaded by CI and launched as a guest
with hooks that fake its bundle ID. Harbor links the signing and install core
directly into the host UI. This removes an unpinned binary download, the hook
layer, and the URL-scheme hand-off of the certificate between two halves of
what is really one app.

**D2. Reuse the engines, replace the shell.**

| Kept (as pinned modules) | Why |
| --- | --- |
| SideSign (Apple auth, developer portal, signing API) | Implements private Apple protocols; costly to rewrite, easy to regress |
| minimuxer + IDevice xcframework | Working lockdown / RemotePairing / install / JIT transport |
| LiveContainer engine: Mach-O patcher, bootstrap, guest hooks, LiveProcess, ZSign | Depends on dyld and FrontBoard internals per iOS version |

| Replaced | With |
| --- | --- |
| Two UIs (UIKit + SwiftUI), CoreData model, GCD operation chains | One SwiftUI app, Observation, SwiftData, structured concurrency (Swift 6 strict) |
| Ad-hoc secret storage | `SecretStore` with one policy (section 4) |
| URL-scheme interop between apps | Typed deep-link router with a confirmation policy |
| "Verify if a hash happens to be present" | Mandatory verification with pinned digests and signed manifests |
| Silent-audio / location keep-alive | BGTaskScheduler + App Intents + notifications (section 5) |
| iloader's general-purpose UI | A setup tool that does two jobs only |

**D3. iOS 17 minimum.** One pairing model (RemotePairing), modern SwiftUI,
SwiftData, App Intents.

**D4. Guests do not share a process with the credentials.** The main app
process holds the Apple ID session, signing key and pairing record, and never
loads guest code. Guests run in the LiveProcess extension, whose entitlements
omit the keychain access group that holds those secrets. This is a hypothesis
until measured on a device: extension processes have tighter memory limits and
some guests may not run. Fallback: a per-app, opt-in "run in main process"
switch with an explicit warning. Validate in phase 3.

Status of D4: built, measured on the simulator only (13 October 2026). A
guest opened the normal way now runs in the LiveProcess extension, beside
Harbor, which stays alive. That process's entitlements list the guests'
keychain groups and not Harbor's own, and it is handed bookmarks to three
folders (the guest's bundle, its data container, the tweak folder) and
nothing else of Harbor's. On the simulator the guest's home directory is the
extension's sandbox, not Harbor's container. Not yet measured: the same on a
device, that a guest there really cannot read Harbor's keychain items, and
which real apps run this way.

The other way of running a guest is still there, as "Open as the whole app":
Harbor restarts its own process as the guest, as LiveContainer does by
default. Such a guest has Harbor's entitlements. The engine's hooks move its
keychain use into a group of its own, which keeps well-behaved apps apart
from Harbor's secrets; a hostile guest can call past hooks. Use it only for
apps you trust that will not run beside Harbor.

Both processes share an app group. It holds the engine's own settings and
nothing of Harbor's.

**D5. Project is generated, not hand-edited.** The Xcode project comes from an
XcodeGen `project.yml`, so it can be authored on any OS and built in CI.

**D6. Platform-independent logic lives in `HarborCore`.** Verification, policy,
planning and parsing have no UIKit or Security dependency, so they compile and
test on Windows, Linux and macOS.

## 4. Security model

Each row is a finding from the reverse-engineering pass and what replaces it.

| Finding | Harbor |
| --- | --- |
| SideStore keychain is iCloud-synchronizable and holds the plaintext Apple ID password and signing p12 | Device-only, never synchronizable. Password is not stored by default; the session token is. Storing the password for unattended re-login is opt-in |
| LiveContainer keeps the p12 and its password in app-group defaults, readable by guests | Signing key in a keychain access group only the main app holds (D4) |
| `sidestore://pairing?urlName=X` exports the pairing file to any scheme with no prompt, and logs it | No deep link returns a secret. Export exists only as a user-initiated share with confirmation |
| Certificate export URL logged with p12 and password | Secrets are wrapped in a type that cannot be printed |
| `CodeSignKit.PKCS12Builder` (behind SideSign's `KeyStore.exportP12`) ignores its password: every "password-protected" .p12 it writes holds the private key unencrypted. Found by a Harbor test, confirmed in the source | Harbor never writes a .p12. Certificate and key are separate secret-store items. Any future export must use a real PKCS#12 encryptor |
| Pairing file kept in Documents with file sharing enabled | Stored through `SecretStore`; file sharing off |
| ADI library zip: hash mismatch is logged, extraction proceeds | Mismatch is a hard failure; digest pinned in a signed manifest |
| Source downloads: SHA-256 checked only if supplied; dependencies unverified | Digest required for every artifact from a verified source; unverified sources are labelled and need confirmation per install |
| SideSign's zip extractor joins entry names onto the destination unchecked, so `../x` is written outside it | Every archive, IPAs included, goes through `SafeArchive`: entry names and unpacked size are checked before anything is written |
| The hash published with the anisette library archive (`zzz.haus/oda.json`, key `s`) does not match the archive under any obvious reading, so SideStore's check fails on every run and extraction proceeds | Harbor ignores the published hash and pins the SHA-256 of the archive itself, as served on 13 October 2026. This is trust on first use: there is no authoritative hash to compare with. The per-library hashes are recorded in `LiveAppleProbeTests` for checking against a copy from Apple's own app. The app no longer uses these libraries (section 8) |
| LiveContainer's executable patcher (`LCPatchExecSlice`) reads and writes through raw pointers with no bounds checks, on files that come from arbitrary apps. When tweaks are switched on for an app it earlier parked, it copies a 43-character path into a 24-byte field and writes past the load command. Confirmed by running the original in CI | `GuestExecutable` is a bounds-checked Swift port, compared byte for byte with the original in CI on a real iOS executable and on cramped layouts. A parked slot is always created at full size, and one that is too small is reported, not overrun |
| App Transport Security disabled globally | Enabled; local-network exception only for user-added JIT servers |
| iloader: IPAs downloaded with no verification | Setup tool installs only an IPA whose digest matches a signed release manifest |
| iloader: pairing file sent to any app whose display name matches | Matched by bundle identifier |
| iloader: selecting a device silently enables Wi-Fi debugging | Explicit step, explained, reversible |
| LiveContainer CI runs an unpinned `dylibify` and embeds an unpinned nightly | Not needed after D1; all remaining dependencies pinned by commit or digest |
| LiveProcess `customPayloadDylib` loader, `preloadLibraries.txt` loader | Removed / restricted to bundled paths |

Not solvable, stated plainly: a guest app runs with Harbor's code signature.
Hooks limit what it sees; they are not a security boundary against a hostile
guest. D4 is the boundary for credentials. Only install apps you trust.

## 5. Automation that does not rely on tricks

- `BGAppRefreshTask` and `BGProcessingTask` request a run from 48 hours before
  the earliest expiry. iOS may or may not grant it.
- A Shortcuts time-of-day automation that runs Harbor's own Renew Harbor
  action (`App/Intents/RenewHarborIntent.swift`) in the background. This is
  the reliable path; Settings › Automatic Renewal walks through it
  (`docs/SHORTCUTS.md`). Harbor retries passing failures, checks that each
  expiry moved, and fails the action with the reason. The action lives in
  the interface framework, which the stub does not link, so iOS would not
  see it; the build copies the framework's `Metadata.appintents` to the top
  of the app (`scripts/embed-package-frameworks.sh`). The metadata names the
  types in full, and the framework is loaded before any action runs.
  `harbor://x-callback-url/renew` still works for older shortcuts.
- Local notifications at 48 h, 24 h and 2 h before expiry, scheduled at signing
  time so they fire even if Harbor never runs again.
- A widget showing the next expiry.
- Recovery: every operation is a resumable, journaled step. A failed refresh
  states the cause (VPN off, pairing rejected, Apple session expired, App ID
  limit) and the single action that fixes it.

## 6. Modules

```
Packages/
  HarborCore/        pure Swift, no Apple-only frameworks     (phase 1)
    Verification     digests, signed manifests
    Secrets          SecretStore protocol, Redacted, policy
    Pairing          pairing record parsing and validation
    DeepLinks        typed routes + confirmation policy
    Refresh          expiry planning, free-account limits
    Sources          catalogue model, strict decoding
  HarborPlatform/    Keychain, BGTasks, notifications         (phase 2)
  HarborSigning/     adapter over SideSign                    (phase 2)
  HarborDevice/      adapter over minimuxer                   (phase 2)
  HarborContainer/   adapter over the LiveContainer engine    (phase 3)
App/                 SwiftUI app, intents, widget             (phase 4)
Extensions/          LiveProcess, share, launch               (phase 3)
Setup/               desktop tool (Rust)                      (phase 6)
Vendor/              pinned upstream engines
```

## 7. Phases

| Phase | Deliverable | Validated by |
| --- | --- | --- |
| 1 | `HarborCore` with tests; CI | Unit tests on Windows and macOS |
| 2 | Platform, signing and device adapters; sign in, sign and install one IPA | CI build; on-device test from the Mac |
| 3 | Container engine, LiveProcess isolation (D4) | On-device: guest launch matrix, keychain isolation test |
| 4 | Unified UI | CI build, UI tests, on-device |
| 5 | Background tasks, intents, notifications, widget, recovery journal | On-device over a full 7-day cycle |
| 6 | Setup tool: verified install + pairing | Windows and macOS builds; real device |
| 7 | Hardening: threat-model review, dependency pinning audit, release signing | Review + CI |

## 8. Not yet verified or built

- **Apple refuses sign-in from made-up machine identities (from 12 October
  2026).** Every sign-in request says which machine it comes from
  ("anisette"). Apple's sign-in now answers `-80045` when that identity was
  made by the emulated provisioning libraries, before it looks at the
  account, and still accepts a real Mac's. Measured on 13 October 2026 from
  one Mac, with one request each for an Apple ID that cannot exist:

  | Where the machine identity came from | Apple's answer |
  | --- | --- |
  | Harbor's on-device anisette, freshly provisioned | `-80045` |
  | Anisette server `ani.sidestore.app` | `-80045` |
  | Anisette server `ani.sidestore.zip` | `-80045` |
  | macOS itself (AOSKit and AuthKit on the Mac) | `-20101`, "account information entered incorrectly": the request was accepted and the account looked at |

  `LiveAppleProbeTests` repeats this. Harbor's sign-in code is SideStore's,
  at the same revisions, called the same way, so there is no setting to
  flip: the emulated identity is what is refused. This is what the reported
  AltStore workaround (turning off "Prefer Remote AltServer") changes: the
  identity then comes from AltServer on the user's own computer.

  What follows from it:
  - Harbor Setup on a Mac signs in with the Mac's own identity
    (`MacSystemAnisette`) and can install Harbor today.
  - An app cannot get the iPhone's own identity: that needs entitlements
    only Apple's apps have.
  - **Anisette servers backed by a real Mac are accepted (19 October
    2026).** The anisette community moved to servers that provision on a
    Mac rather than in an emulator; iloader 2.3.9 and later use them. With
    the same probe, freshly provisioned and with the device description each
    server gives (`/v3/client_info`):

    | Anisette server | Apple's answer |
    | --- | --- |
    | `mac-ani.jkcoxson.com` (Mac) | `-20970`, about the account: accepted |
    | `ani3.stikstore.app` (Mac) | `-20970`, about the account: accepted |
    | `new.ani.sidestore.io` (Mac) | provisioning failed on the server (HTTP error on `/v3/provisioning_session`) |
    | `ani.jkcoxson.com` (Windows) | provisioning failed (Apple answered 401) |

    So Harbor on the iPhone signs in by itself again, through
    `ServerAnisette`: the first two servers, in that order. The machine a
    server provisions is kept with the server's address, so a refresh
    presents the machine the session was made on; Harbor moves to the next
    server only when one fails, and that is a new machine, for which Apple
    may ask for two-factor again. The server never sees the Apple ID or the
    password. It does decide which machine Apple sees, and Harbor depends
    on it staying up and staying accepted.
  - Harbor renews itself on the phone (`HostRenewal`): it rebuilds the
    record of its own install from its bundle (the installed identifiers
    without the team suffix) and refreshes it like any installed app, new
    profiles installed over LocalDevVPN, nothing reinstalled. A refresh
    deletes the profile Apple already issued and asks again, because Apple
    otherwise returns the same profile with the same end date. Triggered by
    the Renew button or a daily Shortcuts automation (section 5).
  - Not handled yet: Apple can answer the first sign-in step with status
    434 and ask for the anisette to be resynced (`X-Apple-I-MD-DATA`).
    isideload 0.4.5 answers it through the server's `/v3/get_headers` with
    `sim`; SideSign does not, so such a sign-in fails. Not seen in the probe.
  - A session is tied to the machine it was made on, so a session made on
    the Mac by Harbor Setup is not handed to the phone; the phone signs in
    once itself.
  - Whether a Windows PC's own identity is accepted has not been measured.
  Sign-in failures of this kind are reported as what they are
  (`AccountError.machineIdentityRefused`), not as a wrong password.

- Nothing has run against Apple's servers. On a real device only the
  container runtime has run, with one small test guest (13 October 2026);
  pairing, install and refresh have not. See `docs/TESTING.md`.
- App groups are registered under team-unique identifiers, as SideStore does.
  An app that looks up its group by the identifier it was built with will not
  find it unless the container redirects the lookup (phase 3).
- Whether Apple issues certificates named "iPhone Developer" or "Apple
  Development" through this endpoint decides which ones Harbor would offer to
  revoke. To be observed on the first real run.

## 9. Open questions

- **Q1. Can pairing be created without a computer? (researched and run on
  a device 19 October 2026).** On iOS 27 and later, yes: Harbor paired an
  iPhone on iOS 27.0 with itself and installed a profile with the record
  through LocalDevVPN. On iOS 26 and earlier, no.
  - iOS 27 lets an app on the phone act as a "pairable host": it advertises
    `_remotepairing-pairable-host._tcp.` on Bonjour, the user picks it under
    Settings › Privacy & Security › Developer Mode and types the PIN the app
    shows, and the app gets a RemotePairing record for that phone. This is
    minimuxer's `wirelessPair.start` (`pairable_host_prepare`,
    `pairable_host_accept_fd`), vendored, and called through
    `SelfPairingHost` (App/PhonePairing.swift).
  - Shipped by others: StikPair (v1.2.0, "creates a pairing file on-device",
    iOS 27 only) and SideInstaller (1.5.3), whose notes report, on an
    iPhone with iOS 27 (30 September 2026), the RemotePairing tunnel over
    LocalDevVPN, an install and SideStore starting on that record. Harbor has
    since reproduced pairing and a profile install. The StikPair author
    declined iOS 26 and earlier.
  - iOS 27 closes lockdown on every route (SideInstaller's probes; SideStore#1532),
    so on iOS 27 Harbor uses the RemotePairing record end to end and does not
    mint a lockdown record.
  - Needs: iOS 27, Developer Mode, Wi-Fi once, Local Network permission and
    `NSBonjourServices` for the service type, LocalDevVPN, the app kept
    running while the user is in Settings (the PIN shown by Live Activity or
    notification), and the host key pair and `alt_irk` kept between runs (a new
    pair each run invalidates every copy of the file).
  - Shown on 19 October 2026: the tunnel works from Harbor's own build, and
    pairing completed even though iOS ended Harbor's background time while
    the PIN was being typed. Not known: whether the record survives a
    reboot (`docs/TESTING.md`, section 5). The lockdown port (62078) still answered on the
    network on that iOS 27.0 phone and the device identifier was read, so
    "closes lockdown on every route" is not what this phone showed.
  - Decision: build it for iOS 27 (the device spike passed: advertise, pair
    from Settings, `tunnel_create_rppairing` to the VPN peer, install a
    profile).
    Harbor Setup stays for iOS 17 to 26. StikPair (MIT, non-commercial) and
    SideInstaller (custom, non-commercial) are not copied from; the protocol
    comes from minimuxer and idevice. Built: Settings › Pair This iPhone,
    offered on iOS 27 and later.
- **Q1b. First install with no computer.** Nothing legitimate is verified. What
  works today (SideInstaller, ESign) signs with enterprise certificates that
  were not issued to those projects, plus a DNS profile to avoid revocation
  checks; Harbor will not do that. A Harbor-run ad hoc service needs a paid
  account, the user's UDID (a web configuration profile can return it) and has a
  100-device yearly cap. The workable plan is to publish the IPA and document
  installing it with whatever sideloading tool the person already has.
- **Q1c. Renewal without a pairing file, by itms-services from a server inside
  Harbor.** Feather has done this with the user's own certificate, but its HTTPS
  certificate came from `*.backloop.dev`, whose published key was revoked on
  4 September 2026. A per-phone self-signed certificate for `localhost`, installed
  and trusted once through a configuration profile, would replace it; this is
  unproven on iOS 27. iOS asks for confirmation on every itms-services install,
  so it is a "tap to renew" fallback for iOS 26 and earlier, not the automatic
  renewal of section 5. Spike only after Q1.
- **Q2. LiveContainer upstream (decided).** `LiveContainer/LiveContainer` was
  taken down. The engine is taken from the mirror
  `timosaiah77-source/livecontainer` at `4dbe0f9`, which could not be diffed
  against the original; its history carries only upstream authors and a scan
  found no injected hosts or payloads. `litehook` at the pinned commit
  `a7e9f59` is fetchable from `khanhduytran0/litehook` (the upstream
  author's own repository). Both are pinned by commit; the engine code that
  Harbor keeps is reviewed as it is brought in during phase 3.
- **Q3. Extension-only guests (D4).** Memory ceiling and compatibility need
  measuring.
- **Q4. Dependency pinning (partly answered).** Inspected at the revisions
  SideStore `0dd743f` locks:
  - `CodeSignKit`, `GSACryptoKit`, `AnisetteKit` and `RemotePairingKit` are
    source packages, but SideSign and minimuxer track them by *branch* on a
    personal account (`mahee96/*`, `main`). Only a lockfile holds them still.
    Harbor commits a lockfile with the same revisions and CI must build with
    `-onlyUsePackageVersionsFromResolvedFile` once these are linked in.
    Longer term: fork them and depend on the forks by revision.
  - Prebuilt binaries are pinned by checksum in the manifests: OpenSSL
    3.6.2000, Unicorn (AnisetteKit runs Apple's ADI libraries in a CPU
    emulator), IDevice 0.1.68, libimobiledevice 1.4.0, EMProxy 0.9.3.
    Open: whether to rebuild any of these from source in CI.
  - SideSign requires swift-crypto exactly 4.3.1, so `HarborCore` accepts
    3.9 up to 5.
- **Q5. iOS 26 JIT.** What still works on TXM devices needs a device matrix.
