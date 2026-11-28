//
//  TradeAPI.swift
//  nodeloc
//
//  担保交易 on a topic's first post (docs/specs/trade.md). Money is in cents
//  throughout, as the server keeps it.
//

import Foundation

nonisolated struct NLTrade: Decodable, Sendable, Equatable {
    nonisolated struct Offer: Decodable, Sendable, Equatable, Identifiable {
        let id: Int
        let user: String
        let unitPriceCents: Int
        let quantity: Int
        let note: String?
        /// `pending`, `accepted`, `rejected`, `withdrawn`, `declined`.
        let status: String
        let updatedAt: String?
    }
    let id: Int
    let postId: Int?
    let topicId: Int?
    /// `sell` or `buy`.
    let kind: String
    let title: String?
    let owner: String
    let unitPriceCents: Int
    let quantity: Int
    let sold: Int
    let remaining: Int
    let delivery: String?
    /// `open`, `sold_out`, `closed`.
    let status: String
    let feePercent: Int?
    let allowBargain: Bool?
    let bargainPayHours: Int?
    let offers: [Offer]
    /// The reader's own orders on it, when signed in.
    let myOrders: Int?
    /// Which payment channels work right now (`alipay`, `usdt`).
    let payTypes: [String: Bool]?

    var isSell: Bool { kind == "sell" }
    var isOpen: Bool { status == "open" }
}

nonisolated struct NLTradeOrderCreated: Decodable, Sendable {
    nonisolated struct Order: Decodable, Sendable {
        let id: Int
        let amountCents: Int
        let quantity: Int?
        let status: String?
        let paymentNumber: String?
        let payBy: String?
    }
    let order: Order
}

/// What the gateway answered: a page to jump to, or details to show.
nonisolated struct NLPaymentStart: Decodable, Sendable {
    let payType: String?
    let payInfo: String?
}

extension DiscourseClient {
    func postTrade(postID: Int) async throws -> NLTrade {
        struct Envelope: Decodable { let trade: NLTrade }
        let envelope: Envelope = try await get("api/v1/posts/\(postID)/trade")
        return envelope.trade
    }

    /// 下单. The idempotency key keeps a double tap to one order.
    func placeTradeOrder(tradeID: Int, quantity: Int, idempotencyKey: String) async throws -> NLTradeOrderCreated {
        let data = try await send(
            "POST", "api/v1/trades/\(tradeID)/orders",
            json: ["quantity": quantity],
            headers: ["Idempotency-Key": idempotencyKey]
        )
        return try NodelocJSON.decode(NLTradeOrderCreated.self, from: data)
    }

    /// Starts paying an order's 付款单 through `alipay` or `usdt`.
    func startTradePayment(paymentNumber: String, payType: String) async throws -> NLPaymentStart {
        let data = try await send(
            "POST", "api/v1/promo/orders/\(Self.pathEscape(paymentNumber))/pay",
            json: ["pay_type": payType]
        )
        return try NodelocJSON.decode(NLPaymentStart.self, from: data)
    }

    /// 砍价 on a sale, 报价 on a want.
    @discardableResult
    func makeTradeOffer(tradeID: Int, unitPriceCents: Int, quantity: Int, note: String) async throws -> Data {
        try await send("POST", "api/v1/trades/\(tradeID)/offers", json: [
            "unit_price_cents": unitPriceCents,
            "quantity": quantity,
            "note": note,
        ])
    }

    @discardableResult
    func withdrawTradeOffer(offerID: Int) async throws -> Data {
        try await send("DELETE", "api/v1/trade-offers/\(offerID)")
    }

    @discardableResult
    func rejectTradeOffer(offerID: Int) async throws -> Data {
        try await send("POST", "api/v1/trade-offers/\(offerID)/reject")
    }

    /// The owner accepts: a pending order is created for the buyer.
    @discardableResult
    func acceptTradeOffer(offerID: Int, idempotencyKey: String) async throws -> Data {
        try await send("POST", "api/v1/trade-offers/\(offerID)/accept", headers: ["Idempotency-Key": idempotencyKey])
    }

    /// 下架.
    @discardableResult
    func closeTrade(tradeID: Int) async throws -> Data {
        try await send("POST", "api/v1/trades/\(tradeID)/close")
    }
}
