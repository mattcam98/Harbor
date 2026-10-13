#if canImport(Darwin)
import Foundation

public enum DownloadError: Error, Equatable, Sendable {
    /// The address, or somewhere it redirected to, is not HTTPS.
    case notSecure(String)
    /// The server answered with something other than success.
    case status(Int)
    case tooLarge(limit: Int64)
}

/// Downloads catalogues and apps to a file.
///
/// Nothing here decides whether a download can be trusted; that is
/// `ArtifactVerifier`'s job, on the file this returns. What this does
/// guarantee is the transport: HTTPS from the first request to the last
/// redirect, no cookies or cache carried between requests, and a ceiling on
/// the size so a server cannot fill the device.
public struct ArtifactDownloader: Sendable {
    /// A catalogue is a list of text entries; the largest in use are around
    /// ten megabytes.
    public static let catalogueLimit: Int64 = 64 << 20
    public static let appLimit: Int64 = 4 << 30

    public typealias Progress = @Sendable (_ received: Int64, _ expected: Int64?) -> Void

    private let configuration: @Sendable () -> URLSessionConfiguration

    public init(configuration: @escaping @Sendable () -> URLSessionConfiguration = ArtifactDownloader.privateConfiguration) {
        self.configuration = configuration
    }

    /// Keeps nothing between requests and sends nothing that identifies the
    /// user beyond what any connection does.
    public static func privateConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        return configuration
    }

    /// Downloads to a new temporary file and returns it. The caller removes
    /// the file when done with it.
    ///
    /// - Parameter progress: called a few times a second while data arrives,
    ///   on an arbitrary thread.
    public func download(
        _ url: URL,
        limit: Int64,
        progress: @escaping Progress = { _, _ in }
    ) async throws -> URL {
        guard Self.isSecure(url) else {
            throw DownloadError.notSecure(url.host ?? url.absoluteString)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-download-\(UUID().uuidString)")
        let transfer = Transfer(destination: destination, limit: limit, progress: progress)
        let session = URLSession(configuration: configuration(), delegate: transfer, delegateQueue: nil)
        let task = session.downloadTask(with: URLRequest(url: url))

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.begin(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func isSecure(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https" && url?.host?.isEmpty == false
    }
}

/// One download. The session's delegate callbacks arrive on its own queue,
/// so the state they share is behind a lock.
private final class Transfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let limit: Int64
    private let progress: ArtifactDownloader.Progress

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?
    /// The first thing that went wrong. It outranks the cancellation it causes.
    private var failure: DownloadError?
    private var saved = false
    private var lastReport = Date.distantPast

    init(destination: URL, limit: Int64, progress: @escaping ArtifactDownloader.Progress) {
        self.destination = destination
        self.limit = limit
        self.progress = progress
    }

    func begin(_ continuation: CheckedContinuation<URL, any Error>) {
        lock.withLock { self.continuation = continuation }
    }

    private func fail(_ error: DownloadError) {
        lock.withLock { if failure == nil { failure = error } }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard ArtifactDownloader.isSecure(request.url) else {
            fail(.notSecure(request.url?.host ?? request.url?.absoluteString ?? ""))
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        if totalBytesWritten > limit || (expected ?? 0) > limit {
            fail(.tooLarge(limit: limit))
            downloadTask.cancel()
            return
        }
        let due = lock.withLock {
            let now = Date()
            guard now.timeIntervalSince(lastReport) >= 0.2 else { return false }
            lastReport = now
            return true
        }
        if due {
            progress(totalBytesWritten, expected)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The file at `location` is gone when this returns, so it is judged
        // and moved here.
        guard let response = downloadTask.response as? HTTPURLResponse else {
            fail(.status(0))
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            fail(.status(response.statusCode))
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value
        guard let size, size <= limit else {
            fail(.tooLarge(limit: limit))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { saved = true }
            progress(size, size)
        } catch {
            fail(.status(0))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        session.finishTasksAndInvalidate()

        let (continuation, failure, saved) = lock.withLock {
            let state = (self.continuation, self.failure, self.saved)
            self.continuation = nil
            return state
        }
        guard let continuation else { return }

        if let failure {
            try? FileManager.default.removeItem(at: destination)
            continuation.resume(throwing: failure)
        } else if let error {
            try? FileManager.default.removeItem(at: destination)
            let cancelled = (error as? URLError)?.code == .cancelled
            continuation.resume(throwing: cancelled ? CancellationError() : error)
        } else if saved {
            continuation.resume(returning: destination)
        } else {
            continuation.resume(throwing: DownloadError.status(0))
        }
    }
}
#endif
