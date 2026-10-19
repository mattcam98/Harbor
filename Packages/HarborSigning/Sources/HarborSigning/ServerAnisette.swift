import Foundation
import HarborCore
import AnisetteKit
import SideSign

/// What an anisette server says about the machine it stands in for: the
/// device description and user agent Apple must see with its headers.
public struct AnisetteServerClientInfo: Codable, Equatable, Sendable {
    public var clientInfo: String
    public var userAgent: String

    enum CodingKeys: String, CodingKey {
        case clientInfo = "client_info"
        case userAgent = "user_agent"
    }

    public init(clientInfo: String, userAgent: String) {
        self.clientInfo = clientInfo
        self.userAgent = userAgent
    }
}

/// Talks to one anisette server. Separated from `ServerAnisette` so the
/// failover and the kept state can be tested without a network.
protocol AnisetteServerClient: Sendable {
    func clientInfo(server: URL) async throws -> AnisetteServerClientInfo
    func generate(
        server: URL,
        directory: URL,
        identifier: UUID,
        existingBlob: Data?,
        clientInfo: AnisetteServerClientInfo
    ) async throws -> (data: AnisetteData, newBlob: Data?)
}

struct SideSignAnisetteServerClient: AnisetteServerClient {
    func clientInfo(server: URL) async throws -> AnisetteServerClientInfo {
        var request = URLRequest(url: server.appendingPathComponent("v3").appendingPathComponent("client_info"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(AnisetteServerClientInfo.self, from: data)
    }

    func generate(
        server: URL,
        directory: URL,
        identifier: UUID,
        existingBlob: Data?,
        clientInfo: AnisetteServerClientInfo
    ) async throws -> (data: AnisetteData, newBlob: Data?) {
        var headers = AnisetteRequestHeaders()
        headers.clientInfo = clientInfo.clientInfo
        headers.userAgent = clientInfo.userAgent
        // A fresh manager each time, so SideSign's short-lived cache never
        // hands back headers for another identifier.
        let manager = AnisetteDataManager(mode: nil, baseDirectory: directory)
        let result = try await manager.fetchAnisetteData(
            mode: .remote(server: server),
            identifier: identifier,
            existingAdiBlob: existingBlob,
            headers: headers
        )
        return (result.data, result.newAdiBlob)
    }
}

/// Anisette from a server that runs Apple's provisioning on a real Mac.
///
/// Why this exists. From 12 October 2026 Apple refuses sign-in when the
/// machine identity was made by the emulated provisioning libraries
/// (`OnDeviceAnisette`, and the older anisette servers), with -80045. Some
/// servers now make the identity on a real Mac instead, and Apple accepts
/// those: measured on 19 October 2026 with an Apple ID that cannot exist,
/// `mac-ani.jkcoxson.com` and `ani3.stikstore.app` got an answer about the
/// account. This is what iloader 2.3.9 and later use. `LiveAppleProbeTests`
/// repeats the measurement.
///
/// What the server learns: the machine it provisioned and when Harbor asks
/// for headers. It never sees the Apple ID or the password, which go from
/// Harbor to Apple directly.
///
/// The machine a server provisions is kept, with the server's address, so a
/// refresh presents the machine the session was made on. Servers are tried
/// in order, the one holding Harbor's machine first. Moving to another
/// server means a new machine, which Apple may want two-factor for.
public struct ServerAnisette: AnisetteProviding {
    /// Servers whose identities Apple accepted when last measured, best
    /// first.
    public static let defaultServers: [URL] = [
        URL(string: "https://mac-ani.jkcoxson.com")!,
        URL(string: "https://ani3.stikstore.app")!,
    ]

    public enum Failure: Error, Equatable, Sendable {
        case noServers
    }

    struct State: Codable, Equatable {
        var server: URL
        var identifier: UUID
        var blob: Data?
    }

    private let servers: [URL]
    private let directory: URL
    private let secrets: any SecretStore
    private let client: any AnisetteServerClient

    /// - Parameter directory: a private directory Harbor owns, for
    ///   provisioning scratch files.
    public init(servers: [URL] = ServerAnisette.defaultServers, directory: URL, secrets: any SecretStore) {
        self.init(servers: servers, directory: directory, secrets: secrets, client: SideSignAnisetteServerClient())
    }

    init(servers: [URL], directory: URL, secrets: any SecretStore, client: any AnisetteServerClient) {
        self.servers = servers
        self.directory = directory
        self.secrets = secrets
        self.client = client
    }

    public func anisetteData() async throws -> AnisetteData {
        let stored = try loadState()
        var lastError: any Error = Failure.noServers

        for server in ordered(holding: stored?.server) {
            let state = stored.flatMap { $0.server == server ? $0 : nil } ?? State(server: server, identifier: UUID())
            do {
                return try await generate(state)
            } catch where state.blob != nil && Self.isUnprovisioned(error) {
                // The server no longer knows Harbor's machine. Provision a
                // new one there rather than move to another server.
                do {
                    return try await generate(State(server: server, identifier: UUID()))
                } catch {
                    lastError = error
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func generate(_ state: State) async throws -> AnisetteData {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let info = try await client.clientInfo(server: state.server)
        let result = try await client.generate(
            server: state.server,
            directory: directory,
            identifier: state.identifier,
            existingBlob: state.blob,
            clientInfo: info
        )
        var kept = state
        if let newBlob = result.newBlob {
            kept.blob = newBlob
        }
        try secrets.write(Redacted(JSONEncoder().encode(kept)), for: .serverAnisetteState)
        return result.data
    }

    func ordered(holding server: URL?) -> [URL] {
        guard let server, servers.contains(server) else { return servers }
        return [server] + servers.filter { $0 != server }
    }

    /// The server's answer when it has no record of the machine it is asked
    /// to stand in for.
    static func isUnprovisioned(_ error: any Error) -> Bool {
        String(describing: error).contains("-45061")
    }

    func loadState() throws -> State? {
        guard let stored = try secrets.read(.serverAnisetteState) else { return nil }
        return try? JSONDecoder().decode(State.self, from: stored.expose())
    }
}
