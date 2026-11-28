//
//  EnergyTransferSheet.swift
//  nodeloc
//
//  转赠能量 from 能量明细: who, how much, an optional message. Mirrors the web's
//  dialog (static/energy.js): the rule line (fee, per-transfer limits, what is
//  available), quick amounts, the fee spelled out once an amount is valid, and
//  the server's own error under the form.
//
//  `POST /api/v1/points/transfers` `{to, amount, memo}` with an
//  `Idempotency-Key`. The key stays the same while the request is unchanged,
//  so tapping 确认转赠 again after a dropped connection can't send twice.
//

import SwiftUI

struct EnergyTransferSheet: View {
    let rule: NLPointsAccount.TransferRule?
    let balance: Int
    let onSent: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var to = ""
    @State private var amountText = ""
    @State private var memo = ""
    @State private var isSending = false
    @State private var problem: String?
    @State private var attempt: (payload: String, key: String)?

    private var amount: Int? { Int(amountText.trimmingCharacters(in: .whitespaces)) }
    private var feePercent: Int { rule?.feePercent ?? 0 }
    private func fee(_ amount: Int) -> Int { Int((Double(amount * feePercent) / 100).rounded(.up)) }

    /// The web's checks, in its words; nil when the form can go.
    private var amountProblem: String? {
        guard let rule else { return nil }
        guard let amount, amount > 0 else { return nil }
        if amount < rule.min || amount > rule.max {
            return AppString("单笔可转 \(EnergyFormat.grouped(rule.min)) 到 \(EnergyFormat.grouped(rule.max))")
        }
        if amount + fee(amount) > balance {
            return feePercent > 0
                ? AppString("加上手续费超过了当前余额 \(EnergyFormat.grouped(balance))")
                : AppString("超过了当前余额 \(EnergyFormat.grouped(balance))")
        }
        return nil
    }

    private var canSend: Bool {
        !to.trimmingCharacters(in: .whitespaces).isEmpty && (amount ?? 0) > 0 && amountProblem == nil && !isSending && rule != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let rule {
                        Text(ruleLine(rule))
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textMuted)
                    }

                    field(AppString("转给谁")) {
                        TextField(AppString("输入对方的用户名"), text: $to)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        field(AppString("数量")) {
                            TextField(AppString("能量"), text: $amountText)
                                .keyboardType(.numberPad)
                        }
                        HStack(spacing: 8) {
                            ForEach(quickAmounts, id: \.self) { value in
                                Button {
                                    amountText = String(value)
                                } label: {
                                    EnergyFilterChip(title: "\(value)", isSelected: amount == value)
                                }
                                .buttonStyle(.pressable)
                            }
                        }
                        if let amountProblem {
                            Text(amountProblem)
                                .font(Theme.body(12))
                                .foregroundStyle(Theme.danger)
                        } else if let amount, amount > 0, feePercent > 0 {
                            Text(AppString("对方收到 \(EnergyFormat.grouped(amount))，手续费 \(EnergyFormat.grouped(fee(amount)))，一共从你这里扣 \(EnergyFormat.grouped(amount + fee(amount)))。"))
                                .font(Theme.body(12))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }

                    field(AppString("留言（可不填）")) {
                        TextField(AppString("说点什么"), text: $memo)
                    }

                    if let problem {
                        Text(problem)
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.danger)
                    }

                    Button {
                        Task { await send() }
                    } label: {
                        HStack(spacing: 6) {
                            if isSending { ProgressView().controlSize(.mini).tint(Theme.onAccent) }
                            Text(AppString("确认转赠"))
                        }
                    }
                    .buttonStyle(FilledButtonStyle(block: true))
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.5)
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle(AppString("转赠能量"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppString("取消")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var quickAmounts: [Int] {
        [10, 50, 100].filter { value in
            guard let rule else { return false }
            return value >= rule.min && (rule.max == 0 || value <= rule.max)
        }
    }

    private func ruleLine(_ rule: NLPointsAccount.TransferRule) -> String {
        let fee = rule.feePercent > 0
            ? AppString("转赠另收 \(rule.feePercent)% 手续费（由你出），")
            : AppString("转赠不收手续费，")
        return fee + AppString("单笔 \(EnergyFormat.grouped(rule.min))–\(EnergyFormat.grouped(rule.max))。当前可用 \(EnergyFormat.grouped(balance))。")
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Theme.body(13, weight: .bold))
                .foregroundStyle(Theme.text)
            content()
                .font(Theme.body(15))
                .tint(Theme.accent)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.textFaint, lineWidth: 1)
                }
        }
    }

    private func send() async {
        guard canSend, let amount else { return }
        let username = to.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let note = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = "\(username)|\(amount)|\(note)"
        let key = attempt?.payload == payload ? attempt!.key : UUID().uuidString
        attempt = (payload, key)
        isSending = true
        problem = nil
        defer { isSending = false }
        do {
            _ = try await DiscourseClient().transferPoints(to: username, amount: amount, memo: note, idempotencyKey: key)
            ToastCenter.shared.show(AppString("已转给 u/\(username) \(EnergyFormat.grouped(amount)) 能量"))
            onSent()
            dismiss()
        } catch {
            problem = (error as? DiscourseError)?.errorDescription ?? AppString("没有转出去，请稍后再试")
        }
    }
}
