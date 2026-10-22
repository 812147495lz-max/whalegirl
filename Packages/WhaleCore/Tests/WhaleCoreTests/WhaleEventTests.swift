import Foundation
import Testing
@testable import WhaleCore

struct WhaleEventTests {
    private func validJSON(
        eventID: UUID = UUID(),
        eventType: String = "agent.waiting_approval",
        occurredAt: String = "2026-10-10T15:00:00+08:00",
        sequence: String = "42",
        extra: String = ""
    ) -> Data {
        Data("""
        {
          "schemaVersion": 1,
          "eventId": "\(eventID.uuidString)",
          "source": "codex",
          "sourceInstance": "local-mac",
          "sessionId": "session-1",
          "parentSessionId": null,
          "projectKey": "whale-project",
          "eventType": "\(eventType)",
          "occurredAt": "\(occurredAt)",
          "receivedAt": null,
          "sequence": \(sequence),
          "severity": "action_required",
          "summary": "Codex 正在等待操作授权",
          "displayTarget": {"kind":"app","bundleId":"com.openai.codex","uri":null},
          "metadata": {"client":"codex-cli","approvalKind":"shell_command"},
          "privacyClass": "metadata_only"
          \(extra)
        }
        """.utf8)
    }

    @Test func decodesStrictSecondsTimestamp() throws {
        let event = try WhaleEventCodec.decode(validJSON())
        #expect(event.eventType == "agent.waiting_approval")
        #expect(event.sequence == 42)
        #expect(event.receivedAt == nil)
    }

    @Test(arguments: [
        "2026-10-10T15:00:00.123+08:00",
        "2026-10-10T15:00:00",
        "2026-02-30T15:00:00Z"
    ])
    func rejectsInvalidTimestamps(_ timestamp: String) {
        #expect(throws: WhaleEventCodecError.self) {
            try WhaleEventCodec.decode(validJSON(occurredAt: timestamp))
        }
    }

    @Test func rejectsUnknownFieldsAndOversizedSequence() {
        #expect(throws: WhaleEventCodecError.self) {
            try WhaleEventCodec.decode(validJSON(extra: ",\"prompt\":\"secret\""))
        }
        #expect(throws: WhaleEventCodecError.self) {
            try WhaleEventCodec.decode(validJSON(sequence: "9223372036854775808"))
        }
    }

    @Test func rejectsUnsafeDisplayURIAndMetadata() throws {
        let unsafeURI = validJSON()
            .replacingOccurrences(of: "\"uri\":null", with: "\"uri\":\"file:///tmp/a\"")
        #expect(throws: WhaleEventCodecError.self) { try WhaleEventCodec.decode(unsafeURI) }

        let unsafeMetadata = validJSON()
            .replacingOccurrences(of: "\"approvalKind\":\"shell_command\"", with: "\"prompt\":\"secret\"")
        #expect(throws: WhaleEventCodecError.self) { try WhaleEventCodec.decode(unsafeMetadata) }
    }

    @Test func enforcesSummaryLimits() {
        let event = WhaleEvent(
            source: .codex,
            sourceInstance: "local",
            sessionId: "s",
            eventType: "agent.working",
            occurredAt: Date(),
            severity: .info,
            summary: String(repeating: "鲸", count: 201)
        )
        #expect(throws: WhaleEventCodecError.summaryTooLong) { try WhaleEventCodec.validate(event) }
    }
}

private extension Data {
    func replacingOccurrences(of old: String, with new: String) -> Data {
        let text = String(decoding: self, as: UTF8.self).replacingOccurrences(of: old, with: new)
        return Data(text.utf8)
    }
}
