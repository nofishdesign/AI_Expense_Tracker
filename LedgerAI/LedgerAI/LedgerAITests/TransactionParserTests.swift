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

    func testExtractsSpokenSubjectAsMerchant() {
        let draft = parser.parse(
            text: "今天买猪肉花了231元",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(draft.amountCNY, 231, accuracy: 0.01)
        XCTAssertEqual(draft.merchant, "猪肉")
    }

    func testExtractsSpokenChineseAmountAndSubject() {
        let draft = parser.parse(
            text: "今天买牛奶花了二十三元",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(draft.amountCNY, 23, accuracy: 0.01)
        XCTAssertEqual(draft.merchant, "牛奶")
    }

    func testParsesAlipayScreenshotLikeContent() {
        let raw = """
        账单详情
        牛街清真熟食
        8.00
        交易成功
        支付时间 2026-03-27 10:52:04
        付款方式 支付宝小荷包(别人存钱我们干饭)
        商品说明 扫码付款_牛街清真熟食
        """

        let sanitized = PaymentTextSanitizer.paymentOnlyText(from: raw, source: .screenshot)
        let draft = parser.parse(text: sanitized, occurredAt: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(draft.amountCNY, 8.0, accuracy: 0.01)
        XCTAssertEqual(draft.merchant, "牛街清真熟食")
        XCTAssertEqual(draft.channel, .alipay)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: draft.occurredAt)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 27)
    }

    func testScreenshotSanitizerKeepsStandaloneAmountLine() {
        let raw = """
        账单详情
        牛街清真熟食
        8.00
        交易成功
        """

        let sanitized = PaymentTextSanitizer.paymentOnlyText(from: raw, source: .screenshot)
        XCTAssertTrue(sanitized.contains("8.00"))
    }

    func testParsesMerchantFromAlipayGoodsDescriptionOnNextLine() {
        let text = """
        账单详情
        某某商户
        26.80
        交易成功
        商品说明
        扫码付款_烤肉饭
        """
        let draft = parser.parse(text: text, occurredAt: .now)
        XCTAssertEqual(draft.amountCNY, 26.8, accuracy: 0.01)
        XCTAssertEqual(draft.merchant, "烤肉饭")
    }

    func testExtractsMerchantFromVoicePatternWoZaiXXXXiaoFei() {
        let draft = parser.parse(
            text: "我在三里屯便利店消费了200元",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(draft.amountCNY, 200, accuracy: 0.01)
        XCTAssertEqual(draft.merchant, "三里屯便利店")
    }
}
