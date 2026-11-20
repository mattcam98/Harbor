import Darwin
import Foundation
import os

/// Finds the port this iPhone's RemotePairing service listens on, through
/// LocalDevVPN.
///
/// minimuxer assumes 49152. On iOS 27.2 some phones listen elsewhere, a
/// port that can change when the phone restarts, and every renewal then
/// fails to reach the phone (Henge #67, 9 November 2026). Looking the
/// service up on the phone with Bonjour is no help there: it finds nothing,
/// or another device's port. So, in order:
///
/// 1. the port that worked last time,
/// 2. 49152,
/// 3. every port from 49152 up, through the VPN, except lockdownd's 62078.
///
/// minimuxer asks only when the phone doesn't answer on the port it has
/// (`ConnectionConfigBinding.resolveServicePort`), re-checks the answer, and
/// uses it from then on. The port is remembered once a connection works.
public actor RemotePairingPortFinder {
    /// Which of `ports` accept a TCP connection at `address`, and whether
    /// the address answered at all (accepted or refused). An address that
    /// lets every attempt time out is not the phone.
    public typealias Probe = @Sendable (_ address: String, _ ports: [UInt16]) async -> ProbeResult

    public struct ProbeResult: Sendable, Equatable {
        public var open: Set<UInt16>
        public var answered: Bool

        public init(open: Set<UInt16>, answered: Bool) {
            self.open = open
            self.answered = answered
        }
    }

    public static let defaultPort: UInt16 = 49152
    /// Where iOS gives services their ports.
    static let scanRange: ClosedRange<UInt16> = 49152...65535
    /// lockdownd, which also answers through the VPN and is not RemotePairing.
    static let lockdownPort: UInt16 = 62078
    /// Few enough open sockets at once to stay well inside an app's limit.
    static let batchSize = 64
    /// minimuxer asks again on every network change; a scan that found
    /// nothing is not repeated within this time.
    static let quietPeriod: TimeInterval = 60
    /// LocalDevVPN's address for the phone, when nothing better is known.
    static let localDevVPNPhoneAddress = "10.7.0.1"

    static let portKey = "HarborRemotePairingPort"
    static let addressKey = "HarborRemotePairingAddress"

    private let defaults: UserDefaults
    private let probe: Probe
    private let tunnelAddresses: @Sendable () -> [String]
    private let now: @Sendable () -> Date
    private var reportedPeer: String?
    private var lastFruitlessScan: Date?
    private let log = Logger(subsystem: "Harbor", category: "RemotePairing")

    public init(
        defaults: UserDefaults = .standard,
        probe: @escaping Probe = { address, ports in
            RemotePairingPortFinder.tcpProbe(address: address, ports: ports)
        },
        tunnelAddresses: @escaping @Sendable () -> [String] = { RemotePairingPortFinder.vpnPeerAddresses() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.probe = probe
        self.tunnelAddresses = tunnelAddresses
        self.now = now
    }

    /// The port that last worked, if it isn't the default.
    public var rememberedPort: UInt16? {
        let value = defaults.integer(forKey: Self.portKey)
        guard let port = UInt16(exactly: value), port != 0 else { return nil }
        return port
    }

    /// The phone's address on the VPN, as minimuxer reports it.
    public func notePeer(_ address: String?) {
        guard let address, !address.isEmpty else { return }
        reportedPeer = address
    }

    /// A connection on `port` worked: try it first next time.
    public func remember(port: UInt16) {
        if port == Self.defaultPort {
            defaults.removeObject(forKey: Self.portKey)
        } else {
            defaults.set(Int(port), forKey: Self.portKey)
        }
        if let reportedPeer {
            defaults.set(reportedPeer, forKey: Self.addressKey)
        }
        lastFruitlessScan = nil
    }

    /// The port to try instead of `current`, which the phone did not answer
    /// on; `current` itself when nothing better was found.
    public func resolve(current: UInt16) async -> UInt16 {
        let addresses = candidateAddresses()
        guard !addresses.isEmpty else { return current }

        var quick: [UInt16] = []
        if let remembered = rememberedPort, remembered != current { quick.append(remembered) }
        if current != Self.defaultPort, !quick.contains(Self.defaultPort) { quick.append(Self.defaultPort) }
        if !quick.isEmpty {
            for address in addresses {
                let result = await probe(address, quick)
                if let port = quick.first(where: result.open.contains) {
                    log.info("RemotePairing answered on port \(port, privacy: .public)")
                    return port
                }
            }
        }

        if let last = lastFruitlessScan, now().timeIntervalSince(last) < Self.quietPeriod {
            return current
        }
        log.info("RemotePairing is not on port \(current, privacy: .public); scanning")
        for address in addresses {
            if let port = await scan(address, skipping: Set(quick).union([current])) {
                log.info("RemotePairing found on port \(port, privacy: .public) by scanning")
                return port
            }
        }
        lastFruitlessScan = now()
        log.info("No RemotePairing port found")
        return current
    }

    private func scan(_ address: String, skipping skipped: Set<UInt16>) async -> UInt16? {
        let ports = Self.scanRange.filter { $0 != Self.lockdownPort && !skipped.contains($0) }
        var start = ports.startIndex
        while start < ports.endIndex {
            let end = min(start + Self.batchSize, ports.endIndex)
            let batch = Array(ports[start..<end])
            let result = await probe(address, batch)
            if let found = batch.first(where: result.open.contains) { return found }
            // Nothing at all came back from the first batch: not the phone.
            if start == ports.startIndex, !result.answered { return nil }
            start = end
        }
        return nil
    }

    private func candidateAddresses() -> [String] {
        var seen = Set<String>()
        let all = [reportedPeer, defaults.string(forKey: Self.addressKey)].compactMap { $0 }
            + tunnelAddresses()
            + [Self.localDevVPNPhoneAddress]
        return all.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: The network

    /// Tries `ports` at an IPv4 `address` at once, without blocking, and
    /// waits up to `timeout` for the answers.
    public static func tcpProbe(address: String, ports: [UInt16], timeout: TimeInterval = 0.25) -> ProbeResult {
        var target = in_addr()
        guard inet_pton(AF_INET, address, &target) == 1 else {
            return ProbeResult(open: [], answered: false)
        }
        var sockets: [(fd: Int32, port: UInt16)] = []
        defer { sockets.forEach { close($0.fd) } }
        var open = Set<UInt16>()
        var answered = false

        for port in ports {
            let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { continue }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = target
            let status = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if status == 0 {
                open.insert(port)
                answered = true
                close(fd)
            } else if errno == EINPROGRESS {
                sockets.append((fd, port))
            } else {
                if errno == ECONNREFUSED { answered = true }
                close(fd)
            }
        }

        var pending = sockets
        sockets = []
        let deadline = Date().addingTimeInterval(timeout)
        while !pending.isEmpty {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var fds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
            let ready = poll(&fds, nfds_t(fds.count), Int32(remaining * 1000))
            guard ready > 0 else { break }
            var still: [(fd: Int32, port: UInt16)] = []
            for (index, entry) in pending.enumerated() {
                guard fds[index].revents != 0 else {
                    still.append(entry)
                    continue
                }
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(entry.fd, SOL_SOCKET, SO_ERROR, &error, &length)
                if error == 0 {
                    open.insert(entry.port)
                    answered = true
                } else if error == ECONNREFUSED {
                    answered = true
                }
                close(entry.fd)
            }
            pending = still
        }
        pending.forEach { close($0.fd) }
        return ProbeResult(open: open, answered: answered)
    }

    /// The far end of each VPN tunnel interface: the phone, through
    /// LocalDevVPN.
    public static func vpnPeerAddresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var addresses: [String] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = interface.pointee
            guard String(cString: entry.ifa_name).hasPrefix("utun"),
                  entry.ifa_flags & UInt32(IFF_POINTOPOINT) != 0,
                  let destination = entry.ifa_dstaddr,
                  destination.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            var address = destination.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil {
                let bytes = text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                addresses.append(String(decoding: bytes, as: UTF8.self))
            }
        }
        return addresses
    }
}
