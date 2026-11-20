import Darwin
import Foundation
import HarborCore
import Minimuxer
import MinimuxerCommon
import Testing

@testable import HarborDevice

/// A phone that listens on `open` at `address`, and refuses everything else
/// there. Other addresses never answer. Records what was tried.
final class FakePhone: @unchecked Sendable {
    let address: String
    let open: Set<UInt16>
    private let lock = NSLock()
    private var tried: [(address: String, ports: [UInt16])] = []

    init(address: String = "10.7.0.1", open: Set<UInt16>) {
        self.address = address
        self.open = open
    }

    var attempts: [(address: String, ports: [UInt16])] { lock.withLock { tried } }
    var portsTried: [UInt16] { attempts.flatMap(\.ports) }

    var probe: RemotePairingPortFinder.Probe {
        { [self] address, ports in
            lock.withLock { tried.append((address, ports)) }
            guard address == self.address else { return .init(open: [], answered: false) }
            return .init(open: open.intersection(ports), answered: true)
        }
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

@Suite struct RemotePairingPortTests {
    /// A preferences domain of this test's own; each instance reads it.
    let suite = "harbor-tests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    func finder(
        _ phone: FakePhone, tunnel: [String] = [], clock: Clock = Clock()
    ) -> RemotePairingPortFinder {
        RemotePairingPortFinder(
            defaults: defaults, probe: phone.probe, tunnelAddresses: { tunnel }, now: { clock.now })
    }

    @Test func triesThePortThatWorkedLastTimeFirst() async {
        let phone = FakePhone(open: [61560])
        let subject = finder(phone)
        await subject.remember(port: 61560)

        #expect(await subject.resolve(current: 49152) == 61560)
        #expect(phone.attempts.count == 1)
    }

    @Test func goesBackTo49152WhenTheRememberedPortHasGone() async {
        let phone = FakePhone(open: [49152])
        let subject = finder(phone)
        await subject.remember(port: 61560)

        #expect(await subject.resolve(current: 61560) == 49152)
        #expect(phone.portsTried == [49152])
    }

    @Test func scansForAPortThatMovedSkippingLockdown() async {
        let phone = FakePhone(open: [62078, 61560])
        let subject = finder(phone)

        #expect(await subject.resolve(current: 49152) == 61560)
        #expect(!phone.portsTried.contains(62078))
        #expect(!phone.portsTried.contains(49152))
        #expect(phone.attempts.allSatisfy { $0.ports.count <= RemotePairingPortFinder.batchSize })
    }

    @Test func findsAPortInTheLastPartialBatch() async {
        let phone = FakePhone(open: [65535])
        #expect(await finder(phone).resolve(current: 49152) == 65535)
    }

    @Test func givesUpOnAnAddressThatNeverAnswers() async {
        let phone = FakePhone(address: "10.7.0.1", open: [50000])
        let subject = finder(phone, tunnel: ["10.99.0.1"])

        #expect(await subject.resolve(current: 49152) == 50000)
        // One batch at the silent address, then on to the phone.
        #expect(phone.attempts.filter { $0.address == "10.99.0.1" }.count == 1)
    }

    @Test func usesTheAddressMinimuxerReportsBeforeTheUsualOne() async {
        let phone = FakePhone(address: "10.8.0.1", open: [49152])
        let subject = finder(phone)
        await subject.notePeer("10.8.0.1")

        #expect(await subject.resolve(current: 50000) == 49152)
        #expect(phone.attempts.first?.address == "10.8.0.1")
    }

    @Test func doesNotScanAgainSoonAfterFindingNothing() async {
        let phone = FakePhone(open: [])
        let clock = Clock()
        let subject = finder(phone, clock: clock)

        #expect(await subject.resolve(current: 49152) == 49152)
        let afterFirst = phone.attempts.count
        #expect(afterFirst > 1)

        clock.advance(30)
        #expect(await subject.resolve(current: 49152) == 49152)
        #expect(phone.attempts.count == afterFirst)

        clock.advance(31)
        _ = await subject.resolve(current: 49152)
        #expect(phone.attempts.count > afterFirst)
    }

    @Test func remembersOnlyAPortThatIsNotTheDefault() async {
        let subject = finder(FakePhone(open: []))
        await subject.notePeer("10.7.0.1")

        await subject.remember(port: 61560)
        #expect(await subject.rememberedPort == 61560)
        #expect(defaults.string(forKey: RemotePairingPortFinder.addressKey) == "10.7.0.1")

        await subject.remember(port: 49152)
        #expect(await subject.rememberedPort == nil)
    }

    /// The real probe, against a listener on this machine. Darwin hands out
    /// listening ports from 49152 up, the range the finder scans.
    @Test func theTCPProbeTellsAnOpenPortFromARefusedOne() throws {
        let listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        try #require(listener >= 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        try #require(listen(listener, 8) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        let closed: UInt16 = port == 65535 ? port - 1 : port + 1

        let result = RemotePairingPortFinder.tcpProbe(address: "127.0.0.1", ports: [closed, port])

        #expect(result.open == [port])
        #expect(result.answered)
    }

    @Test func anAddressThatIsNotIPv4AnswersNothing() {
        let result = RemotePairingPortFinder.tcpProbe(address: "not an address", ports: [49152])
        #expect(result == .init(open: [], answered: false))
    }
}

@Suite struct MinimuxerTransportPortTests {
    final class Port: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt16 = 49152
        private(set) var sets: [UInt16] = []
        var setting: MinimuxerTransport.PortSetting {
            .init(
                get: { [self] in lock.withLock { value } },
                set: { [self] port in lock.withLock { value = port; sets.append(port) } }
            )
        }
        func moved(to port: UInt16) { lock.withLock { value = port } }
    }

