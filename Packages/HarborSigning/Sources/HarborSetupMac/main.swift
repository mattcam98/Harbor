// The Mac half of Harbor Setup.
//
// It signs in to Apple with this Mac's own machine identity, signs Harbor
// with Harbor's own signing code, and has `harbor-setup` (the part that
// talks to the iPhone, which also runs on Windows) install it and hand
// Harbor what it needs.
//
// Why a Mac: since October 2026 Apple's sign-in refuses the made-up machine
// identities every other route uses, and still accepts a real Mac's. See
// `MacSystemAnisette`.
//
// Nothing is kept on the Mac. The password is read from the keyboard, used
// once and dropped. The signing key exists in memory and, briefly, in a
// file only this user can read while it is carried to the iPhone.

#if os(macOS)
import Foundation
import HarborCore
import HarborSigning
import SideSign

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
            throw Failure("the step above failed")
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

/// Asks Apple one question that touches no account: will it talk to this
/// Mac at all?
func check() async throws {
    let service = AccountService(
        portal: DeveloperPortal.shared, anisette: MacSystemAnisette(), secrets: InMemorySecretStore())
    do {
        _ = try await service.signIn(
            appleID: "nobody-\(UUID().uuidString.lowercased())@harbor-probe.invalid",
            password: Redacted("not-a-real-password"),
            verification: nil
        )
        print("Apple accepted a sign-in for an account that does not exist. That should not happen.")
    } catch AccountError.machineIdentityRefused {
        print("Apple is refusing sign-in from this Mac (error -80045), before looking at any account.")
        print("Setup cannot sign in until that changes. Nothing is wrong with your Apple ID.")
        exit(2)
    } catch let error as URLError {
        throw Failure("Apple could not be reached (\(error.localizedDescription)). Check the connection.")
    } catch is MacSystemAnisette.Failure {
        throw Failure("this Mac did not provide its machine identity. Setup needs a Mac that is signed in to iCloud.")
    } catch {
        // Any answer about the account means the request itself was accepted.
        print("Apple accepts sign-in from this Mac. (It answered about the test account: \(error.localizedDescription))")
    }
}

func install(ipa: URL, tool: DeviceTool, appleID given: String?, iPad: Bool) async throws {
    let udid = try tool.run(["udid"], quiet: true)
    print("Device: \(udid)")

    guard let appleID = given ?? ask("Apple ID:"), !appleID.isEmpty else {
        throw Failure("no Apple ID given")
    }
    guard let password = askPassword("Password for \(appleID) (not shown):") else {
        throw Failure("no password given")
    }

    let secrets = InMemorySecretStore()
    let portal = DeveloperPortal.shared
    let service = AccountService(portal: portal, anisette: MacSystemAnisette(), secrets: secrets)

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
    } catch AccountError.machineIdentityRefused {
        throw Failure("Apple is refusing sign-in from this Mac (error -80045), before looking at the account. Nothing is wrong with your Apple ID; try again later")
    }
    print("Signed in. Team: \(account.team.name)")

    let identities = SigningIdentityStore(secrets: secrets)
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
            print("Your Apple ID already has \(existing.count) development certificate(s):")
            for certificate in existing {
                print("  \(certificate.name)")
            }
            print("Setup needs one of its own. Revoking the existing ones stops apps signed with them")
            print("from opening until they are signed again; keeping them may fail if the account is full.")
            switch ask("Type keep, revoke or cancel:")?.lowercased() {
            case "keep": return .keepExisting
            case "revoke": return .revoke(existing)
            default: return .cancel
            }
        },
        progress: { step in
            let description: String
            switch step {
            case .unpack: description = "Unpacking Harbor"
            case .registerDevice: description = "Registering the device with your Apple ID"
            case .certificate: description = "Getting a signing certificate"
            case .profiles: description = "Getting provisioning profiles"
            case .sign: description = "Signing Harbor"
            case .install: description = "Installing on the device"
            }
            print("\(description)…")
        }
    )
    print("Installed \(installed.name) \(installed.version). It works until \(installed.expiry.formatted(date: .abbreviated, time: .shortened)).")

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
    print("Done. On the device: Settings > General > VPN & Device Management, trust your Apple ID,")
    print("then open Harbor. It takes the pairing file and certificate by itself.")
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
    """

do {
    switch arguments.first {
    case "check":
        try await check()
    case "install":
        guard let ipa = value(after: "--ipa", in: arguments), let tool = value(after: "--tool", in: arguments) else {
            throw Failure("install needs --ipa and --tool\n\n\(usage)")
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
} catch {
    FileHandle.standardError.write(Data("Failed: \(error)\n".utf8))
    exit(1)
}
#else
print("Harbor Setup for Mac only runs on macOS.")
#endif
