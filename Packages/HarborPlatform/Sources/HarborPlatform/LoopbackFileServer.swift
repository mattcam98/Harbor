#if canImport(Network)
import Foundation
import Network

/// Serves one file to this device only, for as long as it is kept running.
///
/// iOS installs a configuration profile only when Safari downloads one from
/// a web address; it will not take one from an app directly. This gives
/// Safari an address for a profile Harbor has just made: a listener on the
/// loopback interface, on a port the system picks, at a path that is
/// different every time.
///
/// Nothing leaves the device and nothing but the one file is served.
public final class LoopbackFileServer: @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case couldNotStart(String)
    }

    private let body: Data
    private let contentType: String
    private let path: String
    private let queue = DispatchQueue(label: "harbor.loopback-file-server")

    private let lock = NSLock()
    private var listener: NWListener?

    /// - Parameter fileName: the last part of the address, which Safari
    ///   shows. It is not used to find anything.
    public init(body: Data, contentType: String, fileName: String) {
        self.body = body
        self.contentType = contentType
        // Plain letters and digits only, so the address Safari asks for is
        // character for character the one given out.
        let safeName = fileName.unicodeScalars.map { scalar -> String in
            let plain = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-")
            return plain ? String(scalar) : "-"
        }.joined()
        path = "/\(UUID().uuidString.lowercased())/\(safeName.isEmpty ? "file" : safeName)"
    }

    deinit {
        listener?.cancel()
    }

    /// Starts listening and returns the address of the file.
    public func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Failure.couldNotStart(error.localizedDescription)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    resumed.run { continuation.resume(returning: port) }
                case .failed(let error):
                    resumed.run { continuation.resume(throwing: Failure.couldNotStart(error.localizedDescription)) }
                case .cancelled:
                    resumed.run { continuation.resume(throwing: Failure.couldNotStart("stopped")) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        lock.withLock { self.listener = listener }
        // The parts are a literal, a port number and a path made above.
        return URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    public func stop() {
        let listener = lock.withLock {
            defer { self.listener = nil }
            return self.listener
        }
        listener?.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A request for one small file fits in the first read.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [body, contentType, path] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let line = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = line.split(separator: " ")

            let response: Data
            if parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD", parts[1] == path {
                var header = "HTTP/1.1 200 OK\r\n"
                header += "Content-Type: \(contentType)\r\n"
                header += "Content-Length: \(body.count)\r\n"
                header += "Cache-Control: no-store\r\n"
                header += "Connection: close\r\n\r\n"
                response = Data(header.utf8) + (parts[0] == "HEAD" ? Data() : body)
            } else {
                response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

/// Runs a block the first time it is asked to and never again.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ block: () -> Void) {
        let first = lock.withLock {
            defer { done = true }
            return !done
        }
        if first {
            block()
        }
    }
}
#endif
