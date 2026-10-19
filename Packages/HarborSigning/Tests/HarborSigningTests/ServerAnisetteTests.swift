import Foundation
import HarborCore
import SideSign
import Testing

@testable import HarborSigning

/// Stands in for anisette servers: records what each was asked, provisions a
/// machine the first time it sees an identifier, and fails the servers it is
/// told to.
final class FakeAnisetteServers: AnisetteServerClient, @unchecked Sendable {
    struct Request: Equatable {
        var server: URL
        var identifier: UUID
        var existingBlob: Data?
        var clientInfo: String
    }

    struct Down: Error {}
    struct Unprovisioned: Error, CustomStringConvertible {
        var description: String { "Anisette server returned HTTP status -1: -45061" }
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private var down: Set<URL> = []
    private var forgotten: Set<UUID> = []

    var requests: [Request] { lock.withLock { recorded } }
    func takeDown(_ server: URL) { lock.withLock { _ = down.insert(server) } }
    func bringUp(_ server: URL) { lock.withLock { _ = down.remove(server) } }
    func forget(_ identifier: UUID) { lock.withLock { _ = forgotten.insert(identifier) } }

    func clientInfo(server: URL) async throws -> AnisetteServerClientInfo {
        try lock.withLock {
            if down.contains(server) { throw Down() }
        }
        return AnisetteServerClientInfo(clientInfo: "<Mac> \(server.host ?? "")", userAgent: "akd/1.0")
    }

    func generate(
        server: URL,
        directory: URL,
        identifier: UUID,
        existingBlob: Data?,
        clientInfo: AnisetteServerClientInfo
    ) async throws -> (data: AnisetteData, newBlob: Data?) {
        try lock.withLock {
            recorded.append(Request(
                server: server, identifier: identifier, existingBlob: existingBlob, clientInfo: clientInfo.clientInfo))
            if down.contains(server) { throw Down() }
            if existingBlob != nil, forgotten.contains(identifier) { throw Unprovisioned() }
        }
        let newBlob = existingBlob == nil ? Data("machine on \(server.host ?? "")".utf8) : nil
        return (FakeAnisette.data(oneTimePassword: "otp"), newBlob)
    }
}

@Suite struct ServerAnisetteTests {
    let secrets = InMemorySecretStore()
    let servers = FakeAnisetteServers()
    let first = URL(string: "https://first.example")!
    let second = URL(string: "https://second.example")!
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("harbor-server-anisette-\(UUID().uuidString)", isDirectory: true)

    func anisette(_ list: [URL]? = nil) -> ServerAnisette {
        ServerAnisette(servers: list ?? [first, second], directory: directory, secrets: secrets, client: servers)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func keepsTheMachineTheServerProvisioned() async throws {
        defer { cleanUp() }
        let subject = anisette()

        _ = try await subject.anisetteData()
        _ = try await subject.anisetteData()

        let requests = servers.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.server == first })
        #expect(requests[0].existingBlob == nil)
        #expect(requests[1].identifier == requests[0].identifier)
        #expect(requests[1].existingBlob == Data("machine on first.example".utf8))
        #expect(try subject.loadState()?.server == first)
    }

    @Test func presentsTheDeviceTheServerDescribes() async throws {
        defer { cleanUp() }
        _ = try await anisette().anisetteData()
        #expect(servers.requests.first?.clientInfo == "<Mac> first.example")
    }

    @Test func movesToTheNextServerWhenOneIsDown() async throws {
        defer { cleanUp() }
        servers.takeDown(first)

        _ = try await anisette().anisetteData()

        #expect(servers.requests.last?.server == second)
        #expect(servers.requests.last?.existingBlob == nil)
        #expect(try anisette().loadState()?.server == second)
    }

    @Test func staysWithTheServerHoldingItsMachine() async throws {
        defer { cleanUp() }
        servers.takeDown(first)
        _ = try await anisette().anisetteData()
        servers.bringUp(first)

        _ = try await anisette().anisetteData()

        let last = try #require(servers.requests.last)
        #expect(last.server == second)
        #expect(last.existingBlob == Data("machine on second.example".utf8))
    }

    @Test func provisionsAgainWhereTheServerForgotTheMachine() async throws {
        defer { cleanUp() }
        let subject = anisette()
        _ = try await subject.anisetteData()
        let original = try #require(try subject.loadState())
        servers.forget(original.identifier)

        _ = try await subject.anisetteData()

        let kept = try #require(try subject.loadState())
        #expect(kept.server == first)
        #expect(kept.identifier != original.identifier)
        #expect(servers.requests.allSatisfy { $0.server == first })
    }

    @Test func dropsAMachineOnAServerNoLongerListed() async throws {
        defer { cleanUp() }
        _ = try await anisette([second]).anisetteData()

        _ = try await anisette([first]).anisetteData()

        #expect(servers.requests.last?.server == first)
        #expect(servers.requests.last?.existingBlob == nil)
    }

    @Test func reportsTheLastFailureWhenEveryServerIsDown() async throws {
        defer { cleanUp() }
        servers.takeDown(first)
        servers.takeDown(second)

        await #expect(throws: FakeAnisetteServers.Down.self) {
            try await anisette().anisetteData()
        }
        #expect(try secrets.read(.serverAnisetteState) == nil)
    }

    @Test func refusesAnEmptyServerList() async throws {
        await #expect(throws: ServerAnisette.Failure.noServers) {
            try await anisette([]).anisetteData()
        }
    }

    @Test func readsTheServersDescriptionOfItsDevice() throws {
        let document = Data("""
            {"client_info":"<MacBookPro13,3> <Mac OS X;10.12.6;16G29> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",\
            "user_agent":"akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0"}
            """.utf8)
        let info = try JSONDecoder().decode(AnisetteServerClientInfo.self, from: document)
        #expect(info.clientInfo.hasPrefix("<MacBookPro13,3>"))
        #expect(info.userAgent == "akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0")
    }
}
