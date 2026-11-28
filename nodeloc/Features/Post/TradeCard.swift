//
//  TradeCard.swift
//  nodeloc
//
//  担保交易 on a topic's first post (App-iOS-PostTrade). A sale: price, stock,
//  delivery, a quantity stepper, 立即购买 and 砍价, and the bargains made on it.
//  A want: the budget, how many are needed, 我来报价 and the offers.
//
//  Every action that spends or commits is behind a confirmation. Buying opens
//  the payment channel the reader picks (支付宝 or USDT) in the browser, which
//  is where the gateway lives; the order itself is kept in 我的交易 until it
//  is paid or expires.
//

import SwiftUI

struct TradeCard: View {
    let trade: NLTrade
    let isOwner: Bool
    let isSignedIn: Bool
    /// Reloads the trade after anything changed it.
    let onChanged: () async -> Void
    let onSignIn: () -> Void
    let onOpenURL: (URL) -> Void

    @State private var quantity = 1
    @State private var confirmingBuy = false
    @State private var offering = false
    @State private var confirmingClose = false
    @State private var busy = false
    @State private var payInfo: String?

    private let client = DiscourseClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            facts
            guarantees
            if trade.isOpen {
                actions
            }
            if !trade.offers.isEmpty {
                offersList
            }
            if (trade.myOrders ?? 0) > 0 {
                Button {
                    if let url = nodelocSiteURL("/trades") { onOpenURL(url) }
                } label: {
                    Label(AppString("你在这里有 \(trade.myOrders ?? 0) 笔订单 · 去我的交易"), systemImage: "list.bullet.rectangle")
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.divider, lineWidth: 1)
        }
        .alert(
            AppString("确认购买"),
            isPresented: $confirmingBuy
        ) {
            ForEach(payChannels, id: \.0) { key, title in
                Button(AppString("用\(title)付 \(Self.yuan(trade.unitPriceCents * quantity))")) { buy(payType: key) }
            }
            Button(AppString("取消"), role: .cancel) {}
        } message: {
            Text(AppString("\(trade.title ?? "") × \(quantity)，合计 \(Self.yuan(trade.unitPriceCents * quantity))。平台代收款，你确认收货后才打给卖家。"))
        }
        .alert(AppString("下架这个交易？"), isPresented: $confirmingClose) {
            Button(AppString("下架"), role: .destructive) { run { try await client.closeTrade(tradeID: trade.id) } }
            Button(AppString("取消"), role: .cancel) {}
        } message: {
            Text(AppString("不再接受新订单和出价，已付款的订单照常走完。"))
        }
        .alert(AppString("用下面的信息付款"), isPresented: Binding(get: { payInfo != nil }, set: { if !$0 { payInfo = nil } })) {
            Button(AppString("知道了"), role: .cancel) { payInfo = nil }
        } message: {
            Text(AppString("\(payInfo ?? "")\n\n付完之后到「我的交易」查看，到账后订单自动变成待发货。"))
        }
        .sheet(isPresented: $offering) {
            TradeOfferSheet(trade: trade) { cents, count, note in
                do {
                    try await client.makeTradeOffer(tradeID: trade.id, unitPriceCents: cents, quantity: count, note: note)
                    ToastCenter.shared.show(trade.isSell ? AppString("已提交砍价，等卖家回复") : AppString("已提交报价"))
                    await onChanged()
                    return true
                } catch {
                    ToastCenter.shared.showError(error)
                    return false
                }
            }
            .formSheet()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.tierChipText)
                .frame(width: 40, height: 40)
                .background(Theme.tierChipFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(trade.isSell ? AppString("出售") : AppString("求购"))
                    .font(Theme.body(16, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(trade.isSell ? AppString("卖家 \(trade.owner)") : AppString("求购人 \(trade.owner)"))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 6)
            Text(statusTitle)
                .font(Theme.body(12, weight: .bold))
                .foregroundStyle(trade.isOpen ? Theme.accent : Theme.textMuted)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(trade.isOpen ? Theme.accent.opacity(0.12) : Theme.chip, in: Capsule())
        }
    }

    private var statusTitle: String {
        switch trade.status {
        case "sold_out": trade.isSell ? AppString("已售完") : AppString("已收齐")
        case "closed": AppString("已下架")
        default: trade.isSell ? AppString("在售") : AppString("求购中")
        }
    }

