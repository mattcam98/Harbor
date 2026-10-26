// The Mac half of Harbor Setup.
//
// It signs in to Apple with this Mac's own machine identity, signs Harbor
// with Harbor's own signing code, and has `harbor-setup` (the part that
// talks to the iPhone, which also runs on Windows) install it and hand
// Harbor what it needs.
//
// Why a Mac: since October 2026 Apple's sign-in refuses the made-up machine
// identities every other route uses, and still accepts a real Mac's. See
// `MacSystemAnisette`. macOS only gives one with an Apple Account signed in;
// without one, Setup uses the anisette servers the iPhone app uses, which
// make the identity on a real Mac of their own (`ServerAnisette`).
//
// What is kept on the Mac: the signing certificate and its key, in the
// login keychain, so that renewing Harbor next week uses the same
// certificate instead of asking Apple for another and revoking the last.
// Nothing else. The password is read from the keyboard, used once and
// dropped, and the sign-in session lives only as long as this run. The key
// is also, briefly, in a file only this user can read while it is carried
// to the iPhone.

#if os(macOS)
import Foundation
import HarborCore
import HarborSigning
import Security
import SideSign

/// `harbor-setup` failed and has already said why.
struct AlreadyReported: Error {}

/// What to tell the person about `error`, in a sentence.
func explain(_ error: any Error) -> String {
    switch error {
    case let failure as Failure:
        return failure.description
    case DeveloperPortalError.incorrectCredentials, ServerError.underlyingError(code: -20101, _):
        return "Wrong Apple ID or password. Check them and try again."
    case AccountError.machineIdentityRefused:
        return "Apple isn't accepting sign-ins from this Mac right now (error -80045). Your Apple ID is fine. Try again later."
    case AccountError.noTeams:
        return "This Apple ID isn't part of a development team."
    case SigningError.cancelled:
        return "Cancelled. Nothing was changed."
    case let error as URLError:
        return "Couldn't reach Apple (\(error.localizedDescription)). Check your internet connection."
    case let error as LocalizedError:
        return error.errorDescription ?? "\(error)"
    default:
        return "\(error)"
    }
}

struct Failure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

// MARK: The device tool

/// Runs `harbor-setup`, the part of Setup that talks to the iPhone.
struct DeviceTool: Sendable {
    let executable: URL
    let udid: String?

