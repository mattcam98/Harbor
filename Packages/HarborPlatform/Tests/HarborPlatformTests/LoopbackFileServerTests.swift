#if canImport(Network)
import Foundation
import Testing

@testable import HarborPlatform

@Suite struct LoopbackFileServerTests {
    static let body = Data("<plist>profile</plist>".utf8)

    func server(fileName: String = "Player.mobileconfig") -> LoopbackFileServer {
        LoopbackFileServer(body: Self.body, contentType: "application/x-apple-aspen-config", fileName: fileName)
    }

    func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        return (data, try #require(response as? HTTPURLResponse))
    }

    @Test func servesTheFileWithItsTypeOnTheLoopbackAddress() async throws {
        let server = server()
        let address = try await server.start()
        defer { server.stop() }

        #expect(address.scheme == "http")
        #expect(address.host == "127.0.0.1")
        #expect(address.lastPathComponent == "Player.mobileconfig")

        let (data, response) = try await fetch(address)
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/x-apple-aspen-config")
        #expect(data == Self.body)
    }

    @Test func servesNothingElse() async throws {
        let server = server()
        let address = try await server.start()
        defer { server.stop() }

        let root = try #require(URL(string: "/", relativeTo: address)?.absoluteURL)
        #expect(try await fetch(root).1.statusCode == 404)
        // The right name at the wrong path is not enough.
        let guess = try #require(URL(string: "/Player.mobileconfig", relativeTo: address)?.absoluteURL)
        #expect(try await fetch(guess).1.statusCode == 404)
    }

    @Test func theAddressIsDifferentEveryTime() async throws {
        let first = server()
        let second = server()
        let one = try await first.start()
        let two = try await second.start()
        defer {
            first.stop()
            second.stop()
        }
        #expect(one.path != two.path)
    }

    @Test func aNameWithOddCharactersStillMakesAnAddress() async throws {
        let server = server(fileName: "Mon appli / ünï.mobileconfig")
        let address = try await server.start()
        defer { server.stop() }

        #expect(try await fetch(address).1.statusCode == 200)
    }

    @Test func stopsAnswering() async throws {
        let server = server()
        let address = try await server.start()
        #expect(try await fetch(address).1.statusCode == 200)

        server.stop()
        // Give the listener a moment to close.
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: (any Error).self) {
            try await fetch(address)
        }
    }
}
#endif
