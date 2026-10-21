import XCTest
@testable import MNGCore

final class DetectionDecodingTests: XCTestCase {
    func testDecodesTitleAndSupportFields() throws {
        let json = """
        {"files":[{"path":"/games/AoC.xci","exists":true,"role":"base","titleId":"01002B00111A2000",
                   "game":"Hyrule Warriors: Age of Calamity","supported":false,"reason":"different engine"}],
         "base":"/games/AoC.xci","keys":null,"supported":false,"reason":"different engine"}
        """.data(using: .utf8)!
        let detection = try JSONDecoder().decode(Detection.self, from: json)
        XCTAssertEqual(detection.supported, false)
        XCTAssertEqual(detection.files.first?.titleId, "01002B00111A2000")
        XCTAssertEqual(detection.files.first?.game, "Hyrule Warriors: Age of Calamity")
        XCTAssertNil(detection.keys)
    }

    func testDecodesOlderRepliesWithoutTheNewFields() throws {
        let json = """
        {"files":[{"path":"/games/totk.xci","exists":true,"role":"base","title":"Tears of the Kingdom (game card)"}],
         "base":"/games/totk.xci","keys":"/keys/prod.keys"}
        """.data(using: .utf8)!
        let detection = try JSONDecoder().decode(Detection.self, from: json)
        XCTAssertNil(detection.supported)
        XCTAssertNil(detection.files.first?.titleId)
    }
}
