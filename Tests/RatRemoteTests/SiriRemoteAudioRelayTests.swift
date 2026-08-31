import XCTest
@testable import RatRemote

final class SiriRemoteAudioRelayTests: XCTestCase {
    func testExtractsOpusPayloadFromMicrophoneReport() {
        var report = Data(repeating: 0, count: 99)
        report[0] = 0xFA
        report[4] = 3
        report[5] = 0x11
        report[6] = 0x22
        report[7] = 0x33

        XCTAssertEqual(SiriRemoteAudioRelay.opusPacket(from: report), Data([0x11, 0x22, 0x33]))
    }

    func testRejectsMalformedMicrophoneReports() {
        XCTAssertNil(SiriRemoteAudioRelay.opusPacket(from: Data(repeating: 0, count: 98)))

        var emptyPacket = Data(repeating: 0, count: 99)
        emptyPacket[4] = 0
        XCTAssertNil(SiriRemoteAudioRelay.opusPacket(from: emptyPacket))

        var oversizedPacket = Data(repeating: 0, count: 99)
        oversizedPacket[4] = 95
        XCTAssertNil(SiriRemoteAudioRelay.opusPacket(from: oversizedPacket))
    }
}
