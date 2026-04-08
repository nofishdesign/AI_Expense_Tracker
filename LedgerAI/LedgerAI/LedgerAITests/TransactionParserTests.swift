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

    func testParsesLabeledAmountFromScreenshot() {
        let text = """
        支付宝
        账单详情
        支付金额：¥2,300.50
        交易成功
        商品说明
        丽思卡尔顿酒店
        """

        let sanitized = PaymentTextSanitizer.paymentOnlyText(from: text, source: .screenshot)
        let draft = parser.parse(text: sanitized, occurredAt: .now)

        XCTAssertEqual(draft.amountCNY, 2300.5, accuracy: 0.01)
        XCTAssertEqual(draft.merchant, "丽思卡尔顿酒店")
        XCTAssertEqual(draft.channel, .alipay)
    }

    func testParsesMerchantNearAmountWhenMerchantLabelMissing() {
        let text = """
        账单详情
        肯德基上海南京东路店
        31.00
        交易成功
        支付时间 2026-03-29 09:00:00
        """

        let sanitized = PaymentTextSanitizer.paymentOnlyText(from: text, source: .screenshot)
        let draft = parser.parse(text: sanitized, occurredAt: .now)

        XCTAssertEqual(draft.amountCNY, 31.0, accuracy: 0.01)
        XCTAssertEqual(draft.merchant, "肯德基上海南京东路店")
    }

    func testParsesGoodsDescriptionWithEnglishAndSpacedAmount() {
        let text = """
        支付宝
        账单详情
        商品说明 Apple Store Mac mini
        实付款 ¥ 12 999.00
        交易成功
        """

        let sanitized = PaymentTextSanitizer.paymentOnlyText(from: text, source: .screenshot)
        let draft = parser.parse(text: sanitized, occurredAt: .now)

        XCTAssertEqual(draft.amountCNY, 12999.0, accuracy: 0.01)
        XCTAssertEqual(draft.merchant, "Apple Store Mac mini")
    }

    func testParsesWeChatScreenshotWithNegativeHeadlineAmount() {
        let text = """
        北京长楹天街（停车场）
        -37.80
        当前状态 支付成功
        支付时间 2026年3月29日 21:48:24
        商品 北京长楹天街 京ACE7212停车费
        商户全称 北京龙湖长楹园区管理有限公司
        收单机构 上海电银支付有限公司
        支付方式 招商银行信用卡(1072)
        交易单号 4200003047202603297105292886
        商户单号 202603292447659852
        """

        let sanitized = PaymentTextSanitizer.paymentOnlyText(from: text, source: .screenshot)
        let draft = parser.parse(text: sanitized, occurredAt: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(draft.amountCNY, 37.8, accuracy: 0.01)
        XCTAssertEqual(draft.merchant, "北京长楹天街 京ACE7212停车费")
        XCTAssertEqual(draft.channel, .wechat)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: draft.occurredAt)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 29)
    }

    func testScreenshotSanitizerKeepsWeChatCoreFields() {
        let raw = """
        当前状态 支付成功
        商品 北京长楹天街 京ACE7212停车费
        商户全称 北京龙湖长楹园区管理有限公司
        交易单号 4200003047202603297105292886
        """

        let sanitized = PaymentTextSanitizer.paymentOnlyText(from: raw, source: .screenshot)
        XCTAssertTrue(sanitized.contains("商品 北京长楹天街 京ACE7212停车费"))
        XCTAssertTrue(sanitized.contains("交易单号"))
    }

    func testParsesWeChatTopMerchantAndIgnoresOrderNumbers() {
        let text = """
        22:49
        北京长楹天街（停车场）
        -37.80
        当前状态 支付成功
        支付时间 2026年3月29日 21:48:24
        交易单号
        4200003047202603297105292886
        商户单号
        202603292447659852
        """

        let sanitized = PaymentTextSanitizer.paymentOnlyText(from: text, source: .screenshot)
        let draft = parser.parse(text: sanitized, occurredAt: .now)

        XCTAssertEqual(draft.amountCNY, 37.8, accuracy: 0.01)
        XCTAssertEqual(draft.merchant, "北京长楹天街（停车场）")
        XCTAssertEqual(draft.channel, .wechat)
    }
}
