import Foundation
import HarborCore
import SideSign
import Testing

@testable import HarborSigning

@Suite struct TwoFactorTests {
    static let phones = [
        TrustedPhoneNumber(id: "1", number: "•• 11"),
        TrustedPhoneNumber(id: "2", number: "•• 22"),
    ]

    /// Records the prompts shown and answers each with the same code.
    final class Asker: @unchecked Sendable {
        private let lock = NSLock()
        private var shown: [VerificationPrompt] = []
        private let answer: String?

        init(answering answer: String?) {
            self.answer = answer
        }

        var prompts: [VerificationPrompt] { lock.withLock { shown } }

        func ask(_ prompt: VerificationPrompt) -> String? {
            lock.withLock { shown.append(prompt) }
            return answer
        }
    }

    func respond(to request: TwoFactorRequest, answering answer: String? = "123456") async throws
        -> (response: TwoFactorResponse, prompts: [VerificationPrompt])
    {
        let asker = Asker(answering: answer)
        let response = try await TwoFactor.handler(asking: asker.ask)(request)
        return (response, asker.prompts)
    }

    @Test func choosesADeliveryMethodWithoutBotheringTheUser() async throws {
        let device = try await respond(
            to: .selectDeliveryMethod(preferredMode: .trustedDevice, phoneNumbers: Self.phones))
        guard case .requestTrustedDevice = device.response else {
            Issue.record("expected a trusted-device request, got \(device.response)")
            return
        }
        #expect(device.prompts.isEmpty)

        let sms = try await respond(to: .selectDeliveryMethod(preferredMode: .sms, phoneNumbers: Self.phones))
        guard case .requestSMS(let phoneID) = sms.response else {
            Issue.record("expected an SMS request, got \(sms.response)")
            return
        }
        #expect(phoneID == "1")

        let noPhones = try await respond(to: .selectDeliveryMethod(preferredMode: .sms, phoneNumbers: []))
        guard case .requestTrustedDevice = noPhones.response else {
            Issue.record("expected a trusted-device fallback, got \(noPhones.response)")
            return
        }
    }

    @Test func asksForATrustedDeviceCodeAndPassesOnApplesError() async throws {
        let result = try await respond(to: .trustedDevice(error: "Incorrect code"), answering: "123 456")

        guard case .verificationCode(let code) = result.response else {
            Issue.record("expected a code, got \(result.response)")
            return
        }
        #expect(code == "123456")
        #expect(result.prompts == [.trustedDeviceCode(error: "Incorrect code")])
    }

    @Test func namesTheNumberAPhoneCodeWasSentTo() async throws {
        let result = try await respond(to: .sms(phoneNumbers: Self.phones, activeID: "2", error: nil))

        guard case .verificationCode("123456") = result.response else {
            Issue.record("expected the code, got \(result.response)")
            return
        }
        #expect(result.prompts == [.phoneCode(number: "•• 22", error: nil)])
    }

    @Test(arguments: [nil, "", "   ", "abc"] as [String?])
    func noUsableCodeCancels(_ answer: String?) async throws {
        let result = try await respond(to: .trustedDevice(error: nil), answering: answer)
        guard case .cancel = result.response else {
            Issue.record("expected cancel, got \(result.response)")
            return
        }
    }
}

@Suite struct InlinePayloadTests {
    @Test func unwrapsTheArchive() throws {
        let archive = Data([0x50, 0x4b, 0x03, 0x04, 0xff])
        let document = try JSONSerialization.data(withJSONObject: [
            "s": "a digest that is deliberately ignored",
            "l": archive.base64EncodedString(),
        ])
        #expect(try OnDeviceAnisette.archive(fromInlinePayload: document) == archive)
    }

    @Test(arguments: [#"{"s":"x"}"#, #"{"l":""}"#, #"{"l":"!!!"}"#, "not json"])
    func rejectsDocumentsWithoutAPayload(_ text: String) {
        #expect(throws: OnDeviceAnisette.PayloadError.malformed) {
            try OnDeviceAnisette.archive(fromInlinePayload: Data(text.utf8))
        }
    }
}
