import XCTest
@testable import LedgerAI

final class TransactionParserTests: XCTestCase {
    private let parser = TransactionParser()

    func testParsesAmountAndChannelFromText() {
        let draft = parser.parse(
            text: "微信支付 58.50 元 瑞幸咖啡",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(draft.amountCNY, 58.50, accuracy: 0.01)
        XCTAssertEqual(draft.channel, .wechat)
        XCTAssertTrue(draft.confidence >= 0.8)
    }

    func testFallsBackToLowConfidenceWhenAmountMissing() {
        let draft = parser.parse(
            text: "今天在超市买东西",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(draft.amountCNY, 0, accuracy: 0.01)
        XCTAssertTrue(draft.confidence < 0.8)
    }

    func testParsesMonthDayDate() {
        let fallback = Date(timeIntervalSince1970: 1_700_000_000)
        let draft = parser.parse(text: "3月15日 支付宝支付 20 元", occurredAt: fallback)

        let comps = Calendar.current.dateComponents([.month, .day], from: draft.occurredAt)
        XCTAssertEqual(comps.month, 3)
        XCTAssertEqual(comps.day, 15)
    }
}
