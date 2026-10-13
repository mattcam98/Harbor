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
| Apple ID sign-in, 2FA | Yes | | Anisette data: on-device ADI libraries (downloaded) or a remote anisette server |
| Certificate, App ID, profile management | Yes | | |
| Re-signing an IPA | Yes | | |
| Installing / refreshing an app | Yes | | Pairing file, and the loopback VPN switched on |
| First install of Harbor itself | No | Yes | Or a paid developer account / an existing sideloading tool |
| Creating the pairing file | Not proven | Yes | Open question Q1 below |
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

Status of D4: not implemented. Harbor currently runs guests the way
LiveContainer does by default, by restarting its own process as the guest. A
guest therefore has Harbor's entitlements. Each guest's keychain use is moved
into a keychain group of its own by the engine's hooks, which keeps
well-behaved apps apart from Harbor's secrets and from each other; a hostile
guest can call past hooks. Until the extension model is in place, the rule
stands: only run apps you trust.

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
| The hash published with the anisette library archive (`zzz.haus/oda.json`, key `s`) does not match the archive under any obvious reading, so SideStore's check fails on every run and extraction proceeds | Harbor ignores the published hash and pins the SHA-256 of the archive itself, as served on 13 October 2026. This is trust on first use: there is no authoritative hash to compare with. The per-library hashes are recorded in `App/Services.swift` for checking against a copy from Apple's own app |
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
- An App Intent, `Refresh All`, for a Shortcuts time-of-day automation. This is
  the reliable path, and setup offers to create it.
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

- **Sign-in is blocked at Apple (from 12 October 2026).** Apple's GrandSlam
  endpoint returns `-80045` to every tool that signs in the way Xcode does
  without being Xcode, before credentials are checked. Harbor's sign-in goes
  through SideSign and is expected to fail the same way. This is the
  platform's one hard external dependency: everything except the container
  engine needs a developer session. Track SideSign, isideload and xtool for
  the fix and take it by bumping the SideSign submodule.

- Nothing has run against Apple's servers or a real device. See
  `docs/DEVICE-TEST.md`.
- App groups are registered under team-unique identifiers, as SideStore does.
  An app that looks up its group by the identifier it was built with will not
  find it unless the container redirects the lookup (phase 3).
- Whether Apple issues certificates named "iPhone Developer" or "Apple
  Development" through this endpoint decides which ones Harbor would offer to
  revoke. To be observed on the first real run.

## 9. Open questions

- **Q1. Can pairing be created without a computer?** minimuxer exposes a
  wireless-pair call. Whether RemotePairing can be established from the device
  to itself over the loopback tunnel is unverified. Until proven, pairing
  needs the setup tool once.
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
