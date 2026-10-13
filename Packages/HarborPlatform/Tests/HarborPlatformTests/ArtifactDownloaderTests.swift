#if canImport(Darwin)
import Foundation
import HarborCore
import Testing

@testable import HarborPlatform

/// Answers requests for `stub.test` from a fixed table, so the downloader's
/// rules can be tested without a network.
final class StubServer: URLProtocol, @unchecked Sendable {
    static let body = Data(repeating: 0x5a, count: 3000)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let client else { return }

        func respond(_ status: Int, _ data: Data) {
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(data.count)"])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // In pieces, as a real download arrives.
            var offset = 0
            while offset < data.count {
                let end = min(offset + 1000, data.count)
                client.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
                offset = end
            }
            client.urlProtocolDidFinishLoading(self)
        }

        func redirect(to address: String) {
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": address])!
            client.urlProtocol(
                self, wasRedirectedTo: URLRequest(url: URL(string: address)!), redirectResponse: response)
        }

        switch url.path {
        case "/file": respond(200, Self.body)
        case "/missing": respond(404, Data("not here".utf8))
        case "/moved": redirect(to: "https://stub.test/file")
        case "/downgraded": redirect(to: "http://stub.test/file")
        default: respond(500, Data())
        }
    }

    static func downloader() -> ArtifactDownloader {
        ArtifactDownloader {
            let configuration = ArtifactDownloader.privateConfiguration()
            configuration.protocolClasses = [StubServer.self]
            return configuration
        }
    }
}

@Suite struct ArtifactDownloaderTests {
    let downloader = StubServer.downloader()

    static func url(_ path: String) -> URL { URL(string: "https://stub.test\(path)")! }

    @Test func downloadsToAFile() async throws {
        let file = try await downloader.download(Self.url("/file"), limit: 10_000)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(try Data(contentsOf: file) == StubServer.body)
    }

    @Test func reportsProgressUpToTheWholeFile() async throws {
        let seen = Recorder()
        let file = try await downloader.download(Self.url("/file"), limit: 10_000) { received, expected in
            seen.add(received, expected)
        }
        defer { try? FileManager.default.removeItem(at: file) }

        let last = try #require(seen.values.last)
        #expect(last.received == 3000)
        #expect(last.expected == 3000)
    }

    @Test func followsARedirectThatStaysOnHTTPS() async throws {
        let file = try await downloader.download(Self.url("/moved"), limit: 10_000)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(try Data(contentsOf: file) == StubServer.body)
    }

    @Test func refusesARedirectToPlainHTTP() async {
        await #expect(throws: DownloadError.notSecure("stub.test")) {
            try await downloader.download(Self.url("/downgraded"), limit: 10_000)
        }
    }

    @Test func refusesAPlainHTTPAddressWithoutConnecting() async {
        await #expect(throws: DownloadError.notSecure("stub.test")) {
            try await downloader.download(URL(string: "http://stub.test/file")!, limit: 10_000)
        }
    }

    @Test func anErrorPageIsNotADownload() async {
        await #expect(throws: DownloadError.status(404)) {
            try await downloader.download(Self.url("/missing"), limit: 10_000)
        }
    }

    @Test func stopsAtTheSizeLimit() async {
        await #expect(throws: DownloadError.tooLarge(limit: 2000)) {
            try await downloader.download(Self.url("/file"), limit: 2000)
        }
    }

    /// Reads a real source over the network and decodes it. Skipped unless
    /// asked for:  HARBOR_LIVE_SOURCE=https://… swift test
    @Test func readsALiveSourceWhenAskedTo() async throws {
        guard let address = ProcessInfo.processInfo.environment["HARBOR_LIVE_SOURCE"] else { return }
        let file = try await ArtifactDownloader().download(
            try SourceList.address(from: address), limit: ArtifactDownloader.catalogueLimit)
        defer { try? FileManager.default.removeItem(at: file) }

        let source = try SourceCatalogue.decode(Data(contentsOf: file), trust: .unverified)
        print("Live source \"\(source.name)\": \(source.apps.count) apps, \(source.skippedEntries) entries left out")
        #expect(!source.apps.isEmpty)
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(received: Int64, expected: Int64?)] = []

    func add(_ received: Int64, _ expected: Int64?) {
        lock.withLock { recorded.append((received, expected)) }
    }

    var values: [(received: Int64, expected: Int64?)] {
        lock.withLock { recorded }
    }
}
#endif
