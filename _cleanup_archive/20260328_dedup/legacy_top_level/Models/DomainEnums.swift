import Foundation

enum InputSourceType: String, Codable, CaseIterable, Identifiable {
    case voice
    case text
    case screenshot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .voice: return "语音"
        case .text: return "文字"
        case .screenshot: return "截图"
        }
    }
}

enum TransactionStatus: String, Codable, CaseIterable {
    case draft
    case confirmed

    var title: String {
        switch self {
        case .draft: return "待确认"
        case .confirmed: return "已入账"
        }
    }
}

enum PaymentChannel: String, Codable, CaseIterable {
    case wechat
    case alipay
    case bankCard
    case cash
    case unknown

    var title: String {
        switch self {
        case .wechat: return "微信"
        case .alipay: return "支付宝"
        case .bankCard: return "银行卡"
        case .cash: return "现金"
        case .unknown: return "未知"
        }
    }
}
