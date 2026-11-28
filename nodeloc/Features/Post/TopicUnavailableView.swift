//
//  TopicUnavailableView.swift
//  nodeloc
//
//  主题打不开 (App-iOS-Gone, App-iOS-NoAccess): a full page in place of the
//  reader, driven by what the server answered.
//
//  The mobile API says less than the web's error page: a deleted topic —
//  whoever deleted it — a participants-only one and a topic in a node the
//  reader can't see all come back as one 404 「主题不存在」. So 作者删除,
//  管理员删除 and 只有节点成员能看 can't be told apart here and are not drawn;
//  what is drawn is 不存在 (404), 登录后才能阅读 (login_required), 段位不够
//  (trust_level_too_low), 节点被封禁 (node_banned) and any other refusal.
//

import SwiftUI

struct TopicUnavailableView: View {
    let status: Int
    let code: String?
    let message: String?

    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var trending: [NLTopicSummary] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                mark
                    .padding(.top, 36)
                Text(title)
                    .font(Theme.body(22, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                Text(detail)
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 8)
                    .padding(.horizontal, 8)

                actions
                    .padding(.top, 22)

                if !trending.isEmpty {
                    trendingList
                        .padding(.top, 30)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg.ignoresSafeArea())
        .task { await loadTrending() }
    }

    // MARK: Pieces

    private var mark: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 92, height: 92)
                .background(Theme.chip, in: Circle())
            if status == 404 {
                Text("404")
                    .font(Theme.body(12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Theme.text, in: Capsule())
                    .offset(x: 10, y: -2)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch code {
        case "login_required":
            HStack(spacing: 10) {
                wideButton(AppString("登录"), filled: true) { presentAuth(app) }
                wideButton(AppString("注册"), filled: false) { presentAuth(app, mode: .signup) }
            }
        case "trust_level_too_low":
            VStack(spacing: 10) {
                wideButton(AppString("查看我的升级进度"), filled: true) { app.pushPage(.upgrade) }
                homeButton
            }
        default:
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Theme.textMuted)
                        TextField(AppString("搜索主题标题或关键词"), text: $query)
                            .submitLabel(.search)
                            .onSubmit(search)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .overlay(Capsule().strokeBorder(Theme.textFaint, lineWidth: 1))
                    Button(AppString("搜索"), action: search)
                        .font(Theme.body(15, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 46)
                        .background(Theme.accentFill, in: Capsule())
                        .buttonStyle(.pressable)
                }
                homeButton
            }
        }
    }

    private var homeButton: some View {
        Button {
            goHome()
        } label: {
            Text(AppString("回到首页"))
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(Theme.chip, in: Capsule())
        }
        .buttonStyle(.pressable)
    }

    private func wideButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(15, weight: .bold))
                .foregroundStyle(filled ? Theme.bg : Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(filled ? Theme.text : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(filled ? Color.clear : Theme.textFaint, lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }

    private var trendingList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppString("大家都在看"))
                .font(Theme.body(15, weight: .bold))
                .foregroundStyle(Theme.text)
            VStack(spacing: 0) {
                ForEach(Array(trending.enumerated()), id: \.element.id) { index, topic in
                    if index > 0 { Divider().overlay(Theme.divider) }
                    Button {
                        app.openTopicPage(id: topic.id, nodeSlug: topic.nodeSlug)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(topic.title)
                                    .font(Theme.body(15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(AppString("n/\(topic.nodeSlug) · \(topic.replyCount ?? 0) 条回复"))
                                    .font(Theme.body(12))
                                    .foregroundStyle(Theme.textMuted)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textFaint)
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.divider, lineWidth: 1))
        }
    }

    // MARK: Wording

    private var icon: String {
        switch code {
        case "login_required": "lock"
        case "trust_level_too_low": "lock.shield"
        case "node_banned": "nosign"
        default: status == 404 ? "doc.text.magnifyingglass" : "hand.raised"
        }
    }

    private var title: String {
        switch code {
        case "login_required": AppString("登录后才能阅读这个主题")
        case "trust_level_too_low": AppString("段位不够，暂时看不了")
        case "node_banned": AppString("这个节点已被封禁")
        default: status == 404 ? AppString("这个主题不存在") : AppString("没有权限查看这个主题")
        }
    }

    private var detail: String {
        if status == 404 {
            return AppString("链接可能写错了，或者主题编号已经失效。可以搜一下标题里的关键词。")
        }
        if let message, !message.isEmpty { return message }
        return AppString("你的账号暂时看不了这个主题。")
    }

    // MARK: Actions

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        app.searchInitialQuery = term
        app.pageStack = []
        app.overlay = .search
    }

    private func goHome() {
        app.pageStack = []
        app.overlay = nil
        app.tab = .home
    }

    private func loadTrending() async {
        guard trending.isEmpty else { return }
        let page: NLTopicPage? = try? await DiscourseClient().get(
            "api/v1/topics",
            query: [URLQueryItem(name: "sort", value: "hot"), URLQueryItem(name: "limit", value: "3")]
        )
        trending = Array((page?.topics ?? []).prefix(3))
    }
}
