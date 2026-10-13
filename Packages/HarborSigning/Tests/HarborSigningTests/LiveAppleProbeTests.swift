import Foundation
import HarborCore
import SideSign
import Testing

@testable import HarborSigning

/// Asks Apple's sign-in service one question, for real: does it still talk
/// to Harbor's way of signing in?
///
/// Apple can refuse a sign-in before it looks at the account, because of
/// what the request says about the machine it comes from. When it does,
/// every account fails the same way (error -80045 in October 2026). This
/// sends one request for an Apple ID that cannot exist, under a reserved
/// domain, so no real account is touched. An answer about the account
/// ("not found") means Harbor's requests are accepted; -80045 means they
/// are refused.
///
/// Skipped unless asked for, because it uses the network and Apple:
///
///     HARBOR_PROBE_APPLE=1 swift test --filter LiveAppleProbe
@Suite struct LiveAppleProbe {
    @Test func whatAppleSaysToHarborsSignIn() async throws {
        guard ProcessInfo.processInfo.environment["HARBOR_PROBE_APPLE"] == "1" else { return }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = InMemorySecretStore()

        // The same libraries, from the same place, pinned the same way as
        // the app (App/Services.swift).
        let anisette = OnDeviceAnisette(
            release: AnisetteLibraryRelease(
                url: URL(string: "https://zzz.haus/oda.json")!,
                sha256: ContentDigest(hex: "a2f9aeef4cc31efda69ecdceeadd0f1bbd04199e6339b880636c14a3ecba2b96")!,
                size: 2_609_673
            ),
            directory: directory,
            secrets: secrets,
            download: OnDeviceAnisette.inlinePayloadDownload
        )

        do {
            _ = try await anisette.anisetteData()
            print("PROBE anisette: generated on this machine")
        } catch {
            print("PROBE anisette FAILED: \(String(reflecting: error))")
            throw error
        }

        let service = AccountService(portal: DeveloperPortal.shared, anisette: anisette, secrets: secrets)
        do {
            _ = try await service.signIn(
                appleID: "nobody-\(UUID().uuidString.lowercased())@harbor-probe.invalid",
                password: Redacted("not-a-real-password"),
                verification: nil
            )
            print("PROBE sign-in: unexpectedly succeeded")
        } catch {
            print("PROBE sign-in answer: \(String(reflecting: error))")
            print("PROBE sign-in message: \(error.localizedDescription)")
        }
    }

    /// The same question, with the machine identity made by anisette
    /// servers instead of on this machine:
    ///
    ///     HARBOR_PROBE_SERVERS=https://a.example,https://b.example swift test --filter LiveAppleProbe
    @Test func whatAppleSaysWhenAnisetteComesFromAServer() async throws {
        guard let list = ProcessInfo.processInfo.environment["HARBOR_PROBE_SERVERS"] else { return }

        for address in list.split(separator: ",") {
            guard let server = URL(string: String(address)) else { continue }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("harbor-probe-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let anisette = ServerAnisette(server: server, directory: directory)
            do {
                _ = try await anisette.anisetteData()
            } catch {
                print("PROBE \(server.host ?? "") anisette FAILED: \(String(reflecting: error).prefix(200))")
                continue
            }

            let service = AccountService(
                portal: DeveloperPortal.shared, anisette: anisette, secrets: InMemorySecretStore())
            do {
                _ = try await service.signIn(
                    appleID: "nobody-\(UUID().uuidString.lowercased())@harbor-probe.invalid",
                    password: Redacted("not-a-real-password"),
                    verification: nil
                )
                print("PROBE \(server.host ?? "") sign-in: unexpectedly succeeded")
            } catch {
                print("PROBE \(server.host ?? "") sign-in answer: \(String(reflecting: error).prefix(200))")
            }
        }
    }
}

/// Anisette made with the help of a server, freshly provisioned.
private struct ServerAnisette: AnisetteProviding {
    let server: URL
    let directory: URL

    func anisetteData() async throws -> AnisetteData {
        let manager = AnisetteDataManager(mode: nil, baseDirectory: directory)
        return try await manager.fetchAnisetteData(mode: .remote(server: server), identifier: UUID()).data
    }
}

#if os(macOS)
/// The control for the probes above: the same question asked with this
/// Mac's own machine identity, which macOS makes for Apple's own apps.
///
///     HARBOR_PROBE_MAC=1 swift test --filter MacIdentityProbe
@Suite struct MacIdentityProbe {
    @Test func whatAppleSaysToThisMacsOwnIdentity() async throws {
        guard ProcessInfo.processInfo.environment["HARBOR_PROBE_MAC"] == "1" else { return }

        let anisette = MacSystemAnisette()
        let service = AccountService(portal: DeveloperPortal.shared, anisette: anisette, secrets: InMemorySecretStore())
        do {
            _ = try await service.signIn(
                appleID: "nobody-\(UUID().uuidString.lowercased())@harbor-probe.invalid",
                password: Redacted("not-a-real-password"),
                verification: nil
            )
            print("PROBE this Mac sign-in: unexpectedly succeeded")
        } catch {
            print("PROBE this Mac sign-in answer: \(String(reflecting: error).prefix(300))")
        }
    }
}
#endif