    // MARK: Facts

    private var facts: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trade.isSell ? AppString("单价") : AppString("预算"))
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                    if trade.isSell || trade.unitPriceCents > 0 {
                        (Text(Self.yuan(trade.unitPriceCents)).font(Theme.heading(26, weight: .bold))
                            + Text(AppString(" / 件")).font(Theme.body(13)).foregroundColor(Theme.textMuted))
                            .foregroundStyle(Theme.text)
                    } else {
                        Text(AppString("不限"))
                            .font(Theme.heading(22, weight: .bold))
                            .foregroundStyle(Theme.text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(trade.isSell ? AppString("库存") : AppString("还需要"))
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                    Text(AppString("\(trade.remaining) 件"))
                        .font(Theme.body(18, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let delivery = trade.delivery, !delivery.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppString("交付方式"))
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                    Text(delivery)
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var guarantees: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(AppString("平台代收款，确认收货后才打给卖家"), systemImage: "checkmark.shield")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                Spacer(minLength: 4)
                if trade.isSell, trade.sold > 0 {
                    Text(AppString("已售 \(trade.sold) 件"))
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            if trade.isSell, trade.allowBargain == true {
                Text(AppString("允许砍价"))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if isOwner {
            Button(role: .destructive) { confirmingClose = true } label: {
                Text(AppString("下架"))
                    .font(Theme.body(14, weight: .bold))
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(Theme.chip, in: Capsule())
            }
            .buttonStyle(.pressable)
            .disabled(busy)
        } else if trade.isSell {
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    stepper
                    if trade.allowBargain == true {
                        smallButton(AppString("砍价")) { guardSignedIn { offering = true } }
                    }
                }
                Button {
                    guardSignedIn { confirmingBuy = true }
                } label: {
                    Text(AppString("立即购买 · \(Self.yuan(trade.unitPriceCents * quantity))"))
                        .font(Theme.body(15, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 46)
                        .background(canPay ? Theme.accentFill : Theme.textFaint, in: Capsule())
                }
                .buttonStyle(.pressable)
                .disabled(!canPay || busy || trade.remaining <= 0)
                if !canPay {
                    Text(AppString("站点的付款渠道暂时不可用"))
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        } else {
            HStack {
                Spacer(minLength: 0)
                smallButton(myPendingOffer == nil ? AppString("我来报价") : AppString("修改报价")) {
                    guardSignedIn { offering = true }
                }
            }
        }
    }

    private var stepper: some View {
        HStack(spacing: 0) {
            Button { quantity = max(1, quantity - 1) } label: {
                Image(systemName: "minus").frame(width: 40, height: 40)
            }
            .disabled(quantity <= 1)
            Text("\(quantity)")
                .font(Theme.body(16, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 28)
            Button { quantity = min(max(trade.remaining, 1), quantity + 1) } label: {
                Image(systemName: "plus").frame(width: 40, height: 40)
            }
            .disabled(quantity >= trade.remaining)
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Theme.text)
        .overlay(Capsule().strokeBorder(Theme.textFaint, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppString("数量 \(quantity)"))
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(14, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(Theme.chip, in: Capsule())
        }
        .buttonStyle(.pressable)
        .disabled(busy)
    }

    // MARK: Offers

    private var offersList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(trade.isSell ? AppString("砍价记录") : AppString("报价"))
                    .font(Theme.body(14, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(AppString("公开"))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.bottom, 6)
            ForEach(trade.offers) { offer in
                Divider().overlay(Theme.divider)
                offerRow(offer)
            }
        }
    }

    private func offerRow(_ offer: NLTrade.Offer) -> some View {
        HStack(spacing: 8) {
            Text(AppString("\(offer.user) 出价 \(Self.yuan(offer.unitPriceCents))"))
                .font(Theme.body(14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if offer.quantity > 1 {
                Text("× \(offer.quantity)")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 6)
            if let at = offer.updatedAt {
                Text(DiscourseFormat.relative(at))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textFaint)
            }
            if offer.status == "pending", isOwner, trade.isOpen {
                Menu {
                    Button(trade.isSell ? AppString("同意") : AppString("选这个")) {
                        run { try await client.acceptTradeOffer(offerID: offer.id, idempotencyKey: UUID().uuidString) }
                    }
                    Button(AppString("拒绝"), role: .destructive) {
                        run { try await client.rejectTradeOffer(offerID: offer.id) }
                    }
                } label: {
                    offerStatus(AppString("回复"), tone: .amber)
                }
            } else if offer.status == "pending", offer.user.lowercased() == DiscourseAuth.shared.username?.lowercased() {
                Menu {
                    Button(AppString("撤回"), role: .destructive) {
                        run { try await client.withdrawTradeOffer(offerID: offer.id) }
                    }
                } label: {
                    offerStatus(AppString("等待回复"), tone: .amber)
                }
            } else {
                offerStatus(offerStatusTitle(offer.status), tone: offer.status == "pending" ? .amber : .neutral)
            }
        }
        .frame(minHeight: 44)
    }

    private func offerStatus(_ title: String, tone: AdminTone) -> some View {
        Text(title)
            .font(Theme.body(12, weight: .bold))
            .foregroundStyle(tone.text)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(tone.fill, in: Capsule())
    }

    private func offerStatusTitle(_ status: String) -> String {
        switch status {
        case "pending": AppString("等待回复")
        case "accepted": AppString("已同意")
        case "rejected", "declined": AppString("已拒绝")
        case "withdrawn": AppString("已撤回")
        default: status
        }
    }

    private var myPendingOffer: NLTrade.Offer? {
        let me = DiscourseAuth.shared.username?.lowercased()
        return trade.offers.first { $0.status == "pending" && $0.user.lowercased() == me }
    }

    // MARK: Buying

    private var payChannels: [(String, String)] {
        [("alipay", AppString("支付宝")), ("usdt", "USDT · TRC20")].filter { trade.payTypes?[$0.0] == true }
    }

    private var canPay: Bool { !payChannels.isEmpty }

    private func buy(payType: String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let created = try await client.placeTradeOrder(tradeID: trade.id, quantity: quantity, idempotencyKey: UUID().uuidString)
                await onChanged()
                guard let number = created.order.paymentNumber else { return }
                let start = try await client.startTradePayment(paymentNumber: number, payType: payType)
                if start.payType == "jump", let info = start.payInfo, let url = URL(string: info) {
                    onOpenURL(url)
                } else if let info = start.payInfo, !info.isEmpty {
                    payInfo = info
                }
            } catch {
                ToastCenter.shared.showError(error)
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Data) {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await work()
                await onChanged()
            } catch {
                ToastCenter.shared.showError(error)
            }
        }
    }

    private func guardSignedIn(_ action: () -> Void) {
        if isSignedIn { action() } else { onSignIn() }
    }

    static func yuan(_ cents: Int) -> String {
        cents % 100 == 0 ? "¥\(cents / 100)" : String(format: "¥%.2f", Double(cents) / 100)
    }
}

/// 砍价 / 报价: a price per item, how many, and a note.
struct TradeOfferSheet: View {
    let trade: NLTrade
    let onSubmit: (Int, Int, String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var price = ""
    @State private var quantity = 1
    @State private var note = ""
    @State private var sending = false

    private var cents: Int? {
        guard let value = Double(price.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return Int((value * 100).rounded())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(AppString("每件出价（元）"), text: $price)
                        .keyboardType(.decimalPad)
                    Stepper(AppString("数量 \(quantity)"), value: $quantity, in: 1...max(trade.remaining, 1))
                } footer: {
                    Text(trade.isSell
                         ? AppString("卖家标价 \(TradeCard.yuan(trade.unitPriceCents)) / 件。卖家同意后生成待付款的订单。")
                         : AppString("报价不能高于预算，数量不能多于还缺的件数。"))
                }
                Section(AppString("说明（可选）")) {
                    TextField(AppString("写给对方的话"), text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle(trade.isSell ? AppString("砍价") : AppString("报价"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppString("取消")) { dismiss() }
                }
                PrimaryToolbarAction(title: AppString("提交"), isEnabled: cents != nil, isWorking: sending) {
                    guard let cents else { return }
                    sending = true
                    Task {
                        if await onSubmit(cents, quantity, note) { dismiss() }
                        sending = false
                    }
                }
            }
        }
    }
}
