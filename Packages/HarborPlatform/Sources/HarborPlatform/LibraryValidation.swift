#if canImport(Darwin)
import Darwin
import Foundation
import HarborCore

/// Asks the kernel whether it would let this process load an executable, and
/// keeps the reason when it would not.
///
/// This is the same pair of calls dyld makes before mapping a library:
/// attach the file's code signature, then run library validation. Doing it
/// up front turns a guest that would be killed at launch into an explanation.
public enum LibraryValidation {
    public enum Stage: String, Equatable, Sendable {
        /// The kernel would not accept the signature blob at all.
        case attachingSignature = "attaching the signature"
        /// The signature is well formed but not one this process may load.
        case libraryValidation = "library validation"
    }

    public enum Verdict: Equatable, Sendable {
        case accepted
        case unsigned
        case rejected(stage: Stage, code: Int32, reason: String)
    }

    public static func check(executableAt url: URL) throws -> Verdict {
        guard let location = try GuestExecutable.signatureLocation(fileAt: url) else {
            return .unsigned
        }

        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        var signature = fsignatures_t()
        signature.fs_file_start = off_t(location.sliceOffset)
        signature.fs_blob_start = UnsafeMutableRawPointer(bitPattern: location.offset)
        signature.fs_blob_size = location.size
        let attached = withUnsafeMutablePointer(to: &signature) {
            fcntl(descriptor, addFileSignaturesAndReturn, UnsafeMutableRawPointer($0))
        }
        if attached == -1 {
            let code = errno
            return .rejected(stage: .attachingSignature, code: code, reason: String(cString: strerror(code)))
        }

        var message = [CChar](repeating: 0, count: 1024)
        let (result, code): (Int32, Int32) = message.withUnsafeMutableBufferPointer { buffer in
            var request = LibraryValidationRequest(
                fileStart: off_t(location.sliceOffset),
                messageSize: buffer.count,
                message: UnsafeMutableRawPointer(buffer.baseAddress)
            )
            let result = withUnsafeMutablePointer(to: &request) {
                fcntl(descriptor, checkLibraryValidation, UnsafeMutableRawPointer($0))
            }
            return (result, errno)
        }
        if result == 0 {
            return .accepted
        }

        let detail = String(cString: message)
        return .rejected(
            stage: .libraryValidation,
            code: code,
            reason: detail.isEmpty ? String(cString: strerror(code)) : detail
        )
    }

    // fcntl commands and the request structure from <sys/fcntl.h>
    // (F_ADDFILESIGS_RETURN, F_CHECK_LV, fchecklv_t). Spelled out here because
    // not every SDK exposes them to Swift.
    private static let addFileSignaturesAndReturn: Int32 = 97
    private static let checkLibraryValidation: Int32 = 98

    private struct LibraryValidationRequest {
        var fileStart: off_t
        var messageSize: Int
        var message: UnsafeMutableRawPointer?
    }
}
#endif