    /// A preferences domain of this test's own; each instance reads it.
    let suite = "harbor-tests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    func subject(_ fake: FakeMinimuxer, _ port: Port, phone: FakePhone) -> (MinimuxerTransport, RemotePairingPortFinder) {
        let finder = RemotePairingPortFinder(defaults: defaults, probe: phone.probe, tunnelAddresses: { [] })
        let transport = MinimuxerTransport(
            core: fake,
            diskImageDirectory: URL(fileURLWithPath: "/private/harbor/disk-images", isDirectory: true),
            systemVersion: (27, 2),
            portFinder: finder,
            remotePairingPort: port.setting
        )
        return (transport, finder)
    }

    @Test func startsFromTheRememberedPort() async throws {
        let port = Port()
        let (transport, finder) = subject(FakeMinimuxer(), port, phone: FakePhone(open: [61000]))
        await finder.remember(port: 61000)

        try await transport.connect(using: PairingFixture.combined())

        #expect(port.sets == [61000])
    }

    @Test func remembersThePortMinimuxerConnectedOn() async throws {
        let port = Port()
        // Where minimuxer ended up, having asked the finder while starting.
        port.moved(to: 61560)
        let (transport, finder) = subject(FakeMinimuxer(), port, phone: FakePhone(open: [61560]))

        try await transport.connect(using: PairingFixture.combined())

        #expect(port.sets.isEmpty)
        #expect(await finder.rememberedPort == 61560)
    }

    @Test func givesMinimuxerAResolverForRemotePairingOnly() async throws {
        let fake = FakeMinimuxer()
        let (transport, _) = subject(fake, Port(), phone: FakePhone(open: [61560]))

        try await transport.connect(using: PairingFixture.combined())
        let resolve = try #require(fake.binding?.resolveServicePort)

        #expect(await resolve(ServicePort(protocolType: .rppairing, port: 49152)).port == 61560)
        #expect(await resolve(ServicePort(protocolType: .lockdown, port: 62078)).port == 62078)
    }

    @Test func aFailedStartRemembersNothing() async throws {
        let fake = FakeMinimuxer(failingWith: .noConnection("tunnel"))
        let port = Port()
        port.moved(to: 61560)
        let (transport, finder) = subject(fake, port, phone: FakePhone(open: []))

        await #expect(throws: DeviceIssue.self) {
            try await transport.connect(using: PairingFixture.combined())
        }
        #expect(await finder.rememberedPort == nil)
    }
}
