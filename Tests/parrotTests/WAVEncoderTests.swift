import XCTest
@testable import parrot

final class WAVEncoderTests: XCTestCase {
    func testEncodes16BitMonoWAVAndClampsSamples() {
        let wav = WAVEncoder.data(samples: [-2, 0, 2], sampleRate: 16_000)

        XCTAssertEqual(wav.count, 50)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(uint16(wav, at: 22), 1)
        XCTAssertEqual(uint32(wav, at: 24), 16_000)
        XCTAssertEqual(uint16(wav, at: 34), 16)
        XCTAssertEqual(Int16(bitPattern: uint16(wav, at: 44)), -32_767)
        XCTAssertEqual(Int16(bitPattern: uint16(wav, at: 46)), 0)
        XCTAssertEqual(Int16(bitPattern: uint16(wav, at: 48)), 32_767)
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