    @discardableResult
    func run(_ arguments: [String], quiet: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments + (udid.map { ["--udid", $0] } ?? [])
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if !quiet, !text.isEmpty {
            print(text, terminator: "")
        }
        guard process.terminationStatus == 0 else {
            throw AlreadyReported()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Harbor's install pipeline, pointed at an iPhone on the end of a cable.
struct CableTransport: DeviceTransport {
    let tool: DeviceTool
    let deviceUDID: String

    func connect(using pairing: PairingRecord) async throws {}
    func deviceIdentifier() async throws -> String { deviceUDID }

    func installApp(at bundleURL: URL, bundleIdentifier: String) async throws {
        try tool.run(["install-app", bundleURL.path])
    }

    func installProfile(_ profile: Data) async throws {
        throw DeviceIssue.failed("Setup installs apps, which carry their own profiles")
    }

    func removeApp(bundleIdentifier: String) async throws {
        throw DeviceIssue.failed("Setup does not remove apps")
    }
}

// MARK: Keeping the certificate

/// The Mac's login keychain, for the signing certificate and its key.
///
/// If the keychain refuses (no window to ask in, or the user says no) the
/// value is kept for this run only and Setup carries on: losing it means one
/// more certificate next time, which is how Setup worked before it kept any.
final class MacLoginKeychain: SecretStore, @unchecked Sendable {
    static let service = "Harbor Setup"
    private let fallback = InMemorySecretStore()

    private func query(_ key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    func read(_ key: SecretKey) throws -> Redacted<Data>? {
        if let held = try fallback.read(key) {
            return held
        }
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return Redacted(data)
    }

    func write(_ value: Redacted<Data>, for key: SecretKey, optedIn: Bool) throws {
        try checkWriteAllowed(key, optedIn: optedIn)
        SecItemDelete(query(key) as CFDictionary)
        var item = query(key)
        item[kSecValueData as String] = value.expose()
        item[kSecAttrLabel as String] = "Harbor Setup signing identity"
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            print("Note: could not save to the Mac's keychain (\(status)); the next run will need a new certificate.")
            try fallback.write(value, for: key, optedIn: optedIn)
        }
    }

    func delete(_ key: SecretKey) throws {
        try fallback.delete(key)
        SecItemDelete(query(key) as CFDictionary)
    }
}

// MARK: Asking the user

func ask(_ question: String) -> String? {
    print(question, terminator: " ")
    fflush(stdout)
    return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Reads a password without showing it.
func askPassword(_ question: String) -> Redacted<String>? {
    guard let typed = getpass(question + " ") else { return nil }
    let password = String(cString: typed)
    return password.isEmpty ? nil : Redacted(password)
}

// MARK: Commands

/// This Mac's own machine identity, or, when macOS won't give one because
/// no Apple Account is signed in, one from the servers the iPhone app uses.
/// Decided once, so the whole run shows Apple the same machine: the server
/// keeps the one it provisions in `secrets`.
func machineIdentity(secrets: any SecretStore) async throws -> any AnisetteProviding {
    let mac = MacSystemAnisette()
    if (try? await mac.anisetteData()) != nil {
        return mac
    }
    print("This Mac isn't signed in to an Apple Account, so Harbor is using an anisette server instead.")
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("harbor-setup-anisette-\(UUID().uuidString)", isDirectory: true)
    let server = ServerAnisette(directory: directory, secrets: secrets)
    do {
        _ = try await server.anisetteData()
    } catch {
        throw Failure("No anisette server answered (\(error)). Sign in to your Apple Account on this Mac, or try again later.")
    }
    return server
}

/// Asks Apple one question that touches no account: will it talk to this
/// Mac at all?
func check() async throws {
    let secrets = InMemorySecretStore()
    let service = AccountService(
        portal: DeveloperPortal.shared, anisette: try await machineIdentity(secrets: secrets), secrets: secrets)
    do {
        _ = try await service.signIn(
            appleID: "nobody-\(UUID().uuidString.lowercased())@harbor-probe.invalid",
            password: Redacted("not-a-real-password"),
            verification: nil
        )
        print("Apple accepted a sign-in for an account that doesn't exist. That shouldn't happen.")
    } catch AccountError.machineIdentityRefused {
        print(explain(AccountError.machineIdentityRefused))
        exit(2)
    } catch let error as URLError {
        throw Failure(explain(error))
    } catch {
        // Any answer about the account means the request itself was accepted.
        print("Apple accepts sign-ins from this Mac.")
    }
}

func install(ipa: URL, tool: DeviceTool, appleID given: String?, iPad: Bool) async throws {
    let udid = try tool.run(["udid"], quiet: true)
    print("iPhone: \(udid)")

    guard let appleID = given ?? ask("Apple ID:"), !appleID.isEmpty else {
        throw Failure("No Apple ID entered.")
    }
    guard let password = askPassword("Password for \(appleID) (not shown):") else {
        throw Failure("No password entered.")
    }

    let secrets = InMemorySecretStore()
    let portal = DeveloperPortal.shared
    let service = AccountService(portal: portal, anisette: try await machineIdentity(secrets: secrets), secrets: secrets)

    print("Signing in to Apple…")
    let account: SignedInAccount
    do {
        account = try await service.signIn(
            appleID: appleID,
            password: password,
            verification: TwoFactor.handler { prompt in
                switch prompt {
                case .trustedDeviceCode(let error):
                    if let error { print(error) }
                    return ask("Code shown on your other Apple devices:")
                case .phoneCode(let number, let error):
                    if let error { print(error) }
                    return ask("Code sent to \(number ?? "your phone"):")
                }
            }
        )
    }
    print("Signed in to \(account.team.name).")

    // Kept between runs, unlike everything else: see the top of this file.
    let identities = SigningIdentityStore(secrets: MacLoginKeychain())
    if let kept = try? identities.load() {
        print("Using the signing certificate from last time: \(kept.certificate.name)")
    }
    let work = FileManager.default.temporaryDirectory
        .appendingPathComponent("harbor-setup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    let pipeline = InstallPipeline(
        portal: portal,
        identities: identities,
        transport: CableTransport(tool: tool, deviceUDID: udid),
        machineName: "Harbor Setup - \(Host.current().localizedName ?? "Mac")",
        deviceName: iPad ? "iPad" : "iPhone",
        workDirectory: work
    )
    let installed = try await pipeline.install(
        ipaAt: ipa,
        account: account,
        activeApps: [],
        deviceType: iPad ? .iPad : .iPhone,
        onExistingCertificates: { existing in
            print(existing.count == 1
                ? "Your Apple ID already has a development certificate:"
                : "Your Apple ID already has \(existing.count) development certificates:")
            for certificate in existing {
                print("  \(certificate.name)")
            }
            print("Harbor Setup needs its own. Apps signed with a certificate you revoke stop opening")
            print("until they're signed again. If you keep them all, Apple may refuse to make another.")
            while true {
                switch ask("Type keep, revoke or cancel:")?.trimmingCharacters(in: .whitespaces).lowercased() {
                case "keep": return .keepExisting
                case "revoke": return .revoke(existing)
                case "cancel", nil: return .cancel
                default: print("Please type keep, revoke or cancel.")
                }
            }
        },
        progress: { step in
            let description: String
            switch step {
            case .unpack: description = "Unpacking Harbor"
            case .registerDevice: description = "Registering your iPhone"
            case .certificate: description = "Getting a signing certificate"
            case .profiles: description = "Getting provisioning profiles"
            case .sign: description = "Signing Harbor"
            case .install: description = "Installing on your iPhone"
            }
            print("\(description)…")
        }
    )
    print("Installed \(installed.name) \(installed.version). It works until \(installed.expiry.formatted(date: .abbreviated, time: .shortened)), then renews itself.")

    // Harbor was signed with this certificate and needs it to sign the apps
    // it runs. The file exists only for the moment it takes to carry over.
    if let identity = try identities.load() {
        let file = work.appendingPathComponent("identity.p12")
        FileManager.default.createFile(
            atPath: file.path, contents: try identity.exportP12(), attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: file) }
        try tool.run(["give-identity", file.path, "--bundle-id", installed.installedBundleIdentifier])
    }
    // The copy just installed, not one Xcode may have put there earlier.
    try tool.run(["pair", "--bundle-id", installed.installedBundleIdentifier])

    print("")
    print("Done. Now, on the iPhone:")
    print("  1. Open Settings > General > VPN & Device Management.")
    print("  2. Tap your Apple ID under Developer App, then Trust.")
    print("  3. Turn on LocalDevVPN, then open Harbor. It sets itself up from there.")
}

// MARK: Entry

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())
let usage = """
    harbor-setup-mac check
        Ask Apple whether it accepts sign-in from this Mac. Touches no account.

    harbor-setup-mac install --ipa Harbor.ipa --tool path/to/harbor-setup [--apple-id you@example.com] [--udid ID] [--ipad]
        Sign in, sign Harbor, install it on the connected device and pair it.
        Run it again within seven days to renew.

    harbor-setup-mac forget
        Remove the signing certificate and key this Mac keeps between runs.
    """

do {
    switch arguments.first {
    case "check":
        try await check()
    case "forget":
        try SigningIdentityStore(secrets: MacLoginKeychain()).clear()
        print("Removed the signing certificate and key from this Mac's keychain.")
    case "install":
        guard let ipa = value(after: "--ipa", in: arguments), let tool = value(after: "--tool", in: arguments) else {
            throw Failure("install needs --ipa and --tool.\n\n\(usage)")
        }
        try await install(
            ipa: URL(fileURLWithPath: ipa),
            tool: DeviceTool(executable: URL(fileURLWithPath: tool), udid: value(after: "--udid", in: arguments)),
            appleID: value(after: "--apple-id", in: arguments),
            iPad: arguments.contains("--ipad")
        )
    default:
        print(usage)
    }
} catch is AlreadyReported {
    exit(1)
} catch {
    FileHandle.standardError.write(Data("\(explain(error))\n".utf8))
    exit(1)
}
#else
print("Harbor Setup for Mac only runs on macOS.")
#endif
