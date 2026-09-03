import Foundation

enum PromotionFilter {
    static func shouldSkipBeforeSummarization(_ message: MailMessage) -> Bool {
        let headers = message.headers.reduce(into: [String: String]()) { result, entry in
            let key = entry.key.lowercased()
            if result[key] == nil {
                result[key] = entry.value.lowercased()
            }
        }

        if headers["x-maildigest-category"] == "promotions" {
            return true
        }

        let hasBulkMarker = headers["list-unsubscribe"] != nil
            || headers["list-id"] != nil
            || ["bulk", "list"].contains(headers["precedence"] ?? "")
        guard hasBulkMarker else { return false }

        let explicitMarketingHeader = [
            headers["x-campaign"],
            headers["x-campaign-id"],
            headers["x-mailgun-tag"],
            headers["x-sg-eid"]
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        let visibleText = "\(message.subject) \(message.sender) \(message.bodyText.prefix(2_000))"
            .lowercased()
        return containsCommercialLanguage(visibleText)
            || containsCommercialLanguage(explicitMarketingHeader)
    }

    static func shouldDiscard(_ actions: [SummarizedAction]) -> Bool {
        actions.contains { $0.mailType == .promotion }
    }

    private static func containsCommercialLanguage(_ value: String) -> Bool {
        let phrases = [
            "sale", "discount", "% off", "special offer", "limited-time offer",
            "limited time offer", "promo code", "coupon", "shop now", "buy now",
            "clearance", "exclusive offer", "member offer", "new arrivals",
            "促销", "折扣", "优惠", "特价", "限时", "优惠券", "领券",
            "立即购买", "马上购买", "新品", "会员专享", "专属优惠"
        ]
        return phrases.contains { value.contains($0) }
    }
}
