import XCTest
@testable import WhaleCore

final class DialogueCSVTests: XCTestCase {
    func testQuotedUnicodeNewlinesAndBOMRoundTrip() throws {
        let lines = ["你好🐋", "逗号,引号\"都可以", "第一行\n第二行"]
        XCTAssertEqual(try DialogueCSV.decode(DialogueCSV.encode(lines)), lines)
        XCTAssertEqual(try DialogueCSV.decode("\u{FEFF}text\r\n你好\r\n\r\n你好\r\n再见\r\n"), ["你好", "再见"])
        XCTAssertEqual(try DialogueCSV.decode("不用表头\n第二句"), ["不用表头", "第二句"])
    }
    func testRejectsTruncatedQuotesMultipleColumnsAndEmptyContent() {
        for text in ["", "气泡文案\n\n", "\"没有结束", "气泡文案\n未引用,逗号", "\"好\"尾巴", "坏\"引号"] {
            XCTAssertThrowsError(try DialogueCSV.decode(text))
        }
    }
}
