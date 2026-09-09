//
//  LotteryRulesSheet.swift
//  nodeloc
//
//  The official rules for 抽奖, required by App Store guideline 5.3.2:
//  "Official rules for sweepstakes, contests, and raffles must be presented in
//  the app and make clear that Apple is not a sponsor or involved in the
//  activity in any manner."
//
//  Reachable from two places, because a reader has to be able to find them
//  without going through the composer: the composer itself, and every lottery
//  card in a post.
//
//  The wording also does the work of keeping this a points game rather than a
//  raffle with real-world stakes — energy is earned on the site and cannot be
//  bought, and prizes are limited to things that exist on the site. That
//  distinction is what keeps 5.3.4's licensing requirements out of scope.
//

import SwiftUI

struct LotteryRulesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(
                        title: AppString("这是什么"),
                        body: AppString("抽奖是社区成员自己发起的站内活动。发起人设置奖项和开奖时间，其他成员用站内能量购买抽奖票参与，到时间由系统随机开奖。")
                    )

                    section(
                        title: AppString("能量怎么来"),
                        body: AppString("能量只能通过站内活动获得，例如签到、发帖被赞、参与讨论。能量不能用现金购买，也不能兑换成现金或站外权益。")
                    )

                    section(
                        title: AppString("参与规则"),
                        body: AppString("每张抽奖票消耗 1 点能量，开奖后归发起人。发起人可以设置参与门槛（信任等级）、最少和最多参与人数，以及每人最多可买的票数。")
                    )

                    section(
                        title: AppString("流抽与退还"),
                        body: AppString("到开奖时间时参与人数低于发起人设置的最少人数，本次抽奖流抽，所有已消耗的能量原路退还给参与者。")
                    )

                    section(
                        title: AppString("奖品限制"),
                        body: AppString("奖品仅限站内虚拟物品，例如能量、徽章、头衔或社区身份。不得以现金、实物、礼品卡或任何可兑换站外权益的物品作为奖品。违反规则的抽奖可以通过帖子上的举报入口反馈，由管理团队处理。")
                    )

                    section(
                        title: AppString("发起人责任"),
                        body: AppString("抽奖由发起人自行举办并负责，NodeLoc 提供功能与仲裁。参与前请自行判断发起人的信誉。")
                    )

                    // Guideline 5.3.2 requires this, in these terms.
                    VStack(alignment: .leading, spacing: 8) {
                        Label(AppString("与 Apple 无关"), systemImage: "info.circle.fill")
                            .font(Theme.body(14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("Apple 不是本活动的赞助方，也未以任何方式参与本活动。")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.muted(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.divider, lineWidth: 1)
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("抽奖规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(body)
                .font(Theme.body(13))
                .foregroundStyle(Theme.text.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A small "抽奖规则" link. Shared so the composer and the post card open the
/// same sheet rather than each rolling its own entry point.
struct LotteryRulesLink: View {
    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing = true
        } label: {
            Label("抽奖规则", systemImage: "doc.text")
                .font(Theme.body(12, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isShowing) {
            LotteryRulesSheet()
        }
    }
}
